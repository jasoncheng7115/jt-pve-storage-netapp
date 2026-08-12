package PVE::Storage::Custom::NetAppONTAP::FC;

use strict;
use warnings;

use Carp qw(croak);
use File::Basename qw(basename);

use PVE::Storage::Custom::NetAppONTAP::Multipath qw(sysfs_write_with_timeout sysfs_read_with_timeout);

use Exporter qw(import);

our @EXPORT_OK = qw(
    get_fc_wwpns
    get_fc_wwnn
    get_fc_hosts
    rescan_fc_hosts
    is_fc_available
    format_wwn
);

# Constants
use constant {
    FC_HOST_PATH   => '/sys/class/fc_host',
    FC_REMOTE_PATH => '/sys/class/fc_remote_ports',
};

# Read file content (with timeout for sysfs files that could block)
sub _read_file {
    my ($path) = @_;
    return undef unless -r $path;
    my $content = sysfs_read_with_timeout($path, 5);
    chomp($content) if defined $content;
    return $content;
}

# Format WWN from 0x format to colon-separated format
# Input:  0x5001438032a5b6c7 or 5001438032a5b6c7
# Output: 50:01:43:80:32:a5:b6:c7
sub format_wwn {
    my ($wwn) = @_;
    return undef unless defined $wwn;

    # Remove 0x prefix if present
    $wwn =~ s/^0x//i;

    # Remove any existing colons or spaces
    $wwn =~ s/[:\s]//g;

    # Validate length (16 hex chars = 8 bytes)
    return undef unless $wwn =~ /^[0-9a-fA-F]{16}$/;

    # Insert colons every 2 characters
    $wwn = lc($wwn);
    $wwn =~ s/(..)(?=.)/$1:/g;

    return $wwn;
}

# Parse WWN to raw format (no colons, lowercase)
# Input:  50:01:43:80:32:a5:b6:c7 or 0x5001438032a5b6c7
# Output: 5001438032a5b6c7
sub parse_wwn {
    my ($wwn) = @_;
    return undef unless defined $wwn;

    # Remove 0x prefix if present
    $wwn =~ s/^0x//i;

    # Remove colons and spaces
    $wwn =~ s/[:\s]//g;

    # Validate and return lowercase
    return undef unless $wwn =~ /^[0-9a-fA-F]{16}$/;
    return lc($wwn);
}

# Check if FC HBA is available on this system
sub is_fc_available {
    return -d FC_HOST_PATH && scalar(@{get_fc_hosts()}) > 0;
}

# Get list of FC host adapters
# Returns: arrayref of host names (e.g., ['host0', 'host1'])
sub get_fc_hosts {
    my @hosts;

    return [] unless -d FC_HOST_PATH;

    opendir(my $dh, FC_HOST_PATH) or return [];
    for my $entry (readdir($dh)) {
        next if $entry =~ /^\./;
        next unless $entry =~ /^host\d+$/;

        # Verify it's a valid FC host by checking port_name exists
        my $port_name_file = FC_HOST_PATH . "/$entry/port_name";
        if (-r $port_name_file) {
            push @hosts, $entry;
        }
    }
    closedir($dh);

    # Sort by host number
    @hosts = sort {
        my ($a_num) = $a =~ /(\d+)/;
        my ($b_num) = $b =~ /(\d+)/;
        $a_num <=> $b_num;
    } @hosts;

    return \@hosts;
}

# Get FC HBA port WWPNs (World Wide Port Names)
# Returns: arrayref of WWPNs in colon-separated format
# Example: ['50:01:43:80:32:a5:b6:c7', '50:01:43:80:32:a5:b6:c8']
sub get_fc_wwpns {
    my (%opts) = @_;

    my @wwpns;
    my $hosts = get_fc_hosts();

    for my $host (@$hosts) {
        my $port_name_file = FC_HOST_PATH . "/$host/port_name";
        my $port_state_file = FC_HOST_PATH . "/$host/port_state";

        # Read port name (WWPN)
        my $wwpn_raw = _read_file($port_name_file);
        next unless $wwpn_raw;

        # Check port state if requested
        if ($opts{online_only}) {
            my $state = _read_file($port_state_file) // '';
            next unless $state =~ /online/i;
        }

        my $wwpn = format_wwn($wwpn_raw);
        push @wwpns, $wwpn if $wwpn;
    }

    return \@wwpns;
}

# Get FC HBA node WWNNs (World Wide Node Names)
# Returns: arrayref of WWNNs in colon-separated format
sub get_fc_wwnn {
    my (%opts) = @_;

    my @wwnns;
    my $hosts = get_fc_hosts();

    for my $host (@$hosts) {
        my $node_name_file = FC_HOST_PATH . "/$host/node_name";

        my $wwnn_raw = _read_file($node_name_file);
        next unless $wwnn_raw;

        my $wwnn = format_wwn($wwnn_raw);
        push @wwnns, $wwnn if $wwnn;
    }

    # Return unique WWNNs (multiple ports may share same node name)
    my %seen;
    @wwnns = grep { !$seen{$_}++ } @wwnns;

    return \@wwnns;
}

# Get detailed FC host information
# Returns: arrayref of hashrefs with host details
sub get_fc_host_info {
    my @info;
    my $hosts = get_fc_hosts();

    for my $host (@$hosts) {
        my $base = FC_HOST_PATH . "/$host";

        my $port_name = _read_file("$base/port_name");
        my $node_name = _read_file("$base/node_name");
        my $port_state = _read_file("$base/port_state") // 'unknown';
        my $port_type = _read_file("$base/port_type") // 'unknown';
        my $speed = _read_file("$base/speed") // 'unknown';
        my $fabric_name = _read_file("$base/fabric_name");

        push @info, {
            host        => $host,
            wwpn        => format_wwn($port_name),
            wwnn        => format_wwn($node_name),
            port_state  => $port_state,
            port_type   => $port_type,
            speed       => $speed,
            fabric_name => format_wwn($fabric_name),
        };
    }

    return \@info;
}

# Rescan FC hosts for new LUNs
# This triggers a LIP (Loop Initialization Primitive) or fabric rescan
# Rescan FC hosts for newly mapped LUNs.
#
# %opts:
#   lip    - issue a Loop Initialization Primitive first (default OFF, see below)
#   budget - wall-clock ceiling in seconds for the whole call (default 30)
#   delay  - settle time after scanning (default 2)
#
# LIP IS OFF BY DEFAULT, DELIBERATELY. issue_lip resets the FC port and forces a
# fabric re-login; it briefly disturbs every LUN behind that HBA, not just ours.
# activate_storage() runs on the pvestatd path roughly every 10 seconds on every
# node, and it used to call this unconditionally -- so an FC installation was
# issuing a LIP per HBA port every ~10s, forever. Discovering a newly mapped LUN
# on a port that is already logged in only needs the plain SCSI "- - -" scan
# below; LIP is for genuine topology changes and belongs on the "the device never
# appeared" fallback path, not on a poll.
#
# The wall-clock budget matters for the same reason it did for the iSCSI login
# loop in v0.2.20: the per-write timeouts (10s each) bound ONE write, not the
# loop. With four HBA ports the old code could spend 4 x (10 + 10) = 80s inside
# activate_storage -- a per-call timeout never bounds a loop's total time.
sub rescan_fc_hosts {
    my (%opts) = @_;

    my $hosts = get_fc_hosts();
    my $deadline = time() + ($opts{budget} // 30);
    my $scanned = 0;

    if ($opts{lip}) {
        for my $host (@$hosts) {
            if (time() >= $deadline) {
                warn "FC rescan: wall-clock budget spent before issuing LIP on all "
                   . "hosts; remaining hosts skipped this round\n";
                last;
            }
            my $issue_lip_file = FC_HOST_PATH . "/$host/issue_lip";
            next unless -w $issue_lip_file;
            sysfs_write_with_timeout($issue_lip_file, "1\n", 10)
                or warn "FC rescan failed for $host (issue_lip): timed out\n";
        }
    }

    # Trigger a SCSI host scan for new devices on the FC hosts ONLY.
    #
    # CRITICAL: do NOT iterate all of /sys/class/scsi_host/. Writing "- - -" to a
    # non-FC host's scan file (e.g. smartpqi RAID controllers, USB SD readers,
    # virtio-scsi, megaraid, mpt3sas) triggers driver-side full rescans that can
    # hang for hundreds of seconds in HBA/RAID drivers. Observed in production on
    # HPE ProLiant with smartpqi: 600+ seconds D-state blocking all subsequent
    # storage operations.
    #
    # Instead, only rescan the SCSI hosts corresponding to the FC hosts we
    # enumerated via /sys/class/fc_host/. Each FC host is also a SCSI host with the
    # same hostN name, so /sys/class/scsi_host/hostN maps to
    # /sys/class/fc_host/hostN for the same N.
    my $scsi_host_path = '/sys/class/scsi_host';
    for my $host (@$hosts) {
        if (time() >= $deadline) {
            warn "FC rescan: wall-clock budget spent; remaining hosts are scanned "
               . "on a later call\n";
            last;
        }
        # Untaint host name (comes from get_fc_hosts() which validates)
        my ($safe) = $host =~ /^(host\d+)$/;
        next unless $safe;

        my $scan_file = "$scsi_host_path/$safe/scan";
        next unless -w $scan_file;
        if (sysfs_write_with_timeout($scan_file, "- - -\n", 10)) {
            $scanned++;
        } else {
            warn "SCSI rescan failed for $safe: timed out\n";
        }
    }

    # Give the kernel time to discover devices
    sleep($opts{delay} // 2);

    return $scanned;
}

# Validate and untaint an fc_remote_ports entry name.
#
# The kernel names a remote port rport-<host>:<channel>-<remote>, with a
# COLON after the host number: 'rport-5:0-3'. This filter used to ask for
# three HYPHEN-separated numbers, which matches no entry the kernel has ever
# created -- so get_fc_targets() could only ever return an empty list, and any
# caller would conclude the fabric was unzoned however well it was zoned.
#
# Ported from the sibling jt-pve-storage-dellemc project, where exactly that
# was reported from a working PowerVault ME4024 over FC. This plugin never
# called get_fc_targets(), so it was latent rather than live -- but a wrong
# pattern in unused code is the next caller's bug.
#
# It doubles as the taint check: what comes back is what the pattern MATCHED,
# never the string read from the directory. Only a capture untaints.
sub rport_name {
    my ($entry) = @_;

    return undef unless defined $entry;
    my ($name) = $entry =~ /^(rport-\d+:\d+-\d+)\z/;

    return $name;
}

# Get FC remote port (target) information
# Returns: arrayref of hashrefs with target details
sub get_fc_targets {
    my @targets;

    return [] unless -d FC_REMOTE_PATH;

    opendir(my $dh, FC_REMOTE_PATH) or return [];
    for my $raw (readdir($dh)) {
        my $entry = rport_name($raw) // next;

        my $base = FC_REMOTE_PATH . "/$entry";

        my $port_name = _read_file("$base/port_name");
        my $node_name = _read_file("$base/node_name");
        my $port_state = _read_file("$base/port_state") // 'unknown';
        my $roles = _read_file("$base/roles") // '';

        push @targets, {
            rport       => $entry,
            wwpn        => format_wwn($port_name),
            wwnn        => format_wwn($node_name),
            port_state  => $port_state,
            roles       => $roles,
            is_target   => ($roles =~ /target/i) ? 1 : 0,
        };
    }
    closedir($dh);

    return \@targets;
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::NetAppONTAP::FC - Fibre Channel HBA management utilities

=head1 SYNOPSIS

    use PVE::Storage::Custom::NetAppONTAP::FC qw(
        get_fc_wwpns
        is_fc_available
        rescan_fc_hosts
    );

    # Check if FC is available
    if (is_fc_available()) {
        # Get local FC HBA WWPNs
        my $wwpns = get_fc_wwpns();
        # Returns: ['50:01:43:80:32:a5:b6:c7', ...]

        # Rescan for new LUNs
        rescan_fc_hosts();
    }

=head1 DESCRIPTION

This module provides Fibre Channel HBA management utilities for the NetApp
ONTAP storage plugin. It reads FC HBA information from /sys/class/fc_host
and provides functions for WWPN retrieval and LUN rescanning.

=head1 FUNCTIONS

=over 4

=item B<is_fc_available()>

Returns true if FC HBAs are available on the system.

=item B<get_fc_wwpns(%opts)>

Returns arrayref of WWPNs in colon-separated format.
Options: online_only => 1 to return only online ports.

=item B<get_fc_wwnn()>

Returns arrayref of WWNNs (node names) in colon-separated format.

=item B<get_fc_hosts()>

Returns arrayref of FC host names (e.g., ['host0', 'host1']).

=item B<rescan_fc_hosts(%opts)>

Triggers LIP and SCSI rescan for new LUNs.
Options: delay => seconds to wait after rescan.

=item B<format_wwn($wwn)>

Converts WWN to colon-separated format.

=back

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
