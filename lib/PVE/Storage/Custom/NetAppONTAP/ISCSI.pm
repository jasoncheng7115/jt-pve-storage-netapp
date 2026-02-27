package PVE::Storage::Custom::NetAppONTAP::ISCSI;

use strict;
use warnings;

use Carp qw(croak);
use IPC::Open3;
use IO::Select;
use Symbol qw(gensym);

use Exporter qw(import);

our @EXPORT_OK = qw(
    get_initiator_name
    set_initiator_name
    discover_targets
    login_target
    logout_target
    get_sessions
    rescan_sessions
    is_target_logged_in
    wait_for_device
);

# Constants
use constant {
    INITIATOR_NAME_FILE => '/etc/iscsi/initiatorname.iscsi',
    ISCSIADM            => '/usr/bin/iscsiadm',
    DISCOVERY_TIMEOUT   => 30,
    LOGIN_TIMEOUT       => 60,
    DEVICE_WAIT_TIMEOUT => 30,
    DEVICE_WAIT_INTERVAL => 1,
};

# Read file content
sub _read_file {
    my ($path) = @_;
    open(my $fh, '<', $path) or croak "Cannot open $path: $!";
    local $/;
    my $content = <$fh>;
    close($fh);
    return $content;
}

# Write file content
sub _write_file {
    my ($path, $content) = @_;
    open(my $fh, '>', $path) or croak "Cannot open $path for writing: $!";
    print $fh $content;
    close($fh);
    return 1;
}

# Run a command and return output
sub _run_cmd {
    my ($cmd, %opts) = @_;

    my $timeout = $opts{timeout} // 30;

    my ($stdout, $stderr) = ('', '');
    my $err = gensym;

    my $child_pid;

    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm($timeout);

        $child_pid = open3(my $in, my $out, $err, @$cmd);
        close($in);

        my $sel = IO::Select->new($out, $err);
        while (my @ready = $sel->can_read()) {
            for my $fh (@ready) {
                my $buf;
                my $bytes = sysread($fh, $buf, 4096);
                if (!$bytes) {
                    $sel->remove($fh);
                    next;
                }
                if ($fh == $out) {
                    $stdout .= $buf;
                } else {
                    $stderr .= $buf;
                }
            }
        }

        waitpid($child_pid, 0);
        alarm(0);
    };

    if ($@) {
        alarm(0);
        if ($child_pid) {
            kill('TERM', $child_pid);
            waitpid($child_pid, 0);
        }
        if ($@ eq "timeout\n") {
            croak "Command timed out after ${timeout}s: @$cmd";
        }
        croak "Command failed: $@";
    }

    my $exit_code = $? >> 8;

    if ($exit_code != 0 && !$opts{ignore_errors}) {
        unless ($opts{allow_nonzero}) {
            croak "Command failed (exit $exit_code): @$cmd\nstderr: $stderr";
        }
    }

    return wantarray ? ($stdout, $stderr, $exit_code) : $stdout;
}

# Get the local initiator name (IQN)
sub get_initiator_name {
    my $content = _read_file(INITIATOR_NAME_FILE);

    if ($content =~ /InitiatorName\s*=\s*(\S+)/) {
        return $1;
    }

    croak "Failed to parse initiator name from " . INITIATOR_NAME_FILE;
}

# Set the local initiator name (IQN)
sub set_initiator_name {
    my ($iqn) = @_;

    croak "Invalid IQN format" unless $iqn =~ /^iqn\.\d{4}-\d{2}\.[^:]+:/;

    _write_file(INITIATOR_NAME_FILE, "InitiatorName=$iqn\n");

    # Restart iscsid to pick up new name
    system('systemctl', 'restart', 'iscsid');

    return 1;
}

# Discover iSCSI targets on a portal
sub discover_targets {
    my ($portal, %opts) = @_;

    croak "portal is required" unless $portal;

    my $port = $opts{port} // 3260;
    my $portal_addr = "$portal:$port";

    my ($stdout) = _run_cmd(
        [ISCSIADM, '-m', 'discovery', '-t', 'sendtargets', '-p', $portal_addr],
        timeout => $opts{timeout} // DISCOVERY_TIMEOUT,
        allow_nonzero => 1,  # May return non-zero if already discovered
    );

    my @targets;
    for my $line (split /\n/, $stdout) {
        # Format: portal,portal_group target_name
        if ($line =~ /^(\S+),\d+\s+(\S+)/) {
            push @targets, {
                portal => $1,
                target => $2,
            };
        }
    }

    return \@targets;
}

# Login to an iSCSI target
sub login_target {
    my ($portal, $target, %opts) = @_;

    croak "portal is required" unless $portal;
    croak "target is required" unless $target;

    my $port = $opts{port} // 3260;
    my $portal_addr = "$portal:$port";

    # Check if already logged in
    if (is_target_logged_in($target)) {
        return 1;
    }

    # Set login parameters if CHAP is configured
    if ($opts{chap_username}) {
        _run_cmd([ISCSIADM, '-m', 'node', '-T', $target, '-p', $portal_addr,
                  '-o', 'update', '-n', 'node.session.auth.authmethod', '-v', 'CHAP']);
        _run_cmd([ISCSIADM, '-m', 'node', '-T', $target, '-p', $portal_addr,
                  '-o', 'update', '-n', 'node.session.auth.username', '-v', $opts{chap_username}]);
        _run_cmd([ISCSIADM, '-m', 'node', '-T', $target, '-p', $portal_addr,
                  '-o', 'update', '-n', 'node.session.auth.password', '-v', $opts{chap_password}]);
    }

    # Enable automatic login on boot
    _run_cmd([ISCSIADM, '-m', 'node', '-T', $target, '-p', $portal_addr,
              '-o', 'update', '-n', 'node.startup', '-v', 'automatic'],
             allow_nonzero => 1);

    # Login
    my ($stdout, $stderr, $exit) = _run_cmd(
        [ISCSIADM, '-m', 'node', '-T', $target, '-p', $portal_addr, '-l'],
        timeout => $opts{timeout} // LOGIN_TIMEOUT,
        allow_nonzero => 1,
    );

    # Exit code 15 means already logged in
    if ($exit != 0 && $exit != 15) {
        croak "Failed to login to target $target: $stderr";
    }

    return 1;
}

# Logout from an iSCSI target
sub logout_target {
    my ($portal, $target, %opts) = @_;

    croak "portal is required" unless $portal;
    croak "target is required" unless $target;

    my $port = $opts{port} // 3260;
    my $portal_addr = "$portal:$port";

    my ($stdout, $stderr, $exit) = _run_cmd(
        [ISCSIADM, '-m', 'node', '-T', $target, '-p', $portal_addr, '-u'],
        allow_nonzero => 1,
    );

    # Exit code 21 means not logged in
    if ($exit != 0 && $exit != 21) {
        croak "Failed to logout from target $target: $stderr";
    }

    return 1;
}

# Get all active iSCSI sessions
sub get_sessions {
    my (%opts) = @_;

    my ($stdout, $stderr, $exit) = _run_cmd(
        [ISCSIADM, '-m', 'session'],
        allow_nonzero => 1,
    );

    # Exit code 21 means no active sessions
    return [] if $exit == 21;

    my @sessions;
    for my $line (split /\n/, $stdout) {
        # Format: protocol: [session_id] portal target
        if ($line =~ /^(\w+):\s+\[(\d+)\]\s+(\S+)\s+(\S+)/) {
            push @sessions, {
                protocol   => $1,
                session_id => $2,
                portal     => $3,
                target     => $4,
            };
        }
    }

    return \@sessions;
}

# Check if a target is logged in
sub is_target_logged_in {
    my ($target) = @_;

    my $sessions = get_sessions();
    for my $session (@$sessions) {
        return 1 if $session->{target} eq $target;
    }

    return 0;
}

# Rescan all iSCSI sessions for new LUNs
sub rescan_sessions {
    my (%opts) = @_;

    my ($stdout, $stderr, $exit) = _run_cmd(
        [ISCSIADM, '-m', 'session', '--rescan'],
        allow_nonzero => 1,
        timeout => $opts{timeout} // 60,
    );

    # Exit code 21 means no active sessions
    return 1 if $exit == 0 || $exit == 21;

    croak "Failed to rescan iSCSI sessions: $stderr";
}

# Rescan a specific target
sub rescan_target {
    my ($target, %opts) = @_;

    croak "target is required" unless $target;

    my ($stdout, $stderr, $exit) = _run_cmd(
        [ISCSIADM, '-m', 'node', '-T', $target, '--rescan'],
        allow_nonzero => 1,
        timeout => $opts{timeout} // 60,
    );

    return 1 if $exit == 0;
    croak "Failed to rescan target $target: $stderr";
}

# Untaint a device path for taint mode compatibility
sub _untaint_device_path {
    my ($path) = @_;
    return undef unless defined $path;
    # Allow paths like: /dev/sda, /dev/mapper/3600a0980..., /dev/disk/by-id/...
    if ($path =~ m|^(/dev/[a-zA-Z0-9_\-/\.]+)$|) {
        return $1;
    }
    return undef;
}

# Wait for a SCSI device to appear
sub wait_for_device {
    my ($serial, %opts) = @_;

    croak "serial is required" unless $serial;

    my $timeout = $opts{timeout} // DEVICE_WAIT_TIMEOUT;
    my $interval = $opts{interval} // DEVICE_WAIT_INTERVAL;
    my $start_time = time();

    while ((time() - $start_time) < $timeout) {
        # Check /dev/disk/by-id for the device
        (my $safe_serial = $serial) =~ s/([\[\]{}*?\\])/\\$1/g;
        my @devices = glob("/dev/disk/by-id/scsi-*$safe_serial*");

        if (@devices) {
            # Return the first matching device (untainted for taint mode)
            return _untaint_device_path($devices[0]);
        }

        # Also check multipath
        my $mpath_device = _find_multipath_device($serial);
        if ($mpath_device) {
            return $mpath_device;  # Already untainted by _find_multipath_device
        }

        sleep($interval);
    }

    return undef;  # Device not found within timeout
}

# Find multipath device by LUN serial
sub _find_multipath_device {
    my ($serial) = @_;

    # Use multipathd to query devices
    my ($stdout, $stderr, $exit) = _run_cmd(
        ['multipathd', 'show', 'maps', 'raw', 'format', '%n %w'],
        allow_nonzero => 1,
        ignore_errors => 1,
    );

    return undef unless defined $stdout;

    for my $line (split /\n/, $stdout) {
        my ($name, $wwid) = split /\s+/, $line, 2;
        next unless $name && $wwid;

        # WWID may contain the serial
        if ($wwid =~ /\Q$serial\E/i) {
            # Untaint the device path for taint mode compatibility
            return _untaint_device_path("/dev/mapper/$name");
        }
    }

    return undef;
}

# Get device path by serial number
sub get_device_by_serial {
    my ($serial, %opts) = @_;

    croak "serial is required" unless $serial;

    # First try multipath
    my $mpath = _find_multipath_device($serial);
    return $mpath if $mpath;  # Already untainted

    # Fall back to /dev/disk/by-id
    (my $safe_serial = $serial) =~ s/([\[\]{}*?\\])/\\$1/g;
    my @devices = glob("/dev/disk/by-id/scsi-*$safe_serial*");
    if (@devices) {
        return _untaint_device_path($devices[0]);
    }

    return undef;
}

# Remove iSCSI node configuration
sub delete_node {
    my ($portal, $target, %opts) = @_;

    croak "portal is required" unless $portal;
    croak "target is required" unless $target;

    my $port = $opts{port} // 3260;
    my $portal_addr = "$portal:$port";

    my ($stdout, $stderr, $exit) = _run_cmd(
        [ISCSIADM, '-m', 'node', '-T', $target, '-p', $portal_addr, '-o', 'delete'],
        allow_nonzero => 1,
    );

    return 1;
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::NetAppONTAP::ISCSI - iSCSI management utilities

=head1 SYNOPSIS

    use PVE::Storage::Custom::NetAppONTAP::ISCSI qw(
        get_initiator_name
        discover_targets
        login_target
    );

    # Get local initiator IQN
    my $iqn = get_initiator_name();

    # Discover targets
    my $targets = discover_targets('192.168.1.100');

    # Login to target
    login_target('192.168.1.100', $targets->[0]{target});

=head1 DESCRIPTION

This module provides iSCSI management utilities for the NetApp ONTAP
storage plugin. It wraps the iscsiadm command-line tool.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
