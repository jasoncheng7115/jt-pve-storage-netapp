package PVE::Storage::Custom::NetAppONTAPPlugin;

use strict;
use warnings;

use base qw(PVE::Storage::Plugin);

use JSON;
use PVE::Tools qw(run_command);
use PVE::JSONSchema qw(get_standard_option);
use Fcntl qw(:flock);
use POSIX qw();
use Time::Local qw();
use PVE::INotify;
use PVE::Storage::Common;

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
    sanitize_for_ontap
);
use PVE::Storage::Custom::NetAppONTAP::ISCSI qw(
    get_initiator_name
    probe_portal
    discover_targets
    login_target
    logout_target
    rescan_sessions
    is_portal_logged_in
    get_sessions
    wait_for_device
);
use PVE::Storage::Custom::NetAppONTAP::Multipath qw(
    rescan_scsi_hosts
    multipath_reload
    get_multipath_device
    multipath_path_health
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
    list_netapp_scsi_paths
);
use File::Basename qw(basename);
use PVE::Storage::Custom::NetAppONTAP::FC qw(
    get_fc_wwpns
    is_fc_available
    rescan_fc_hosts
);

# Plugin API version.
#
# APIVERSION_MAX is the highest PVE storage-plugin API version this plugin
# actually implements. APIVERSION_MIN is the lowest it is known to work against.
#
# api() must NOT return a fixed number, because PVE's custom-plugin loader
# (PVE::Storage, "load third-party plugins") treats the two directions very
# differently:
#
#   $version > APIVER            -> HARD REJECT. The plugin is not loaded at all
#                                   and the storage silently disappears from the
#                                   node (every VM on it becomes unusable).
#   $version < APIVER - APIAGE   -> HARD REJECT ("API version too old").
#   $version != APIVER           -> loads, but PVE warns
#                                   "implementing an older storage API, an
#                                   upgrade is recommended" on EVERY load of
#                                   PVE::Storage (pvedaemon / pvestatd /
#                                   pveproxy / every pvesm invocation).
#
# Proxmox VE 9 bumped APIVER twice *within* the 9.1 point releases, and the
# supported range differs per package version (verified by unpacking each
# libpve-storage-perl from the official repository):
#
#   libpve-storage-perl 9.0.16 - 9.1.2 : APIVER 13, APIAGE 4  (accepts 9..13)
#   libpve-storage-perl 9.1.3  - 9.1.5 : APIVER 14, APIAGE 5  (accepts 9..14)
#   libpve-storage-perl 9.1.6+         : APIVER 15, APIAGE 6  (accepts 9..15)
#
# A hardcoded 15 would be REJECTED on PVE 9.0/9.1.0-9.1.5; a hardcoded 13 loads
# everywhere in 9.0-9.2 but spams the "older storage API" warning on 9.1.3+.
# So report the highest version we implement that the running PVE understands.
# This is safe because api() is only a load-time gate plus a warning: PVE always
# calls plugin methods with its own current signature regardless of what api()
# returned, and the APIVER 14/15 deltas relevant to this plugin (volume_resize's
# $snapname parameter, get_identity) are both implemented below.
use constant APIVERSION_MAX => 15;
use constant APIVERSION_MIN => 9;

# Kept for backwards compatibility with anything that referenced the old
# constants. APIVERSION is the value used when the running PVE's APIVER cannot
# be determined; 13 is accepted by every Proxmox VE 9.0/9.1/9.2 storage library.
use constant APIVERSION => 13;
use constant MIN_APIVERSION => APIVERSION_MIN;

# Mark as shared storage (accessible from multiple nodes)
push @PVE::Storage::Plugin::SHARED_STORAGE, 'netappontap';

#
# Plugin registration
#

sub api {
    # PVE::Storage is mid-compilation while it require()s us, but its APIVER /
    # APIAGE constants are established before the third-party plugin loop runs,
    # so they are readable here. Guard anyway for standalone use (unit tests,
    # `perl -c`), where we fall back to APIVERSION (13) -- accepted by every
    # Proxmox VE 9.0/9.1/9.2 storage library.
    return APIVERSION if !defined(&PVE::Storage::APIVER);

    my $pve_apiver = eval { PVE::Storage::APIVER() };
    return APIVERSION if !defined($pve_apiver) || $pve_apiver !~ /^\d+$/;

    # Never claim more than we implement (that would be dishonest and, on a
    # future PVE, still rejected), and never claim less than our floor.
    my $ver = $pve_apiver > APIVERSION_MAX ? APIVERSION_MAX : $pve_apiver;
    $ver = APIVERSION_MIN if $ver < APIVERSION_MIN;

    return $ver;
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
        # Tells PVE to strip 'ontap-password' out of the parameters before they
        # are written to /etc/pve/storage.cfg (mode 640, readable by www-data)
        # and hand it to on_add_hook/on_update_hook as %sensitive instead, so we
        # can store it under /etc/pve/priv/ (root-only). Without this,
        # PVE::Storage::Plugin::sensitive_properties() falls back to a hardcoded
        # list containing the bare name 'password', which does NOT match our
        # 'ontap-password' -- which is why the secret used to land in
        # storage.cfg verbatim.
        'sensitive-properties' => {
            'ontap-password' => 1,
        },
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
        'ontap-portal-probe-timeout' => {
            description => "Timeout in seconds for the TCP pre-check that"
                . " skips unreachable iSCSI portals before iscsiadm"
                . " discovery/login. Set to 0 to disable the pre-check"
                . " (legacy behaviour). Raise on high-latency or congested"
                . " storage networks.",
            type => 'integer',
            minimum => 0,
            maximum => 30,
            default => 2,
        },
        'ontap-status-timeout' => {
            description => "Per-call ONTAP REST timeout (seconds) used ONLY by"
                . " the pvestatd health path (activate_storage/status), with no"
                . " retry. Keeps a degraded ONTAP (e.g. one controller offline"
                . " during a firmware/ONTAP upgrade) from stalling pvestatd and"
                . " dragging sibling netappontap storages on the same node into"
                . " 'inactive'. The data path (alloc/free/clone) is unaffected"
                . " and keeps its resilient longer timeout + retries. Lower ="
                . " faster isolation of a sibling storage; higher = more"
                . " tolerance for a slow-but-alive ONTAP.",
            type => 'integer',
            minimum => 1,
            maximum => 30,
            default => 5,
        },
        'ontap-activate-deadline' => {
            description => "Wall-clock budget (seconds) for the iSCSI"
                . " discover/login loop in activate_storage. Once this budget"
                . " is spent AND at least one portal is already logged in, the"
                . " remaining portals are skipped this round (they are picked up"
                . " on a later activation). Bounds the cumulative iSCSI login"
                . " time so a single reachable-but-hanging portal cannot stall"
                . " pvestatd. An in-progress login is never interrupted, and the"
                . " loop never skips when zero portals are up yet (it must get"
                . " at least one path). Raise on high-latency fabrics with many"
                . " LIFs.",
            type => 'integer',
            minimum => 5,
            maximum => 120,
            default => 30,
        },
        'ontap-inuse-io-check' => {
            description => "Before deleting a volume whose device is NOT mapped on"
                . " this node, ask ONTAP whether the LUN is doing I/O and refuse the"
                . " delete if it is. The host-side in-use check (mounts, swap, sysfs"
                . " holders, open file descriptors) only covers the node it runs on;"
                . " on shared SAN storage the guest may be running elsewhere in the"
                . " cluster, and 'pvesm free' / the storage content view's Remove"
                . " button perform no in-use check at all. This is one-directional:"
                . " observed I/O refuses the delete, absence of I/O never blocks one"
                . " (an idle guest produces no I/O), so it cannot break 'qm destroy'."
                . " The verdict rests on BYTES transferred, not operation counts:"
                . " multipathd's path checker issues TEST UNIT READY on every mapped"
                . " LUN continuously, which moves no data but would otherwise look like"
                . " activity. ONTAP's counters lag by up to one statistics interval, so"
                . " a disk whose guest was just stopped can read as active for a few"
                . " seconds; retrying clears it. Costs a few seconds, and only on that"
                . " ambiguous path. Set to 0 to disable.",
            type => 'boolean',
            default => 1,
        },
        'ontap-delete-deadline' => {
            description => "Wall-clock budget (seconds) for the volume-delete retry"
                . " loop in free_image. free_image runs inside PVE's cluster-wide"
                . " storage lock, so a long retry loop blocks alloc/free for this"
                . " storage on every node; one ONTAP volume delete can take ~240s, so"
                . " the 5 attempts could otherwise hold that lock for ~20 minutes."
                . " Raise only if your ONTAP is legitimately slow to delete volumes.",
            type => 'integer',
            minimum => 60,
            maximum => 1800,
            default => 300,
        },
        'ontap-purge-recovery-queue' => {
            description => "Allow the plugin to purge its OWN already-deleted"
                . " FlexClones from ONTAP's volume recovery queue when they block"
                . " a snapshot or volume delete. A FlexClone that has been deleted"
                . " still counts as a clone of its parent while ONTAP retains it in"
                . " the recovery queue (per-SVM"
                . " 'volume-delete-retention-hours', default 12h), which makes"
                . " deleting the parent's snapshot fail with \"has not expired or is"
                . " locked\" and deleting the parent volume fail with \"it has one or"
                . " more clones\" -- with no hint about the queue. Only entries that"
                . " ONTAP reports as clones of the volume being operated on, that are"
                . " no longer live, and whose names match the plugin's own scheme are"
                . " ever purged. Set to 0 to keep the recovery queue untouched and"
                . " receive an actionable error instead (you then purge manually with"
                . " 'volume recovery-queue purge').",
            type => 'boolean',
            default => 1,
        },
    };
}

sub options {
    return {
        'ontap-portal'       => { fixed => 1 },
        'ontap-svm'          => { fixed => 1 },
        'ontap-aggregate'    => { fixed => 1 },
        'ontap-username'     => { fixed => 1 },
        # NOT fixed, and NOT required:
        #  - required would fail check_config, because PVE extracts a sensitive
        #    property out of the parameters BEFORE check_config runs
        #  - fixed would make the password unchangeable for the life of the
        #    storage (PVE drops fixed properties from the update schema
        #    entirely), so it could never be rotated and on_update_hook could
        #    never fire. Matches PBSPlugin, which declares `password` optional
        #    for the same reasons.
        'ontap-password'     => { optional => 1 },
        'ontap-ssl-verify'   => { optional => 1 },
        'ontap-thin'         => { optional => 1 },
        'ontap-igroup-mode'  => { optional => 1 },
        'ontap-cluster-name' => { optional => 1 },
        'ontap-protocol'     => { optional => 1 },
        'ontap-device-timeout' => { optional => 1 },
        'ontap-portal-probe-timeout' => { optional => 1 },
        'ontap-status-timeout' => { optional => 1 },
        'ontap-activate-deadline' => { optional => 1 },
        'ontap-inuse-io-check' => { optional => 1 },
        'ontap-delete-deadline' => { optional => 1 },
        'ontap-purge-recovery-queue' => { optional => 1 },
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

# Turn a storage ID into something safe to put in a filename -- validating and
# UNTAINTING in the same operation.
#
# This must be one capture. A substitution does NOT untaint: the old code here
# was `$safe =~ s/[^a-zA-Z0-9_-]/_/g`, which looks sanitised and still carries
# the taint, so `rename`/`unlink` on the resulting path dies with
# "Insecure dependency" under -T. That is invisible from `qm` and `pvesm`
# (plain `#!/usr/bin/perl`) and fires from `pvedaemon`, `pveproxy`, `vzdump`
# and `pct`, all of which are `#!/usr/bin/perl -T`.
#
# The pattern is PVE's own storage-ID rule (JSONSchema::parse_id): at least two
# characters, starting with a letter, ending alphanumeric, `-`, `_` and `.`
# allowed between. A value PVE could not have produced is refused rather than
# mangled into a different storage's filename.
sub _storeid_filename_component {
    my ($storeid) = @_;

    die "storage ID is required to build a state file name\n"
        if !defined($storeid) || !length($storeid);

    my ($safe) = ($storeid =~ /\A([a-z][a-z0-9\-\_\.]*[a-z0-9])\z/i);

    die "refusing to build a file name from storage ID '$storeid'"
        . " (not a valid Proxmox VE storage ID)\n"
        if !defined($safe);

    return $safe;
}

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
    my ($scfg, %opts) = @_;

    # status_path: a short-timeout, single-attempt client for the pvestatd
    # health path (activate_storage/status). A degraded ONTAP must fail fast
    # here so it cannot back up pvestatd's sequential storage loop and starve
    # sibling netappontap storages on the same node into 'inactive'. The data
    # path keeps the resilient default client (longer timeout + retries).
    # Cached under a separate key so the two clients never clobber each other.
    my $status_path = $opts{status_path} ? 1 : 0;

    # Cache key MUST include the SVM, not just the portal.
    #
    # PVE never populates $scfg->{storage} (verified: no PVE code path sets it),
    # so the old `$scfg->{storage} // $scfg->{'ontap-portal'}` key degraded to
    # "portal only". The cache-validity check below then compared host AND svm,
    # so the very common layout "one ONTAP cluster / one management LIF, two
    # SVMs, two netappontap storages on the same node" made each storage evict
    # the other's client on every single _get_api() call. Rebuilding the client
    # throws away its keep-alive connection, which puts us straight back into the
    # "new TCP + TLS handshake + basic auth on every REST request" behaviour that
    # caused the 2026-06-16 ONTAP mgwd congestion collapse (v0.2.19). Keying on
    # (portal, svm, path) keeps sibling storages on independent, reused
    # connections.
    my $cache_key = join("\0",
        $scfg->{'ontap-portal'} // 'unknown',
        $scfg->{'ontap-svm'} // 'unknown',
        $status_path ? 'status' : 'data',
    );

    # storeid is REQUIRED: it names the credential file. Without it a migrated
    # storage (password only in /etc/pve/priv) silently falls back to undef and
    # fails later as a bare "password is required", far from the actual cause.
    die "_get_api requires a storeid\n"
        if !defined($opts{storeid}) || !length($opts{storeid});

    my $password = _get_ontap_password($opts{storeid}, $scfg);

    # Return cached client if available, config hasn't changed, and cache is fresh.
    # The password is part of the validity check so that rotating it takes effect
    # on the next call instead of after API_CACHE_TTL -- a long-running pvedaemon
    # would otherwise keep authenticating with the old one for minutes.
    if (my $cached = $api_cache{$cache_key}) {
        my $cache_age = time() - ($cached->{timestamp} // 0);
        if ($cache_age < API_CACHE_TTL &&
            ($cached->{host} // '') eq ($scfg->{'ontap-portal'} // '') &&
            ($cached->{svm} // '') eq ($scfg->{'ontap-svm'} // '') &&
            ($cached->{password} // '') eq ($password // '')) {
            return $cached->{api};
        }
    }

    my $ssl_verify = $scfg->{'ontap-ssl-verify'} // 1;

    my %api_opts = (
        host       => $scfg->{'ontap-portal'},
        username   => $scfg->{'ontap-username'},
        password   => $password,
        svm        => $scfg->{'ontap-svm'},
        aggregate  => $scfg->{'ontap-aggregate'},
        ssl_verify => $ssl_verify,
    );
    if ($status_path) {
        # No retry: pvestatd re-polls every ~10s, so the next poll IS the
        # retry. One short attempt bounds the per-cycle cost to ~timeout.
        $api_opts{timeout}     = $scfg->{'ontap-status-timeout'} // 5;
        $api_opts{retry_count} = 1;
    }

    my $api = PVE::Storage::Custom::NetAppONTAP::API->new(%api_opts);

    $api_cache{$cache_key} = {
        api       => $api,
        host      => $scfg->{'ontap-portal'},
        svm       => $scfg->{'ontap-svm'},
        password  => $password,
        timestamp => time(),
    };

    return $api;
}

# Refuse to let two storages share one ONTAP volume namespace.
#
# Volume names are pve_{sanitized-storeid}_{vmid}_disk{N}, and
# sanitize_for_ontap() TRUNCATES the storage ID to 32 characters (and strips
# characters PVE allows but ONTAP does not, e.g. '.'). Two DIFFERENT PVE storage
# IDs can therefore produce the SAME prefix -- for example
# 'netapp-production-cluster-alpha-one' and 'netapp-production-cluster-alpha-two'
# both become 'netapp_production_cluster_alpha_'.
#
# If those two storages also point at the same SVM, they address literally the
# same FlexVols: list_images() on one reports the other's disks, and free_image()
# on one DELETES the other's volume. That is silent cross-storage data loss.
#
# We cannot fix this by changing the naming scheme -- that would rename every
# existing customer volume. Instead we refuse to create the collision, and warn
# about any that predate this check. Note the SVM is part of the test: the same
# prefix under a different SVM is a different namespace and is fine.
sub _assert_unique_ontap_namespace {
    my ($storeid, $scfg, $noerr) = @_;

    my $prefix = sanitize_for_ontap($storeid, 32);
    my $portal = $scfg->{'ontap-portal'} // '';
    my $svm    = $scfg->{'ontap-svm'} // '';
    return 1 if !length($prefix) || !length($svm);

    my $cfg = eval { PVE::Storage::config(); };
    return 1 if !$cfg || !$cfg->{ids};

    for my $other_id (sort keys %{ $cfg->{ids} }) {
        next if $other_id eq $storeid;
        my $other = $cfg->{ids}{$other_id};
        next unless $other && ($other->{type} // '') eq 'netappontap';
        next unless ($other->{'ontap-svm'} // '') eq $svm;
        next unless ($other->{'ontap-portal'} // '') eq $portal;
        next unless sanitize_for_ontap($other_id, 32) eq $prefix;

        my $msg =
            "storage '$storeid' would share the ONTAP volume namespace 'pve_${prefix}_*' "
          . "with existing storage '$other_id' (same portal '$portal', same SVM '$svm').\n"
          . "  ONTAP volume names are pve_{storage}_{vmid}_disk{N} with the storage ID "
          . "sanitized and truncated to 32 characters, so these two IDs are "
          . "indistinguishable on ONTAP.\n"
          . "  Both storages would address the SAME FlexVols: one would list the "
          . "other's disks, and deleting a disk on one would DESTROY the other's "
          . "volume.\n"
          . "  Use a storage ID whose first 32 sanitized characters differ, or a "
          . "different SVM.\n";

        die $msg if !$noerr;
        warn "WARNING: $msg";
        return 0;
    }

    return 1;
}

#
# ONTAP API password storage
#
# PVE keeps storage secrets under /etc/pve/priv/ (root-only, cluster-wide via
# pmxcfs), NOT in /etc/pve/storage.cfg, which is mode 640 root:www-data and so
# readable by pveproxy. PBSPlugin is the closest reference implementation: same
# shape as us (a password used to authenticate against an external REST
# service, read on the status path), same file name and mode.
#
# Backward compatibility: storages created before 0.2.28 have the secret inline
# in storage.cfg. _get_ontap_password() therefore prefers the priv file and
# FALLS BACK to $scfg->{'ontap-password'}, so an existing storage keeps working
# with no action required. Any `pvesm set` on that storage migrates it (see
# on_update_hook_full), and the cleartext copy is removed from storage.cfg at
# the same time. To migrate immediately without changing anything else:
#
#   pvesm set <storeid> --ontap-password '<password>'
#
# Package variable so the test suite can redirect writes away from the real
# /etc/pve/priv. Never reassign it in plugin code.
our $PRIV_STORAGE_DIR = '/etc/pve/priv/storage';

sub _ontap_password_file {
    my ($storeid) = @_;
    # Validated and untainted -- this path is passed to file_set_contents and
    # unlink, both of which die under -T on a tainted value.
    return "$PRIV_STORAGE_DIR/" . _storeid_filename_component($storeid) . ".pw";
}

sub _set_ontap_password {
    my ($storeid, $password) = @_;

    mkdir $PRIV_STORAGE_DIR;
    PVE::Tools::file_set_contents(
        _ontap_password_file($storeid), "$password\n", 0600);

    return;
}

sub _delete_ontap_password {
    my ($storeid) = @_;

    my $file = _ontap_password_file($storeid);
    if (-e $file) {
        unlink($file)
            or warn "removing ONTAP password file '$file' failed: $!\n";
    }

    return;
}

# Returns the password, or undef if neither location has one.
sub _get_ontap_password {
    my ($storeid, $scfg) = @_;

    if (defined($storeid)) {
        my $file = _ontap_password_file($storeid);
        if (-e $file) {
            my $pw = eval { PVE::Tools::file_read_firstline($file) };
            return $pw if defined($pw) && $pw ne '';
        }
    }

    # Pre-0.2.28 storage, or a config written by hand.
    return $scfg->{'ontap-password'};
}

# Called by PVE before a new storage is written to the config (locked context).
# %sensitive carries 'ontap-password' because plugindata() declares it in
# 'sensitive-properties' -- by this point PVE has already removed it from $scfg,
# so it never reaches storage.cfg.
sub on_add_hook {
    my ($class, $storeid, $scfg, %sensitive) = @_;

    _assert_unique_ontap_namespace($storeid, $scfg);

    if (defined($sensitive{'ontap-password'})) {
        _set_ontap_password($storeid, $sensitive{'ontap-password'});
    } elsif (!defined($scfg->{'ontap-password'})) {
        # 'ontap-password' cannot be declared required (see options()), so catch
        # a missing password here instead of failing later inside an API call.
        die "storage '$storeid': ontap-password is required\n";
    }

    return undef;
}

# PVE calls on_update_hook_full (not on_update_hook) for any plugin whose api()
# is >= 13, which is every version we support. We override the _full variant
# because only it receives the CURRENT $scfg -- needed to purge a legacy
# cleartext password. Mutating $scfg here persists: PVE applies deletions and
# merges the update into this same hash after the hook returns, then writes it.
sub on_update_hook_full {
    my ($class, $storeid, $scfg, $update, $delete, $sensitive) = @_;

    if (exists($sensitive->{'ontap-password'})) {
        if (defined($sensitive->{'ontap-password'})) {
            _set_ontap_password($storeid, $sensitive->{'ontap-password'});
            # Drop any pre-0.2.28 cleartext copy now that the secret is stored
            # in /etc/pve/priv/.
            delete $scfg->{'ontap-password'};
        } else {
            # Caller asked to remove the password outright.
            _delete_ontap_password($storeid);
        }
        return undef;
    }

    # Deliberately NO automatic migration of a legacy inline password here.
    #
    # Both /etc/pve/storage.cfg and /etc/pve/priv are cluster-wide (pmxcfs).
    # Removing the cleartext key would take effect on every node at once, while
    # a node still running < 0.2.28 reads ONLY $scfg->{'ontap-password'} -- so
    # migrating during a rolling upgrade would break the storage on every
    # not-yet-upgraded node. Migration is therefore an explicit operator action,
    # performed after the whole cluster is upgraded:
    #
    #     pvesm set <storeid> --ontap-password '<password>'
    #
    # Until then the fallback in _get_ontap_password() keeps the storage working
    # untouched on old and new nodes alike.

    return undef;
}

sub on_delete_hook {
    my ($class, $storeid, $scfg) = @_;

    _delete_ontap_password($storeid);

    return undef;
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
    # Backup fleecing scratch disk: vm-100-fleece-0 (Proxmox VE 9).
    # PVE::VZDump::QemuServer::vdisk_alloc's it by name on whichever storage is
    # configured as the fleecing target, so it is an ordinary allocation here.
    } elsif ($volname =~ /^vm-(\d+)-fleece-(\d+)$/) {
        return {
            vmid   => $1,
            diskid => $2,
            format => 'raw',
            type   => 'fleece',
            isBase => 0,
        };
    }

    return undef;
}

# Get next available disk ID for a VM
sub _find_free_diskid {
    my ($scfg, $storeid, $vmid) = @_;

    my $api = _get_api($scfg, storeid => $storeid);

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
    #
    # status_path => 1: use the short-timeout, no-retry client. A degraded
    # ONTAP (e.g. a controller mid-upgrade whose mgmt REST read-times-out) must
    # fail this check in ~ontap-status-timeout seconds, NOT ~32s. Otherwise the
    # several sequential REST calls below (each 15s x 2 retries on the default
    # client) stack up -- the field incident showed pvestatd "status update
    # time (189s)" -- and pvestatd's sequential storage loop drags sibling
    # netappontap storages on the same node into 'inactive'. The next pvestatd
    # poll (~10s) is the retry, so dropping per-call retries here loses nothing.
    my $api = eval { _get_api($scfg, storeid => $storeid, status_path => 1); };
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

        my $probe_timeout = $scfg->{'ontap-portal-probe-timeout'} // 2;
        my @logged_in;
        my @unreachable;
        my @failed;
        my @skipped_budget;

        # Wall-clock budget for the cumulative discover/login work (v0.2.20).
        # Per-call timeouts (probe 2s, discovery 30s, login 60s) bound EACH
        # portal but NOT the loop's total time -- with several reachable-but-
        # hanging LIFs the sum can still wedge pvestatd (the "never wedge PVE"
        # rule; same lesson as v0.2.12). Once the budget is spent AND we already
        # have a working path, stop starting NEW logins. We never interrupt an
        # in-progress login, and we never skip while zero portals are up (we
        # must obtain at least one path or fail honestly).
        my $login_deadline = time() + ($scfg->{'ontap-activate-deadline'} // 30);

        # Snapshot current iSCSI sessions ONCE (one `iscsiadm -m session` call)
        # instead of re-running it per portal via is_portal_logged_in(). With
        # many LIFs and a degraded iscsid the per-portal calls would otherwise
        # add N x up-to-30s -- and that runs BEFORE the budget gate, so the
        # budget could not bound it. One snapshot keeps the loop's setup cost
        # flat. (Empty list on error -> treat all as not-logged-in, safe.)
        my $iscsi_sessions = eval { get_sessions(); } // [];

        for my $portal (@$portals) {
            my $portal_addr = "$portal->{address}:$portal->{port}";

            # Fast path: already logged in (free -- always counted, even past
            # the budget). Uses the one-shot session snapshot.
            if (is_portal_logged_in($portal_addr, $portal->{target}, $iscsi_sessions)) {
                push @logged_in, $portal_addr;
                next;
            }

            # Budget gate: past the deadline with at least one path already up
            # -> defer the rest to a later activation rather than risk stalling
            # pvestatd on a slow/hanging portal.
            if (time() >= $login_deadline && @logged_in) {
                push @skipped_budget, $portal_addr;
                next;
            }

            # TCP pre-check: skip portals this host cannot reach so we do
            # NOT eat 30s discovery + 60s login timeouts per dead LIF.
            # ONTAP HA best practice distributes iSCSI LIFs across both
            # controllers and across multiple network segments; with
            # asymmetric cabling the unreachable LIFs would otherwise
            # stall every activate_storage()/status() and cascade into
            # pvestatd timeouts that wedge the web UI.
            if ($probe_timeout > 0
                && !probe_portal($portal->{address}, $portal->{port},
                                 timeout => $probe_timeout)) {
                push @unreachable, $portal_addr;
                next;
            }

            eval {
                discover_targets($portal->{address}, port => $portal->{port});
                login_target($portal->{address}, $portal->{target},
                             port => $portal->{port});
            };
            if ($@) {
                my $err = $@;
                push @failed, "$portal_addr ($err)";
                warn "Failed to connect to portal $portal->{address}: $err";
            } else {
                push @logged_in, $portal_addr;
            }
        }

        if (@unreachable) {
            warn "Skipped " . scalar(@unreachable)
                . " unreachable iSCSI portal(s) on SVM '$scfg->{'ontap-svm'}': "
                . join(", ", @unreachable)
                . " (no TCP response within ${probe_timeout}s).\n"
                . "  If this is unexpected, check network/switch zoning"
                . " between this node and the listed LIFs, or move"
                . " unused LIFs off the SVM.\n";
        }

        if (@skipped_budget) {
            warn "Deferred login to " . scalar(@skipped_budget)
                . " iSCSI portal(s) on SVM '$scfg->{'ontap-svm'}' after the "
                . "activate budget (" . ($scfg->{'ontap-activate-deadline'} // 30)
                . "s) with " . scalar(@logged_in) . " path(s) already up: "
                . join(", ", @skipped_budget) . ".\n"
                . "  These are picked up on a later activation; this protects "
                . "pvestatd from a slow/hanging portal. If it recurs, check why "
                . "those LIFs are slow to log in (or raise ontap-activate-deadline).\n";
        }

        unless (@logged_in) {
            my $msg = "No iSCSI portal on SVM '$scfg->{'ontap-svm'}' is"
                . " reachable from this node.";
            $msg .= " Unreachable: " . join(", ", @unreachable) if @unreachable;
            $msg .= " Failed: " . join("; ", @failed) if @failed;
            $msg .= "\n  Verify network connectivity to the SVM's iSCSI"
                . " LIFs, or use 'pvesm set <storeid> --nodes <list>' to"
                . " bind this storage only to nodes that can reach it.";
            die "$msg\n";
        }
    }

    # Ensure igroup exists (common for both protocols)
    _ensure_igroup($scfg, $api);

    # Namespace-collision check for configs created before on_add_hook existed.
    # Warn only -- refusing to activate an existing storage would take running
    # guests offline, which is worse than the collision it reports.
    eval { _assert_unique_ontap_namespace($storeid, $scfg, 1); };

    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    # Tear down this storage's host-side state: multipath devices + SCSI paths
    # for every LUN of this storage, plus the iSCSI sessions to its SVM.
    #
    # NOTE ON WHEN THIS RUNS: nothing in Proxmox VE 9.0/9.1/9.2 calls
    # PVE::Storage::deactivate_storage() (verified across the whole
    # /usr/share/perl5/PVE tree: only the dispatcher at Storage.pm and the per-
    # plugin implementations exist). The earlier comment here claimed it runs
    # "when storage is disabled or removed", which is not true on PVE 9 -- do not
    # rely on this function for cleanup on `pvesm set --disable` or storage
    # removal. It is effectively operator/manual territory today.
    #
    # Because it IS destructive and could be reached manually (or by a future PVE
    # release), it must obey the same safety rule as the orphan reaper: never tear
    # down a device that still has an active multipath path. is_device_in_use()
    # alone is NOT sufficient -- a QEMU-held disk of a running VM is an open fd,
    # not a sysfs holder, so is_device_in_use() does not see it (v0.2.17 lesson).
    # Without the path-health gate this function would reproduce the v0.2.17
    # incident: multipath -f fails on the busy map, the dmsetup remove --force
    # fallback rips it out from under QEMU, and the running guest takes I/O
    # errors. v0.2.18's Step 8 sweep would additionally remove every sd path for
    # the WWID.

    warn "Deactivating storage '$storeid': cleaning up connections...\n";

    my $protocol = $scfg->{'ontap-protocol'} // 'iscsi';
    my $cleanup_count = 0;
    my $skip_count = 0;

    # Step 1: Force cleanup temporary FlexClones for this storage (from state file)
    # This works even if ONTAP is unreachable - we just clear the local state
    eval { _cleanup_temp_clones_for_storage($storeid); };
    warn "Temp FlexClone state cleanup: $@\n" if $@;

    # Step 2: Try to connect to ONTAP API
    my $api = eval { _get_api($scfg, storeid => $storeid); };
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
    # MUST use sanitize_for_ontap(), the same function encode_volume_name() uses
    # to build the real volume names. A naive s/-/_/g diverges from it for any
    # storage ID containing a dot (PVE allows [a-z][a-z0-9\-\_\.]*[a-z0-9]) or
    # longer than 32 chars, because sanitize_for_ontap also strips non-word
    # characters and truncates. A divergent prefix makes this query match NOTHING,
    # which is dangerous here: an empty result reads as "nothing exists".
    my $san_storeid = sanitize_for_ontap($storeid, 32);
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

            # Path-health gate (see the rationale at the top of this function).
            # 1 = at least one active path -> live, do NOT touch.
            # -1 = indeterminate (multipathd unreachable / unparseable output) ->
            #      also do NOT touch; a false "it's dead" costs data availability,
            #      a false "it's alive" only leaves a stale device for later.
            # 0 = map exists and ALL paths failed -> genuinely safe to tear down.
            my $health = eval { multipath_path_health($wwid); };
            if (!defined $health || $health != 0) {
                warn "  [SKIP] $vol->{name}: device $device still has active "
                   . "path(s) or path state is indeterminate; refusing to tear "
                   . "down a live device\n";
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
    return "$WWID_STATE_DIR/" . _storeid_filename_component($storeid) . "-wwids.json";
}

sub _wwid_lock_file {
    my ($storeid) = @_;
    return "$WWID_LOCK_DIR/" . _storeid_filename_component($storeid) . "-wwids.lock";
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

# Stale-SCSI-path grace state (v0.2.19). Lives in /var/run (tmpfs) -- it only
# enforces a "seen reapable for >= N seconds" grace window, so losing it on
# reboot is harmless (a reboot clears the stale sd anyway). Keyed per storage;
# only the per-storage background grandchild touches it, so no lock is needed.
sub _stale_sd_state_file {
    my ($storeid) = @_;
    (my $safe = $storeid) =~ s/[^a-zA-Z0-9_-]/_/g;
    return "$WWID_LOCK_DIR/${safe}-stale-sd.json";
}

sub _read_stale_sd_state {
    my ($storeid) = @_;
    my $file = _stale_sd_state_file($storeid);
    return {} unless -f $file;
    my $json = do { local $/; open my $fh, '<', $file or return {}; <$fh> };
    return eval { JSON::decode_json($json) } // {};
}

sub _write_stale_sd_state {
    my ($storeid, $state) = @_;
    _ensure_wwid_state_dir();   # also (re)creates the /var/run tmpfs dir
    my $file = _stale_sd_state_file($storeid);
    my $tmp = "$file.tmp.$$";
    open my $fh, '>', $tmp or do {
        warn "Cannot write stale-sd state file $tmp: $!\n";
        return;
    };
    print $fh JSON::encode_json($state);
    close $fh;
    rename($tmp, $file) or warn "Cannot rename $tmp -> $file: $!\n";
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
    # MUST use sanitize_for_ontap() -- see the note in deactivate_storage().
    # This one is load-bearing for DATA AVAILABILITY: a prefix that does not match
    # the real volume names yields an EMPTY alive set, so every tracked WWID looks
    # like a deleted LUN. The path-health gate still protects devices with active
    # paths, but a device whose paths are all momentarily down (controller
    # failover, fabric blip) would then be torn down even though its LUN is alive.
    my $san_storage = sanitize_for_ontap($storeid, 32);
    my $luns = eval { $api->lun_list("/vol/pve_${san_storage}_*/lun0"); };
    if ($@ || !defined $luns) {
        # API error - abort to avoid false positives
        warn "Orphan cleanup: failed to query ONTAP LUN list: $@\n" if $@;
        return;
    }

    # Build set of currently-alive WWIDs and auto-import them into tracking.
    #
    # PERFORMANCE (v0.2.21, CRITICAL): lun_list() already returns
    # serial_number for every LUN in ONE paginated call, so compute the WWID
    # locally via serial_to_wwid(). The previous code called
    # lun_get_wwid($lun->{name}) per LUN -- an N+1 REST storm (lun_get_serial
    # -> lun_get -> GET, once PER LUN). This runs in the status() background
    # cleanup on EVERY ~10s poll on EVERY cluster node, so an SVM with 75 LUNs
    # x N nodes generated ~75*N REST calls every 10s -- enough to overwhelm
    # ONTAP's management gateway (mgwd) into congestion collapse, especially
    # after a firmware upgrade leaves mgwd more load-sensitive. serial_to_wwid()
    # is pure local computation (no REST). 75 calls/poll -> 0 extra.
    my %alive_wwids;
    for my $lun (@$luns) {
        my $serial = $lun->{serial_number};
        my $wwid = $serial ? $api->serial_to_wwid($serial) : undef;
        next unless $wwid;
        $alive_wwids{lc($wwid)} = 1;
        # Auto-import: ensure this WWID is tracked even if path() was never
        # called on this node. _track_wwid is idempotent (no-op if already tracked).
        eval { _track_wwid($storeid, $wwid); };
    }

    # Read tracked WWIDs AFTER auto-import
    my $tracked = _read_wwid_state($storeid);

    # Phase 2: Find orphans = tracked WWIDs that are no longer on ONTAP
    #
    # Grace window (v0.2.17): the bulk lun_list() snapshot used to build the
    # alive set can lag behind a freshly-created LUN (ONTAP read-after-write /
    # propagation delay -- same class as the v0.2.9 ASA eventual-consistency
    # issue, but here it feeds the reaper's "alive" set). A LUN tracked only
    # seconds ago that appears "missing" from the bulk query is almost always
    # a brand-new disk the query has not caught up to, NOT a deleted one.
    # $tracked->{$wwid} is the first-tracked epoch; skip reaping until the WWID
    # has been continuously absent past this window.
    my $ORPHAN_GRACE_SECS = 300;
    my $cleaned = 0;
    for my $wwid (keys %$tracked) {
        next if $alive_wwids{$wwid};

        my $tracked_at = $tracked->{$wwid};
        if ($tracked_at && $tracked_at =~ /^\d+$/
            && (time() - $tracked_at) < $ORPHAN_GRACE_SECS) {
            next;  # recently tracked: assume bulk list just hasn't caught up
        }

        # WWID is no longer on ONTAP. Check if there's a local multipath device
        # to clean up. cleanup_lun_devices is idempotent and safe.
        my $mpath = get_multipath_device($wwid);
        if ($mpath) {
            # Path-health gate (v0.2.17, CRITICAL): a genuinely orphaned LUN
            # (deleted on ONTAP) has ALL paths failed/faulty. A live, in-use
            # device -- e.g. a just-added VM disk -- still has active paths.
            # NEVER tear down a device that has an active path: that destroys a
            # live VM disk and causes immediate I/O errors (exactly the field
            # incident this guard was added for). If health is indeterminate
            # (-1) we also refuse, erring on the side of preserving I/O.
            my $health = multipath_path_health($wwid);
            if ($health != 0) {
                warn "Orphan cleanup: WWID $wwid is absent from the ONTAP LUN " .
                     "list but its multipath device still has active path(s) " .
                     "(or path state is indeterminate). Refusing to remove a " .
                     "live device; keeping tracked for re-evaluation.\n";
                next;
            }

            warn "Orphan cleanup: removing stale device for WWID $wwid (LUN deleted on ONTAP, all paths failed)\n";
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
    #
    # Cross-storage cross-talk fix (v0.2.15): list_netapp_multipath_devices()
    # returns ALL NETAPP vendor devices on host with no storage filter. When
    # multiple netappontap storages are configured (e.g. customer with both
    # netappASA and netappFAS_Node2 on the same PVE node), the per-storage
    # cleanup loop would falsely flag the OTHER storage's legitimate LUNs as
    # "untracked orphans". Symptoms: false-positive warnings like
    # "multipathd disablequeueing map <wwid>" / "multipath -f <wwid>" for
    # WWIDs that are perfectly healthy plugin-managed LUNs in a sibling
    # storage. If the operator follows the suggested commands, they would
    # tear down active VM disks. Fix: build a union of WWIDs tracked by any
    # OTHER netappontap storage and treat them as "owned by another sibling
    # storage; not our concern". Each storage's own cleanup still runs
    # independently to handle its own orphans.
    #
    # Built once here (hoisted out of the eval below) so the v0.2.19 stale-SCSI-
    # path reaper can reuse the exact same sibling-ownership set.
    my %other_plugin_wwid;
    {
        my $cfg = eval { PVE::Storage::config(); };
        if ($cfg && $cfg->{ids}) {
            for my $other_storeid (keys %{$cfg->{ids}}) {
                next if $other_storeid eq $storeid;
                my $other_scfg = $cfg->{ids}{$other_storeid};
                next unless $other_scfg && ($other_scfg->{type} // '') eq 'netappontap';
                # Read-only access to the sibling storage's tracking file.
                # _read_wwid_state() does atomic-rename-aware reads so we
                # don't need to hold the sibling's lock for a consistent
                # snapshot.
                my $other_tracked = eval { _read_wwid_state($other_storeid); } // {};
                $other_plugin_wwid{lc($_)} = 1 for keys %$other_tracked;
            }
        }
    }

    eval {
        my $netapp_devs = list_netapp_multipath_devices();
        my @untracked;
        for my $dev (@$netapp_devs) {
            my $wwid = lc($dev->{wwid});
            next if $alive_wwids{$wwid};       # alive on ONTAP, leave alone
            next if $tracked->{$wwid};         # already handled in first pass
            next if $other_plugin_wwid{$wwid}; # owned by sibling plugin storage
            # Path-health gate (v0.2.17): only flag devices whose paths are ALL
            # failed (genuine stale residue). A device with active paths is in
            # use -- suggesting `multipath -f` on it would tear down live I/O.
            # health: 1 = active paths, -1 = indeterminate -> skip warning in
            # both cases; only 0 (all paths failed) is a real stale candidate.
            my $health = eval { multipath_path_health($dev->{wwid}); };
            next unless defined $health && $health == 0;
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

    # Third pass (v0.2.19): reap stale RAW SCSI (sd) paths left behind by
    # LUN-ID reuse. These are below the multipath-map layer the first two
    # passes operate on, so neither catches them. Reuses the alive set,
    # tracking, and sibling-ownership already computed above.
    eval { _reap_stale_scsi_paths($storeid, \%alive_wwids, $tracked, \%other_plugin_wwid); };
    warn "Stale SCSI path reaper error for '$storeid': $@\n" if $@;
}

# v0.2.19: reap stale raw SCSI (sd) paths left behind by LUN-ID reuse.
#
# Background: in per-node igroup mode every LUN is mapped to ALL node igroups
# (so VMs can migrate). When a LUN is deleted, only the node that ran
# free_image() tears down its sd paths; other nodes that merely had it mapped
# keep stale sd. ONTAP later reuses that freed SCSI LUN-ID for a DIFFERENT LUN.
# On those other nodes the stale sd (whose backing LUN is gone -- it now reports
# no WWID, or a cached old one) shadows the reused LUN-ID, and device-mapper
# cannot build the new map: "error getting device (-EBUSY)"; the map never
# appears in `multipath -ll`. The teardown-time sweep (get_scsi_paths_for_wwid)
# cannot catch these because they no longer advertise any matchable WWID. This
# reaper works at the raw-sd / topology level instead.
#
# SAFETY (data-availability is paramount -- a false reap destroys live I/O). An
# sd is removed ONLY when ALL of the following hold:
#   - vendor is NETAPP (enforced inside list_netapp_scsi_paths)
#   - it has NO holders (not in any multipath map, no LVM/dm-crypt/kpartx on
#     top) and is not mounted/swap. Any in-use path is excluded by this alone,
#     because an in-use path is always a holder of something.
#   - it is provably plugin-scoped stale, by ONE of:
#       Case A (orphan): a readable WWID that THIS storage tracked but is no
#         longer in the ONTAP alive set, and not owned by a sibling storage.
#       Case B (reused LUN-ID): a sibling sd at the SAME iSCSI target IQN and
#         SAME LUN-ID reports a WWID that IS in the ONTAP alive set (a live
#         pve_* LUN), while this sd reports a DIFFERENT WWID (or none). Within
#         one target a LUN-ID maps to exactly one LUN, so a mismatch here is by
#         definition stale residue of that LUN-ID's previous tenant -- and the
#         live sibling proves the slot now belongs to a plugin LUN, so this is
#         never a customer's manually-managed LUN.
#   - it has been continuously reapable for >= 300s (grace), ruling out a
#     freshly discovered device whose INQUIRY has not completed, and ONTAP
#     read-after-write races (same class as the v0.2.17 orphan-reaper grace).
#
# If ONTAP could not be queried the caller has already aborted before reaching
# here, so the alive set is always authoritative. Anything indeterminate is left
# alone: we would rather leave a stale device for the next poll than risk
# removing a live one.
sub _reap_stale_scsi_paths {
    my ($storeid, $alive_wwids, $tracked, $other_plugin_wwid) = @_;

    my $paths = eval { list_netapp_scsi_paths(); } // [];
    return unless @$paths;

    # For each (iSCSI target IQN, SCSI LUN-ID), record the alive plugin WWID a
    # sibling path reports there (if any). This is the Case B reuse evidence.
    my %alive_at;
    for my $p (@$paths) {
        next unless defined $p->{target_id} && defined $p->{lun};
        next unless $p->{wwid} && $alive_wwids->{$p->{wwid}};
        $alive_at{"$p->{target_id}\0$p->{lun}"} = $p->{wwid};
    }

    # Grace state (tmpfs): reapable-key -> first-seen epoch. We only persist
    # keys still reapable this pass, so a device that recovers (or is reaped)
    # drops out and its grace timer resets.
    my $seen = _read_stale_sd_state($storeid);
    my %new_seen;
    my $GRACE_SECS = 300;

    my @reap;
    for my $p (@$paths) {
        next if $p->{has_holders};   # in a map / stacked / live -> NEVER reap
        next if $p->{mounted};

        my $w = $p->{wwid};          # '' if the device reports none
        my $gkey = (defined $p->{target_id} && defined $p->{lun})
            ? "$p->{target_id}\0$p->{lun}" : undef;
        my $alive_here = defined $gkey ? $alive_at{$gkey} : undef;

        my $reason;
        if ($w && $alive_wwids->{$w}) {
            # This sd IS a live LUN's path -> absolutely never reap.
            next;
        } elsif (defined $alive_here && (!$w || $w ne $alive_here)) {
            # Case B: the LUN-ID is now owned by a live plugin LUN ($alive_here)
            # on a sibling path; this path is the stale leftover of its previous
            # tenant.
            $reason = "reused LUN-ID at $p->{hctl} (live $alive_here on a "
                    . "sibling path; this path stale)";
        } elsif ($w && $tracked->{$w} && !$other_plugin_wwid->{$w}) {
            # Case A: orphan of a deleted plugin LUN this storage tracked.
            $reason = "orphan of deleted tracked LUN $w at $p->{hctl}";
        } else {
            # Untracked/unknown WWID, or no reuse evidence -> could be a
            # customer's manual storage or a transient. Leave it alone.
            next;
        }

        my $key = "$p->{hctl}|$w";
        my $first = $seen->{$key};
        if (!$first) {
            # First time we have seen this path reapable: start the grace clock.
            $new_seen{$key} = time();
            next;
        }
        $new_seen{$key} = $first;
        next if (time() - $first) < $GRACE_SECS;

        push @reap, { %$p, reason => $reason };
    }

    _write_stale_sd_state($storeid, \%new_seen);

    return unless @reap;

    my $reaped = 0;
    for my $p (@reap) {
        warn "Stale SCSI path reaper: removing /dev/$p->{dev} ($p->{reason})\n";
        eval { remove_scsi_device("/dev/$p->{dev}"); $reaped++; 1; }
            or warn "Stale SCSI path reaper: failed to remove /dev/$p->{dev}: $@\n";
    }

    if ($reaped) {
        # Self-heal: rescan the iSCSI hosts so the now-freed LUN-ID is
        # rediscovered cleanly, then reconfigure multipath so the map that was
        # previously blocked with -EBUSY can finally load. rescan_scsi_hosts()
        # is iSCSI-host scoped (safe per the SCSI-host-scan-filtering rule).
        warn "Stale SCSI path reaper: removed $reaped stale path(s) for "
           . "'$storeid'; rescanning and reloading multipath to rebuild "
           . "clean maps\n";
        eval { rescan_scsi_hosts(delay => 1); };
        eval { multipath_reload(); };
    }
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
    my $file = "$dir/" . _storeid_filename_component($storeid) . "-failstate";
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
    my $file = "$dir/" . _storeid_filename_component($storeid) . "-failstate";
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
    my $flag = "$dir/" . _storeid_filename_component($storeid) . "-aggr-warn";
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
# Detect a SECOND Proxmox VE cluster using the same ONTAP volume namespace.
#
# Volume names are pve_{storage}_{vmid}_disk{N} -- there is NO cluster component.
# 'ontap-cluster-name' only ever appears in IGROUP names. So two PVE clusters that
# each have a storage called e.g. 'netapp1' pointing at the same SVM share the
# namespace pve_netapp1_* completely.
#
# The dangerous consequence is not allocation (alloc_image checks existence and
# picks the next free disk ID) but VISIBILITY: list_images() returns the other
# cluster's volumes as if they belonged here, so they appear in the storage
# content view and in `qm rescan` as unused disks -- and deleting one from there
# destroys a live disk of the other cluster.
#
# Detection is cheap and specific: this plugin maps every LUN it owns to igroups
# named pve_{our-cluster}_*. A pve_{storage}_* LUN mapped to an igroup with a
# DIFFERENT pve_* cluster prefix is therefore owned by another PVE cluster.
#
# Warn only, never refuse: the storages are already in service, and refusing to
# activate would take running guests offline over a reporting problem.
sub _check_foreign_cluster_namespace {
    my ($api, $storeid, $scfg) = @_;

    my $dir = _health_state_dir();
    my $flag = "$dir/" . _storeid_filename_component($storeid) . "-foreign-cluster-warn";
    my $last = (stat($flag))[9] // 0;
    return if (time() - $last) < 86400;    # 24h cooldown

    # Stamp the cooldown BEFORE doing any work and regardless of the outcome.
    # If it were only written when a problem is found, a healthy single-cluster
    # setup would re-run this on every ~10s status() poll -- the v0.2.21 N+1 REST
    # storm all over again.
    if (open(my $fh, '>', $flag)) { close($fh); }

    my $our_prefix = 'pve_' . sanitize_for_ontap($scfg->{'ontap-cluster-name'} // 'pve', 32) . '_';
    my $prefix = sanitize_for_ontap($storeid, 32);

    # ONE paginated call that already carries the igroup names.
    my $luns = eval { $api->lun_list_with_maps("/vol/pve_${prefix}_*/lun0"); };
    return if $@ || !$luns || !@$luns;

    my %foreign;
    for my $lun (@$luns) {
        for my $map (@{ $lun->{lun_maps} // [] }) {
            my $ig = $map->{igroup} && $map->{igroup}{name};
            next unless defined $ig;
            # Only igroups following this plugin's own scheme are meaningful; a
            # customer's hand-made igroup says nothing about PVE cluster ownership.
            next unless $ig =~ /^pve_/;
            # Compare by PREFIX rather than parsing the cluster name out of the
            # igroup: 'pve_{cluster}_{node}' is ambiguous once the cluster name
            # itself contains '_' (or '-', which sanitizes to '_'), and a wrong
            # parse here would be a false accusation of namespace sharing.
            next if index($ig, $our_prefix) == 0;
            $foreign{$ig}++;
        }
    }
    return unless %foreign;

    my $msg = sprintf(
        "WARNING: Storage '%s' appears to share its ONTAP volume namespace "
      . "'pve_%s_*' with ANOTHER Proxmox VE cluster. LUNs in this namespace are "
      . "mapped to igroup(s) %s, which do not belong to this cluster (expected the "
      . "prefix '%s'). Volume names carry NO cluster identifier -- 'ontap-cluster-name' "
      . "only appears in igroup names -- so this storage's image list includes the "
      . "other cluster's disks. They appear in the storage content view and in "
      . "'qm rescan' as unused disks, and DELETING ONE THERE WOULD DESTROY A LIVE "
      . "DISK OF THE OTHER CLUSTER. Give each cluster its own SVM, or storage IDs "
      . "that differ within their first 32 sanitized characters.",
        $storeid, $prefix,
        join(', ', map { "'$_'" } sort keys %foreign),
        $our_prefix);

    warn "$msg\n";
    eval {
        require Sys::Syslog;
        my $formatted = sprintf("%s", $msg);
        Sys::Syslog::openlog('pve-storage-netapp', 'pid', 'daemon');
        Sys::Syslog::syslog('warning', "%s", $formatted);
        Sys::Syslog::closelog();
    };
}

sub _check_lif_redundancy {
    my ($api, $storeid, $scfg) = @_;
    my $proto = $scfg->{'ontap-protocol'} // 'iscsi';
    return unless $proto eq 'iscsi';  # Only check iSCSI (FC handled by SAN switch)

    my $dir = _health_state_dir();
    my $flag = "$dir/" . _storeid_filename_component($storeid) . "-lif-warn";
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

    # Normal (resilient) client for the BACKGROUND cleanup grandchild below --
    # it runs detached and must not fail-fast on transient blips.
    my $api = eval { _get_api($scfg, storeid => $storeid); };
    if (!$api) {
        warn "Failed to connect to ONTAP API for status check: $@";
        _record_status_failure($storeid, "API connection failed: $@");
        return (0, 0, 0, 0);
    }

    # Short-timeout, no-retry client for the FOREGROUND capacity/health checks,
    # which run inline in the pvestatd loop. A degraded ONTAP must fail these in
    # ~ontap-status-timeout seconds so it cannot back up pvestatd and starve
    # sibling storages (see the activate_storage rationale). Construction never
    # touches the network, so this cannot fail here.
    my $status_api = eval { _get_api($scfg, storeid => $storeid, status_path => 1); } // $api;

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
        my $capacity = $status_api->get_managed_capacity();

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
    eval { _check_aggregate_capacity($status_api, $storeid, $scfg); };

    # LIF redundancy check (24h cooldown, warns if < 2 iSCSI LIFs)
    eval { _check_lif_redundancy($status_api, $storeid, $scfg); };

    # Another PVE cluster sharing this storage's ONTAP volume namespace (24h cooldown)
    eval { _check_foreign_cluster_namespace($status_api, $storeid, $scfg); };

    return ($cache->{total}, $cache->{avail}, $cache->{used}, 1);
}

#
# Volume management
#

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    die "unsupported format '$fmt'" if $fmt ne 'raw';

    my $api = _get_api($scfg, storeid => $storeid);

    # Parse the requested volume name to determine type
    my $parsed;
    my $voltype = 'disk';  # Default type
    my $diskid;
    my $snapname;

    if ($name) {
        $parsed = _parse_volname($name);

        # A name we cannot parse must be REFUSED, not quietly replaced.
        #
        # Most volume names come back from find_free_diskname, so the plugin
        # chooses them; a few Proxmox VE builds itself and hands to alloc_image
        # already named -- today cloudinit, state-<snapshot> and fleece-<n>.
        # Falling through to "pick a free disk ID" does not fail: it creates the
        # volume under a name that says it is an ordinary VM disk, and PVE then
        # holds a volid that does not exist. Measured before 0.2.29:
        # `pvesm alloc <store> 9990 vm-9990-fleece-0 1G` answered
        # "successfully created 'vm-9990-disk-0'".
        #
        # Refusing here covers every name a future PVE adds, instead of needing
        # this plugin to have heard of it first.
        die "cannot allocate '$name' on storage '$storeid': this plugin does not"
            . " recognise that volume name. Recognised forms are"
            . " vm-<vmid>-disk-<n>, base-<vmid>-disk-<n>, vm-<vmid>-cloudinit,"
            . " vm-<vmid>-state-<snapshot> and vm-<vmid>-fleece-<n>.\n"
            if !$parsed;

        $voltype = $parsed->{type} // 'disk';
        $diskid = $parsed->{diskid} if defined $parsed->{diskid};
        $snapname = $parsed->{snapname} if defined $parsed->{snapname};
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
    } elsif ($voltype eq 'fleece') {
        # Backup fleecing scratch disk: vm-{vmid}-fleece-{n} (Proxmox VE 9).
        # The name is chosen by PVE::VZDump::QemuServer and must be honoured
        # exactly -- it holds the volume ID for the rest of the backup and frees
        # it by that name afterwards. There is no free-ID search and no retry on
        # collision for the same reason.
        $pve_volname = "vm-${vmid}-fleece-${diskid}";
        $ontap_volname = pve_volname_to_ontap($storeid, $pve_volname);
        $lun_path = encode_lun_path($ontap_volname);

        my $existing_vol = $api->volume_get($ontap_volname);
        if ($existing_vol) {
            die "Volume '$ontap_volname' already exists on ONTAP. "
                . "A previous backup's fleecing image was not cleaned up; "
                . "remove '$storeid:$pve_volname' and retry.\n";
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

# Is the LUN doing I/O right now, as seen by ONTAP itself?
#
# Returns a short human-readable description of the observed activity, or 0 for
# "no activity observed", or dies if it cannot tell. ONTAP's per-LUN counters are
# CUMULATIVE, so a single reading is meaningless -- two samples are compared, and
# the second is only taken once ONTAP's own statistics timestamp has advanced
# (otherwise we would compare a sample against itself and always conclude "idle").
sub _lun_has_active_io {
    my ($api, $lun_path, %opts) = @_;

    my $window = $opts{window} // 4;    # seconds to watch for
    my $first = $api->lun_get_io_sample($lun_path);
    die "this ONTAP did not report usable LUN statistics\n" if !$first;

    my $deadline = time() + $window;
    my $second;
    while (time() < $deadline) {
        select(undef, undef, undef, 0.5);
        $second = $api->lun_get_io_sample($lun_path);
        last if $second
            && defined $second->{timestamp}
            && defined $first->{timestamp}
            && $second->{timestamp} ne $first->{timestamp};
        $second = undef;
    }

    # ONTAP never refreshed its statistics inside the window -- we cannot
    # distinguish "idle" from "stale", so say so rather than guess "idle".
    die "ONTAP statistics did not refresh within ${window}s\n" if !$second;

    my $d_ops   = ($second->{ops}   // 0) - ($first->{ops}   // 0);
    my $d_bytes = ($second->{bytes} // 0) - ($first->{bytes} // 0);

    # The verdict rests on BYTES TRANSFERRED, not the operation count.
    #
    # lun_get_io_sample() already excludes 'other' ops, but read/write op counts
    # alone are still the weaker signal -- bytes are what unambiguously separate a
    # guest touching the disk from housekeeping. Verified on real ONTAP: a genuinely
    # idle LUN moved 0 bytes while a running dd moved ~20 MB in 10s.
    #
    # Counters can also reset (controller takeover, LUN remap), and a negative
    # delta is not evidence of use.
    return 0 if $d_bytes <= 0;

    return sprintf("%d byte(s) transferred in %d read/write operation(s) over the last %ds",
        $d_bytes, $d_ops > 0 ? $d_ops : 0, $window);
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format) = @_;

    my $api = _get_api($scfg, storeid => $storeid);
    my $ontap_volname = pve_volname_to_ontap($storeid, $volname);
    my $lun_path = encode_lun_path($ontap_volname);

    # Get LUN WWID for cleanup and in-use check
    my $wwid = eval { $api->lun_get_wwid($lun_path); };

    # Safety check: Verify device is not in use before deletion.
    #
    # is_device_in_use() covers THIS node thoroughly: mounts, swap, sysfs holders
    # (LVM/dm-crypt/kpartx) and -- via fuser -- any process holding the block
    # device open, which includes a running QEMU. What it cannot cover is the rest
    # of the cluster: on shared SAN storage the guest may be running on another
    # node, and on the node servicing a `pvesm free` the LUN may not even be
    # mapped, in which case $device is undef and there is nothing local to check.
    #
    # That gap is reachable: DELETE /nodes/{node}/storage/{storage}/content/{volume}
    # (the storage content view's Remove button, and `pvesm free`) does a
    # permission check and then calls vdisk_free straight away -- no in-use test,
    # no config-reference test. PVE only guards base volumes there
    # (volume_is_base_and_used).
    my $local_device_checked = 0;
    if ($wwid) {
        my $device = get_device_by_wwid($wwid);
        if ($device && -b $device) {
            $local_device_checked = 1;
            if (is_device_in_use($device)) {
                my $details = get_device_usage_details($device);
                die "Cannot delete volume '$volname': device $device is still in use.\n\n" .
                    "$details\n";
            }
        }
    }

    # Cross-node safety net: ask ONTAP whether the LUN is doing I/O right now.
    #
    # Only when the local check could not run -- if the device is mapped here, the
    # host-side test above is authoritative and cheaper. This costs one short
    # sampling window and only on the ambiguous path.
    #
    # This is deliberately ONE-DIRECTIONAL. Observed I/O proves the volume is in
    # use somewhere and we refuse. The absence of I/O proves nothing (a running
    # guest can be idle), so it never blocks a legitimate delete: a guest being
    # destroyed is stopped, and `qm destroy` frees volumes while the config still
    # references them, so a config-reference test would break destroy entirely.
    if ($wwid && !$local_device_checked && ($scfg->{'ontap-inuse-io-check'} // 1)) {
        my $busy = eval { _lun_has_active_io($api, $lun_path); };
        if ($@) {
            warn "Could not sample ONTAP I/O activity for '$volname' before deleting "
               . "(continuing; the host-side check could not run either): $@";
        } elsif ($busy) {
            die "Cannot delete volume '$volname': ONTAP reports ACTIVE I/O on LUN "
              . "'$lun_path' ($busy), so it is in use -- most likely by a guest "
              . "running on another cluster node. This node has no local mapping "
              . "for it, so the host-side in-use check could not see that.\n"
              . "  Stop or migrate the guest that owns this disk, then retry. Note "
              . "ONTAP's counters lag by up to one statistics interval, so a disk "
              . "whose guest has JUST been stopped can still read as active for a few "
              . "seconds -- simply retry. If you are certain the I/O is not a guest, "
              . "disable this cross-node check with "
              . "'pvesm set $storeid --ontap-inuse-io-check 0'.\n";
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

    # Wall-clock budget for the whole retry loop.
    #
    # free_image() runs inside PVE's cluster_lock_storage(), so every second spent
    # here blocks alloc/free for this storage on EVERY node. One volume_delete can
    # take up to ~240s on its own (60s HTTP x 2 retries + a 120s job wait), so five
    # attempts could hold the cluster-wide lock for ~20 minutes. Bound the loop: a
    # per-call timeout does not bound a loop's total time (the v0.2.12 lesson).
    # Exceeding the budget fails with a clear message instead of holding the lock.
    my $delete_deadline = time() + ($scfg->{'ontap-delete-deadline'} // 300);

    for my $attempt (1 .. $max_retries) {
        if ($attempt > 1 && time() >= $delete_deadline) {
            die "Failed to delete volume '$ontap_volname': gave up after "
              . ($scfg->{'ontap-delete-deadline'} // 300) . "s and $attempt attempt(s). "
              . "ONTAP kept reporting a clone dependency. free_image() holds the "
              . "cluster-wide storage lock, so it must not retry indefinitely. "
              . "Check 'volume clone show' and 'volume recovery-queue show' for "
              . "'$ontap_volname' on the SVM, then retry the delete.\n";
        }
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

            # No LIVE clone children, yet ONTAP insists there are clones. The
            # cause is almost always a clone that was already deleted but is
            # still held in ONTAP's volume recovery queue -- it remains a clone
            # of this volume for the whole retention window (default 12h), so
            # retrying/sleeping can NEVER succeed on its own. That is what the
            # old "stale clone metadata, retrying..." loop was really hitting;
            # it burned 5 attempts and then failed with a message that pointed
            # nowhere. Release those holds, then let the loop retry for real.
            my ($purged, $live, $refused) =
                _release_recovery_queue_clone_holds($api, $scfg, $ontap_volname);

            if (@$purged) {
                warn "Volume delete blocked by " . scalar(@$purged) . " deleted-but-queued "
                   . "clone(s); purged from the recovery queue: "
                   . join(', ', @$purged) . ". Retrying delete.\n";
                next;    # retry immediately, the blocker is gone
            }

            if (@$live || @$refused) {
                # One line: PVE flattens newlines in task/CLI errors into spaces.
                die "Cannot delete volume '$volname': ONTAP reports clone(s) of "
                  . "'$ontap_volname' that the plugin will not remove: "
                  . _clone_hold_hint($live, $refused, $scfg->{'ontap-svm'}) . "."
                  . " A clone that has ALREADY BEEN DELETED still counts while ONTAP"
                  . " retains it in the volume recovery queue (see"
                  . " 'volume recovery-queue show' and the SVM's"
                  . " volume-delete-retention-hours, default 12h). Purge it with:"
                  . " 'volume recovery-queue purge -vserver $scfg->{'ontap-svm'} -volume <name>'.\n";
            }

            # Nothing identifiable to release -- fall back to the original
            # wait-and-retry in case this really is a transient ONTAP state.
            warn "Volume delete failed (attempt $attempt/$max_retries): ONTAP reports a "
               . "clone dependency but none is visible; retrying...\n"
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

    my $api = _get_api($scfg, storeid => $storeid);

    my @res;

    # Build filter pattern
    my $filter = 'pve_*';
    # MUST use sanitize_for_ontap() -- see the note in deactivate_storage().
    # A divergent prefix makes list_images() return an empty list, i.e. "this
    # storage has no disks", which hides real volumes from the UI and from
    # callers such as find_free_diskname()/clone_image().
    my $san_storage = sanitize_for_ontap($storeid, 32);
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

    my $api = _get_api($scfg, storeid => $storeid);
    my $ontap_volname = pve_volname_to_ontap($storeid, $volname);
    my $lun_path = encode_lun_path($ontap_volname);

    # Honour the $timeout PVE passes in (commonly 10s). Previously it was
    # accepted and ignored, so the call was bounded only by the client default
    # (15s x 2 retries = ~32s) -- longer than the caller asked for.
    my %opts;
    $opts{timeout} = $timeout if $timeout && $timeout =~ /^\d+$/;

    my $lun = $api->lun_get($lun_path, %opts);
    die "LUN '$lun_path' not found" unless $lun;

    return wantarray ?
        ($lun->{space}{size}, 'raw', $lun->{space}{used}, undef) :
        $lun->{space}{size};
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running, $snapname) = @_;

    # $snapname was added to this method in storage APIVER 14 (libpve-storage-perl
    # 9.1.3+), where a non-undef value means "the snapshot itself is the resize
    # target". PVE only passes it for storages using 'snapshot-as-volume-chain',
    # which this plugin does not declare -- but accept and reject it explicitly
    # rather than silently resizing the CURRENT volume, which would be a
    # data-corrupting misinterpretation of the caller's intent.
    die "resizing a snapshot is not supported by the NetApp ONTAP plugin "
      . "(volume '$volname', snapshot '$snapname')\n"
        if defined $snapname && length $snapname;

    my $api = _get_api($scfg, storeid => $storeid);
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

#
# Volume export / import  (raw+size stream)
#
# Enables `qm remote-migrate` / `pct remote-migrate` (cluster-to-cluster) and the
# storage-content copy API. LOCAL migration never needs this -- both
# QemuMigrate.pm and LXC/Migrate.pm return early for $scfg->{shared}, and this
# plugin is registered in @SHARED_STORAGE.
#
# The wire format is deliberately trivial (see PVE::Storage::Plugin):
#   8 bytes  little-endian uint64 = image size in bytes
#   N bytes  the raw image
#
# Modelled on LVMPlugin, with two differences that matter for a SAN backend:
#
#   1. The device does not exist the moment alloc_image() returns. It has to be
#      mapped to the node's igroup, rediscovered over iSCSI/FC and assembled by
#      multipath. Both directions therefore call activate_volume() and fail
#      loudly if the device never shows up, instead of dd'ing into nothing.
#
#   2. THE SIZE MUST BE VERIFIED BEFORE WRITING. The stream carries an exact byte
#      count; alloc_image() takes KiB and ONTAP creates a LUN of exactly that many
#      bytes. If the stream is not a whole number of KiB, dd would silently write
#      past the end of the LUN and the imported disk would be TRUNCATED --
#      corruption no error message would report. We round up before allocating,
#      then re-read the REAL device size and refuse if it is smaller.

sub volume_export_formats {
    my ($class, $scfg, $storeid, $volname, $snapshot, $base_snapshot, $with_snapshots) = @_;

    # No incremental streams, no snapshot bundles, and no exporting a snapshot
    # directly (that would need a temp FlexClone; out of scope and untested).
    return () if $with_snapshots || defined($base_snapshot) || defined($snapshot);

    my ($vtype) = eval { $class->parse_volname($volname) };
    return () if $@ || !$vtype || $vtype ne 'images';

    return ('raw+size');
}

sub volume_import_formats {
    my ($class, $scfg, $storeid, $volname, $snapshot, $base_snapshot, $with_snapshots) = @_;

    return $class->volume_export_formats(
        $scfg, $storeid, $volname, $snapshot, $base_snapshot, $with_snapshots);
}

sub volume_export {
    my ($class, $scfg, $storeid, $fh, $volname, $format, $snapshot, $base_snapshot,
        $with_snapshots) = @_;

    die "volume export format '$format' not available for $class\n"
        if $format ne 'raw+size';
    die "cannot export volumes together with their snapshots in $class\n" if $with_snapshots;
    die "cannot export an incremental stream in $class\n" if defined($base_snapshot);
    die "cannot export a snapshot in $class\n" if defined($snapshot);

    # The LUN must be mapped and assembled on THIS node before it can be read.
    $class->activate_volume($storeid, $scfg, $volname, undef, {});

    my ($file) = $class->path($scfg, $volname, $storeid);
    die "internal error: no path for volume '$volname'\n" if !$file;
    die "device '$file' for volume '$volname' is not a block device\n" if !-b $file;

    # Ask the kernel, not ONTAP: this is the size dd will actually read, and it
    # doubles as proof that the device is really present and readable.
    my $size;
    run_command(
        ['/sbin/blockdev', '--getsize64', $file],
        outfunc => sub {
            my ($line) = @_;
            die "unexpected output from blockdev: $line\n" if $line !~ /^(\d+)$/;
            $size = int($1);
        },
    );
    die "could not determine size of '$file'\n" if !$size;

    PVE::Storage::Plugin::write_common_header($fh, $size);
    run_command(['dd', "if=$file", 'bs=64k', 'status=none'], output => '>&' . fileno($fh));
}

sub volume_import {
    my ($class, $scfg, $storeid, $fh, $volname, $format, $snapshot, $base_snapshot,
        $with_snapshots, $allow_rename) = @_;

    die "volume import format '$format' not available for $class\n"
        if $format ne 'raw+size';
    die "cannot import volumes together with their snapshots in $class\n" if $with_snapshots;
    die "cannot import an incremental stream in $class\n" if defined($base_snapshot);
    die "cannot import into a snapshot in $class\n" if defined($snapshot);

    my ($vtype, $name, $vmid, undef, undef, undef, $file_format) =
        $class->parse_volname($volname);
    die "cannot import format '$format' into a volume of format '$file_format'\n"
        if $file_format ne 'raw';

    my $stream_size = PVE::Storage::Plugin::read_common_header($fh);
    die "import: refusing a zero-length stream\n" if !$stream_size;

    # alloc_image() takes KiB. Round the byte count UP so the LUN can never be
    # smaller than the stream -- see the truncation note above.
    my $size_kb = PVE::Storage::Common::align_size_up($stream_size, 1024) / 1024;

    # Only the ALLOCATION is serialised. The transfer is a full disk copy and must
    # NOT run while holding the cluster-wide storage lock (the v0.2.24 lesson).
    my $allocname = $class->cluster_lock_storage(
        $storeid,
        $scfg->{shared},
        undef,
        sub {
            my $api = _get_api($scfg, storeid => $storeid);
            my $existing = eval { $api->volume_get(pve_volname_to_ontap($storeid, $volname)); };
            if ($existing) {
                die "volume '$volname' already exists on storage '$storeid'\n" if !$allow_rename;
                warn "volume '$volname' already exists - importing under a different name\n";
                $name = undef;
            }
            return $class->alloc_image($storeid, $scfg, $vmid, 'raw', $name, $size_kb);
        },
    );

    my $imported = eval {
        my $oldname = $volname;
        $volname = $allocname;
        die "internal error: allocated name '$allocname' differs from requested '$oldname'\n"
            if defined($name) && $allocname ne $oldname;

        # Map + rediscover + assemble multipath, then wait for the device.
        $class->activate_volume($storeid, $scfg, $volname, undef, {});

        my ($file) = $class->path($scfg, $volname, $storeid);
        die "internal error: no path for freshly allocated volume '$volname'\n" if !$file;
        die "device '$file' for '$volname' did not appear as a block device\n" if !-b $file;

        # ANTI-TRUNCATION GUARD. Re-read the real device size and refuse if it
        # cannot hold the stream. Without this, dd writes past the end of the LUN
        # and silently produces a truncated disk.
        my $dev_size;
        run_command(
            ['/sbin/blockdev', '--getsize64', $file],
            outfunc => sub {
                my ($line) = @_;
                $dev_size = int($1) if $line =~ /^(\d+)$/;
            },
        );
        die "could not determine size of '$file' before importing\n" if !$dev_size;
        die "refusing to import: device '$file' is $dev_size bytes but the stream is "
          . "$stream_size bytes -- writing it would TRUNCATE the image\n"
            if $dev_size < $stream_size;

        run_command(['dd', "of=$file", 'bs=64k', 'conv=fsync', 'status=none'],
            input => '<&' . fileno($fh));

        return "$storeid:$volname";
    };
    if (my $err = $@) {
        # free_image() does the full 7-step host-side teardown plus the ONTAP
        # delete, so a failed import leaves neither a stale device nor an orphaned
        # FlexVol.
        eval { $class->free_image($storeid, $scfg, $volname, 0, 'raw'); };
        warn "cleanup of partially imported volume '$volname' failed: $@" if $@;
        die $err;
    }

    return $imported;
}

# $hints is passed through by PVE::Storage::activate_volumes (Storage.pm:1411) on
# Proxmox VE 9.1+. Currently only 'guest-is-windows' and
# 'plugin-may-deactivate-volume' exist, neither of which changes anything for a SAN
# LUN, so we accept and ignore them -- but the parameter is named in the signature
# so a future hint cannot be silently swallowed by a too-short one.
sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache, $hints) = @_;

    my $api = _get_api($scfg, storeid => $storeid);
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

    my $api = eval { _get_api($scfg, storeid => $storeid); };
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

# Remove a temporary FlexClone: tears down host-side state (multipath
# device, SCSI slaves, residual maps) AND removes the volume on ONTAP
# via clone-split-then-delete. Mirrors the free_image() 7-step pattern.
#
# Reason for this helper: v0.2.13 introduced inline temp clone cleanup
# in volume_snapshot_delete() that only handled the ONTAP side. After
# delete, the host's dm-multipath + sd* devices were left orphaned --
# multipathd then spammed "path is down" for the dead WWID indefinitely
# (until manual `multipath -f`). The 1-hour TTL reaper in
# _cleanup_temp_clones had the same gap. Both now route through here.
#
# Order matches free_image:
#   1. Capture slave list BEFORE unmap (after unmap, multipath device
#      may disappear and we lose the sd* names).
#   2. unmap LUN from all igroups (prevents iSCSI rescan from
#      re-discovering and re-creating devices).
#   3. cleanup_lun_devices on the WWID (multipath flush + sd remove).
#   4. Remove residual sd* using the captured list.
#   5. multipath_reload to drop any stale maps.
#   6. volume_clone_split on ONTAP (required: ONTAP only guarantees
#      release of the parent snapshot's owner reference after split.
#      Real FAS may clear it on plain volume_delete, simulator does
#      not; split is the cross-platform-reliable mechanism).
#   7. volume_wait_clone_split (bounded 300s timeout).
#   8. volume_delete the now-independent volume.
#
# Dies on unrecoverable errors (split failure, wait timeout). Warns on
# best-effort failures (lun_unmap, host cleanup, post-split delete).
# Returns 1 on success.
sub _remove_temp_clone {
    my ($api, $temp_clone_name) = @_;

    # Idempotency check (v0.2.16): if the volume is already absent on
    # ONTAP, skip the ONTAP-side steps (which would die at
    # volume_clone_split with "Volume not found") and return success so
    # the caller can untrack the stale entry from local state.
    #
    # When this scenario arises:
    #  - Interrupted previous cleanup (volume_delete succeeded but
    #    state file write didn't happen)
    #  - Cross-node race: another node deleted the clone between our
    #    state read and our action
    #  - Manual ONTAP cleanup by an admin
    #  - Post-reboot state where tmpfs survived but ONTAP had already
    #    been pruned
    #
    # Without this check the TTL background reaper retries every cycle
    # and spams the journal -- one repeating "Failed to cleanup temp
    # clone ...: Volume not found" line per dead entry per status()
    # poll. Observed on the v0.2.14/v0.2.15 simulator after the v0.2.13
    # development testing left a stale 9997_splittest entry.
    #
    # IMPORTANT: distinguish "confirmed not found" (volume_get returns
    # undef, no error) from "transient API failure" (volume_get dies).
    # Only the former should skip; the latter must propagate so we
    # retry next cycle rather than silently leak a real clone.
    my $exists = eval { $api->volume_get($temp_clone_name); };
    if ($@) {
        die "volume_get on temp clone '$temp_clone_name' failed: $@";
    }
    if (!$exists) {
        warn "Temp clone '$temp_clone_name' already absent on ONTAP; "
           . "skipping ONTAP-side cleanup. Caller may untrack the stale entry.\n";
        return 1;
    }

    my $temp_lun_path = encode_lun_path($temp_clone_name);
    my $temp_wwid = eval { $api->lun_get_wwid($temp_lun_path); };

    # Step 1: capture slave list before any unmap (lose-able state)
    my @scsi_slaves;
    if ($temp_wwid) {
        my $mpath = get_multipath_device($temp_wwid);
        if ($mpath && -b $mpath) {
            my $slaves = get_multipath_slaves($mpath);
            @scsi_slaves = @$slaves if $slaves;
        }
    }

    # Step 2: unmap from all igroups (cluster-wide, mirrors free_image)
    eval { $api->lun_unmap_all($temp_lun_path); };
    warn "lun_unmap_all on temp clone '$temp_clone_name' failed: $@" if $@;

    # Steps 3-5: local kernel state cleanup
    if ($temp_wwid) {
        eval { cleanup_lun_devices($temp_wwid); };
        warn "cleanup_lun_devices for temp clone '$temp_clone_name' failed: $@" if $@;

        for my $slave (@scsi_slaves) {
            if (-b $slave) {
                eval { remove_scsi_device($slave); };
            }
        }

        eval { multipath_reload(); };
    }

    # Step 6: split clone -- the ONTAP-guaranteed owner-release mechanism
    eval { $api->volume_clone_split($temp_clone_name); };
    if ($@) {
        die "volume_clone_split on temp clone '$temp_clone_name' failed: $@";
    }

    # Step 7: bounded wait (300s is generous; vzdump temp clones with
    # zero unique blocks split in seconds, qm-clone temp clones may take
    # longer if heavily modified -- still bounded)
    eval { $api->volume_wait_clone_split($temp_clone_name, timeout => 300); };
    if ($@) {
        die "Clone split for '$temp_clone_name' did not complete within 300s: $@";
    }

    # Step 8: delete the now-independent volume (no owner blocking)
    eval { $api->volume_delete($temp_clone_name); };
    if ($@) {
        # Volume is already split -- snapshot owner is released so any
        # snapshot_delete after this still works. Leave the orphan
        # volume for next TTL pass; don't fail the caller.
        warn "Post-split volume_delete of '$temp_clone_name' failed "
           . "(orphan left behind, will be retried by TTL cleanup): $@";
    }

    return 1;
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
                eval { _remove_temp_clone($api, $clone_name); };
                if ($@) {
                    warn "Failed to cleanup temp clone '$clone_name': $@\n";
                } else {
                    delete $storage_clones->{$clone_name};
                    $cleaned++;
                }
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
            # Last resort after the device failed to appear: this is the one place
            # a LIP is justified (see FC::rescan_fc_hosts -- it is disruptive to
            # every LUN behind the HBA, so it must never run on a poll or in a loop).
            rescan_fc_hosts(delay => 2, lip => 1);
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

    return wantarray ? ($device, $parsed->{vmid}, 'raw') : $device;
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    my $parsed = _parse_volname($volname);
    die "Cannot parse volume name: $volname" unless $parsed;

    my $api = _get_api($scfg, storeid => $storeid);
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
        # LUN doesn't exist - return a placeholder path so callers that only need
        # a path (and check -b before touching it) can proceed; delete operations
        # go through the ONTAP API and never use this.
        #
        # It MUST be unique per volume. The old form hex-encoded the first 12
        # characters of the ONTAP volume name, which is the shared
        # "pve_{storage}_" prefix -- so EVERY volume of a storage produced the
        # identical placeholder. That made the warning useless for diagnosis and
        # meant one fabricated identifier stood in for many volumes. Derive it
        # from the whole name instead. (Nothing destructive consumes path(): the
        # verified callers are free_image, both reapers, _remove_temp_clone and
        # deactivate_storage, none of which use it.)
        my $digest = 0;
        for my $c (split //, $ontap_volname) {
            $digest = ($digest * 33 + ord($c)) % (2**48);
        }
        my $synthetic_wwid = sprintf("3600a0980%012x%012x",
            $digest, length($ontap_volname));
        warn "LUN $lun_path not found on ONTAP, returning synthetic path for cleanup\n";
        return wantarray ? ("/dev/mapper/$synthetic_wwid", $parsed->{vmid}, 'raw')
                         : "/dev/mapper/$synthetic_wwid";
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

    # Honour wantarray, exactly as PVE::Storage::Plugin::path() does. Returning a
    # 3-element list unconditionally means `my $p = $plugin->path(...)` silently
    # yields the LAST element -- the string 'raw' -- instead of the device path,
    # and the failure surfaces far away as "'raw' is not a block device".
    return wantarray ? ($device, $parsed->{vmid}, 'raw') : $device;
}

# filesystem_path() cannot be implemented by this plugin.
#
# Its signature carries no $storeid, and this plugin needs the storage ID to
# derive the ONTAP FlexVol name (pve_{storage}_{vmid}_disk{N}); the volname alone
# is not sufficient. The previous implementation passed $scfg->{storage}, which
# PVE NEVER populates (no code path in the PVE 9 storage layer sets that key), so
# it did not fall back gracefully -- it died with the misleading low-level error
# "storage is required at .../Naming.pm line 213".
#
# Nothing in Proxmox VE 9.0/9.1/9.2 reaches it today: every base-class method
# that calls filesystem_path() is either overridden here, or (volume_snapshot_info
# / rename_snapshot) only invoked when volume_qemu_snapshot_method() returns
# 'mixed', while this plugin returns 'storage'. Both of those are now overridden
# below as well. Fail loudly and legibly instead of leaving a booby trap for the
# next PVE release that widens the external-snapshot API.
sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;

    die "filesystem_path() is not supported by the NetApp ONTAP plugin: the "
      . "ONTAP FlexVol name cannot be derived without a storage ID. Use "
      . "PVE::Storage::path()/\$plugin->path(\$scfg, \$volname, \$storeid, "
      . "\$snapname) instead (volume '$volname').\n";
}

# Snapshot metadata for PVE.
#
# PVE uses this for two things, neither of which applies to this plugin:
#   - 'snapshot-as-volume-chain' external snapshots (needs file/volid/parent/child)
#   - storage replication (currently native ZFS only; we do not implement
#     storage_can_replicate, so PVE never asks us to replicate)
#
# The base implementation shells out to qemu-img against filesystem_path(), which
# this plugin cannot provide. Implement the plain (non-volume-chain) shape from
# ONTAP instead -- name => { order, timestamp } -- so any present or future caller
# gets truthful data rather than a die or an empty hash.
sub volume_snapshot_info {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $api = _get_api($scfg, storeid => $storeid);
    my $ontap_volname = pve_volname_to_ontap($storeid, $volname);

    my $snapshots = eval { $api->snapshot_list($ontap_volname, 'pve_snap_*'); } // [];

    my @decoded;
    for my $s (@$snapshots) {
        my $pve_name = decode_snapshot_name($s->{name} // '');
        next unless $pve_name;
        push @decoded, {
            name => $pve_name,
            ts   => _parse_ontap_time($s->{create_time}),
        };
    }

    # 'order' must be monotonic oldest -> newest. Snapshots with an unparseable
    # timestamp sort last but keep a stable relative order by name.
    @decoded = sort {
        (defined $a->{ts} && defined $b->{ts}) ? ($a->{ts} <=> $b->{ts})
      : (defined $a->{ts}) ? -1
      : (defined $b->{ts}) ?  1
      : ($a->{name} cmp $b->{name})
    } @decoded;

    my $info = {};
    my $order = 0;
    for my $s (@decoded) {
        $info->{ $s->{name} }{order} = $order++;
        $info->{ $s->{name} }{timestamp} = $s->{ts} if defined $s->{ts};
    }

    return $info;
}

# ONTAP has no in-place snapshot rename that preserves the FlexClone/LUN
# relationships PVE would expect here, and PVE only calls this from the
# 'external' (volume-chain) snapshot-delete path, which this plugin never
# selects. Fail explicitly rather than inheriting the base implementation, which
# would call the unsupported filesystem_path().
sub rename_snapshot {
    my ($class, $scfg, $storeid, $volname, $source_snap, $target_snap) = @_;

    die "renaming a snapshot is not supported by the NetApp ONTAP plugin "
      . "(volume '$volname', '$source_snap' -> '$target_snap')\n";
}

# Unique identity for this storage instance (storage APIVER 15,
# libpve-storage-perl 9.1.6+; exposed via GET /nodes/{node}/storage/{id}/identity).
# The SVM is the real administrative boundary on ONTAP -- two PVE storages that
# share a portal but use different SVMs are genuinely different backing stores,
# and two that share portal+SVM are the same one. The aggregate is deliberately
# excluded: it only decides where new FlexVols are placed and can be changed
# without the underlying store becoming a different thing.
sub get_identity {
    my ($class, $scfg, $storeid) = @_;

    my $portal = $scfg->{'ontap-portal'}
        or die "cannot determine identity: 'ontap-portal' is not set for storage '$storeid'\n";
    my $svm = $scfg->{'ontap-svm'}
        or die "cannot determine identity: 'ontap-svm' is not set for storage '$storeid'\n";

    return "netappontap://$portal/$svm";
}

#
# Snapshot operations
#

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $api = _get_api($scfg, storeid => $storeid);
    my $ontap_volname = pve_volname_to_ontap($storeid, $volname);
    my $ontap_snapname = encode_snapshot_name($snap);
    my $lun_path = encode_lun_path($ontap_volname);

    # Safety check: Verify snapshot doesn't already exist
    my $existing_snap = $api->snapshot_get($ontap_volname, $ontap_snapname);
    if ($existing_snap) {
        # ONTAP snapshot names are sanitized, and '-' becomes '_'. PVE allows both
        # ([a-z][a-z0-9_-]+), so 'my-snap' and 'my_snap' are distinct in PVE but
        # BOTH become 'pve_snap_my_snap' on ONTAP. Without this hint the operator
        # sees "already exists" for a name Proxmox VE shows as free, which is
        # baffling. (Creation failing is the safe outcome -- it stops two PVE
        # snapshots from silently becoming one ONTAP snapshot.)
        my $hint = '';
        if ($snap =~ /-/) {
            (my $alt = $snap) =~ s/-/_/g;
            $hint = " Note: on ONTAP '-' is converted to '_', so '$snap' and '$alt'"
                  . " map to the same ONTAP snapshot name '$ontap_snapname'."
                  . " If Proxmox VE does not list '$snap', an existing snapshot named"
                  . " '$alt' (or another variant differing only in '-' vs '_') already"
                  . " occupies it.";
        }
        die "Snapshot '$snap' already exists on volume '$volname' "
          . "(ONTAP name '$ontap_snapname').$hint "
          . "Please use a different snapshot name or delete the existing snapshot first.\n";
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

    my $api = _get_api($scfg, storeid => $storeid);
    my $ontap_volname = pve_volname_to_ontap($storeid, $volname);
    my $ontap_snapname = encode_snapshot_name($snap);

    # ONTAP locks a snapshot while any FlexClone uses it as parent.
    # _get_snapshot_path() creates such a temp FlexClone whenever PVE
    # opens this snapshot for read (vzdump CT snapshot-mode backup,
    # qm clone --snapname, qemu-img convert from snapshot, etc.).
    # The TTL-based _cleanup_temp_clones() background task reaps them
    # after 1 hour, but vzdump calls volume_snapshot_delete IMMEDIATELY
    # after the backup completes -- well within the TTL -- so the
    # snapshot_delete fails with "has not expired or is locked".
    # Reap the dependent temp clone synchronously here so the
    # snapshot delete can proceed.
    my $temp_clone_name = _get_temp_clone_name($ontap_volname, $snap);
    my $temp_vol = eval { $api->volume_get($temp_clone_name); };
    if ($temp_vol) {
        my $temp_lun_path = encode_lun_path($temp_clone_name);
        my $temp_wwid = eval { $api->lun_get_wwid($temp_lun_path); };

        # Safety: refuse to tear down the temp clone if its block
        # device is still in use locally. Cross-node usage is not
        # directly observable, but we rely on the convention that
        # snapshot_delete is called by the same node that opened the
        # snapshot (vzdump completes on one node and deletes there).
        if ($temp_wwid) {
            my $temp_device = get_device_by_wwid($temp_wwid);
            if ($temp_device && -b $temp_device && is_device_in_use($temp_device)) {
                die "Cannot delete snapshot '$snap': temporary FlexClone "
                  . "'$temp_clone_name' is still in use locally ($temp_device). "
                  . "Wait for the operation that opened the snapshot to "
                  . "complete (e.g. backup, clone), or check holders with "
                  . "'lsof $temp_device'.\n";
            }
        }

        warn "Detaching temporary FlexClone '$temp_clone_name' from "
           . "snapshot '$ontap_snapname' before snapshot delete\n";

        # Route through the shared helper. _remove_temp_clone:
        #  - Captures slave list BEFORE unmap (so we can clean sd*)
        #  - Unmaps LUN from all igroups
        #  - cleanup_lun_devices + remove_scsi_device + multipath_reload
        #    (HOST-side cleanup; was missing in initial v0.2.13 patch
        #    and produced "tur checker reports path is down" spam after
        #    every backup -- fixed in v0.2.14)
        #  - volume_clone_split + wait + volume_delete on ONTAP
        # Dies on unrecoverable failure (split error / timeout).
        eval { _remove_temp_clone($api, $temp_clone_name); };
        if ($@) {
            die "Cannot delete snapshot '$snap': $@";
        }

        # Untrack from local state file (best effort; tmpfs may have
        # been wiped on reboot, or another node holds the entry).
        eval {
            _with_temp_clone_lock(sub {
                my $state = _read_temp_clone_state();
                if ($state->{$storeid} && exists $state->{$storeid}{$temp_clone_name}) {
                    delete $state->{$storeid}{$temp_clone_name};
                    _write_temp_clone_state($state);
                }
            });
        };
    }

    # Any OTHER FlexClone still pinned to this snapshot also locks it, and the
    # deterministic-temp-clone handling above cannot see those.
    #
    # Reachable path: PVE::Storage::vdisk_clone($cfg, $volid, $vmid, $snapname)
    # -- i.e. a LINKED clone taken from a named snapshot (`qm clone ... --snapname
    # X` without --full, and the LXC equivalent in API2/LXC.pm). clone_image()
    # then creates a normal pve_<store>_<vmid>_disk<N> FlexClone whose parent IS
    # this snapshot, and deliberately does not split it (that is the whole point
    # of a linked clone). ONTAP therefore refuses the snapshot delete with
    # "Snapshot ... has not expired or is locked" -- the same symptom class as the
    # v0.2.13 vzdump incident, but from a clone this function never looked for, so
    # the operator got a raw ONTAP error with no indication of what was holding it.
    #
    # We must NOT auto-split or auto-delete here: that clone is a live VM/CT disk
    # belonging to another guest. Fail with an actionable message instead.
    my $blocking_clones = eval { $api->volume_get_clone_children($ontap_volname); } // [];
    my @locked_by;
    for my $child (@$blocking_clones) {
        my $parent_snap = $child->{clone} && $child->{clone}{parent_snapshot}
            ? ($child->{clone}{parent_snapshot}{name} // '') : '';
        next unless $parent_snap eq $ontap_snapname;

        # NEVER block on the deterministic temp clone: it was just torn down
        # above (or confirmed absent), and _remove_temp_clone() already dies
        # loudly if that failed. ONTAP metadata can lag behind a completed
        # volume delete (the v0.2.13 lesson: "wait_for_job success does NOT imply
        # downstream-visible side effects are complete"), so a stale entry here is
        # expected. Blocking on it would break exactly the vzdump CT
        # snapshot-mode path that v0.2.13/v0.2.14 fixed. The temp clone name is
        # derived from volume+snapshot, so it is the ONLY tmpclone that can
        # legitimately point at this snapshot.
        next if $child->{name} eq $temp_clone_name;

        push @locked_by, $child->{name};
    }
    # Second source of truth: ONTAP's CLI clone view, which ALSO reports clones
    # that were deleted but are still held in the volume recovery queue. Those
    # keep the parent snapshot's 'volume_clone_dependent' owner set, so
    # snapshot_delete fails with "has not expired or is locked" -- for up to the
    # SVM's volume-delete-retention window (default 12h) -- even though
    # /storage/volumes reports no clone children at all. Reproduced on real ONTAP
    # by deleting a linked clone and then its source snapshot.
    #
    # Deleted-but-queued clones are purged (the operator already deleted them);
    # live ones are reported so the operator can act.
    if (!@locked_by) {
        my ($purged, $live, $refused) =
            _release_recovery_queue_clone_holds($api, $scfg, $ontap_volname);

        if (@$purged) {
            warn "Released " . scalar(@$purged) . " recovery-queue clone hold(s) on "
               . "'$ontap_volname': " . join(', ', @$purged) . "\n";
        }

        if (@$live || @$refused) {
            # One line: PVE flattens newlines in task/CLI errors into spaces.
            die "Cannot delete snapshot '$snap' of '$volname': ONTAP snapshot "
              . "'$ontap_snapname' is still held by clone(s) of this volume: "
              . _clone_hold_hint($live, $refused, $scfg->{'ontap-svm'}) . "."
              . " A FlexClone keeps its parent snapshot locked, and one that has ALREADY"
              . " BEEN DELETED still counts while ONTAP retains it in the volume recovery"
              . " queue (see 'volume recovery-queue show' and the SVM's"
              . " volume-delete-retention-hours, default 12h)."
              . " Delete the guest(s) owning any live clone, or purge the queued entry:"
              . " 'volume recovery-queue purge -vserver $scfg->{'ontap-svm'} -volume <name>'"
              . " (the plugin does this automatically unless"
              . " 'ontap-purge-recovery-queue' is set to 0).\n";
        }
    }

    if (@locked_by) {
        my @hints;
        for my $c (@locked_by) {
            my $decoded = decode_volume_name($c);
            if ($decoded && defined $decoded->{vmid}) {
                push @hints, "$c (guest $decoded->{vmid})";
            } else {
                push @hints, $c;
            }
        }
        # One line: PVE flattens newlines in task/CLI errors into spaces.
        die "Cannot delete snapshot '$snap' of '$volname': ONTAP snapshot "
          . "'$ontap_snapname' is locked by " . scalar(@locked_by) . " dependent "
          . "FlexClone(s): " . join(', ', @hints) . "."
          . " These are linked clones of this snapshot (e.g. 'qm clone <vmid> <newid>"
          . " --snapname $snap --full 0'); ONTAP will not release a snapshot while a"
          . " clone still has it as parent."
          . " Delete the guest(s) owning them, or make them independent"
          . " ('volume clone split start -vserver $scfg->{'ontap-svm'} -flexclone <name>')."
          . " The plugin will not split or delete them for you -- they are live disks"
          . " belonging to other guests.\n";
    }

    $api->snapshot_delete($ontap_volname, $ontap_snapname);

    return 1;
}

# Release ONTAP volume-recovery-queue clone holds on $ontap_volname.
#
# See API::volume_get_clone_children_cli() for the mechanism. Short version: a
# FlexClone that has been deleted but is still in ONTAP's recovery queue REMAINS a
# clone of its parent, which blocks both `snapshot_delete` on the parent's
# snapshot ("has not expired or is locked") and `volume_delete` on the parent
# ("it has one or more clones") for the whole retention window (default 12h),
# with an error that never mentions the queue.
#
# SAFETY -- an entry is purged only when ALL of these hold:
#   1. ONTAP's own CLI clone view reports it as a clone of $ontap_volname (so it
#      is genuinely what is blocking us),
#   2. it is NOT a live volume (volume_get returns undef) -- we never purge
#      something still in use; a live clone is the operator's problem to resolve
#      and callers report it instead,
#   3. it is present in the recovery queue, and
#   4. its name is plugin-managed: "<one of our volume names>_<digits>", i.e. it
#      derives from a pve_* volume of a netappontap storage. A customer's
#      manually created clone is never touched.
#
# Purging is limited to entries blocking the operation the operator just
# requested, so the recovery queue's safety net is preserved for everything else.
# Set 'ontap-purge-recovery-queue 0' to disable and get an actionable error
# instead.
#
# Returns (\@purged, \@live_blockers, \@refused).
sub _release_recovery_queue_clone_holds {
    my ($api, $scfg, $ontap_volname) = @_;

    my (@purged, @live, @refused);

    my $cli_children = eval { $api->volume_get_clone_children_cli($ontap_volname); } // [];
    return (\@purged, \@live, \@refused) unless @$cli_children;

    my $queue_entries = eval { $api->recovery_queue_list(); } // [];
    my %queued = map { ($_->{volume} // '') => 1 } @$queue_entries;

    my $purge_enabled = $scfg->{'ontap-purge-recovery-queue'} // 1;

    for my $child (@$cli_children) {
        my $name = $child->{flexclone} // next;

        # (2) Live volumes are never purged -- the caller reports them instead.
        #
        # Distinguish "confirmed absent" (volume_get returned undef) from "could
        # not tell" (volume_get died: network blip, auth, ONTAP busy). A naive
        # `if (eval { ... })` treats BOTH as absent, which would let a transient
        # API error advance a live volume toward purging. This is the v0.2.16
        # lesson ("distinguish confirmed-not-found from transient error when
        # deciding to skip cleanup") applied to a destructive operation, so it
        # matters more here, not less.
        my $live_vol = eval { $api->volume_get($name); };
        if ($@) {
            push @refused, "$name (could not verify whether it is still a live "
                         . "volume: $@)";
            next;
        }
        if ($live_vol) {
            push @live, $name;
            next;
        }

        # (4) Plugin-managed naming only: "<pve_*_volume>_<digits>", or one of our
        # temp FlexClones. Anything else may be a customer-created clone and is
        # left strictly alone.
        my ($base) = $name =~ /^(.+)_\d+$/;
        if (!$base || !(is_pve_managed_volume($base) || $base =~ /^tmpclone_pve_/)) {
            push @refused, "$name (not a plugin-managed volume name)";
            next;
        }

        # (3) Must actually be in the recovery queue.
        if (!$queued{$name}) {
            push @refused, "$name (not found in the volume recovery queue)";
            next;
        }

        if (!$purge_enabled) {
            push @refused, "$name (queued clone; 'ontap-purge-recovery-queue' is disabled)";
            next;
        }

        warn "Purging deleted FlexClone '$name' from the ONTAP volume recovery "
           . "queue: it was already deleted but still counts as a clone of "
           . "'$ontap_volname', which blocks snapshot/volume deletion for the "
           . "remainder of the SVM's volume-delete-retention window.\n";

        eval { $api->recovery_queue_purge($name); };
        if ($@) {
            push @refused, "$name (purge failed: $@)";
        } else {
            push @purged, $name;
        }
    }

    return (\@purged, \@live, \@refused);
}

# Build the operator-facing explanation for clones that still block $ontap_snapname.
sub _clone_hold_hint {
    my ($live, $refused, $svm) = @_;

    my @hints;
    for my $c (@$live) {
        my $decoded = decode_volume_name($c);
        push @hints, (($decoded && defined $decoded->{vmid})
            ? "$c (live, guest $decoded->{vmid})" : "$c (live)");
    }
    push @hints, @$refused;

    return join(', ', @hints);
}

# Guard the destructive half of snapshot rollback.
#
# ONTAP's SnapRestore (PATCH /storage/volumes/{uuid} with restore_to.snapshot,
# see API::snapshot_rollback) reverts the volume to the chosen snapshot AND
# DELETES every snapshot created after it. PVE does not know that:
#
#   - PVE::Storage::Plugin::volume_rollback_is_possible() returns 1 immediately
#     unless the storage uses 'snapshot-as-volume-chain', which we do not.
#   - PVE::AbstractConfig::snapshot_rollback() does NOT remove the newer
#     snapshots from the guest config (it only applies the snapshot's config via
#     __snapshot_apply_config).
#
# So without this method, rolling back to snap1 while snap2/snap3 exist silently
# destroys snap2 and snap3 on ONTAP while PVE keeps listing them in the config
# and in the web UI. The operator believes they still hold three restore points
# and only finds out when a later rollback/delete of snap2 fails. Every core
# plugin whose rollback is likewise destructive (ZFSPool, LvmThin, LVM, BTRFS)
# implements this method for exactly this reason.
#
# Contract (PVE::Storage::volume_rollback_is_possible): die if rollback is not
# possible, and push the names of the blocking snapshots into $blockers (which
# may be undef -- Storage.pm calls us both ways) so the caller can show them.
sub volume_rollback_is_possible {
    my ($class, $scfg, $storeid, $volname, $snap, $blockers) = @_;

    $blockers //= [];

    my $api = _get_api($scfg, storeid => $storeid);
    my $ontap_volname = pve_volname_to_ontap($storeid, $volname);
    my $target = encode_snapshot_name($snap);

    # Query ALL snapshots, not just pve_snap_*: a template's '__pve_base__'
    # snapshot (which linked clones depend on) would also be destroyed by a
    # SnapRestore that reverts past it, so it must be able to act as a blocker.
    my $snapshots = $api->snapshot_list($ontap_volname);

    my %by_name;
    my $target_ts;
    for my $s (@$snapshots) {
        my $name = $s->{name};
        next unless defined $name;
        my $ts = _parse_ontap_time($s->{create_time});
        $by_name{$name} = $ts;
        $target_ts = $ts if $name eq $target;
    }

    die "can't rollback, snapshot '$snap' does not exist on '$volname'\n"
        if !exists $by_name{$target};

    # If ONTAP gave us an unparseable timestamp for the target we cannot order
    # anything safely. Refuse rather than risk destroying newer snapshots.
    die "can't rollback '$volname' to '$snap': ONTAP did not report a usable "
      . "creation time for snapshot '$target', so the plugin cannot prove that "
      . "no newer snapshots would be destroyed by SnapRestore.\n"
        if !defined $target_ts;

    for my $name (sort keys %by_name) {
        next if $name eq $target;
        my $ts = $by_name{$name};

        # Unknown timestamp, or created at/after the target: treat as blocking.
        # Ties are deliberately treated as blockers -- a false block is an
        # inconvenience, a false "safe to roll back" silently destroys a restore
        # point. (A tie needs two snapshots of the SAME volume in the same
        # second, which PVE cannot produce.)
        next if defined $ts && $ts < $target_ts;

        push $blockers->@*, (decode_snapshot_name($name) // $name);
    }

    if (scalar($blockers->@*) > 0) {
        # Keep this to ONE line. Proxmox VE collapses newlines in task/CLI error
        # output into spaces, so a multi-line explanation renders as an unreadable
        # run-on paragraph (observed in `qm rollback`). Lead with the same wording
        # the core plugins use, then the essential consequence.
        die "can't rollback, '$snap' is not the most recent snapshot on '$volname'"
          . " -- ONTAP SnapRestore would DELETE these newer snapshot(s): "
          . join(', ', $blockers->@*)
          . " (Proxmox VE would still list them). Delete them first, newest first,"
          . " if you really want to roll back to '$snap'.\n";
    }

    # A dependent FlexClone pinned to a snapshot that SnapRestore would remove
    # is caught by the blocker loop above (that snapshot is itself newer than the
    # target). Nothing further to check here.

    return 1;
}

# Parse an ONTAP REST timestamp ("2026-07-26T10:15:30+08:00", "...Z", optional
# fractional seconds) into epoch seconds. Returns undef if unparseable -- callers
# MUST treat undef as "unknown", never as 0.
sub _parse_ontap_time {
    my ($str) = @_;

    return undef unless defined $str && length $str;

    my ($y, $mo, $d, $h, $mi, $s, $tz) = $str =~ m{
        ^(\d{4})-(\d{2})-(\d{2})
        [T ](\d{2}):(\d{2}):(\d{2})
        (?:\.\d+)?
        (Z|[+-]\d{2}:?\d{2})?$
    }x;
    return undef unless defined $y;

    my $epoch = eval { Time::Local::timegm($s, $mi, $h, $d, $mo - 1, $y); };
    return undef if $@ || !defined $epoch;

    # Convert the local-with-offset reading back to true UTC.
    if (defined $tz && $tz ne 'Z') {
        my ($sign, $oh, $om) = $tz =~ /^([+-])(\d{2}):?(\d{2})$/;
        if (defined $sign) {
            my $off = ($oh * 3600) + ($om * 60);
            $epoch += ($sign eq '+') ? -$off : $off;
        }
    }

    return $epoch;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $api = _get_api($scfg, storeid => $storeid);
    my $ontap_volname = pve_volname_to_ontap($storeid, $volname);
    my $ontap_snapname = encode_snapshot_name($snap);
    my $lun_path = encode_lun_path($ontap_volname);

    # Quiesce device before rollback to prevent data corruption.
    #
    # Rollback is MORE destructive than delete: it silently overwrites the whole
    # volume with older content, so a mistake here is not even visible as a
    # missing disk. It gets the same treatment as free_image().
    my $wwid = eval { $api->lun_get_wwid($lun_path); };
    my $device;
    my $local_device_checked = 0;
    if ($wwid) {
        $device = get_device_by_wwid($wwid);
        if ($device && -b $device) {
            $local_device_checked = 1;
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

    # Cross-node safety net, identical in shape to free_image()'s: only when the
    # host-side check could not run, and one-directional (observed I/O refuses,
    # idle never blocks). PVE routes a rollback to the guest's owning node and
    # stops the guest first, so this mainly catches the case where the same volid
    # was attached to a guest on another node -- which PVE permits and does not
    # guard, and where the overwrite would be silent.
    if ($wwid && !$local_device_checked && ($scfg->{'ontap-inuse-io-check'} // 1)) {
        my $busy = eval { _lun_has_active_io($api, $lun_path); };
        if ($@) {
            warn "Could not sample ONTAP I/O activity for '$volname' before rolling "
               . "back (continuing; the host-side check could not run either): $@";
        } elsif ($busy) {
            die "Cannot rollback snapshot '$snap' of '$volname': ONTAP reports ACTIVE "
              . "I/O on LUN '$lun_path' ($busy), so it is in use -- most likely by a "
              . "guest running on another cluster node. This node has no local mapping "
              . "for it, so the host-side in-use check could not see that. A rollback "
              . "would OVERWRITE whatever that guest is currently using.\n"
              . "  Stop or migrate the guest that owns this disk, then retry. ONTAP's "
              . "counters lag by up to one statistics interval, so a guest that was "
              . "JUST stopped can still read as active for a few seconds -- simply "
              . "retry. To disable this cross-node check: "
              . "'pvesm set $storeid --ontap-inuse-io-check 0'.\n";
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

    my $api = _get_api($scfg, storeid => $storeid);
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

    # Every core PVE plugin dies on an unparseable volume name. Returning undef
    # (the old behaviour) makes the caller's list assignment yield an empty list,
    # so $vtype/$format come back undefined and the real failure surfaces much
    # later as "Use of uninitialized value" somewhere in PVE, with no hint about
    # which volume was at fault.
    die "unable to parse NetApp ONTAP volume name '$volname'\n" unless $parsed;

    # Return format: ($vtype, $name, $vmid, $basename, $basevmid, $isBase, $format)
    if ($parsed->{type} eq 'disk') {
        my $isBase = $parsed->{isBase} ? 1 : 0;
        return ('images', $volname, $parsed->{vmid}, undef, undef, $isBase, $parsed->{format});
    } elsif ($parsed->{type} eq 'cloudinit') {
        return ('images', $volname, $parsed->{vmid}, undef, undef, 0, $parsed->{format});
    } elsif ($parsed->{type} eq 'state') {
        return ('images', $volname, $parsed->{vmid}, undef, undef, 0, $parsed->{format});
    } elsif ($parsed->{type} eq 'fleece') {
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

    my $api = _get_api($scfg, storeid => $storeid);
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

    my $api = _get_api($scfg, storeid => $storeid);

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

    my $api = _get_api($scfg, storeid => $storeid);

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
        ontap-portal 192.168.1.100
        ontap-svm svm0
        ontap-aggregate aggr1
        ontap-username admin
        ontap-password secret
        content images,rootdir
        shared 1

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

All plugin-specific options carry the C<ontap-> prefix. See properties() for the
authoritative schema, and docs/CONFIGURATION.md for full descriptions.

=over 4

=item B<ontap-portal> - ONTAP management IP/hostname (required)

=item B<ontap-svm> - Storage Virtual Machine name (required)

=item B<ontap-aggregate> - Aggregate for volume creation (required)

=item B<ontap-username> - API username (required)

=item B<ontap-password> - API password (required)

=item B<ontap-ssl-verify> - Verify SSL certificates (default: yes)

=item B<ontap-thin> - Use thin provisioning (default: yes)

=item B<ontap-igroup-mode> - 'per-node' or 'shared' igroup (default: per-node)

=item B<ontap-cluster-name> - PVE cluster name used for igroup naming (default: pve)

=item B<ontap-protocol> - 'iscsi' or 'fc' (default: iscsi)

=item B<ontap-device-timeout> - Device discovery timeout in seconds (default: 60)

=item B<ontap-portal-probe-timeout> - TCP pre-check timeout before iscsiadm,
0 disables (default: 2)

=item B<ontap-status-timeout> - Per-call ONTAP REST timeout for the pvestatd
health path only (default: 5)

=item B<ontap-activate-deadline> - Wall-clock budget for the iSCSI
discover/login loop in activate_storage (default: 30)

=back

=head1 PROXMOX VE COMPATIBILITY

Supports Proxmox VE 9.0, 9.1 and 9.2. The storage plugin API version reported by
api() is negotiated at load time against the running C<PVE::Storage::APIVER>,
because Proxmox VE bumped APIVER twice within the 9.1 point releases
(libpve-storage-perl 9.0.16-9.1.2 = 13, 9.1.3-9.1.5 = 14, 9.1.6+ = 15) and PVE
hard-rejects a plugin that reports a version higher than its own. See the
APIVERSION_MAX comment for details.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
