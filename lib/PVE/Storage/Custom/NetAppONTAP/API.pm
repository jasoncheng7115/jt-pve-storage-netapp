package PVE::Storage::Custom::NetAppONTAP::API;

use strict;
use warnings;

use LWP::UserAgent;
use HTTP::Request;
use JSON;
use URI;
use MIME::Base64;
use Carp qw(croak);

# Constants
use constant {
    DEFAULT_TIMEOUT     => 15,
    DEFAULT_RETRY_COUNT => 2,
    DEFAULT_RETRY_DELAY => 2,
    API_VERSION         => '9.8',  # Minimum ONTAP REST API version
};

# Constructor
sub new {
    my ($class, %opts) = @_;

    croak "host is required" unless $opts{host};
    croak "username is required" unless $opts{username};
    croak "password is required" unless $opts{password};
    croak "svm is required" unless $opts{svm};

    my $self = {
        host        => $opts{host},
        username    => $opts{username},
        password    => $opts{password},
        svm         => $opts{svm},
        aggregate   => $opts{aggregate},
        port        => $opts{port} // 443,
        ssl_verify  => $opts{ssl_verify} // 1,
        timeout     => $opts{timeout} // DEFAULT_TIMEOUT,
        retry_count => $opts{retry_count} // DEFAULT_RETRY_COUNT,
        retry_delay => $opts{retry_delay} // DEFAULT_RETRY_DELAY,
        _ua         => undef,
        _svm_uuid   => undef,
    };

    bless $self, $class;
    $self->_init_ua();

    return $self;
}

# Initialize LWP::UserAgent
sub _init_ua {
    my ($self) = @_;

    my $ua = LWP::UserAgent->new(
        timeout         => $self->{timeout},
        ssl_opts        => {
            verify_hostname => $self->{ssl_verify},
            SSL_verify_mode => $self->{ssl_verify} ? 1 : 0,
        },
    );

    # Set default headers
    my $auth = encode_base64("$self->{username}:$self->{password}", '');
    $ua->default_header('Authorization' => "Basic $auth");
    $ua->default_header('Accept' => 'application/json');
    $ua->default_header('Content-Type' => 'application/json');

    $self->{_ua} = $ua;
}

# Build API URL
sub _build_url {
    my ($self, $endpoint) = @_;

    $endpoint =~ s|^/||;  # Remove leading slash if present
    return "https://$self->{host}:$self->{port}/api/$endpoint";
}

# Execute API request with retry logic
sub _request {
    my ($self, $method, $endpoint, $data) = @_;

    my $url = $self->_build_url($endpoint);
    my $retry_count = $self->{retry_count};
    my $last_error;

    for my $attempt (1 .. $retry_count) {
        my $req = HTTP::Request->new($method => $url);

        if ($data && ($method eq 'POST' || $method eq 'PATCH')) {
            $req->content(encode_json($data));
        }

        my $resp = $self->{_ua}->request($req);

        if ($resp->is_success) {
            my $content = $resp->decoded_content;
            return {} if !$content || $content eq '';
            return decode_json($content);
        }

        # Handle specific error codes
        my $code = $resp->code;
        $last_error = "HTTP $code: " . $resp->status_line;

        # Parse error response if JSON
        eval {
            my $err = decode_json($resp->decoded_content);
            if ($err->{error}) {
                $last_error = "ONTAP API Error: $err->{error}{message} (code: $err->{error}{code})";
            }
        };

        # On 401, reinitialize auth and retry (session/token may have expired)
        if ($code == 401 && $attempt < $retry_count) {
            warn "ONTAP API returned 401, reinitializing auth (attempt $attempt/$retry_count)\n";
            $self->_init_ua();
            next;
        }

        # Don't retry on client errors (4xx) except 429 (rate limit)
        last if $code >= 400 && $code < 500 && $code != 429;

        # Wait before retry
        if ($attempt < $retry_count) {
            sleep($self->{retry_delay} * $attempt);
        }
    }

    croak $last_error;
}

# GET request
sub get {
    my ($self, $endpoint, $params) = @_;

    if ($params && %$params) {
        my $uri = URI->new($endpoint);
        $uri->query_form($params);
        $endpoint = $uri->as_string;
    }

    return $self->_request('GET', $endpoint);
}

# POST request (with async job handling)
sub post {
    my ($self, $endpoint, $data, %opts) = @_;
    my $resp = $self->_request('POST', $endpoint, $data);

    # Handle async jobs
    if ($resp->{job} && $resp->{job}{uuid} && !$opts{no_wait}) {
        return $self->wait_for_job($resp->{job}{uuid});
    }

    return $resp;
}

# Wait for async job to complete
sub wait_for_job {
    my ($self, $job_uuid, %opts) = @_;

    my $timeout = $opts{timeout} // 120;  # 2 minutes default
    my $interval = $opts{interval} // 2;   # 2 seconds
    my $start = time();

    while ((time() - $start) < $timeout) {
        my $job = $self->get("/cluster/jobs/$job_uuid");

        if ($job->{state} eq 'success') {
            return $job;
        }

        if ($job->{state} eq 'failure') {
            my $msg = $job->{error}{message} // $job->{message} // 'Unknown error';
            croak "ONTAP job failed: $msg";
        }

        # Still running, wait and retry
        sleep($interval);
    }

    croak "Timeout waiting for ONTAP job $job_uuid";
}

# PATCH request (with async job handling)
sub patch {
    my ($self, $endpoint, $data, %opts) = @_;
    my $resp = $self->_request('PATCH', $endpoint, $data);

    # Handle async jobs
    if ($resp->{job} && $resp->{job}{uuid} && !$opts{no_wait}) {
        return $self->wait_for_job($resp->{job}{uuid});
    }

    return $resp;
}

# DELETE request (with async job handling)
sub delete {
    my ($self, $endpoint, %opts) = @_;
    my $resp = $self->_request('DELETE', $endpoint);

    # Handle async jobs
    if ($resp->{job} && $resp->{job}{uuid} && !$opts{no_wait}) {
        return $self->wait_for_job($resp->{job}{uuid});
    }

    return $resp;
}

# Get SVM UUID (cached)
sub get_svm_uuid {
    my ($self) = @_;

    return $self->{_svm_uuid} if $self->{_svm_uuid};

    my $resp = $self->get('/svm/svms', { name => $self->{svm} });

    if ($resp->{records} && @{$resp->{records}}) {
        $self->{_svm_uuid} = $resp->{records}[0]{uuid};
        return $self->{_svm_uuid};
    }

    croak "SVM '$self->{svm}' not found";
}

#
# Volume operations
#

# Create a FlexVol volume
sub volume_create {
    my ($self, %opts) = @_;

    croak "name is required" unless $opts{name};
    croak "aggregate is required" unless $opts{aggregate};
    croak "size is required" unless $opts{size};

    my $svm_uuid = $self->get_svm_uuid();

    my $data = {
        name => $opts{name},
        svm  => { uuid => $svm_uuid },
        aggregates => [{ name => $opts{aggregate} }],
        size => $opts{size},
        style => 'flexvol',
        type => 'rw',
        guarantee => { type => $opts{space_guarantee} // 'none' },
        snapshot_policy => { name => $opts{snapshot_policy} // 'none' },
        # Enable volume autogrow so it expands automatically when needed
        # This eliminates the need for large fixed overhead
        autosize => {
            mode => 'grow',
            maximum => $opts{size} * 2,  # Allow up to 2x initial size
            grow_threshold => 85,         # Grow when 85% full
        },
    };

    # Enable thin provisioning
    if ($opts{thin}) {
        $data->{guarantee}{type} = 'none';
    }

    return $self->post('/storage/volumes', $data);
}

# Get volume by name
sub volume_get {
    my ($self, $name) = @_;

    my $svm_uuid = $self->get_svm_uuid();
    my $resp = $self->get('/storage/volumes', {
        name     => $name,
        'svm.uuid' => $svm_uuid,
        fields   => 'uuid,name,size,space,state',
    });

    if ($resp->{records} && @{$resp->{records}}) {
        return $resp->{records}[0];
    }

    return undef;
}

# Get volume UUID by name
sub volume_get_uuid {
    my ($self, $name) = @_;

    my $vol = $self->volume_get($name);
    return $vol ? $vol->{uuid} : undef;
}

# Delete a volume
sub volume_delete {
    my ($self, $name) = @_;

    my $uuid = $self->volume_get_uuid($name);
    croak "Volume '$name' not found" unless $uuid;

    return $self->delete("/storage/volumes/$uuid");
}

# Resize a volume
sub volume_resize {
    my ($self, $name, $new_size) = @_;

    my $uuid = $self->volume_get_uuid($name);
    croak "Volume '$name' not found" unless $uuid;

    return $self->patch("/storage/volumes/$uuid", { size => $new_size });
}

# Rename a volume
sub volume_rename {
    my ($self, $old_name, $new_name) = @_;

    my $uuid = $self->volume_get_uuid($old_name);
    croak "Volume '$old_name' not found" unless $uuid;

    return $self->patch("/storage/volumes/$uuid", { name => $new_name });
}

# Get volume space information
sub volume_space {
    my ($self, $name) = @_;

    my $vol = $self->volume_get($name);
    return undef unless $vol;

    return {
        size      => $vol->{size},
        used      => $vol->{space}{used},
        available => $vol->{space}{available},
    };
}

# List all PVE-managed volumes
sub volume_list {
    my ($self, $filter) = @_;

    my $svm_uuid = $self->get_svm_uuid();
    my $params = {
        'svm.uuid' => $svm_uuid,
        'name'     => 'pve_*',
        fields     => 'uuid,name,size,space,state,clone',
    };

    if ($filter) {
        $params->{name} = $filter;
    }

    my $resp = $self->get('/storage/volumes', $params);
    return $resp->{records} // [];
}

#
# FlexClone operations
#

# Check if FlexClone license is available
sub license_has_flexclone {
    my ($self) = @_;

    # Query licenses - FlexClone is typically part of ONTAP One or separate license
    my $resp = eval { $self->get('/cluster/licensing/licenses', { name => 'flexclone' }); };

    if ($resp && $resp->{records} && @{$resp->{records}}) {
        return 1;
    }

    # Also check for ONTAP One (includes FlexClone)
    $resp = eval { $self->get('/cluster/licensing/licenses', { name => 'base' }); };
    if ($resp && $resp->{records} && @{$resp->{records}}) {
        return 1;  # ONTAP Base/One includes FlexClone
    }

    return 0;
}

# Create a FlexClone volume from parent volume/snapshot
# Args:
#   clone_name: name for the new clone volume
#   parent_name: name of the parent volume
#   parent_snapshot: (optional) snapshot name to clone from
# Returns: clone volume info
sub volume_clone {
    my ($self, %opts) = @_;

    croak "clone_name is required" unless $opts{clone_name};
    croak "parent_name is required" unless $opts{parent_name};

    my $svm_uuid = $self->get_svm_uuid();

    my $data = {
        name => $opts{clone_name},
        svm  => { uuid => $svm_uuid },
        clone => {
            is_flexclone   => JSON::true,
            parent_volume  => { name => $opts{parent_name} },
        },
    };

    # If snapshot specified, clone from that snapshot
    if ($opts{parent_snapshot}) {
        $data->{clone}{parent_snapshot} = { name => $opts{parent_snapshot} };
    }

    # Set thin provisioning for clone
    $data->{guarantee} = { type => 'none' };

    return $self->post('/storage/volumes', $data);
}

# Check if a volume is a FlexClone
sub volume_is_clone {
    my ($self, $name) = @_;

    my $svm_uuid = $self->get_svm_uuid();
    my $resp = $self->get('/storage/volumes', {
        name       => $name,
        'svm.uuid' => $svm_uuid,
        fields     => 'clone',
    });

    if ($resp->{records} && @{$resp->{records}}) {
        my $vol = $resp->{records}[0];
        return $vol->{clone}{is_flexclone} ? 1 : 0;
    }

    return 0;
}

# Get parent volume info for a FlexClone
sub volume_get_clone_parent {
    my ($self, $name) = @_;

    my $svm_uuid = $self->get_svm_uuid();
    my $resp = $self->get('/storage/volumes', {
        name       => $name,
        'svm.uuid' => $svm_uuid,
        fields     => 'clone.parent_volume,clone.parent_snapshot',
    });

    if ($resp->{records} && @{$resp->{records}}) {
        my $vol = $resp->{records}[0];
        if ($vol->{clone} && $vol->{clone}{parent_volume}) {
            return {
                parent_volume   => $vol->{clone}{parent_volume}{name},
                parent_snapshot => $vol->{clone}{parent_snapshot}{name} // undef,
            };
        }
    }

    return undef;
}

# Get list of FlexClone children for a volume
sub volume_get_clone_children {
    my ($self, $parent_name) = @_;

    my $svm_uuid = $self->get_svm_uuid();
    my $resp = $self->get('/storage/volumes', {
        'svm.uuid'            => $svm_uuid,
        'clone.is_flexclone'  => 'true',
        'clone.parent_volume.name' => $parent_name,
        fields => 'name,uuid,clone',
    });

    return $resp->{records} // [];
}

# Split a FlexClone (make it independent from parent)
sub volume_clone_split {
    my ($self, $name) = @_;

    my $uuid = $self->volume_get_uuid($name);
    croak "Volume '$name' not found" unless $uuid;

    # Split clone by setting clone.split_initiated to true
    return $self->patch("/storage/volumes/$uuid", {
        clone => { split_initiated => JSON::true }
    });
}

# Check if volume is currently splitting (clone split in progress)
sub volume_is_splitting {
    my ($self, $name) = @_;

    my $svm_uuid = $self->get_svm_uuid();
    my $resp = $self->get('/storage/volumes', {
        name         => $name,
        'svm.uuid'   => $svm_uuid,
        fields       => 'clone.is_flexclone,clone.split_initiated,clone.split_complete_percent',
    });

    if ($resp->{records} && @{$resp->{records}}) {
        my $vol = $resp->{records}[0];
        my $clone = $vol->{clone} // {};

        # If it's still a FlexClone and split was initiated, it's splitting
        if ($clone->{is_flexclone} && $clone->{split_initiated}) {
            return {
                splitting => 1,
                percent   => $clone->{split_complete_percent} // 0,
            };
        }

        # If it's no longer a FlexClone, split is complete
        if (!$clone->{is_flexclone}) {
            return { splitting => 0, percent => 100 };
        }
    }

    return { splitting => 0, percent => 0 };
}

# Wait for clone split to complete
# Returns when split is done or timeout reached
sub volume_wait_clone_split {
    my ($self, $name, %opts) = @_;

    my $timeout = $opts{timeout} // 3600;  # Default 1 hour
    my $interval = $opts{interval} // 5;   # Check every 5 seconds
    my $callback = $opts{progress_callback};  # Optional progress callback

    my $start = time();
    my $last_percent = -1;

    while (time() - $start < $timeout) {
        my $status = $self->volume_is_splitting($name);

        # Report progress if callback provided and percentage changed
        if ($callback && $status->{percent} != $last_percent) {
            $callback->($status->{percent});
            $last_percent = $status->{percent};
        }

        # Split complete
        if (!$status->{splitting} && $status->{percent} >= 100) {
            return 1;
        }

        # Check if volume is no longer a clone (split complete)
        my $vol = $self->volume_get($name);
        if ($vol && !$self->volume_is_clone($name)) {
            return 1;  # No longer a clone = split complete
        }

        sleep($interval);
    }

    croak "Timeout waiting for clone split to complete after ${timeout}s";
}

#
# LUN operations
#

# Create a LUN
sub lun_create {
    my ($self, %opts) = @_;

    croak "name is required" unless $opts{name};
    croak "volume is required" unless $opts{volume};
    croak "size is required" unless $opts{size};

    my $svm_uuid = $self->get_svm_uuid();
    my $lun_path = "/vol/$opts{volume}/$opts{name}";

    my $data = {
        name     => $lun_path,
        svm      => { uuid => $svm_uuid },
        os_type  => $opts{os_type} // 'linux',
        space    => {
            size      => $opts{size},
            guarantee => { requested => $opts{thin} ? JSON::false : JSON::true },
        },
    };

    return $self->post('/storage/luns', $data);
}

# Get LUN by path
sub lun_get {
    my ($self, $lun_path) = @_;

    my $svm_uuid = $self->get_svm_uuid();
    my $resp = $self->get('/storage/luns', {
        name       => $lun_path,
        'svm.uuid' => $svm_uuid,
        fields     => 'uuid,name,serial_number,space,lun_maps',
    });

    if ($resp->{records} && @{$resp->{records}}) {
        return $resp->{records}[0];
    }

    return undef;
}

# List LUNs matching a pattern (batch query for performance)
sub lun_list {
    my ($self, $pattern) = @_;

    my $svm_uuid = $self->get_svm_uuid();
    my $resp = $self->get('/storage/luns', {
        name       => $pattern // '*',
        'svm.uuid' => $svm_uuid,
        fields     => 'uuid,name,serial_number,space',
        max_records => 1000,
    });

    return $resp->{records} // [];
}

# Get LUN UUID by path
sub lun_get_uuid {
    my ($self, $lun_path) = @_;

    my $lun = $self->lun_get($lun_path);
    return $lun ? $lun->{uuid} : undef;
}

# Delete a LUN
sub lun_delete {
    my ($self, $lun_path) = @_;

    my $uuid = $self->lun_get_uuid($lun_path);
    croak "LUN '$lun_path' not found" unless $uuid;

    return $self->delete("/storage/luns/$uuid");
}

# Resize a LUN
sub lun_resize {
    my ($self, $lun_path, $new_size) = @_;

    my $uuid = $self->lun_get_uuid($lun_path);
    croak "LUN '$lun_path' not found" unless $uuid;

    return $self->patch("/storage/luns/$uuid", {
        space => { size => $new_size },
    });
}

# Get LUN serial number (used for multipath identification)
sub lun_get_serial {
    my ($self, $lun_path) = @_;

    my $lun = $self->lun_get($lun_path);
    return $lun ? $lun->{serial_number} : undef;
}

# Convert LUN serial to NAA WWID format
# NetApp WWID format: 3600a0980 + hex(serial)
sub serial_to_wwid {
    my ($self, $serial) = @_;

    return undef unless $serial;

    # Convert serial to hex
    my $hex_serial = unpack('H*', $serial);

    # NetApp NAA WWID prefix
    return '3600a0980' . $hex_serial;
}

# Get LUN WWID (NAA format for multipath)
sub lun_get_wwid {
    my ($self, $lun_path) = @_;

    my $serial = $self->lun_get_serial($lun_path);
    return $self->serial_to_wwid($serial);
}

#
# igroup operations
#

# Create an igroup
sub igroup_create {
    my ($self, %opts) = @_;

    croak "name is required" unless $opts{name};
    croak "protocol is required" unless $opts{protocol};

    my $svm_uuid = $self->get_svm_uuid();

    my $data = {
        name     => $opts{name},
        svm      => { uuid => $svm_uuid },
        protocol => $opts{protocol},
        os_type  => $opts{os_type} // 'linux',
    };

    if ($opts{initiators} && @{$opts{initiators}}) {
        $data->{initiators} = [
            map { { name => $_ } } @{$opts{initiators}}
        ];
    }

    return $self->post('/protocols/san/igroups', $data);
}

# Get igroup by name
sub igroup_get {
    my ($self, $name) = @_;

    my $svm_uuid = $self->get_svm_uuid();
    my $resp = $self->get('/protocols/san/igroups', {
        name       => $name,
        'svm.uuid' => $svm_uuid,
        fields     => 'uuid,name,protocol,initiators,lun_maps',
    });

    if ($resp->{records} && @{$resp->{records}}) {
        return $resp->{records}[0];
    }

    return undef;
}

# Get or create igroup (handles concurrent creation race from multiple nodes)
sub igroup_get_or_create {
    my ($self, %opts) = @_;

    my $igroup = $self->igroup_get($opts{name});
    return $igroup if $igroup;

    eval { $self->igroup_create(%opts); };
    if ($@) {
        # Another node may have created it simultaneously (409 Conflict)
        my $retry = $self->igroup_get($opts{name});
        return $retry if $retry;
        die "Failed to create igroup '$opts{name}': $@";
    }
    return $self->igroup_get($opts{name});
}

# List all igroups
sub igroup_list {
    my ($self) = @_;

    my $svm_uuid = $self->get_svm_uuid();
    my $resp = $self->get('/protocols/san/igroups', {
        'svm.uuid' => $svm_uuid,
        fields     => 'name,uuid,protocol,os_type',
    });

    return $resp->{records} // [];
}

# Add initiator to igroup
sub igroup_add_initiator {
    my ($self, $igroup_name, $initiator) = @_;

    my $igroup = $self->igroup_get($igroup_name);
    croak "igroup '$igroup_name' not found" unless $igroup;

    return $self->post("/protocols/san/igroups/$igroup->{uuid}/initiators", {
        name => $initiator,
    });
}

# Remove initiator from igroup
sub igroup_remove_initiator {
    my ($self, $igroup_name, $initiator) = @_;

    my $igroup = $self->igroup_get($igroup_name);
    croak "igroup '$igroup_name' not found" unless $igroup;

    # URL encode the initiator name (IQN contains colons)
    my $enc_initiator = $initiator;
    $enc_initiator =~ s/:/%3A/g;

    return $self->delete("/protocols/san/igroups/$igroup->{uuid}/initiators/$enc_initiator");
}

#
# LUN mapping operations
#

# Map LUN to igroup
sub lun_map {
    my ($self, $lun_path, $igroup_name, $lun_id) = @_;

    my $lun_uuid = $self->lun_get_uuid($lun_path);
    croak "LUN '$lun_path' not found" unless $lun_uuid;

    my $igroup = $self->igroup_get($igroup_name);
    croak "igroup '$igroup_name' not found" unless $igroup;

    my $svm_uuid = $self->get_svm_uuid();

    my $data = {
        svm    => { uuid => $svm_uuid },
        lun    => { uuid => $lun_uuid },
        igroup => { uuid => $igroup->{uuid} },
    };

    # Optionally specify LUN ID
    if (defined $lun_id) {
        $data->{logical_unit_number} = int($lun_id);
    }

    return $self->post("/protocols/san/lun-maps", $data);
}

# Unmap LUN from igroup
sub lun_unmap {
    my ($self, $lun_path, $igroup_name) = @_;

    my $lun_uuid = $self->lun_get_uuid($lun_path);
    croak "LUN '$lun_path' not found" unless $lun_uuid;

    my $igroup = $self->igroup_get($igroup_name);
    croak "igroup '$igroup_name' not found" unless $igroup;

    return $self->delete("/protocols/san/lun-maps/$lun_uuid/$igroup->{uuid}");
}

# Check if LUN is mapped to igroup
sub lun_is_mapped {
    my ($self, $lun_path, $igroup_name) = @_;

    my $lun = $self->lun_get($lun_path);
    return 0 unless $lun && $lun->{lun_maps};

    for my $map (@{$lun->{lun_maps}}) {
        return 1 if $map->{igroup}{name} eq $igroup_name;
    }

    return 0;
}

# Unmap LUN from all igroups
sub lun_unmap_all {
    my ($self, $lun_path) = @_;

    my $lun = $self->lun_get($lun_path);
    return unless $lun && $lun->{lun_maps};

    my @errors;
    for my $map (@{$lun->{lun_maps}}) {
        eval { $self->lun_unmap($lun_path, $map->{igroup}{name}); };
        push @errors, "igroup '$map->{igroup}{name}': $@" if $@;
    }

    warn "lun_unmap_all warnings for $lun_path: " . join('; ', @errors) . "\n" if @errors;

    return 1;
}

#
# Snapshot operations
#

# Create a volume snapshot
sub snapshot_create {
    my ($self, $volume_name, $snapshot_name) = @_;

    my $vol_uuid = $self->volume_get_uuid($volume_name);
    croak "Volume '$volume_name' not found" unless $vol_uuid;

    return $self->post("/storage/volumes/$vol_uuid/snapshots", {
        name => $snapshot_name,
    });
}

# Get snapshot by name
sub snapshot_get {
    my ($self, $volume_name, $snapshot_name) = @_;

    my $vol_uuid = $self->volume_get_uuid($volume_name);
    return undef unless $vol_uuid;

    my $resp = $self->get("/storage/volumes/$vol_uuid/snapshots", {
        name   => $snapshot_name,
        fields => 'uuid,name,create_time',
    });

    if ($resp->{records} && @{$resp->{records}}) {
        return $resp->{records}[0];
    }

    return undef;
}

# List snapshots for a volume
sub snapshot_list {
    my ($self, $volume_name, $filter) = @_;

    my $vol_uuid = $self->volume_get_uuid($volume_name);
    return [] unless $vol_uuid;

    my $params = {
        fields => 'uuid,name,create_time',
    };

    if ($filter) {
        $params->{name} = $filter;
    }

    my $resp = $self->get("/storage/volumes/$vol_uuid/snapshots", $params);
    return $resp->{records} // [];
}

# Delete a snapshot
sub snapshot_delete {
    my ($self, $volume_name, $snapshot_name) = @_;

    my $vol_uuid = $self->volume_get_uuid($volume_name);
    croak "Volume '$volume_name' not found" unless $vol_uuid;

    my $snap = $self->snapshot_get($volume_name, $snapshot_name);
    croak "Snapshot '$snapshot_name' not found on volume '$volume_name'" unless $snap;

    return $self->delete("/storage/volumes/$vol_uuid/snapshots/$snap->{uuid}");
}

# Rollback volume to snapshot
sub snapshot_rollback {
    my ($self, $volume_name, $snapshot_name) = @_;

    my $vol_uuid = $self->volume_get_uuid($volume_name);
    croak "Volume '$volume_name' not found" unless $vol_uuid;

    return $self->patch("/storage/volumes/$vol_uuid", {
        restore_to => { snapshot => { name => $snapshot_name } },
    });
}

#
# iSCSI target information
#

# Get iSCSI target portals
sub iscsi_get_portals {
    my ($self) = @_;

    my $svm_uuid = $self->get_svm_uuid();
    my $resp = $self->get('/protocols/san/iscsi/services', {
        'svm.uuid' => $svm_uuid,
        fields     => 'target,enabled',
    });

    my @portals;

    if ($resp->{records} && @{$resp->{records}}) {
        my $target = $resp->{records}[0]{target}{name};

        # Get LIFs for iSCSI
        my $lif_resp = $self->get('/network/ip/interfaces', {
            'svm.uuid'          => $svm_uuid,
            'services'          => 'data_iscsi',
            fields              => 'ip.address',
        });

        if ($lif_resp->{records}) {
            for my $lif (@{$lif_resp->{records}}) {
                push @portals, {
                    target  => $target,
                    address => $lif->{ip}{address},
                    port    => 3260,
                };
            }
        }
    }

    return \@portals;
}

#
# Aggregate information (for capacity)
#

# Get aggregate information
sub aggregate_get {
    my ($self, $name) = @_;

    my $resp = $self->get('/storage/aggregates', {
        name   => $name,
        fields => 'uuid,name,space',
    });

    if ($resp->{records} && @{$resp->{records}}) {
        return $resp->{records}[0];
    }

    return undef;
}

# Get storage capacity from aggregate
sub get_managed_capacity {
    my ($self) = @_;

    # Get aggregate capacity
    if ($self->{aggregate}) {
        my $aggr = $self->aggregate_get($self->{aggregate});
        if ($aggr && $aggr->{space} && $aggr->{space}{block_storage}) {
            my $space = $aggr->{space}{block_storage};
            return {
                total     => $space->{size} // 0,
                used      => $space->{used} // 0,
                available => $space->{available} // 0,
            };
        }
    }

    # Fallback: sum up managed volumes
    my $volumes = $self->volume_list('pve_*');

    my $total = 0;
    my $used = 0;
    my $available = 0;

    for my $vol (@$volumes) {
        next unless $vol->{space};
        $total += $vol->{size} // 0;
        $used += $vol->{space}{used} // 0;
        $available += $vol->{space}{available} // 0;
    }

    return {
        total     => $total,
        used      => $used,
        available => $available,
    };
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::NetAppONTAP::API - ONTAP REST API client

=head1 SYNOPSIS

    use PVE::Storage::Custom::NetAppONTAP::API;

    my $api = PVE::Storage::Custom::NetAppONTAP::API->new(
        host     => '192.168.1.100',
        username => 'admin',
        password => 'secret',
        svm      => 'svm0',
    );

    # Create a volume
    $api->volume_create(
        name      => 'pve_netapp1_100_disk0',
        aggregate => 'aggr1',
        size      => 10 * 1024 * 1024 * 1024,  # 10GB
        thin      => 1,
    );

    # Create a LUN
    $api->lun_create(
        name    => 'lun0',
        volume  => 'pve_netapp1_100_disk0',
        size    => 10 * 1024 * 1024 * 1024,
        os_type => 'linux',
    );

    # Create snapshot
    $api->snapshot_create('pve_netapp1_100_disk0', 'pve_snap_before_upgrade');

=head1 DESCRIPTION

This module provides a Perl interface to the NetApp ONTAP REST API for
storage management operations required by the Proxmox VE storage plugin.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
