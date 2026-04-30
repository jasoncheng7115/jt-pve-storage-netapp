package PVE::Storage::Custom::NetAppONTAPPlugin;

use strict;
use warnings;

use base qw(PVE::Storage::Plugin);

use JSON;
use PVE::Tools qw(run_command);
use PVE::JSONSchema qw(get_standard_option);
use Fcntl qw(:flock);
use POSIX qw();
use PVE::Cluster qw(cfs_read_file);
use PVE::ProcFSTools;

use PVE::Storage::Custom::NetAppONTAP::API;
use PVE::Storage::Custom::NetAppONTAP::Naming qw(
    encode_volume_name
    decode_volume_name
    encode_lun_path
    encode_snapshot_name
    decode_snapshot_name
    encode_igroup_name
    pve_volname_to_ontap
    ontap_to_pve_volname
    is_pve_managed_volume
);
use PVE::Storage::Custom::NetAppONTAP::ISCSI qw(
    get_initiator_name
    discover_targets
    login_target
    logout_target
    rescan_sessions
    is_portal_logged_in
    wait_for_device
);
use PVE::Storage::Custom::NetAppONTAP::Multipath qw(
    rescan_scsi_hosts
    multipath_reload
    get_multipath_device
    get_device_by_wwid
    get_scsi_devices_by_serial
    get_multipath_slaves
    remove_scsi_device
    rescan_scsi_device
    wait_for_multipath_device
    cleanup_lun_devices
    is_device_in_use
    get_device_usage_details
    sysfs_read_with_timeout
    list_netapp_multipath_devices
);
use File::Basename qw(basename);
use PVE::Storage::Custom::NetAppONTAP::FC qw(
    get_fc_wwpns
    is_fc_available
    rescan_fc_hosts
);

# Plugin API version - bump for compatibility
use constant APIVERSION => 13;
use constant MIN_APIVERSION => 9;

# Mark as shared storage (accessible from multiple nodes)
push @PVE::Storage::Plugin::SHARED_STORAGE, 'netappontap';

#
# Plugin registration
#

sub api {
    return APIVERSION;
}

sub type {
    return 'netappontap';
}

sub plugindata {
    return {
        content => [
            { images => 1, rootdir => 1 },
            { images => 1 },
        ],
        format => [
            { raw => 1 },
            'raw',
        ],
    };
}

sub properties {
    return {
        'ontap-portal' => {
            description => "NetApp ONTAP management IP address or hostname.",
            type => 'string',
        },
        'ontap-svm' => {
            description => "Storage Virtual Machine (SVM/Vserver) name.",
            type => 'string',
        },
        'ontap-aggregate' => {
            description => "Aggregate name for volume creation.",
            type => 'string',
        },
        'ontap-username' => {
            description => "API username for ONTAP REST API.",
            type => 'string',
        },
        'ontap-password' => {
            description => "API password for ONTAP REST API.",
            type => 'string',
        },
        'ontap-ssl-verify' => {
            description => "Verify SSL certificate.",
            type => 'boolean',
            default => 1,
        },
        'ontap-thin' => {
            description => "Use thin provisioning for volumes.",
            type => 'boolean',
            default => 1,
        },
        'ontap-igroup-mode' => {
            description => "igroup mode: 'per-node' or 'shared'.",
            type => 'string',
            enum => ['per-node', 'shared'],
            default => 'per-node',
        },
        'ontap-cluster-name' => {
            description => "PVE cluster name for igroup naming.",
            type => 'string',
            optional => 1,
        },
        'ontap-protocol' => {
            description => "SAN protocol: 'iscsi' or 'fc' (Fibre Channel).",
            type => 'string',
            enum => ['iscsi', 'fc'],
            default => 'iscsi',
        },
        'ontap-device-timeout' => {
            description => "Timeout in seconds for device discovery after LUN mapping.",
            type => 'integer',
            minimum => 10,
            maximum => 300,
            default => 60,
        },
    };
}

sub options {
    return {
        'ontap-portal'       => { fixed => 1 },
        'ontap-svm'          => { fixed => 1 },
        'ontap-aggregate'    => { fixed => 1 },
        'ontap-username'     => { fixed => 1 },
        'ontap-password'     => { fixed => 1 },
        'ontap-ssl-verify'   => { optional => 1 },
        'ontap-thin'         => { optional => 1 },
        'ontap-igroup-mode'  => { optional => 1 },
        'ontap-cluster-name' => { optional => 1 },
        'ontap-protocol'     => { optional => 1 },
        'ontap-device-timeout' => { optional => 1 },
        nodes                => { optional => 1 },
        disable              => { optional => 1 },
        content              => { optional => 1 },
        shared               => { optional => 1 },
    };
}

#
# Helper methods
#

# Get API client instance (cached per storage config)
my %api_cache;
use constant API_CACHE_TTL => 300;  # 5 minutes cache TTL

# Temporary FlexClone state tracking
my $TEMP_CLONE_STATE_FILE = '/var/run/pve-storage-netapp-temp-clones.json';
my $TEMP_CLONE_LOCK_FILE = '/var/run/pve-storage-netapp-temp-clones.lock';
my $TEMP_CLONE_MAX_AGE = 3600;  # 1 hour - cleanup clones older than this

# WWID tracking for orphan device cleanup
# Tracks WWIDs that this node has seen as belonging to this storage.
# Persisted across reboots so we can clean up orphans even after node restart.
my $WWID_STATE_DIR = '/var/lib/pve-storage-netapp';
my $WWID_LOCK_DIR  = '/var/run/pve-storage-netapp';

# Translate ONTAP API errors about resource limits into actionable messages.
# ONTAP raw errors often look like:
#   "POST /api/storage/volumes failed: 917927: Cannot create volume 'pve_xxx'.
#    Reason: Maximum number of volumes is reached on Vserver 'svm0'."
# These messages are technically correct but cluttered. The translation here
# matches common limit-reached patterns and prepends a one-line operator-
# friendly summary so the cause is obvious in the PVE task log.
#
# Returns the friendly message (with the original error appended) if a known
# limit pattern matches, or the original error unchanged otherwise.
sub _translate_limit_error {
    my ($err, $context) = @_;
    return $err unless defined $err;
    $context //= 'operation';

    # FlexVol count limit (per-SVM or per-node FlexVol cap)
    if ($err =~ /maximum number of volumes/i ||
        $err =~ /volume.*limit.*reached/i ||
        $err =~ /too many volumes/i) {
        return "ONTAP FlexVol limit reached on this SVM/node. " .
               "This plugin uses 1 FlexVol per VM disk; you may have hit " .
               "the SVM volume cap (default ~12000) or the per-node cap " .
               "(default 1000 on entry-level systems). " .
               "Ask your ONTAP admin to check 'volume show -vserver <svm>' " .
               "count and either delete unused volumes or move to a node " .
               "with capacity. Original error: $err";
    }

    # SVM/cluster LUN count limit
    if ($err =~ /maximum number of LUNs/i ||
        $err =~ /LUN.*limit.*reached/i ||
        $err =~ /too many LUNs/i) {
        return "ONTAP LUN limit reached on this SVM/cluster. " .
               "Each VM disk creates one LUN; you may have hit the SVM LUN " .
               "cap. Ask your ONTAP admin to check 'lun show -vserver <svm>' " .
               "count and clean up unused LUNs, or contact NetApp support " .
               "about raising the limit. Original error: $err";
    }

    # igroup LUN-map count limit (per-igroup LUN map cap, default 4096)
    if ($err =~ /maximum number of LUN map/i ||
        $err =~ /LUN map.*limit/i ||
        $err =~ /too many LUN maps/i) {
        return "ONTAP LUN-map limit reached on the target igroup. " .
               "Default cap is 4096 LUN maps per igroup. In per-node mode " .
               "this plugin maps each LUN to every node igroup, so you may " .
               "have ~4000 VM disks already. Consider switching to shared " .
               "igroup mode (ontap-igroup-mode shared) or contact NetApp " .
               "support to raise the limit. Original error: $err";
    }

    # Aggregate full (mostly caught by alloc_image pre-check, but thin
    # overcommit can still hit this on volume_create or lun_create)
    if ($err =~ /no space|insufficient space|aggregate.*full/i ||
        $err =~ /not enough space.*aggregate/i) {
        return "ONTAP aggregate is out of space. " .
               "If using thin provisioning, the aggregate has overcommitted " .
               "and there is no physical space left. Either delete unused " .
               "volumes/snapshots, expand the aggregate, or switch new " .
               "allocations to a different aggregate. Original error: $err";
    }

    # SVM-level quota / hard limit
    if ($err =~ /quota.*exceed/i || $err =~ /vserver.*limit/i) {
        return "ONTAP SVM quota or limit exceeded for this $context. " .
               "Ask your ONTAP admin to check the SVM resource limits " .
               "('vserver show -vserver <svm>'). Original error: $err";
    }

    return $err;
}

sub _get_api {
    my ($scfg) = @_;

    my $storeid = $scfg->{storage} // $scfg->{'ontap-portal'} // 'unknown';

    # Return cached client if available, config hasn't changed, and cache is fresh
    if (my $cached = $api_cache{$storeid}) {
        my $cache_age = time() - ($cached->{timestamp} // 0);
        if ($cache_age < API_CACHE_TTL &&
            $cached->{host} eq $scfg->{'ontap-portal'} &&
            $cached->{svm} eq $scfg->{'ontap-svm'}) {
            return $cached->{api};
        }
    }

    my $ssl_verify = $scfg->{'ontap-ssl-verify'} // 1;

    my $api = PVE::Storage::Custom::NetAppONTAP::API->new(
        host       => $scfg->{'ontap-portal'},
        username   => $scfg->{'ontap-username'},
        password   => $scfg->{'ontap-password'},
        svm        => $scfg->{'ontap-svm'},
        aggregate  => $scfg->{'ontap-aggregate'},
        ssl_verify => $ssl_verify,
    );

    $api_cache{$storeid} = {
        api       => $api,
        host      => $scfg->{'ontap-portal'},
        svm       => $scfg->{'ontap-svm'},
        timestamp => time(),
    };

    return $api;
}

# Get igroup name for current node
sub _get_igroup_name {
    my ($scfg) = @_;

    my $cluster_name = $scfg->{'ontap-cluster-name'} // 'pve';
    my $mode = $scfg->{'ontap-igroup-mode'} // 'per-node';

    if ($mode eq 'shared') {
        return encode_igroup_name($cluster_name, undef);
    } else {
        my $nodename = PVE::INotify::nodename();
        return encode_igroup_name($cluster_name, $nodename);
    }
}

# Get initiators based on protocol (iSCSI IQN or FC WWPN)
sub _get_initiators {
    my ($scfg) = @_;

    my $protocol = $scfg->{'ontap-protocol'} // 'iscsi';

    if ($protocol eq 'fc') {
        my $wwpns = get_fc_wwpns(online_only => 1);
        die "No FC HBA WWPNs found on this node. Is FC HBA installed and online?" unless @$wwpns;
        return @$wwpns;
    } else {
        return (get_initiator_name());
    }
}

# Get ONTAP igroup protocol name
sub _get_ontap_protocol {
    my ($scfg) = @_;

    my $protocol = $scfg->{'ontap-protocol'} // 'iscsi';
    return $protocol eq 'fc' ? 'fcp' : 'iscsi';
}

# Ensure igroup exists and has current node's initiator
sub _ensure_igroup {
    my ($scfg, $api) = @_;

    my $igroup_name = _get_igroup_name($scfg);
    my @initiators = _get_initiators($scfg);
    my $ontap_protocol = _get_ontap_protocol($scfg);

    my $igroup = eval {
        $api->igroup_get_or_create(
            name       => $igroup_name,
            protocol   => $ontap_protocol,
            os_type    => 'linux',
            initiators => \@initiators,
        );
    };
    if ($@ && !$igroup) {
        # Handle race condition when multiple nodes create igroup simultaneously
        $igroup = $api->igroup_get($igroup_name);
        die "Failed to create or get igroup '$igroup_name': $@" unless $igroup;
    }

    # Verify all initiators are in igroup
    my %existing_initiators;
    if ($igroup->{initiators}) {
        for my $init (@{$igroup->{initiators}}) {
            $existing_initiators{lc($init->{name})} = 1;
        }
    }

    # Add missing initiators (ignore "already exists" errors from concurrent adds)
    for my $initiator (@initiators) {
        unless ($existing_initiators{lc($initiator)}) {
            eval { $api->igroup_add_initiator($igroup_name, $initiator); };
            warn "Failed to add initiator $initiator to igroup: $@\n"
                if $@ && $@ !~ /already exists|duplicate|entry.*exists/i;
        }
    }

    return $igroup_name;
}

# Parse PVE volname to components
sub _parse_volname {
    my ($volname) = @_;

    # Format: images/vm-100-disk-0 or vm-100-disk-0 or base-100-disk-0
    $volname =~ s|^images/||;

    # VM disk: vm-100-disk-0
    if ($volname =~ /^vm-(\d+)-disk-(\d+)$/) {
        return {
            vmid   => $1,
            diskid => $2,
            format => 'raw',
            type   => 'disk',
            isBase => 0,
        };
    # Template base disk: base-100-disk-0
    } elsif ($volname =~ /^base-(\d+)-disk-(\d+)$/) {
        return {
            vmid   => $1,
            diskid => $2,
            format => 'raw',
            type   => 'disk',
            isBase => 1,
        };
    # Cloud-init: vm-100-cloudinit
    } elsif ($volname =~ /^vm-(\d+)-cloudinit$/) {
        return {
            vmid   => $1,
            format => 'raw',
            type   => 'cloudinit',
            isBase => 0,
        };
    # VM state: vm-100-state-snapname
    } elsif ($volname =~ /^vm-(\d+)-state-(.+)$/) {
        return {
            vmid     => $1,
            snapname => $2,
            format   => 'raw',
            type     => 'state',
            isBase   => 0,
        };
    }

    return undef;
}

# Get next available disk ID for a VM
sub _find_free_diskid {
    my ($scfg, $storeid, $vmid) = @_;

    my $api = _get_api($scfg);

    # List existing volumes for this VM
    my $prefix = pve_volname_to_ontap($storeid, "vm-${vmid}-disk-0");
    $prefix =~ s/_disk\d+$/_disk/;

    my $volumes = $api->volume_list("${prefix}*");

    my %used_ids;
    for my $vol (@$volumes) {
        my $decoded = decode_volume_name($vol->{name});
        if ($decoded && $decoded->{vmid} == $vmid && defined $decoded->{diskid}) {
            $used_ids{$decoded->{diskid}} = 1;
        }
    }

    # Find first unused ID
    for (my $id = 0; $id < 1000; $id++) {
        return $id unless $used_ids{$id};
    }

    die "No free disk ID found for VM $vmid";
}

#
# Storage operations
#

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    # Verify ONTAP connectivity. If this fails (network down, API down,
    # auth changed), record the failure so monitoring systems are alerted.
    # We re-throw the error after recording so PVE behavior is unchanged.
    my $api = eval { _get_api($scfg); };
    if (!$api || $@) {
        my $err = $@ || "API client not available";
        _record_status_failure($storeid, "activate_storage: API connection failed: $err");
        die $err;
    }

    eval { $api->get_svm_uuid(); };
    if ($@) {
        my $err = $@;
        _record_status_failure($storeid, "activate_storage: SVM lookup failed: $err");
        die $err;
    }

    # Verify aggregate exists and is available
    my $aggregate = $scfg->{'ontap-aggregate'};
    my $aggr_info = eval { $api->aggregate_get($aggregate); };
    if ($@) {
        my $err = $@;
        _record_status_failure($storeid, "activate_storage: aggregate query failed: $err");
        die $err;
    }
    unless ($aggr_info) {
        die "Aggregate '$aggregate' not found on ONTAP cluster. " .
            "Please verify the aggregate name in storage configuration.";
    }

    my $protocol = $scfg->{'ontap-protocol'} // 'iscsi';

    if ($protocol eq 'fc') {
        # FC: Verify FC HBA is available
        unless (is_fc_available()) {
            die "FC protocol selected but no FC HBA found on this node. " .
                "Please install FC HBA or use 'ontap-protocol iscsi'.";
        }

        # FC: Rescan for any existing LUNs
        rescan_fc_hosts(delay => 1);

    } else {
        # iSCSI: Get portals and login
        my $portals = $api->iscsi_get_portals();
        die "No iSCSI portals found on SVM $scfg->{'ontap-svm'}" unless @$portals;

        # Discover and login to targets
        my $portal_success = 0;
        for my $portal (@$portals) {
            my $portal_addr = "$portal->{address}:$portal->{port}";
            # Skip discovery if already logged in to this portal
            if (is_portal_logged_in($portal_addr, $portal->{target})) {
                $portal_success++;
                next;
            }
            eval {
                discover_targets($portal->{address}, port => $portal->{port});
                login_target($portal->{address}, $portal->{target}, port => $portal->{port});
                $portal_success++;
            };
            # Continue on error - some portals might not be reachable
            warn "Failed to connect to portal $portal->{address}: $@" if $@;
        }
        die "Failed to connect to any iSCSI portal on SVM '$scfg->{'ontap-svm'}'. " .
            "Check network connectivity and iSCSI LIF configuration." unless $portal_success;
    }

    # Ensure igroup exists (common for both protocols)
    _ensure_igroup($scfg, $api);

    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    # Cleanup iSCSI sessions and multipath devices for this storage
    # This is called when storage is disabled or removed

    warn "Deactivating storage '$storeid': cleaning up connections...\n";

    my $protocol = $scfg->{'ontap-protocol'} // 'iscsi';
    my $cleanup_count = 0;
    my $skip_count = 0;

    # Step 1: Force cleanup temporary FlexClones for this storage (from state file)
    # This works even if ONTAP is unreachable - we just clear the local state
    eval { _cleanup_temp_clones_for_storage($storeid); };
    warn "Temp FlexClone state cleanup: $@\n" if $@;

    # Step 2: Try to connect to ONTAP API
    my $api = eval { _get_api($scfg); };
    if (!$api) {
        warn "WARNING: Cannot connect to ONTAP API.\n";
        warn "  - Local multipath devices cannot be identified for cleanup.\n";
        warn "  - Manual cleanup may be required per-device: multipath -f <wwid>\n";
        warn "  - DO NOT use 'multipath -F' (capital F) -- it flushes ALL maps.\n";
        warn "  - iSCSI sessions not logged out.\n";
        multipath_reload();
        return 1;
    }

    # Step 3: Get all volumes for this storage and cleanup their devices
    my $san_storeid = $storeid;
    $san_storeid =~ s/-/_/g;
    my $prefix = "pve_${san_storeid}_*";
    my $volumes = eval { $api->volume_list($prefix); } // [];

    warn "Found " . scalar(@$volumes) . " volumes for storage '$storeid'\n" if @$volumes;

    # Cleanup each volume's device
    for my $vol (@$volumes) {
        my $lun_path = encode_lun_path($vol->{name});
        my $wwid = eval { $api->lun_get_wwid($lun_path); };
        next unless $wwid;

        my $device = get_device_by_wwid($wwid);
        if ($device && -b $device) {
            # Check if device is in use
            if (is_device_in_use($device)) {
                warn "  [SKIP] $vol->{name}: device $device still in use\n";
                $skip_count++;
                next;
            }

            # Flush and cleanup (with timeout to prevent hang on unresponsive storage)
            eval {
                eval { run_command(['/bin/sync'], timeout => 10); };
                warn "sync timed out: $@" if $@;
                eval { run_command(['/sbin/blockdev', '--flushbufs', $device], timeout => 10); };
                warn "blockdev --flushbufs timed out: $@" if $@;
                cleanup_lun_devices($wwid);
                warn "  [OK] $vol->{name}: device cleaned up\n";
                $cleanup_count++;
            };
            if ($@) {
                warn "  [FAIL] $vol->{name}: $@\n";
            }
        }
    }

    # Step 4: For iSCSI - logout from this SVM's targets
    if ($protocol eq 'iscsi') {
        my $portals = eval { $api->iscsi_get_portals(); } // [];
        for my $portal (@$portals) {
            eval {
                logout_target($portal->{address}, $portal->{target}, port => $portal->{port});
                warn "  [OK] Logged out from iSCSI target: $portal->{address}\n";
            };
            # Ignore logout errors - target might already be logged out
        }
    }

    # Step 5: Reload multipath to reflect changes
    multipath_reload();

    warn "Storage '$storeid' deactivated: $cleanup_count devices cleaned, $skip_count skipped (in use)\n";
    return 1;
}

# File locking for temp clone state
sub _with_temp_clone_lock {
    my ($code) = @_;
    open(my $lock_fh, '>', $TEMP_CLONE_LOCK_FILE) or do {
        warn "Cannot open lock file $TEMP_CLONE_LOCK_FILE: $!\n";
        return $code->();
    };
    # Use non-blocking lock with retry to prevent indefinite hang
    my $lock_timeout = 10;
    my $lock_start = time();
    my $locked = 0;
    while (time() - $lock_start < $lock_timeout) {
        if (flock($lock_fh, LOCK_EX | LOCK_NB)) {
            $locked = 1;
            last;
        }
        select(undef, undef, undef, 0.1);
    }
    unless ($locked) {
        warn "Cannot acquire lock on $TEMP_CLONE_LOCK_FILE within ${lock_timeout}s, proceeding without lock\n";
        close($lock_fh);
        return $code->();
    }
    my $result = eval { $code->() };
    my $err = $@;
    flock($lock_fh, LOCK_UN);
    close($lock_fh);
    die $err if $err;
    return $result;
}

sub _read_temp_clone_state {
    return {} unless -f $TEMP_CLONE_STATE_FILE;
    my $json = do { local $/; open my $fh, '<', $TEMP_CLONE_STATE_FILE or return {}; <$fh> };
    return eval { JSON::decode_json($json) } // {};
}

sub _write_temp_clone_state {
    my ($state) = @_;
    open my $fh, '>', $TEMP_CLONE_STATE_FILE or do {
        warn "Cannot write temp clone state: $!\n";
        return;
    };
    print $fh JSON::encode_json($state);
    close $fh;
}

# Force cleanup temp FlexClones for a specific storage (clear local state)
sub _cleanup_temp_clones_for_storage {
    my ($storeid) = @_;

    _with_temp_clone_lock(sub {
        my $state = _read_temp_clone_state();
        if (exists $state->{$storeid}) {
            my $count = scalar(keys %{$state->{$storeid}});
            delete $state->{$storeid};
            _write_temp_clone_state($state);
            warn "Cleared $count temp FlexClone entries for storage '$storeid'\n" if $count;
        }
    });
}

#
# WWID tracking for cluster-wide orphan device cleanup
#
# Each node maintains a state file per storage listing WWIDs it has seen.
# When a LUN is deleted on one node, other nodes detect orphans by comparing
# their tracked WWIDs against the current ONTAP LUN list.
# Only WWIDs in the tracking file are eligible for cleanup, ensuring we never
# touch devices that don't belong to this plugin.
#

sub _wwid_state_file {
    my ($storeid) = @_;
    my $safe_storeid = $storeid;
    $safe_storeid =~ s/[^a-zA-Z0-9_-]/_/g;
    return "$WWID_STATE_DIR/${safe_storeid}-wwids.json";
}

sub _wwid_lock_file {
    my ($storeid) = @_;
    my $safe_storeid = $storeid;
    $safe_storeid =~ s/[^a-zA-Z0-9_-]/_/g;
    return "$WWID_LOCK_DIR/${safe_storeid}-wwids.lock";
}

sub _ensure_wwid_state_dir {
    # /var/lib persists across reboots
    if (! -d $WWID_STATE_DIR) {
        unless (mkdir $WWID_STATE_DIR, 0700) {
            warn "Cannot create $WWID_STATE_DIR: $!\n" unless -d $WWID_STATE_DIR;
        }
    }
    # /var/run is tmpfs, gets wiped on reboot, so always check/recreate
    if (! -d $WWID_LOCK_DIR) {
        unless (mkdir $WWID_LOCK_DIR, 0700) {
            warn "Cannot create $WWID_LOCK_DIR: $!\n" unless -d $WWID_LOCK_DIR;
        }
    }
}

# Acquire exclusive lock on WWID state file to serialize concurrent
# read-modify-write operations from multiple PVE workers.
sub _with_wwid_lock {
    my ($storeid, $code) = @_;
    _ensure_wwid_state_dir();
    my $lock_file = _wwid_lock_file($storeid);
    open(my $lock_fh, '>', $lock_file) or do {
        warn "Cannot open WWID lock file $lock_file: $!\n";
        return $code->();
    };

    # Non-blocking flock with retry, max 10s
    my $deadline = time() + 10;
    my $locked = 0;
    while (time() < $deadline) {
        if (flock($lock_fh, LOCK_EX | LOCK_NB)) {
            $locked = 1;
            last;
        }
        select(undef, undef, undef, 0.1);
    }
    unless ($locked) {
        warn "Cannot acquire WWID lock for $storeid within 10s, proceeding without lock\n";
        close($lock_fh);
        return $code->();
    }

    my $result = eval { $code->() };
    my $err = $@;
    flock($lock_fh, LOCK_UN);
    close($lock_fh);
    die $err if $err;
    return $result;
}

sub _read_wwid_state {
    my ($storeid) = @_;
    my $file = _wwid_state_file($storeid);
    return {} unless -f $file;
    my $json = do { local $/; open my $fh, '<', $file or return {}; <$fh> };
    return eval { JSON::decode_json($json) } // {};
}

sub _write_wwid_state {
    my ($storeid, $state) = @_;
    _ensure_wwid_state_dir();
    my $file = _wwid_state_file($storeid);
    # Atomic write: write to temp file then rename
    my $tmp = "$file.tmp.$$";
    open my $fh, '>', $tmp or do {
        warn "Cannot write WWID state file $tmp: $!\n";
        return;
    };
    print $fh JSON::encode_json($state);
    close $fh;
    rename($tmp, $file) or warn "Cannot rename $tmp -> $file: $!\n";
}

sub _track_wwid {
    my ($storeid, $wwid) = @_;
    return unless $wwid;
    _with_wwid_lock($storeid, sub {
        my $state = _read_wwid_state($storeid);
        return if $state->{lc($wwid)};  # already tracked
        $state->{lc($wwid)} = time();
        _write_wwid_state($storeid, $state);
    });
}

sub _untrack_wwid {
    my ($storeid, $wwid) = @_;
    return unless $wwid;
    _with_wwid_lock($storeid, sub {
        my $state = _read_wwid_state($storeid);
        if (delete $state->{lc($wwid)}) {
            _write_wwid_state($storeid, $state);
        }
    });
}

# Find and clean up orphaned multipath devices on this node.
#
# Two-phase strategy (v0.2.3):
#
# Phase 1 (auto-import): Query ONTAP for current pve_* LUN WWIDs and add them
# to the tracking file. This ensures all cluster nodes converge to the same
# "alive set" over time, even if path() was never called on this node.
#
# Phase 2 (cleanup): Scan local NETAPP multipath devices. For each one:
#   - WWID is in alive set (currently on ONTAP) → leave alone (it's valid)
#   - WWID NOT in alive set + IS in tracking file → orphan we own, clean it
#   - WWID NOT in alive set + NOT in tracking file → unknown (could be manual
#     storage, customer's other NetApp, etc.) → leave alone for safety
#
# Safety guarantees:
#   - Never touches devices from other SVMs / other ONTAP clusters
#   - Never touches manually-managed devices with custom aliases
#   - If ONTAP API is unreachable, abort entirely (no false positives)
#   - All operations bounded by timeout (won't hang)
sub _cleanup_orphaned_devices {
    my ($api, $storeid) = @_;

    # Phase 1: Query ONTAP for currently alive pve_* LUNs in this storage
    my $san_storage = $storeid;
    $san_storage =~ s/-/_/g;
    my $luns = eval { $api->lun_list("/vol/pve_${san_storage}_*/lun0"); };
    if ($@ || !defined $luns) {
        # API error - abort to avoid false positives
        warn "Orphan cleanup: failed to query ONTAP LUN list: $@\n" if $@;
        return;
    }

    # Build set of currently-alive WWIDs and auto-import them into tracking
    my %alive_wwids;
    for my $lun (@$luns) {
        my $wwid = eval { $api->lun_get_wwid($lun->{name}); };
        next unless $wwid;
        $alive_wwids{lc($wwid)} = 1;
        # Auto-import: ensure this WWID is tracked even if path() was never
        # called on this node. _track_wwid is idempotent (no-op if already tracked).
        eval { _track_wwid($storeid, $wwid); };
    }

    # Read tracked WWIDs AFTER auto-import
    my $tracked = _read_wwid_state($storeid);

    # Phase 2: Find orphans = tracked WWIDs that are no longer on ONTAP
    my $cleaned = 0;
    for my $wwid (keys %$tracked) {
        next if $alive_wwids{$wwid};

        # WWID is no longer on ONTAP. Check if there's a local multipath device
        # to clean up. cleanup_lun_devices is idempotent and safe.
        my $mpath = get_multipath_device($wwid);
        if ($mpath) {
            warn "Orphan cleanup: removing stale device for WWID $wwid (LUN deleted on ONTAP)\n";
            eval { cleanup_lun_devices($wwid); };
            warn "Orphan cleanup error for $wwid: $@\n" if $@;
        }

        # Only untrack if local cleanup actually succeeded (multipath device
        # gone). If device still exists, keep tracked so next status() poll
        # retries cleanup. Mirrors free_image() conditional untrack logic.
        my $still_exists = get_multipath_device($wwid);
        if ($still_exists) {
            warn "Orphan cleanup: device for WWID $wwid still exists after cleanup, " .
                 "keeping tracked for retry.\n";
        } else {
            _untrack_wwid($storeid, $wwid);
        }
        $cleaned++;
    }

    warn "Orphan cleanup: processed $cleaned stale WWID(s) for storage '$storeid'\n"
        if $cleaned > 0;

    # Second-pass: detect UNTRACKED stale NETAPP multipath devices and warn.
    # These could be pre-upgrade leftovers OR customer's manual storage that
    # happens to be in failed state. We do NOT auto-clean to avoid touching
    # customer's manual storage. Instead we list them with cleanup commands.
    eval {
        my $netapp_devs = list_netapp_multipath_devices();
        my @untracked;
        for my $dev (@$netapp_devs) {
            my $wwid = lc($dev->{wwid});
            next if $alive_wwids{$wwid};       # alive on ONTAP, leave alone
            next if $tracked->{$wwid};         # already handled in first pass
            push @untracked, $dev;
        }
        if (@untracked) {
            # Cooldown: only warn once per hour per WWID to avoid flooding
            # the journal (pvestatd polls status() every 10 seconds).
            # State dir is /var/run (tmpfs, cleared on reboot).
            my $cooldown_dir = '/var/run/pve-storage-netapp';
            mkdir $cooldown_dir, 0755 unless -d $cooldown_dir;
            my $cooldown_secs = 3600;  # 1 hour

            my @need_warn;
            for my $o (@untracked) {
                my $flag = "$cooldown_dir/orphan-warn-$o->{wwid}";
                my $last = (stat($flag))[9] // 0;
                if ((time() - $last) >= $cooldown_secs) {
                    push @need_warn, $o;
                    # Touch the flag file to record this warning
                    if (open(my $fh, '>', $flag)) { close($fh); }
                }
            }

            if (@need_warn) {
                warn "Orphan cleanup: detected " . scalar(@need_warn) .
                     " untracked NETAPP multipath device(s) that may be stale.\n";
                warn "Plugin will NOT auto-clean these (risk of touching manually-managed storage).\n";
                warn "If you confirm they are NOT in use, clean manually:\n";
                for my $o (@need_warn) {
                    warn "  multipathd disablequeueing map $o->{wwid}\n";
                    warn "  dmsetup message $o->{wwid} 0 fail_if_no_path\n";
                    warn "  multipath -f $o->{wwid}\n";
                }
                warn "(This warning repeats at most once per hour per device.)\n";
            }
        }
    };
}

sub _health_state_dir {
    my $dir = '/var/run/pve-storage-netapp';
    mkdir $dir, 0755 unless -d $dir;
    return $dir;
}

# Track storage failure duration and emit syslog ERROR after threshold.
# Uses first-failure timestamp + count, NOT consecutive count alone, because
# PVE caches storage state and may not call activate_storage/status() on
# every pvestatd poll once a storage is marked inactive. By tracking the
# timestamp of the first failure, we still emit alerts even if PVE retries
# the plugin only once.
#
# State file format (single line, space-separated):
#   <first_failure_epoch> <count> <last_alert_epoch>
sub _record_status_failure {
    my ($storeid, $reason) = @_;
    my $dir = _health_state_dir();
    my $file = "$dir/$storeid-failstate";
    my $now = time();

    my ($first, $count, $last_alert) = (0, 0, 0);
    if (open(my $fh, '<', $file)) {
        my $line = <$fh>;
        close($fh);
        if (defined $line && $line =~ /^(\d+)\s+(\d+)\s+(\d+)/) {
            ($first, $count, $last_alert) = ($1, $2, $3);
        }
    }

    if (!$first) {
        $first = $now;
        $count = 1;
    } else {
        $count++;
    }

    # Threshold: emit syslog ERROR if storage has been failing for >= 30
    # seconds AND we haven't alerted in the last 60 seconds.
    # 30 seconds is short enough to detect quick outages but long enough to
    # avoid false positives from transient network blips.
    my $duration = $now - $first;
    my $alert_emitted = 0;
    if ($duration >= 30 && ($now - $last_alert) >= 60) {
        my $reason_safe = $reason // 'unknown';
        $reason_safe =~ s/[\r\n]+/ /g;
        my $msg = sprintf(
            "Storage '%s' unreachable for ~%ds (failure count: %d). Reason: %s",
            $storeid, $duration, $count, $reason_safe);
        eval {
            require Sys::Syslog;
            Sys::Syslog::openlog("pve-storage-netapp", "pid", "daemon");
            Sys::Syslog::syslog("err", "%s", $msg);
            Sys::Syslog::closelog();
        };
        $last_alert = $now;
        $alert_emitted = 1;
    }

    # Atomic write
    my $tmp = "$file.tmp.$$";
    if (open(my $fh, '>', $tmp)) {
        print $fh "$first $count $last_alert\n";
        close($fh);
        rename($tmp, $file);
    }
    return $count;
}

sub _record_status_success {
    my ($storeid) = @_;
    my $dir = _health_state_dir();
    my $file = "$dir/$storeid-failstate";
    if (-e $file) {
        # Read previous state to log recovery if outage exceeded threshold
        my ($first, $count, $last_alert) = (0, 0, 0);
        if (open(my $fh, '<', $file)) {
            my $line = <$fh>;
            close($fh);
            if (defined $line && $line =~ /^(\d+)\s+(\d+)\s+(\d+)/) {
                ($first, $count, $last_alert) = ($1, $2, $3);
            }
        }
        unlink($file);
        # Only log recovery if we actually emitted an alert (avoid noise
        # for transient single-poll failures that recovered immediately)
        if ($last_alert > 0) {
            my $now = time();
            my $duration = $now - $first;
            my $msg = sprintf(
                "Storage '%s' reachable again after %ds outage (failure count: %d)",
                $storeid, $duration, $count);
            eval {
                require Sys::Syslog;
                Sys::Syslog::openlog("pve-storage-netapp", "pid", "daemon");
                Sys::Syslog::syslog("info", "%s", $msg);
                Sys::Syslog::closelog();
            };
        }
    }
}

# Check aggregate capacity and emit syslog WARNING if approaching full.
# Cooldown: 1 hour per storage to avoid log flooding.
# Thresholds: 90% WARNING, 95% ERROR.
sub _check_aggregate_capacity {
    my ($api, $storeid, $scfg) = @_;
    my $aggr_name = $scfg->{'ontap-aggregate'};
    return unless $aggr_name;

    my $dir = _health_state_dir();
    my $flag = "$dir/$storeid-aggr-warn";
    my $last = (stat($flag))[9] // 0;
    return if (time() - $last) < 3600;  # 1 hour cooldown

    my $aggr = eval { $api->aggregate_get($aggr_name); };
    return unless $aggr && $aggr->{space} && $aggr->{space}{block_storage};

    my $total = $aggr->{space}{block_storage}{size} // 0;
    my $used  = $aggr->{space}{block_storage}{used} // 0;
    return unless $total > 0;

    my $pct = int($used * 100 / $total);
    return if $pct < 90;

    # Touch flag file to record warning
    if (open(my $fh, '>', $flag)) { close($fh); }

    my $level = $pct >= 95 ? "err" : "warning";
    my $level_text = $pct >= 95 ? "CRITICAL" : "WARNING";
    my $msg = sprintf(
        "%s: Storage '%s' aggregate '%s' is at %d%% capacity (used %d GB / total %d GB). Thin-provisioned LUNs may fail to grow.",
        $level_text, $storeid, $aggr_name, $pct,
        int($used / 1073741824), int($total / 1073741824));
    eval {
        require Sys::Syslog;
        Sys::Syslog::openlog("pve-storage-netapp", "pid", "daemon");
        Sys::Syslog::syslog($level, "%s", $msg);
        Sys::Syslog::closelog();
    };
    warn "$level_text: aggregate '$aggr_name' at ${pct}% capacity\n";
}

# Check LIF redundancy for ONTAP HA. SAN LIFs do NOT auto-migrate during
# takeover (only NAS LIFs do). Path failover relies on host MPIO + ALUA
# selecting LIFs on the surviving controller. Therefore "2+ LIFs" is
# insufficient if all LIFs share the same home_node -- a single
# controller failure would take them all offline simultaneously.
#
# Two failure modes detected:
#  (a) total LIF count < 2 (single point of failure)
#  (b) all LIFs have the same home_node (single controller failure)
# Cooldown: 24 hours per storage (config-related, rarely changes).
sub _check_lif_redundancy {
    my ($api, $storeid, $scfg) = @_;
    my $proto = $scfg->{'ontap-protocol'} // 'iscsi';
    return unless $proto eq 'iscsi';  # Only check iSCSI (FC handled by SAN switch)

    my $dir = _health_state_dir();
    my $flag = "$dir/$storeid-lif-warn";
    my $last = (stat($flag))[9] // 0;
    return if (time() - $last) < 86400;  # 24 hour cooldown

    my $lifs = eval { $api->iscsi_get_lifs_with_home_node(); };
    return unless $lifs && ref($lifs) eq 'ARRAY';

    my $count = scalar(@$lifs);
    my %home_nodes;
    for my $lif (@$lifs) {
        $home_nodes{$lif->{home_node} // 'unknown'}++;
    }
    my $node_count = scalar(keys %home_nodes);

    # Healthy: 2+ LIFs distributed across 2+ home_nodes
    return if $count >= 2 && $node_count >= 2;

    if (open(my $fh, '>', $flag)) { close($fh); }

    my $msg;
    if ($count < 2) {
        $msg = sprintf(
            "WARNING: Storage '%s' SVM has only %d iSCSI LIF -- no path redundancy. " .
            "Recommend at least 2 LIFs on different controllers for HA. " .
            "Note: SAN LIFs do not auto-migrate during takeover.",
            $storeid, $count);
    } else {
        # 2+ LIFs but all on same home_node
        my @nodes = keys %home_nodes;
        $msg = sprintf(
            "WARNING: Storage '%s' SVM has %d iSCSI LIFs but all share home_node '%s'. " .
            "A single controller failure will take all LIFs offline. " .
            "SAN LIFs do not auto-migrate during takeover. " .
            "Distribute LIFs across both controllers for HA.",
            $storeid, $count, $nodes[0]);
    }

    eval {
        require Sys::Syslog;
        Sys::Syslog::openlog("pve-storage-netapp", "pid", "daemon");
        Sys::Syslog::syslog("warning", "%s", $msg);
        Sys::Syslog::closelog();
    };
    warn "WARNING: iSCSI LIF redundancy issue (count=$count, home_nodes=$node_count). " .
         "See docs/CONFIGURATION.md 'ONTAP HA Best Practices'.\n";
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $api = eval { _get_api($scfg); };
    if (!$api) {
        warn "Failed to connect to ONTAP API for status check: $@";
        _record_status_failure($storeid, "API connection failed: $@");
        return (0, 0, 0, 0);
    }

    # Background cleanup tasks (don't block status check)
    # 1. Old temporary FlexClones
    # 2. Orphaned multipath devices (LUNs deleted on other cluster nodes)
    #
    # Double-fork pattern: parent forks intermediate, intermediate forks
    # grandchild and exits immediately. Grandchild gets reparented to init
    # and is reaped by init -- preventing zombie accumulation in pvedaemon.
    my $intermediate_pid = fork();
    if (defined $intermediate_pid && $intermediate_pid == 0) {
        # Intermediate child: fork again then exit
        my $grandchild_pid = fork();
        if (defined $grandchild_pid && $grandchild_pid == 0) {
            # Grandchild: do the actual work, will be reparented to init
            eval { _cleanup_temp_clones($api, $storeid); };
            eval { _cleanup_orphaned_devices($api, $storeid); };
            POSIX::_exit(0);
        }
        # Intermediate exits immediately, leaving grandchild orphaned
        POSIX::_exit(0);
    }
    # Parent reaps the intermediate (which exits immediately)
    waitpid($intermediate_pid, 0) if defined $intermediate_pid;

    eval {
        my $capacity = $api->get_managed_capacity();

        $cache->{total}     = $capacity->{total};
        $cache->{used}      = $capacity->{used};
        $cache->{avail}     = $capacity->{available};
    };
    if ($@) {
        warn "Failed to get storage status: $@";
        _record_status_failure($storeid, "capacity query failed: $@");
        return (0, 0, 0, 0);
    }

    # Success: clear failure counter (will log recovery if was previously failing)
    _record_status_success($storeid);

    # Aggregate capacity health check (syslog WARNING/ERROR with cooldown)
    eval { _check_aggregate_capacity($api, $storeid, $scfg); };

    # LIF redundancy check (24h cooldown, warns if < 2 iSCSI LIFs)
    eval { _check_lif_redundancy($api, $storeid, $scfg); };

    return ($cache->{total}, $cache->{avail}, $cache->{used}, 1);
}

#
# Volume management
#

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    die "unsupported format '$fmt'" if $fmt ne 'raw';

    my $api = _get_api($scfg);

    # Parse the requested volume name to determine type
    my $parsed;
    my $voltype = 'disk';  # Default type
    my $diskid;
    my $snapname;

    if ($name) {
        $parsed = _parse_volname($name);
        if ($parsed) {
            $voltype = $parsed->{type} // 'disk';
            $diskid = $parsed->{diskid} if defined $parsed->{diskid};
            $snapname = $parsed->{snapname} if defined $parsed->{snapname};
        }
    }

    # For disk type, find free disk ID if not specified
    if ($voltype eq 'disk') {
        $diskid //= _find_free_diskid($scfg, $storeid, $vmid);
    }

    # Size is in kilobytes, convert to bytes
    my $size_bytes = $size * 1024;

    # Volume size: LUN size + minimal overhead
    # With autogrow enabled on volume, we only need minimal initial overhead
    # for WAFL metadata. Volume will automatically expand if more space needed.
    # Minimum 64MB to cover LUN metadata and WAFL indirect blocks
    my $overhead = 64 * 1024 * 1024;  # 64MB fixed overhead

    my $vol_size = $size_bytes + $overhead;
    my $min_vol_size = 20 * 1024 * 1024;  # ONTAP minimum 20MB
    $vol_size = $min_vol_size if $vol_size < $min_vol_size;

    # Generate ONTAP volume name based on volume type
    my $ontap_volname;
    my $lun_path;
    my $pve_volname;  # The PVE volume name to return

    if ($voltype eq 'state') {
        # VM state volume: vm-{vmid}-state-{snapname}
        die "snapname is required for vmstate volume" unless $snapname;
        $pve_volname = "vm-${vmid}-state-${snapname}";
        $ontap_volname = pve_volname_to_ontap($storeid, $pve_volname);
        $lun_path = encode_lun_path($ontap_volname);

        # Check if volume already exists
        my $existing_vol = $api->volume_get($ontap_volname);
        if ($existing_vol) {
            die "Volume '$ontap_volname' already exists on ONTAP. " .
                "This may indicate a duplicate vmstate volume.";
        }
    } elsif ($voltype eq 'cloudinit') {
        # Cloud-init volume: vm-{vmid}-cloudinit
        $pve_volname = "vm-${vmid}-cloudinit";
        $ontap_volname = pve_volname_to_ontap($storeid, $pve_volname);
        $lun_path = encode_lun_path($ontap_volname);

        # Check if volume already exists
        my $existing_vol = $api->volume_get($ontap_volname);
        if ($existing_vol) {
            die "Volume '$ontap_volname' already exists on ONTAP. " .
                "This may indicate a duplicate cloudinit volume.";
        }
    } else {
        # Standard disk volume: vm-{vmid}-disk-{diskid}
        # Use retry logic for concurrent allocation
        my $max_retries = 5;

        for my $retry (0 .. $max_retries) {
            $ontap_volname = encode_volume_name($storeid, $vmid, $diskid);
            $lun_path = encode_lun_path($ontap_volname);

            # Check if volume already exists
            my $existing_vol = $api->volume_get($ontap_volname);
            if (!$existing_vol) {
                last;  # Volume name is available
            }

            # Volume exists - try next disk ID (handles concurrent allocation)
            if ($retry < $max_retries) {
                $diskid++;
                next;
            }

            # All retries exhausted
            die "Cannot find free disk ID for VM $vmid after $max_retries retries. " .
                "Volume '$ontap_volname' already exists on ONTAP. " .
                "This may be caused by a manually created volume with a conflicting name, " .
                "orphaned volumes from a previous failed operation, or concurrent allocation. " .
                "Please check ONTAP volumes with prefix 'pve_' and remove unused ones.";
        }
        $pve_volname = "vm-${vmid}-disk-${diskid}";
    }

    # Safety check: Verify aggregate has sufficient space (for thick provisioning)
    my $thin = $scfg->{'ontap-thin'} // 1;
    if (!$thin) {
        my $aggr = $api->aggregate_get($scfg->{'ontap-aggregate'});
        if ($aggr && $aggr->{space} && $aggr->{space}{block_storage}) {
            my $available = $aggr->{space}{block_storage}{available} // 0;
            if ($available < $vol_size) {
                my $avail_gb = sprintf("%.2f", $available / (1024*1024*1024));
                my $need_gb = sprintf("%.2f", $vol_size / (1024*1024*1024));
                die "Insufficient space in aggregate '$scfg->{'ontap-aggregate'}': " .
                    "available ${avail_gb}GB, required ${need_gb}GB";
            }
        }
    }

    # Create FlexVol with bounded TOCTOU retry (same pattern as clone_image).
    # The pre-check loop above finds a free disk ID, but another process can
    # grab it between the check and the create. If volume_create fails with
    # "already exists", advance to the next disk ID and retry.
    my $vol_created = 0;
    my $max_create_retries = 5;

    for my $create_try (0 .. $max_create_retries) {
        eval {
            $api->volume_create(
                name      => $ontap_volname,
                aggregate => $scfg->{'ontap-aggregate'},
                size      => $vol_size,
                thin      => $scfg->{'ontap-thin'} // 1,
            );
        };
        if (!$@) {
            $vol_created = 1;
            last;
        }
        if ($@ =~ /already exists|duplicate|entry.*exists|unique/i && $voltype eq 'disk') {
            warn "Volume '$ontap_volname' race detected, retrying with next disk ID\n";
            $diskid++;
            $ontap_volname = encode_volume_name($storeid, $vmid, $diskid);
            $lun_path = encode_lun_path($ontap_volname);
            $pve_volname = "vm-${vmid}-disk-${diskid}";
            next if $create_try < $max_create_retries;
            die "Cannot find free disk ID for VM $vmid after $max_create_retries race retries: $@";
        }
        # Any other error: not a race, fail immediately
        die "Failed to create volume '$ontap_volname': " .
            _translate_limit_error($@, 'volume creation');
    }
    die "Failed to create volume after $max_create_retries retries"
        unless $vol_created;

    # Warn if aggregate is running low on space (thin provisioning overcommit risk)
    if ($thin) {
        my $aggr = eval { $api->aggregate_get($scfg->{'ontap-aggregate'}); };
        if ($aggr && $aggr->{space} && $aggr->{space}{block_storage}) {
            my $total = $aggr->{space}{block_storage}{size} // 0;
            my $used = $aggr->{space}{block_storage}{used} // 0;
            if ($total > 0) {
                my $used_pct = int($used * 100 / $total);
                if ($used_pct > 85) {
                    warn "WARNING: Aggregate '$scfg->{'ontap-aggregate'}' is at ${used_pct}% capacity. " .
                        "Thin provisioned volumes may fail if aggregate fills up.\n";
                }
            }
        }
    }

    # Create LUN
    eval {
        $api->lun_create(
            name    => 'lun0',
            volume  => $ontap_volname,
            size    => $size_bytes,
            os_type => 'linux',
            thin    => $scfg->{'ontap-thin'} // 1,
        );
    };
    if ($@) {
        my $err = $@;
        # Cleanup volume on failure
        eval { $api->volume_delete($ontap_volname); };
        die "Failed to create LUN: " . _translate_limit_error($err, 'LUN creation');
    }

    # Map LUN to igroups
    # In per-node mode, map to ALL node igroups for migration/HA support
    # (consistent with clone_image behavior)
    eval {
        my $igroup_mode = $scfg->{'ontap-igroup-mode'} // 'per-node';
        if ($igroup_mode eq 'shared') {
            my $igroup = _get_igroup_name($scfg);
            $api->lun_map($lun_path, $igroup);
        } else {
            my $cluster_name = $scfg->{'ontap-cluster-name'} // 'pve';
            my $igroups = $api->igroup_list();
            my $ontap_proto = _get_ontap_protocol($scfg);
            my $mapped = 0;
            for my $ig (@$igroups) {
                next unless ($ig->{protocol} // '') eq $ontap_proto;
                if ($ig->{name} =~ /^pve_${cluster_name}_/) {
                    eval {
                        $api->lun_map($lun_path, $ig->{name});
                        $mapped++;
                    };
                    warn "Failed to map LUN to igroup '$ig->{name}': $@" if $@;
                }
            }
            die "No matching igroups found for cluster '$cluster_name'" unless $mapped > 0;
        }
    };
    if ($@) {
        my $err = $@;
        # Cleanup on failure (unmap first, then delete)
        eval { $api->lun_unmap_all($lun_path); };
        eval { $api->lun_delete($lun_path); };
        eval { $api->volume_delete($ontap_volname); };
        die "Failed to map LUN: " . _translate_limit_error($err, 'LUN map');
    }

    # Return PVE volume name
    return $pve_volname;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format) = @_;

    my $api = _get_api($scfg);
    my $ontap_volname = pve_volname_to_ontap($storeid, $volname);
    my $lun_path = encode_lun_path($ontap_volname);

    # Get LUN WWID for cleanup and in-use check
    my $wwid = eval { $api->lun_get_wwid($lun_path); };

    # Safety check: Verify device is not in use before deletion
    if ($wwid) {
        my $device = get_device_by_wwid($wwid);
        if ($device && -b $device) {
            if (is_device_in_use($device)) {
                my $details = get_device_usage_details($device);
                die "Cannot delete volume '$volname': device $device is still in use.\n\n" .
                    "$details\n";
            }
        }
    }

    # Safety check: Verify no FlexClone children depend on this volume
    my $clone_children = eval { $api->volume_get_clone_children($ontap_volname); };
    if ($clone_children && @$clone_children) {
        my @child_names = map { $_->{name} } @$clone_children;
        die "Cannot delete volume '$volname': it has FlexClone children depending on it. " .
            "Dependent volumes: " . join(', ', @child_names) . ". " .
            "Please delete or split the clones first.";
    }

    # Step 1: Capture multipath device and slave list BEFORE unmap
    # (after unmap, multipath may lose the device and we can't find slaves)
    my @scsi_slaves;
    if ($wwid) {
        my $mpath = get_multipath_device($wwid);
        if ($mpath && -b $mpath) {
            my $slaves = get_multipath_slaves($mpath);
            @scsi_slaves = @$slaves if $slaves;
        }
    }

    # Step 2: Unmap LUN from all igroups
    # This prevents iSCSI session rescans from re-discovering the LUN
    my $lun = $api->lun_get($lun_path);
    if ($lun && $lun->{lun_maps}) {
        for my $map (@{$lun->{lun_maps}}) {
            eval { $api->lun_unmap($lun_path, $map->{igroup}{name}); };
        }
    }

    # Step 3: Cleanup local multipath + SCSI devices
    if ($wwid) {
        eval { cleanup_lun_devices($wwid); };

        # Step 4: Remove any SCSI slave devices that cleanup_lun_devices missed
        # (use the slave list captured before unmap)
        for my $slave (@scsi_slaves) {
            if (-b $slave) {
                eval { remove_scsi_device($slave); };
            }
        }

        # Step 5: Final multipath reload to flush any residual stale maps
        eval { multipath_reload(); };
    }

    # Step 5: Delete LUN on ONTAP
    eval { $api->lun_delete($lun_path); };
    warn "Failed to delete LUN '$lun_path': $@\n" if $@;

    # Delete volume (and all snapshots)
    # Retry logic for stale has_flexclone metadata after clone deletion
    my $max_retries = 5;
    my $retry_delay = 2;
    my $deleted = 0;

    for my $attempt (1 .. $max_retries) {
        eval { $api->volume_delete($ontap_volname); };
        if (!$@) {
            $deleted = 1;
            last;
        }

        # Check if error is due to clone dependency
        if ($@ =~ /clone|child|depend/i) {
            # Verify no actual clones exist
            my $children = eval { $api->volume_get_clone_children($ontap_volname); };
            if ($children && @$children) {
                # Real clones exist, don't retry
                die "Cannot delete volume '$volname': it has FlexClone children. " .
                    "Dependent volumes: " . join(', ', map { $_->{name} } @$children);
            }

            # Stale metadata - wait and retry
            warn "Volume delete failed (attempt $attempt/$max_retries): stale clone metadata, retrying...\n"
                if $attempt < $max_retries;
            sleep($retry_delay);
        } else {
            # Other error, don't retry
            die "Failed to delete volume '$ontap_volname': $@";
        }
    }

    die "Failed to delete volume '$ontap_volname' after $max_retries attempts: ONTAP reports stale clone metadata"
        unless $deleted;

    # Untrack WWID ONLY if local cleanup actually succeeded.
    # If multipath device still exists locally (cleanup_lun_devices failed
    # earlier), KEEP the WWID tracked. The next status() poll will detect
    # it as orphan (in tracking but not in ONTAP alive set) and retry cleanup.
    # This prevents the case where: local cleanup fails -> LUN deleted on
    # ONTAP -> WWID untracked -> stale device permanently orphaned.
    if ($wwid) {
        my $still_exists = get_multipath_device($wwid);
        if ($still_exists) {
            warn "free_image: local multipath device for WWID $wwid still exists after cleanup. " .
                 "Keeping WWID tracked so orphan cleanup can retry.\n";
        } else {
            eval { _untrack_wwid($storeid, $wwid); };
        }
    }

    return undef;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $api = _get_api($scfg);

    my @res;

    # Build filter pattern
    my $filter = 'pve_*';
    my $san_storage = $storeid;
    $san_storage =~ s/-/_/g;
    if ($vmid) {
        $filter = "pve_${san_storage}_${vmid}_*";
    }

    my $volumes = $api->volume_list($filter);

    # Batch query all LUNs for performance (instead of per-volume query)
    my $lun_filter = "/vol/pve_${san_storage}_*/lun0";
    if ($vmid) {
        $lun_filter = "/vol/pve_${san_storage}_${vmid}_*/lun0";
    }
    my $luns = $api->lun_list($lun_filter);

    # Build LUN lookup hash by volume name
    my %lun_by_vol;
    for my $lun (@$luns) {
        if ($lun->{name} =~ m|^/vol/([^/]+)/|) {
            $lun_by_vol{$1} = $lun;
        }
    }

    # Build a set of volumes that are templates
    # A template has __pve_base__ snapshot AND is NOT a FlexClone
    # (FlexClones inherit parent's snapshots, so we must exclude them)
    # Use a deadline to prevent cascading API timeouts with many volumes
    my %is_template;
    my $template_deadline = time() + 10;
    for my $vol (@$volumes) {
        if (time() > $template_deadline) {
            warn "Template detection timed out after 10s, skipping remaining volumes\n";
            last;
        }

        # Skip if this volume is a FlexClone (clone of a template)
        next if $vol->{clone} && $vol->{clone}{is_flexclone};

        # Skip non-disk volumes (state, cloudinit) - they can't be templates
        my $decoded = decode_volume_name($vol->{name});
        next if $decoded && $decoded->{type} && $decoded->{type} ne 'disk';

        my $snap = eval { $api->snapshot_get($vol->{name}, '__pve_base__'); };
        if ($@) {
            warn "Failed to check template status for $vol->{name}: $@\n";
            next;
        }
        $is_template{$vol->{name}} = 1 if $snap;
    }

    for my $vol (@$volumes) {
        my $decoded = decode_volume_name($vol->{name});
        next unless $decoded;

        # Check if volume belongs to requested storage
        next if $decoded->{storage} ne $san_storage;

        # Generate PVE volume name based on volume type
        my $pve_volname;
        if ($decoded->{type} eq 'disk') {
            my $prefix = $is_template{$vol->{name}} ? 'base' : 'vm';
            $pve_volname = "${prefix}-$decoded->{vmid}-disk-$decoded->{diskid}";
        } elsif ($decoded->{type} eq 'state') {
            # VM state volume (RAM snapshot)
            $pve_volname = "vm-$decoded->{vmid}-state-$decoded->{snapname}";
        } elsif ($decoded->{type} eq 'cloudinit') {
            # Cloud-init volume
            $pve_volname = "vm-$decoded->{vmid}-cloudinit";
        } else {
            $pve_volname = ontap_to_pve_volname($vol->{name});
        }
        next unless $pve_volname;

        my $volid = "$storeid:$pve_volname";

        # Filter by vollist if provided
        if ($vollist) {
            my $dominated = 0;
            foreach my $pattern (@$vollist) {
                if ($volid =~ /^\Q$pattern\E/) {
                    $dominated = 1;
                    last;
                }
            }
            next unless $dominated;
        }

        # Get LUN size from batch query result
        my $lun = $lun_by_vol{$vol->{name}};
        my $size = $lun ? $lun->{space}{size} : $vol->{size};

        push @res, {
            volid  => $volid,
            format => 'raw',
            size   => $size,
            vmid   => $decoded->{vmid},
            used   => $vol->{space}{used} // 0,
        };
    }

    return \@res;
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my $api = _get_api($scfg);
    my $ontap_volname = pve_volname_to_ontap($storeid, $volname);
    my $lun_path = encode_lun_path($ontap_volname);

    my $lun = $api->lun_get($lun_path);
    die "LUN '$lun_path' not found" unless $lun;

    return wantarray ?
        ($lun->{space}{size}, 'raw', $lun->{space}{used}, undef) :
        $lun->{space}{size};
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    my $api = _get_api($scfg);
    my $ontap_volname = pve_volname_to_ontap($storeid, $volname);
    my $lun_path = encode_lun_path($ontap_volname);

    # Get current LUN size to prevent shrinking
    my $lun = $api->lun_get($lun_path);
    die "LUN '$lun_path' not found" unless $lun;

    my $current_size = $lun->{space}{size} // 0;

    # Prevent shrinking - this would cause data loss
    if ($size < $current_size) {
        my $current_gb = sprintf("%.2f", $current_size / (1024*1024*1024));
        my $requested_gb = sprintf("%.2f", $size / (1024*1024*1024));
        die "Cannot shrink LUN: current size ${current_gb}GB, requested ${requested_gb}GB. " .
            "Shrinking would cause data loss.";
    }

    # Skip if size unchanged
    if ($size == $current_size) {
        return 1;
    }

    # Size is in bytes
    # Resize volume first (add overhead for WAFL metadata)
    my $vol_size = $size + (64 * 1024 * 1024);
    $api->volume_resize($ontap_volname, $vol_size);

    # Resize LUN
    $api->lun_resize($lun_path, $size);

    # Make kernel + multipath see the new size.
    #
    # IMPORTANT: For RESIZE (not new device discovery), we must use
    # `echo 1 > /sys/block/sdX/device/rescan` on EACH path slave, then
    # `multipathd resize map <wwid>` to refresh the multipath device size.
    #
    # Do NOT use rescan_scsi_hosts() (host scan) -- that's for discovering
    # NEW devices, not re-reading the size of existing ones. Host scan is
    # also slow and can hang on unresponsive iSCSI hosts.
    my $wwid = eval { $api->lun_get_wwid($lun_path); };
    if ($wwid) {
        my $device = get_device_by_wwid($wwid);
        if ($device && -b $device) {
            # Get all underlying SCSI slave devices and rescan each one.
            # This makes the kernel re-read the SCSI device capacity.
            my $slaves = get_multipath_slaves($device) || [];
            for my $slave (@$slaves) {
                eval { rescan_scsi_device($slave); };
                warn "Failed to rescan $slave: $@" if $@;
            }

            # Tell multipathd to resize the map to match the new underlying size.
            # Inline untaint check (basename of /dev/mapper/<wwid>).
            my $mpath_name = basename($device);
            if ($mpath_name =~ /^([a-zA-Z0-9_\-]+)$/) {
                my $safe_name = $1;
                eval {
                    PVE::Tools::run_command(
                        ['/sbin/multipathd', 'resize', 'map', $safe_name],
                        timeout => 15,
                    );
                };
                warn "multipathd resize map $safe_name failed: $@" if $@;
            }
        }
    }

    return 1;
}

#
# Volume activation
#

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    my $api = _get_api($scfg);
    my $ontap_volname = pve_volname_to_ontap($storeid, $volname);
    my $lun_path = encode_lun_path($ontap_volname);

    # Ensure LUN is mapped to this node's igroup (and all node igroups for migration)
    my $igroup_mode = $scfg->{'ontap-igroup-mode'} // 'per-node';
    if ($igroup_mode eq 'shared') {
        my $igroup = _get_igroup_name($scfg);
        unless ($api->lun_is_mapped($lun_path, $igroup)) {
            $api->lun_map($lun_path, $igroup);
        }
    } else {
        my $cluster_name = $scfg->{'ontap-cluster-name'} // 'pve';
        my $igroups = $api->igroup_list();
        my $ontap_proto = _get_ontap_protocol($scfg);
        for my $ig (@$igroups) {
            next unless ($ig->{protocol} // '') eq $ontap_proto;
            if ($ig->{name} =~ /^pve_${cluster_name}_/) {
                unless ($api->lun_is_mapped($lun_path, $ig->{name})) {
                    eval { $api->lun_map($lun_path, $ig->{name}); };
                    warn "Failed to map LUN to igroup '$ig->{name}': $@" if $@;
                }
            }
        }
    }

    # Rescan for the device based on protocol
    my $protocol = $scfg->{'ontap-protocol'} // 'iscsi';

    if ($protocol eq 'fc') {
        # FC: Issue LIP and rescan SCSI hosts (includes SCSI host scan)
        rescan_fc_hosts(delay => 1);
    } else {
        # iSCSI: Rescan sessions and SCSI hosts
        rescan_sessions();
        rescan_scsi_hosts();
    }

    # Reload multipath to pick up new devices
    multipath_reload();

    # Get LUN WWID for device identification
    my $wwid = $api->lun_get_wwid($lun_path);
    die "Cannot get WWID for LUN $lun_path" unless $wwid;

    # Wait for device to appear (use configurable timeout)
    my $timeout = $scfg->{'ontap-device-timeout'} // 60;
    my $device = wait_for_device($wwid, timeout => $timeout);
    die "Device for LUN $lun_path did not appear within ${timeout}s. " .
        "Check iSCSI/FC connectivity and multipath configuration." unless $device;

    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    # In per-node mode, we keep LUN mapped for migration safety.
    # Only flush caches if device is not actively used by another process
    # (prevents sync/flush from blocking during live migration).

    my $api = eval { _get_api($scfg); };
    return 1 unless $api;

    my $ontap_volname = pve_volname_to_ontap($storeid, $volname);
    my $lun_path = encode_lun_path($ontap_volname);

    my $wwid = eval { $api->lun_get_wwid($lun_path); };

    if ($wwid) {
        my $device = get_device_by_wwid($wwid);
        if ($device && -b $device && !is_device_in_use($device)) {
            eval { run_command(['/bin/sync'], timeout => 10); };
            warn "sync timed out: $@" if $@;
            eval { run_command(['/sbin/blockdev', '--flushbufs', $device], timeout => 10); };
            warn "blockdev --flushbufs timed out for $device: $@" if $@;
        }
    }

    return 1;
}

#
# Temporary FlexClone management for snapshot access
# These are created when PVE needs to read snapshot data (e.g., Full Clone from VM snapshot)
#

sub _get_temp_clone_name {
    my ($ontap_volname, $snapname) = @_;
    my $ontap_snapname = encode_snapshot_name($snapname);
    # Temp clone name format: tmpclone_<volname>_<snap>
    my $name = "tmpclone_${ontap_volname}_${ontap_snapname}";
    $name =~ s/[^a-zA-Z0-9_]/_/g;  # Sanitize for ONTAP naming rules
    return substr($name, 0, 197);  # ONTAP max volume name length is 203
}

sub _track_temp_clone {
    my ($storeid, $clone_name) = @_;

    _with_temp_clone_lock(sub {
        my $state = _read_temp_clone_state();
        $state->{$storeid} //= {};
        $state->{$storeid}{$clone_name} = time();
        _write_temp_clone_state($state);
    });
}

sub _cleanup_temp_clones {
    my ($api, $storeid) = @_;

    _with_temp_clone_lock(sub {
        my $state = _read_temp_clone_state();
        my $storage_clones = $state->{$storeid} // {};
        my $now = time();
        my $cleaned = 0;

        for my $clone_name (keys %$storage_clones) {
            my $created = $storage_clones->{$clone_name};
            if ($now - $created > $TEMP_CLONE_MAX_AGE) {
                warn "Cleaning up old temporary FlexClone: $clone_name\n";
                eval {
                    # Unmap LUN and delete volume
                    my $lun_path = encode_lun_path($clone_name);
                    eval { $api->lun_unmap_all($lun_path); };
                    $api->volume_delete($clone_name);
                    delete $storage_clones->{$clone_name};
                    $cleaned++;
                };
                warn "Failed to cleanup temp clone '$clone_name': $@\n" if $@;
            }
        }

        if ($cleaned) {
            $state->{$storeid} = $storage_clones;
            _write_temp_clone_state($state);
        }
    });
}

sub _get_snapshot_path {
    my ($class, $scfg, $volname, $storeid, $snapname, $api, $parsed) = @_;

    my $ontap_volname = pve_volname_to_ontap($storeid, $volname);
    my $temp_clone_name = _get_temp_clone_name($ontap_volname, $snapname);
    my $ontap_snapname = encode_snapshot_name($snapname);

    # Check if temporary clone already exists
    my $temp_vol = eval { $api->volume_get($temp_clone_name); };

    if (!$temp_vol) {
        # Create FlexClone from snapshot
        warn "Creating temporary FlexClone '$temp_clone_name' for snapshot '$snapname' access\n";

        # Create FlexClone from the snapshot. Temp clone names are
        # deterministic (volname + snap), so two parallel path() callers
        # for the same volume+snap will race on this create. Treat
        # "already exists" as success -- whichever process won, the temp
        # clone is now there and we can use it.
        eval {
            $api->volume_clone(
                clone_name      => $temp_clone_name,
                parent_name     => $ontap_volname,
                parent_snapshot => $ontap_snapname,
            );
        };
        if ($@ && $@ !~ /already exists|duplicate|entry.*exists/i) {
            die "Failed to create temporary FlexClone '$temp_clone_name': $@";
        }

        # Track for cleanup
        _track_temp_clone($storeid, $temp_clone_name);
    }

    # Always ensure LUN is mapped and device is discovered
    # (handles case where previous attempt failed after clone creation)
    my $lun_path = encode_lun_path($temp_clone_name);
    my $protocol = $scfg->{'ontap-protocol'} // 'iscsi';
    my $igroup_name = _get_igroup_name($scfg);

    # Try to map LUN (may already be mapped)
    eval { $api->lun_map($lun_path, $igroup_name); };
    if ($@) {
        # Only warn if not "already mapped" error
        warn "LUN map info: $@\n" unless $@ =~ /already mapped|already exists/i;
    }

    # Rescan to discover the LUN
    if ($protocol eq 'fc') {
        rescan_fc_hosts();
    } else {
        rescan_sessions();
        rescan_scsi_hosts();
    }
    multipath_reload();

    # Get WWID and device path
    my $timeout = $scfg->{'ontap-device-timeout'} // 30;

    my $wwid = eval { $api->lun_get_wwid($lun_path); };
    die "Failed to get WWID for temporary clone LUN: $@" unless $wwid;

    # Wait for device to appear
    my $device = wait_for_multipath_device($wwid, timeout => $timeout);
    $device //= get_device_by_wwid($wwid);

    if (!$device || ! -b $device) {
        # One more rescan attempt
        if ($protocol eq 'fc') {
            rescan_fc_hosts(delay => 2);
        } else {
            rescan_sessions();
            rescan_scsi_hosts();
        }
        multipath_reload();
        sleep(3);

        $device = get_multipath_device($wwid);
        $device //= get_device_by_wwid($wwid);
    }

    die "Failed to find device for temporary clone '$temp_clone_name' (WWID: $wwid)"
        unless $device && -b $device;

    return ($device, $parsed->{vmid}, 'raw');
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    my $parsed = _parse_volname($volname);
    die "Cannot parse volume name: $volname" unless $parsed;

    my $api = _get_api($scfg);
    my $ontap_volname = pve_volname_to_ontap($storeid, $volname);

    # For snapshot access, create a temporary FlexClone that qemu-img can read
    # This is needed for Full Clone from VM snapshot operations
    if ($snapname) {
        return _get_snapshot_path($class, $scfg, $volname, $storeid, $snapname, $api, $parsed);
    }

    # For current volume access (no snapshot)
    my $lun_path = encode_lun_path($ontap_volname);

    # Try to get WWID - LUN might not exist (orphaned volume, partial cleanup, etc.)
    my $wwid = eval { $api->lun_get_wwid($lun_path); };
    if (!$wwid) {
        # LUN doesn't exist - return synthetic path based on volume name
        # This allows delete operations to proceed via ONTAP API
        my $synthetic_wwid = "3600a0980" . unpack('H*', substr($ontap_volname, 0, 12));
        warn "LUN $lun_path not found on ONTAP, returning synthetic path for cleanup\n";
        return ("/dev/mapper/$synthetic_wwid", $parsed->{vmid}, 'raw');
    }

    # Try multipath first
    my $device = get_multipath_device($wwid);
    $device //= get_device_by_wwid($wwid);

    # If device not found, rescan and wait with retry loop
    if (!$device || ! -b $device) {
        my $protocol = $scfg->{'ontap-protocol'} // 'iscsi';
        my $max_wait = $scfg->{'ontap-device-timeout'} // 30;
        my $start = time();

        while ((time() - $start) < $max_wait) {
            if ($protocol eq 'fc') {
                rescan_fc_hosts(delay => 1);
            } else {
                rescan_sessions();
                rescan_scsi_hosts();
            }
            multipath_reload();

            $device = get_multipath_device($wwid);
            $device //= get_device_by_wwid($wwid);
            last if $device && -b $device;

            sleep(2);
        }
    }

    # If device still not found, return synthetic path for non-I/O operations
    # (e.g., delete can proceed via ONTAP API without a local device)
    if (!$device || ! -b $device) {
        $device = "/dev/mapper/$wwid";
        warn "Device for LUN $lun_path not found locally after waiting, returning synthetic path: $device\n";
    } else {
        # Track this WWID so we can clean up orphans later if the LUN is deleted on another node
        eval { _track_wwid($storeid, $wwid); };
    }

    return ($device, $parsed->{vmid}, 'raw');
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;

    my ($path, $vmid, $format) = $class->path($scfg, $volname, $scfg->{storage}, $snapname);
    return wantarray ? ($path, $vmid, $format) : $path;
}

#
# Snapshot operations
#

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $api = _get_api($scfg);
    my $ontap_volname = pve_volname_to_ontap($storeid, $volname);
    my $ontap_snapname = encode_snapshot_name($snap);
    my $lun_path = encode_lun_path($ontap_volname);

    # Safety check: Verify snapshot doesn't already exist
    my $existing_snap = $api->snapshot_get($ontap_volname, $ontap_snapname);
    if ($existing_snap) {
        die "Snapshot '$snap' already exists on volume '$volname'. " .
            "Please use a different snapshot name or delete the existing snapshot first.";
    }

    # Best-effort flush of host-side buffers before taking the storage-level
    # snapshot. For running VMs, qemu's own freeze handles consistency at the
    # filesystem layer; this flush only catches the case where the device has
    # dirty page cache from non-qemu access (e.g. external scripts, offline
    # snapshot of a stopped VM after a host write). Skip if device is in use
    # by another process to avoid blocking on a busy live migration.
    my $wwid = eval { $api->lun_get_wwid($lun_path); };
    if ($wwid) {
        my $device = get_device_by_wwid($wwid);
        if ($device && -b $device && !is_device_in_use($device)) {
            eval { run_command(['/bin/sync'], timeout => 10); };
            warn "pre-snapshot sync timed out: $@" if $@;
            eval { run_command(['/sbin/blockdev', '--flushbufs', $device], timeout => 10); };
            warn "pre-snapshot blockdev --flushbufs failed for $device: $@" if $@;
        }
    }

    $api->snapshot_create($ontap_volname, $ontap_snapname);

    return 1;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;

    my $api = _get_api($scfg);
    my $ontap_volname = pve_volname_to_ontap($storeid, $volname);
    my $ontap_snapname = encode_snapshot_name($snap);

    $api->snapshot_delete($ontap_volname, $ontap_snapname);

    return 1;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $api = _get_api($scfg);
    my $ontap_volname = pve_volname_to_ontap($storeid, $volname);
    my $ontap_snapname = encode_snapshot_name($snap);
    my $lun_path = encode_lun_path($ontap_volname);

    # Quiesce device before rollback to prevent data corruption
    my $wwid = eval { $api->lun_get_wwid($lun_path); };
    my $device;
    if ($wwid) {
        $device = get_device_by_wwid($wwid);
        if ($device && -b $device) {
            if (is_device_in_use($device)) {
                die "Cannot rollback snapshot: device $device is still in use. " .
                    "Please stop the VM first.";
            }
            eval { run_command(['/bin/sync'], timeout => 10); };
            warn "sync timed out: $@" if $@;
            eval { run_command(['/sbin/blockdev', '--flushbufs', $device], timeout => 10); };
            warn "blockdev --flushbufs timed out for $device: $@" if $@;
        }
    }

    # Rollback the volume to snapshot
    $api->snapshot_rollback($ontap_volname, $ontap_snapname);

    # After rollback, the data on the LUN has changed but the device identity
    # is the same. We need to:
    #   1. Per-device SCSI rescan to re-read capacity (in case snapshot had
    #      a different size)
    #   2. Invalidate kernel buffer cache so next reads see new content
    #
    # Do NOT use rescan_scsi_hosts() (host scan) -- that's for discovering
    # NEW devices, not refreshing existing ones, and can hang on unresponsive hosts.
    if ($device && -b $device) {
        # Per-device rescan on each path slave
        my $slaves = get_multipath_slaves($device) || [];
        for my $slave (@$slaves) {
            eval { rescan_scsi_device($slave); };
            warn "Failed to rescan $slave: $@" if $@;
        }

        # Refresh multipath map size in case capacity changed
        my $mpath_name = basename($device);
        if ($mpath_name =~ /^([a-zA-Z0-9_\-]+)$/) {
            my $safe_name = $1;
            eval {
                run_command(['/sbin/multipathd', 'resize', 'map', $safe_name],
                    timeout => 15);
            };
        }

        # Invalidate kernel buffer cache so subsequent reads see new content
        eval { run_command(['/sbin/blockdev', '--flushbufs', $device], timeout => 10); };
        warn "post-rollback blockdev --flushbufs failed: $@" if $@;
    }

    return 1;
}

sub volume_snapshot_list {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $api = _get_api($scfg);
    my $ontap_volname = pve_volname_to_ontap($storeid, $volname);

    my $snapshots = $api->snapshot_list($ontap_volname, 'pve_snap_*');

    my @result;
    for my $snap (@$snapshots) {
        my $pve_snapname = decode_snapshot_name($snap->{name});
        next unless $pve_snapname;

        push @result, {
            name   => $pve_snapname,
            ctime  => $snap->{create_time},
        };
    }

    return \@result;
}

#
# Feature support
#

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running, $opts) = @_;

    # For clone feature, we support FlexClone for all cases
    # When cloning from snapshot, clone_image does FlexClone + Split (independent volume)
    # When cloning from template, clone_image does FlexClone only (linked clone)
    if ($feature eq 'clone') {
        return 1;  # Always allow - we handle all clone scenarios via FlexClone
    }

    # For copy feature (qemu-img based full clone):
    # - Snapshots: Allow - we create a temporary FlexClone for qemu-img to read
    # - Current: Allow - QEMU can read current volume directly
    if ($feature eq 'copy') {
        return 1;  # Allow copy - path() handles snapshot access via temp FlexClone
    }

    my $features = {
        snapshot   => { current => 1, snap => 1 },
        sparseinit => { base => 1, current => 1 },
        rename     => { current => 1 },
        template   => { current => 1 },  # Allow template creation
    };

    my $key = $snapname ? 'snap' : 'current';

    return 1 if defined($features->{$feature}) && $features->{$feature}{$key};
    return 0;
}

sub parse_volname {
    my ($class, $volname) = @_;

    my $parsed = _parse_volname($volname);
    return undef unless $parsed;

    # Return format: ($vtype, $name, $vmid, $basename, $basevmid, $isBase, $format)
    if ($parsed->{type} eq 'disk') {
        my $isBase = $parsed->{isBase} ? 1 : 0;
        return ('images', $volname, $parsed->{vmid}, undef, undef, $isBase, $parsed->{format});
    } elsif ($parsed->{type} eq 'cloudinit') {
        return ('images', $volname, $parsed->{vmid}, undef, undef, 0, $parsed->{format});
    } elsif ($parsed->{type} eq 'state') {
        return ('images', $volname, $parsed->{vmid}, undef, undef, 0, $parsed->{format});
    }

    return undef;
}

#
# Template support (create_base and rename_volume)
#

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase, $format) =
        $class->parse_volname($volname);

    die "create_base on wrong vtype '$vtype'\n" if $vtype ne 'images';
    die "create_base not possible with base image\n" if $isBase;

    my $api = _get_api($scfg);
    my $ontap_volname = pve_volname_to_ontap($storeid, $volname);
    my $lun_path = encode_lun_path($ontap_volname);

    # Verify volume exists
    my $vol = $api->volume_get($ontap_volname);
    die "Volume '$ontap_volname' not found on ONTAP\n" unless $vol;

    # Create __pve_base__ snapshot for future cloning
    # This snapshot serves as the base point for linked clones
    my $base_snapshot = '__pve_base__';
    my $existing_snap = $api->snapshot_get($ontap_volname, $base_snapshot);
    unless ($existing_snap) {
        $api->snapshot_create($ontap_volname, $base_snapshot);
    }

    # Generate new PVE volume name (vm-XXX-disk-X -> base-XXX-disk-X)
    # ONTAP volume name stays the same - only PVE naming changes
    my $newname = $name;
    $newname =~ s/^vm-/base-/;

    return $newname;
}

sub rename_volume {
    my ($class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname) = @_;

    my ($vtype, $source_name, $source_vmid, undef, undef, $isBase, $format) =
        $class->parse_volname($source_volname);

    die "rename_volume on wrong vtype '$vtype'\n" if $vtype ne 'images';

    my $api = _get_api($scfg);

    # Determine target volume name if not provided
    if (!$target_volname) {
        $target_volname = $class->find_free_diskname($storeid, $scfg, $target_vmid, $format);
    }

    # Get source ONTAP volume name
    my $source_ontap_vol = pve_volname_to_ontap($storeid, $source_volname);
    my $source_lun_path = encode_lun_path($source_ontap_vol);

    # Get target ONTAP volume name
    my $target_ontap_vol = pve_volname_to_ontap($storeid, $target_volname);
    my $target_lun_path = encode_lun_path($target_ontap_vol);

    # Check if source volume exists
    my $vol = $api->volume_get($source_ontap_vol);
    die "Source volume '$source_ontap_vol' not found on ONTAP\n" unless $vol;

    # Check if target volume already exists
    my $existing = $api->volume_get($target_ontap_vol);
    die "Target volume '$target_ontap_vol' already exists on ONTAP\n" if $existing;

    # Rename ONTAP volume
    $api->volume_rename($source_ontap_vol, $target_ontap_vol);

    return "${storeid}:${target_volname}";
}

sub find_free_diskname {
    my ($class, $storeid, $scfg, $vmid, $fmt, $add_fmt_suffix) = @_;

    # Get list of existing disks for this VM
    my $disk_list = $class->list_images($storeid, $scfg, $vmid);

    my %used_ids;
    for my $disk (@$disk_list) {
        if ($disk->{volid} =~ /(?:vm|base)-$vmid-disk-(\d+)/) {
            $used_ids{$1} = 1;
        }
    }

    # Find first unused ID
    for (my $id = 0; $id < 1000; $id++) {
        unless ($used_ids{$id}) {
            return "vm-${vmid}-disk-${id}";
        }
    }

    die "No free disk ID found for VM $vmid\n";
}

#
# Clone support via NetApp FlexClone
#

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;

    my $api = _get_api($scfg);

    # Check FlexClone license
    unless ($api->license_has_flexclone()) {
        die "FlexClone license not found on ONTAP system. " .
            "FlexClone is required for linked clone operations. " .
            "Please install ONTAP One or FlexClone license.";
    }

    # Parse source volume name
    my $parsed = _parse_volname($volname);
    die "Cannot parse volume name: $volname" unless $parsed;

    # Get parent ONTAP volume name
    my $parent_ontap_vol = pve_volname_to_ontap($storeid, $volname);

    # Determine base snapshot name for clone
    # If $snap is provided, use it; otherwise look for __pve_base__ snapshot
    my $base_snapshot;
    if ($snap) {
        $base_snapshot = encode_snapshot_name($snap);
    } else {
        # Check if __pve_base__ snapshot exists, create if not
        $base_snapshot = '__pve_base__';
        my $existing = $api->snapshot_get($parent_ontap_vol, $base_snapshot);
        unless ($existing) {
            # Create base snapshot for cloning
            $api->snapshot_create($parent_ontap_vol, $base_snapshot);
        }
    }

    # Generate new disk ID for clone and create the FlexClone in one loop.
    # Pre-check (volume_get) handles the cheap case; the volume_clone error
    # handler catches the TOCTOU race window where two parallel clone_image
    # calls on the same VM both pass the pre-check with the same disk ID.
    # The first volume_clone wins; the second gets "already exists" from
    # ONTAP and we retry with the next disk ID.
    my $new_diskid;
    my $new_volname;
    my $clone_ontap_vol;
    my $clone_lun_path;
    my $max_clone_retries = 5;
    my $clone_created = 0;

    my $disk_list = $class->list_images($storeid, $scfg, $vmid);
    my $max_disk = -1;
    for my $disk (@$disk_list) {
        if ($disk->{volid} =~ /vm-$vmid-disk-(\d+)/) {
            $max_disk = $1 if $1 > $max_disk;
        }
    }
    my $base_diskid = $max_disk + 1;

    for my $retry (0 .. $max_clone_retries) {
        $new_diskid = $base_diskid + $retry;
        $new_volname = "vm-${vmid}-disk-${new_diskid}";
        $clone_ontap_vol = encode_volume_name($storeid, $vmid, $new_diskid);
        $clone_lun_path = encode_lun_path($clone_ontap_vol);

        # Cheap pre-check: skip IDs we already know are taken to avoid a
        # round-trip to ONTAP for the create.
        my $existing = $api->volume_get($clone_ontap_vol);
        if ($existing) {
            next if $retry < $max_clone_retries;
            die "Cannot find free disk ID for clone after $max_clone_retries retries";
        }

        # Try to create the FlexClone. This is the actual race-window
        # protection: even if the pre-check said the ID was free, another
        # parallel clone_image may have grabbed it between the check and now.
        eval {
            $api->volume_clone(
                clone_name      => $clone_ontap_vol,
                parent_name     => $parent_ontap_vol,
                parent_snapshot => $base_snapshot,
            );
        };
        if (!$@) {
            $clone_created = 1;
            last;
        }
        if ($@ =~ /already exists|duplicate|entry.*exists|unique/i) {
            warn "Clone '$clone_ontap_vol' race detected, retrying with next disk ID\n";
            next if $retry < $max_clone_retries;
            die "Cannot find free disk ID for clone after $max_clone_retries retries: $@";
        }
        # Any other error: not a race, fail immediately
        die "Failed to create FlexClone: " .
            _translate_limit_error($@, 'FlexClone creation');
    }

    die "Failed to create FlexClone after $max_clone_retries retries"
        unless $clone_created;

    # The LUN inside the FlexClone volume is automatically cloned with new identity
    # Wait a moment for the LUN to be ready
    sleep(2);

    # Check if LUN exists in the cloned volume
    my $lun = $api->lun_get($clone_lun_path);
    unless ($lun) {
        # Cleanup and fail (unmap first in case FlexClone inherited mappings)
        eval { $api->lun_unmap_all($clone_lun_path); };
        eval { $api->volume_delete($clone_ontap_vol); };
        die "LUN not found in cloned volume: $clone_lun_path. " .
            "FlexClone may not have copied the LUN correctly.";
    }

    # Map cloned LUN to igroups
    my $map_error;
    eval {
        my $igroup_mode = $scfg->{'ontap-igroup-mode'} // 'per-node';
        if ($igroup_mode eq 'shared') {
            my $igroup = _get_igroup_name($scfg);
            $api->lun_map($clone_lun_path, $igroup);
        } else {
            # Per-node mode: map to all node igroups for migration support
            my $cluster_name = $scfg->{'ontap-cluster-name'} // 'pve';
            my $igroups = $api->igroup_list();
            my $ontap_proto = _get_ontap_protocol($scfg);
            my $mapped = 0;
            for my $ig (@$igroups) {
                next unless ($ig->{protocol} // '') eq $ontap_proto;
                if ($ig->{name} =~ /^pve_${cluster_name}_/) {
                    eval {
                        $api->lun_map($clone_lun_path, $ig->{name});
                        $mapped++;
                    };
                    if ($@) {
                        $map_error = $@ unless $map_error;
                    }
                }
            }
            die "No matching igroups found for cluster '$cluster_name'" unless $mapped > 0 || $map_error;
        }
    };
    if ($@ || $map_error) {
        my $err = $@ || $map_error || "Unknown error";
        # Cleanup on failure (unmap first, then delete)
        # lun_map may have partially succeeded (mapped to some node igroups
        # before failing on others). volume_delete on a still-mapped LUN
        # will fail on ONTAP, leaving orphaned igroup mappings and ghost
        # LUNs visible to other cluster nodes.
        eval { $api->lun_unmap_all($clone_lun_path); };
        eval { $api->volume_delete($clone_ontap_vol); };
        die "Failed to map cloned LUN to igroup: " .
            _translate_limit_error($err, 'cloned LUN map');
    }

    # Note: clone_image is only called for Linked Clone from template
    # Full Clone from VM snapshot uses the 'copy' path (temp FlexClone + qemu-img)
    # So we keep the clone as a space-efficient FlexClone here

    return $new_volname;
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::NetAppONTAPPlugin - NetApp ONTAP SAN/iSCSI Storage Plugin for Proxmox VE

=head1 SYNOPSIS

Add storage configuration in /etc/pve/storage.cfg:

    netappontap: netapp1
        portal 192.168.1.100
        svm svm0
        aggregate aggr1
        username admin
        password secret
        content images

=head1 DESCRIPTION

This plugin enables Proxmox VE to use NetApp ONTAP storage systems via iSCSI
protocol for VM disk storage.

Key features:

=over 4

=item * 1 VM disk = 1 LUN = 1 FlexVol (clean snapshot semantics)

=item * Snapshot create/delete/rollback via ONTAP Volume Snapshots

=item * Real-time capacity reporting from ONTAP

=item * Multipath I/O support

=item * Cluster-aware for live migration

=back

=head1 CONFIGURATION OPTIONS

=over 4

=item B<portal> - ONTAP management IP/hostname (required)

=item B<svm> - Storage Virtual Machine name (required)

=item B<aggregate> - Aggregate for volume creation (required)

=item B<username> - API username (required)

=item B<password> - API password (required)

=item B<ssl_verify> - Verify SSL certificates (default: yes)

=item B<thin> - Use thin provisioning (default: yes)

=item B<igroup_mode> - 'per-node' or 'shared' igroup (default: per-node)

=back

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
