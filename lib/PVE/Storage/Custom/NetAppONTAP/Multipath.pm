package PVE::Storage::Custom::NetAppONTAP::Multipath;

use strict;
use warnings;

use Carp qw(croak);
use IPC::Open3;
use IO::Select;
use Symbol qw(gensym);
use File::Basename qw(basename);

use Exporter qw(import);

our @EXPORT_OK = qw(
    rescan_scsi_hosts
    multipath_reload
    multipath_flush
    multipath_add
    multipath_remove
    get_multipath_device
    get_multipath_wwid
    get_device_by_wwid
    wait_for_multipath_device
    get_scsi_devices_by_serial
    remove_scsi_device
    rescan_scsi_device
    get_multipath_slaves
    cleanup_lun_devices
    is_device_in_use
);

# Constants
use constant {
    MULTIPATHD         => '/sbin/multipathd',
    MULTIPATH          => '/sbin/multipath',
    SG_INQ             => '/usr/bin/sg_inq',
    SCSI_HOST_PATH     => '/sys/class/scsi_host',
    SCSI_DEVICE_PATH   => '/sys/class/scsi_device',
    BLOCK_DEVICE_PATH  => '/sys/class/block',
    DEVICE_WAIT_TIMEOUT   => 60,
    DEVICE_WAIT_INTERVAL  => 2,
};

# Untaint a device name (e.g., sda, dm-0)
sub _untaint_device_name {
    my ($name) = @_;
    return undef unless defined $name;
    # Allow device names like: sda, sda1, dm-0, nvme0n1, 3600a0980...
    if ($name =~ /^([a-zA-Z0-9_\-]+)$/) {
        return $1;
    }
    return undef;
}

# Untaint a device path (e.g., /dev/sda, /dev/mapper/mpath0)
# This is critical for taint mode compatibility with PVE
sub _untaint_device_path {
    my ($path) = @_;
    return undef unless defined $path;
    # Allow paths like: /dev/sda, /dev/mapper/3600a0980..., /dev/disk/by-id/...
    if ($path =~ m|^(/dev/[a-zA-Z0-9_\-/\.]+)$|) {
        return $1;
    }
    return undef;
}

# Untaint a path component
sub _untaint_path {
    my ($path) = @_;
    return undef unless defined $path;
    # Allow safe path characters
    if ($path =~ m|^([a-zA-Z0-9_\-/\.]+)$|) {
        return $1;
    }
    return undef;
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

# Rescan all SCSI hosts for new devices
sub rescan_scsi_hosts {
    my (%opts) = @_;

    opendir(my $dh, SCSI_HOST_PATH) or croak "Cannot open " . SCSI_HOST_PATH . ": $!";
    my @hosts = grep { /^host\d+$/ } readdir($dh);
    closedir($dh);

    for my $host (@hosts) {
        # Untaint host name (validated by grep above)
        ($host) = $host =~ /^(host\d+)$/;
        next unless $host;

        my $scan_file = SCSI_HOST_PATH . "/$host/scan";
        if (-w $scan_file) {
            open(my $fh, '>', $scan_file) or next;
            print $fh "- - -\n";
            close($fh);
        }
    }

    # Give the kernel time to discover devices
    sleep($opts{delay} // 2);

    return 1;
}

# Reload multipath configuration
sub multipath_reload {
    my (%opts) = @_;

    _run_cmd([MULTIPATHD, 'reconfigure'], allow_nonzero => 1, timeout => $opts{timeout} // 30);
    return 1;
}

# Flush unused multipath maps
sub multipath_flush {
    my ($device, %opts) = @_;

    if ($device) {
        _run_cmd([MULTIPATH, '-f', $device], allow_nonzero => 1);
    } else {
        _run_cmd([MULTIPATH, '-F'], allow_nonzero => 1);
    }

    return 1;
}

# Add a device to multipath
sub multipath_add {
    my ($device, %opts) = @_;

    croak "device is required" unless $device;

    _run_cmd([MULTIPATHD, 'add', 'path', $device], allow_nonzero => 1);
    _run_cmd([MULTIPATHD, 'add', 'map', $device], allow_nonzero => 1);

    return 1;
}

# Remove a device from multipath
sub multipath_remove {
    my ($device, %opts) = @_;

    croak "device is required" unless $device;

    # Flush the multipath device first
    if ($device =~ m|^/dev/mapper/|) {
        _run_cmd([MULTIPATH, '-f', $device], allow_nonzero => 1);
    } else {
        # It's a path, remove just the path
        _run_cmd([MULTIPATHD, 'remove', 'path', $device], allow_nonzero => 1);
    }

    return 1;
}

# Get multipath device name by WWID
sub get_multipath_device {
    my ($wwid, %opts) = @_;

    croak "wwid is required" unless $wwid;

    my ($stdout) = _run_cmd(
        [MULTIPATHD, 'show', 'maps', 'raw', 'format', '%n %w'],
        allow_nonzero => 1,
        ignore_errors => 1,
    );

    return undef unless defined $stdout;

    for my $line (split /\n/, $stdout) {
        $line =~ s/^\s+|\s+$//g;
        my ($name, $map_wwid) = split /\s+/, $line, 2;
        next unless $name && $map_wwid;

        if (lc($map_wwid) eq lc($wwid)) {
            # Untaint the device path for taint mode compatibility
            my $safe_name = _untaint_device_name($name);
            return undef unless $safe_name;
            return _untaint_device_path("/dev/mapper/$safe_name");
        }
    }

    return undef;
}

# Get WWID for a device
sub get_multipath_wwid {
    my ($device, %opts) = @_;

    croak "device is required" unless $device;

    # Try using multipathd
    my ($stdout) = _run_cmd(
        [MULTIPATHD, 'show', 'paths', 'raw', 'format', '%d %w'],
        allow_nonzero => 1,
        ignore_errors => 1,
    );

    if (defined $stdout) {
        my $dev_name = basename($device);
        for my $line (split /\n/, $stdout) {
            my ($path_dev, $wwid) = split /\s+/, $line, 2;
            if ($path_dev && $path_dev eq $dev_name) {
                return $wwid;
            }
        }
    }

    # Fall back to sg_inq
    if (-x SG_INQ) {
        my ($inq_out) = _run_cmd([SG_INQ, '-p', '0x83', $device], allow_nonzero => 1, ignore_errors => 1);
        if ($inq_out && $inq_out =~ /\[0x(\w+)\]/) {
            return $1;
        }
    }

    # Try /sys/block/*/device/wwid
    my $dev_name = _untaint_device_name(basename($device));
    return undef unless $dev_name;
    my $wwid_file = BLOCK_DEVICE_PATH . "/$dev_name/device/wwid";
    if (-r $wwid_file) {
        open(my $fh, '<', $wwid_file) or return undef;
        my $wwid = <$fh>;
        close($fh);
        chomp($wwid) if $wwid;
        return $wwid;
    }

    return undef;
}

# Get device path by WWID
sub get_device_by_wwid {
    my ($wwid, %opts) = @_;

    croak "wwid is required" unless $wwid;

    # First check multipath
    my $mpath = get_multipath_device($wwid);
    return $mpath if $mpath && -b $mpath;

    # Check /dev/disk/by-id
    (my $safe_wwid = $wwid) =~ s/([\[\]{}*?\\])/\\$1/g;
    my @devices = glob("/dev/disk/by-id/wwn-*$safe_wwid*");
    push @devices, glob("/dev/disk/by-id/scsi-*$safe_wwid*");

    if (@devices && -b $devices[0]) {
        # Untaint the device path for taint mode compatibility
        return _untaint_device_path($devices[0]);
    }

    return undef;
}

# Wait for a multipath device to appear
sub wait_for_multipath_device {
    my ($wwid, %opts) = @_;

    croak "wwid is required" unless $wwid;

    my $timeout = $opts{timeout} // DEVICE_WAIT_TIMEOUT;
    my $interval = $opts{interval} // DEVICE_WAIT_INTERVAL;
    my $start_time = time();

    while ((time() - $start_time) < $timeout) {
        # Trigger rescan
        rescan_scsi_hosts(delay => 1);
        multipath_reload();

        # Check for device
        my $device = get_device_by_wwid($wwid);
        if ($device && -b $device) {
            return $device;
        }

        sleep($interval);
    }

    return undef;
}

# Get SCSI devices by LUN serial number
sub get_scsi_devices_by_serial {
    my ($serial, %opts) = @_;

    croak "serial is required" unless $serial;

    my @devices;

    # Search in /dev/disk/by-id
    my @by_id = glob("/dev/disk/by-id/scsi-*");

    for my $link (@by_id) {
        # Check if the symlink name contains the serial
        my $name = basename($link);
        if ($name =~ /\Q$serial\E/i) {
            my $target = readlink($link);
            if ($target) {
                $target =~ s|^\.\./\.\./||;
                push @devices, "/dev/$target";
            }
        }
    }

    # Also scan /sys/block for matching serials
    opendir(my $dh, '/sys/block') or return \@devices;
    my @blocks = grep { /^sd[a-z]+$/ } readdir($dh);
    closedir($dh);

    for my $block (@blocks) {
        # Untaint block device name
        ($block) = $block =~ /^(sd[a-z]+)$/;
        next unless $block;

        my $vpd_file = "/sys/block/$block/device/vpd_pg80";
        if (-r $vpd_file) {
            open(my $fh, '<', $vpd_file) or next;
            local $/;
            my $vpd_data = <$fh>;
            close($fh);

            if ($vpd_data && $vpd_data =~ /\Q$serial\E/i) {
                push @devices, "/dev/$block" unless grep { $_ eq "/dev/$block" } @devices;
            }
        }
    }

    return \@devices;
}

# Remove a SCSI device from the system
sub remove_scsi_device {
    my ($device, %opts) = @_;

    croak "device is required" unless $device;

    my $dev_name = _untaint_device_name(basename($device));
    croak "Invalid device name" unless $dev_name;

    # Untaint device path for system calls
    my $safe_device = _untaint_path($device);

    # Find the SCSI device path
    my $delete_file = BLOCK_DEVICE_PATH . "/$dev_name/device/delete";

    if (-w $delete_file) {
        # Sync and flush first
        system('sync');
        system('blockdev', '--flushbufs', $safe_device) if $safe_device && -b $safe_device;

        open(my $fh, '>', $delete_file) or croak "Cannot write to $delete_file: $!";
        print $fh "1\n";
        close($fh);

        return 1;
    }

    croak "Cannot find delete file for device $device";
}

# Rescan a specific SCSI device
sub rescan_scsi_device {
    my ($device, %opts) = @_;

    croak "device is required" unless $device;

    my $dev_name = _untaint_device_name(basename($device));
    croak "Invalid device name" unless $dev_name;

    my $rescan_file = BLOCK_DEVICE_PATH . "/$dev_name/device/rescan";

    if (-w $rescan_file) {
        open(my $fh, '>', $rescan_file) or croak "Cannot write to $rescan_file: $!";
        print $fh "1\n";
        close($fh);
        return 1;
    }

    croak "Cannot find rescan file for device $device";
}

# Get all slave devices for a multipath device
sub get_multipath_slaves {
    my ($mpath_device, %opts) = @_;

    croak "mpath_device is required" unless $mpath_device;

    my $dev_name = _untaint_device_name(basename($mpath_device));
    return [] unless $dev_name;

    my $slaves_dir = BLOCK_DEVICE_PATH . "/$dev_name/slaves";

    return [] unless -d $slaves_dir;

    opendir(my $dh, $slaves_dir) or return [];
    my @slaves;
    for my $slave (readdir($dh)) {
        next if $slave =~ /^\./;
        my $safe_slave = _untaint_device_name($slave);
        push @slaves, "/dev/$safe_slave" if $safe_slave;
    }
    closedir($dh);

    return \@slaves;
}

# Clean up multipath and SCSI devices for a LUN
# IMPORTANT: This must be called BEFORE deleting the LUN on the storage system
# to prevent stuck I/O and D-state processes
sub cleanup_lun_devices {
    my ($wwid, %opts) = @_;

    croak "wwid is required" unless $wwid;

    # Get multipath device
    my $mpath = get_multipath_device($wwid);

    if ($mpath && -b $mpath) {
        # Get slave devices first (before we remove the multipath)
        my $slaves = get_multipath_slaves($mpath);

        # Step 1: Sync all pending writes to this device
        system('sync');

        # Step 2: Flush device buffers
        my $safe_mpath = _untaint_device_path($mpath);
        if ($safe_mpath) {
            system('blockdev', '--flushbufs', $safe_mpath);
        }

        # Step 3: Remove the multipath device using multipathd
        # Use multipathd's remove map command for cleaner removal
        my $mpath_name = basename($mpath);
        my $safe_name = _untaint_device_name($mpath_name);
        if ($safe_name) {
            _run_cmd([MULTIPATHD, 'remove', 'map', $safe_name], allow_nonzero => 1, ignore_errors => 1);
        }

        # Step 4: Also try multipath -f as fallback
        multipath_flush($mpath);

        # Step 5: Brief pause to let device-mapper settle
        sleep(1);

        # Step 6: Remove the underlying SCSI devices
        for my $slave (@$slaves) {
            eval { remove_scsi_device($slave); };
        }

        # Step 7: Brief pause for cleanup to complete
        sleep(1);
    }

    return 1;
}

# Check if a device is currently in use (mounted, open by process, or has holders)
sub is_device_in_use {
    my ($device, %opts) = @_;

    return 0 unless $device && -b $device;

    my $dev_name = _untaint_device_name(basename($device));
    return 0 unless $dev_name;

    # Check 1: Is device mounted?
    if (open(my $fh, '<', '/proc/mounts')) {
        while (<$fh>) {
            if (/^\Q$device\E\s/ || /^\/dev\/\Q$dev_name\E\s/) {
                close($fh);
                return 1;  # Device is mounted
            }
        }
        close($fh);
    }

    # Check 2: Does device have holders (e.g., LVM, dm-crypt)?
    my $holders_dir = "/sys/block/$dev_name/holders";
    if (-d $holders_dir) {
        opendir(my $dh, $holders_dir);
        my @holders = grep { !/^\./ } readdir($dh);
        closedir($dh);
        if (@holders) {
            return 1;  # Device has holders
        }
    }

    # Check 3: Is device open by any process? (using fuser)
    my $safe_device = _untaint_device_path($device);
    return 0 unless $safe_device;
    my $fuser_check = system('fuser', '-s', $safe_device);
    if ($fuser_check == 0) {
        return 1;  # Device is open by a process
    }

    return 0;  # Device is not in use
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::NetAppONTAP::Multipath - Multipath and SCSI management utilities

=head1 SYNOPSIS

    use PVE::Storage::Custom::NetAppONTAP::Multipath qw(
        rescan_scsi_hosts
        get_multipath_device
        wait_for_multipath_device
    );

    # Rescan for new devices
    rescan_scsi_hosts();

    # Get multipath device by WWID
    my $device = get_multipath_device('3600508b1001c7fcf0d4f0b28a6f8e9c0');

    # Wait for device to appear
    my $device = wait_for_multipath_device($wwid, timeout => 60);

=head1 DESCRIPTION

This module provides multipath and SCSI device management utilities for
the NetApp ONTAP storage plugin.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut
