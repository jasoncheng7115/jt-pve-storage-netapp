package PVE::Storage::Custom::NetAppONTAP::Naming;

use strict;
use warnings;

use Exporter qw(import);

our @EXPORT_OK = qw(
    encode_volume_name
    decode_volume_name
    encode_lun_path
    decode_lun_path
    encode_snapshot_name
    decode_snapshot_name
    encode_igroup_name
    sanitize_for_ontap
    is_valid_ontap_volume_name
    is_valid_ontap_snapshot_name
    is_pve_managed_volume
    pve_volname_to_ontap
    ontap_to_pve_volname
);

# ONTAP naming constraints
use constant {
    MAX_VOLUME_NAME_LENGTH   => 203,
    MAX_LUN_NAME_LENGTH      => 255,
    MAX_SNAPSHOT_NAME_LENGTH => 255,
    MAX_IGROUP_NAME_LENGTH   => 96,
    MAX_STORAGE_NAME_LENGTH  => 32,
};

# Regex patterns for parsing
my $RE_VOLUME_NAME = qr/^pve_([a-zA-Z0-9_]+)_(\d+)_disk(\d+)$/;
my $RE_CLOUDINIT   = qr/^pve_([a-zA-Z0-9_]+)_(\d+)_cloudinit$/;
my $RE_VMSTATE     = qr/^pve_([a-zA-Z0-9_]+)_(\d+)_state_(.+)$/;
my $RE_SNAPSHOT    = qr/^pve_snap_(.+)$/;
my $RE_LUN_PATH    = qr|^/vol/([^/]+)/lun0$|;

# Sanitize a string for ONTAP naming rules
# Replaces invalid characters with underscore
sub sanitize_for_ontap {
    my ($str, $max_len) = @_;
    $max_len //= MAX_VOLUME_NAME_LENGTH;

    return '' unless defined $str && length($str) > 0;

    my $sanitized = $str;
    # Replace hyphens and spaces with underscores
    $sanitized =~ s/[-\s]/_/g;
    # Remove any character that's not alphanumeric or underscore
    $sanitized =~ s/[^a-zA-Z0-9_]//g;
    # Ensure it starts with a letter or underscore
    $sanitized = "_$sanitized" unless $sanitized =~ /^[a-zA-Z_]/;
    # Truncate to max length
    $sanitized = substr($sanitized, 0, $max_len);

    return $sanitized;
}

# Encode PVE volume identifier to ONTAP FlexVol name
# Input: storage ID, VM ID, disk ID
# Output: ONTAP volume name like "pve_netapp1_100_disk0"
sub encode_volume_name {
    my ($storage, $vmid, $diskid) = @_;

    die "storage is required" unless defined $storage;
    die "vmid is required" unless defined $vmid;
    die "diskid is required" unless defined $diskid;

    my $san_storage = sanitize_for_ontap($storage, MAX_STORAGE_NAME_LENGTH);
    return "pve_${san_storage}_${vmid}_disk${diskid}";
}

# Decode ONTAP FlexVol name to PVE components
# Returns hashref: { storage => ..., vmid => ..., diskid => ... }
# Returns undef if name doesn't match expected pattern
sub decode_volume_name {
    my ($volname) = @_;

    return undef unless defined $volname;

    # Standard disk
    if ($volname =~ $RE_VOLUME_NAME) {
        return {
            storage => $1,
            vmid    => int($2),
            diskid  => int($3),
            type    => 'disk',
        };
    }

    # Cloud-init
    if ($volname =~ $RE_CLOUDINIT) {
        return {
            storage => $1,
            vmid    => int($2),
            type    => 'cloudinit',
        };
    }

    # VM state
    if ($volname =~ $RE_VMSTATE) {
        return {
            storage  => $1,
            vmid     => int($2),
            snapname => $3,
            type     => 'state',
        };
    }

    return undef;
}

# Encode FlexVol name to LUN path
# ONTAP LUN paths are: /vol/{volume_name}/{lun_name}
# We use fixed "lun0" since we have 1:1 volume:LUN mapping
sub encode_lun_path {
    my ($volname) = @_;

    die "volume name is required" unless defined $volname;
    return "/vol/$volname/lun0";
}

# Decode LUN path to FlexVol name
sub decode_lun_path {
    my ($lun_path) = @_;

    return undef unless defined $lun_path;

    if ($lun_path =~ $RE_LUN_PATH) {
        return $1;
    }

    return undef;
}

# Encode PVE snapshot name to ONTAP snapshot name
sub encode_snapshot_name {
    my ($snapname) = @_;

    die "snapshot name is required" unless defined $snapname;

    my $san_snap = sanitize_for_ontap($snapname, 200);
    return "pve_snap_${san_snap}";
}

# Decode ONTAP snapshot name to PVE snapshot name
# Note: This only returns the sanitized version, not the original
sub decode_snapshot_name {
    my ($ontap_snapname) = @_;

    return undef unless defined $ontap_snapname;

    if ($ontap_snapname =~ $RE_SNAPSHOT) {
        return $1;
    }

    return undef;
}

# Encode igroup name for a PVE node
sub encode_igroup_name {
    my ($cluster, $node) = @_;

    $cluster //= 'pve';
    my $san_cluster = sanitize_for_ontap($cluster, 32);

    if (defined $node) {
        my $san_node = sanitize_for_ontap($node, 32);
        return "pve_${san_cluster}_${san_node}";
    } else {
        return "pve_${san_cluster}_shared";
    }
}

# Validate ONTAP volume name
sub is_valid_ontap_volume_name {
    my ($name) = @_;

    return 0 unless defined $name;
    return 0 if length($name) > MAX_VOLUME_NAME_LENGTH;
    return 0 if length($name) < 1;
    return 0 unless $name =~ /^[a-zA-Z_][a-zA-Z0-9_]*$/;

    return 1;
}

# Validate ONTAP snapshot name
sub is_valid_ontap_snapshot_name {
    my ($name) = @_;

    return 0 unless defined $name;
    return 0 if length($name) > MAX_SNAPSHOT_NAME_LENGTH;
    return 0 if length($name) < 1;
    return 0 unless $name =~ /^[a-zA-Z_][a-zA-Z0-9_-]*$/;

    return 1;
}

# Check if volume name is managed by this plugin
sub is_pve_managed_volume {
    my ($name) = @_;

    return 0 unless defined $name;
    return ($name =~ /^pve_[a-zA-Z0-9_]+_\d+_(disk\d+|cloudinit|state_.+)$/);
}

# Convert PVE volume name (vm-100-disk-0 or base-100-disk-0) to ONTAP volume name
sub pve_volname_to_ontap {
    my ($storage, $pve_volname) = @_;

    die "storage is required" unless defined $storage;
    die "pve_volname is required" unless defined $pve_volname;

    # Parse PVE volume name format: vm-{vmid}-disk-{diskid}
    if ($pve_volname =~ /^vm-(\d+)-disk-(\d+)$/) {
        return encode_volume_name($storage, $1, $2);
    }

    # Template base disk: base-{vmid}-disk-{diskid}
    # Uses same ONTAP naming as regular disk (underlying volume is the same)
    if ($pve_volname =~ /^base-(\d+)-disk-(\d+)$/) {
        return encode_volume_name($storage, $1, $2);
    }

    # Cloud-init: vm-{vmid}-cloudinit
    if ($pve_volname =~ /^vm-(\d+)-cloudinit$/) {
        my $vmid = $1;
        my $san_storage = sanitize_for_ontap($storage, MAX_STORAGE_NAME_LENGTH);
        return "pve_${san_storage}_${vmid}_cloudinit";
    }

    # VM state: vm-{vmid}-state-{snapname}
    if ($pve_volname =~ /^vm-(\d+)-state-(.+)$/) {
        my ($vmid, $snapname) = ($1, $2);
        my $san_storage = sanitize_for_ontap($storage, MAX_STORAGE_NAME_LENGTH);
        my $san_snap = sanitize_for_ontap($snapname, 100);
        return "pve_${san_storage}_${vmid}_state_${san_snap}";
    }

    die "Unrecognized PVE volume name format: $pve_volname";
}

# Convert ONTAP volume name to PVE volume name
sub ontap_to_pve_volname {
    my ($ontap_volname) = @_;

    my $decoded = decode_volume_name($ontap_volname);
    return undef unless $decoded;

    if ($decoded->{type} eq 'disk') {
        return "vm-$decoded->{vmid}-disk-$decoded->{diskid}";
    } elsif ($decoded->{type} eq 'cloudinit') {
        return "vm-$decoded->{vmid}-cloudinit";
    } elsif ($decoded->{type} eq 'state') {
        return "vm-$decoded->{vmid}-state-$decoded->{snapname}";
    }

    return undef;
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::NetAppONTAP::Naming - Naming convention utilities for NetApp ONTAP plugin

=head1 SYNOPSIS

    use PVE::Storage::Custom::NetAppONTAP::Naming qw(
        encode_volume_name
        decode_volume_name
        encode_snapshot_name
    );

    # Encode PVE disk to ONTAP volume name
    my $volname = encode_volume_name('netapp1', 100, 0);
    # Returns: pve_netapp1_100_disk0

    # Decode ONTAP volume name
    my $info = decode_volume_name('pve_netapp1_100_disk0');
    # Returns: { storage => 'netapp1', vmid => 100, diskid => 0, type => 'disk' }

=head1 DESCRIPTION

This module provides naming convention utilities for mapping between
Proxmox VE volume names and NetApp ONTAP object names (FlexVol, LUN, Snapshot).

=head1 NAMING PATTERNS

=over 4

=item FlexVol: C<pve_{storage}_{vmid}_disk{diskid}>

=item LUN: C</vol/{flexvol}/lun0>

=item Snapshot: C<pve_snap_{snapname}>

=item igroup: C<pve_{cluster}_{node}> or C<pve_{cluster}_shared>

=back

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
