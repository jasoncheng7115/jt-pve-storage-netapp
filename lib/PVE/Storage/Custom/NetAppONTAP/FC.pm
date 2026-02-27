package PVE::Storage::Custom::NetAppONTAP::FC;

use strict;
use warnings;

use Carp qw(croak);
use File::Basename qw(basename);

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

# Read file content
sub _read_file {
    my ($path) = @_;
    return undef unless -r $path;
    open(my $fh, '<', $path) or return undef;
    my $content = <$fh>;
    close($fh);
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
sub rescan_fc_hosts {
    my (%opts) = @_;

    my $hosts = get_fc_hosts();
    my $rescanned = 0;

    for my $host (@$hosts) {
        # Method 1: Issue LIP (Loop Initialization Primitive)
        my $issue_lip_file = FC_HOST_PATH . "/$host/issue_lip";
        if (-w $issue_lip_file) {
            eval {
                open(my $fh, '>', $issue_lip_file) or die "Cannot open $issue_lip_file: $!";
                print $fh "1\n";
                close($fh);
                $rescanned++;
            };
            warn "FC rescan failed for $host (issue_lip): $@" if $@;
        }
    }

    # Also trigger SCSI host scan for new devices
    my $scsi_host_path = '/sys/class/scsi_host';
    if (-d $scsi_host_path) {
        opendir(my $dh, $scsi_host_path) or do {
            warn "Cannot open $scsi_host_path: $!\n";
            sleep($opts{delay} // 2);
            return $rescanned;
        };
        for my $host (grep { /^host\d+$/ } readdir($dh)) {
            # Untaint host name
            ($host) = $host =~ /^(host\d+)$/;
            next unless $host;

            my $scan_file = "$scsi_host_path/$host/scan";
            if (-w $scan_file) {
                eval {
                    open(my $fh, '>', $scan_file) or die "Cannot open $scan_file: $!";
                    print $fh "- - -\n";
                    close($fh);
                };
                warn "SCSI rescan failed for $host: $@" if $@;
            }
        }
        closedir($dh);
    }

    # Give the kernel time to discover devices
    sleep($opts{delay} // 2);

    return $rescanned;
}

# Get FC remote port (target) information
# Returns: arrayref of hashrefs with target details
sub get_fc_targets {
    my @targets;

    return [] unless -d FC_REMOTE_PATH;

    opendir(my $dh, FC_REMOTE_PATH) or return [];
    for my $entry (readdir($dh)) {
        next if $entry =~ /^\./;
        next unless $entry =~ /^rport-\d+-\d+-\d+$/;

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
