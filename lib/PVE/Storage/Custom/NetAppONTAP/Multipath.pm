package PVE::Storage::Custom::NetAppONTAP::Multipath;

use strict;
use warnings;

use Carp qw(croak);
use IPC::Open3;
use IO::Select;
use Symbol qw(gensym);
use File::Basename qw(basename dirname);
use POSIX qw(_exit);

use Exporter qw(import);

our @EXPORT_OK = qw(
    rescan_scsi_hosts
    multipath_reload
    multipath_flush
    multipath_add
    multipath_remove
    get_multipath_device
    get_device_by_wwid
    wait_for_multipath_device
    get_scsi_devices_by_serial
    remove_scsi_device
    rescan_scsi_device
    get_multipath_slaves
    cleanup_lun_devices
    is_device_in_use
    get_device_usage_details
    sysfs_write_with_timeout
    sysfs_read_with_timeout
    list_netapp_multipath_devices
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

# Resolve a device path to the kernel name used in /sys/block/.
# Handles all three forms:
#   /dev/sdX                 → sdX (no change)
#   /dev/dm-N                → dm-N (no change)
#   /dev/mapper/<name>       → dm-N (resolves symlink)
# Returns the kernel name, or undef if it can't be resolved.
sub _resolve_block_device_name {
    my ($device) = @_;
    return undef unless defined $device;

    # If it's a symlink (typical for /dev/mapper/*), resolve to target
    if (-l $device) {
        my $target = readlink($device);
        if (defined $target) {
            # readlink may return relative path like "../dm-9"
            if ($target !~ m|^/|) {
                my $dir = dirname($device);
                $target = "$dir/$target";
            }
            # Normalize: remove "/foo/../" sequences
            while ($target =~ s|/[^/]+/\.\./|/|g) {}
            $device = $target;
        }
    }

    return _untaint_device_name(basename($device));
}

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

# Write to a sysfs file in a forked child process with timeout.
# Prevents the parent from entering uninterruptible sleep (D state)
# if the kernel operation blocks due to unresponsive storage.
# Returns: 1 on success, 0 on timeout/failure (with warning)
sub sysfs_write_with_timeout {
    my ($path, $data, $timeout) = @_;
    $timeout //= 10;

    my $pid = fork();
    if (!defined $pid) {
        warn "fork failed for sysfs write to $path: $!\n";
        return 0;
    }

    if ($pid == 0) {
        # Child: do the sysfs write, then exit immediately
        eval {
            open(my $fh, '>', $path) or die "open: $!";
            print $fh $data;
            close($fh);
        };
        POSIX::_exit($@ ? 1 : 0);
    }

    # Parent: wait for child with timeout
    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        my $res = waitpid($pid, POSIX::WNOHANG());
        if ($res > 0) {
            return ($? >> 8) == 0 ? 1 : 0;
        }
        return 1 if $res < 0;
        select(undef, undef, undef, 0.1);
    }

    # Timeout: kill the child
    warn "sysfs write to $path timed out after ${timeout}s, killing child pid $pid\n";
    kill('KILL', $pid);
    my $reaped = waitpid($pid, POSIX::WNOHANG());
    if ($reaped == 0) {
        warn "child pid $pid in uninterruptible sleep, cannot reap\n";
    }
    return 0;
}

# Read from a sysfs/proc file in a forked child process with timeout.
# Prevents the parent from entering uninterruptible sleep (D state)
# when reading device attributes from unresponsive storage.
# Returns: file content on success, undef on timeout/failure
sub sysfs_read_with_timeout {
    my ($path, $timeout) = @_;
    $timeout //= 5;

    pipe(my $read_fh, my $write_fh) or do {
        warn "pipe failed for sysfs read of $path: $!\n";
        return undef;
    };

    my $pid = fork();
    if (!defined $pid) {
        warn "fork failed for sysfs read of $path: $!\n";
        close($read_fh);
        close($write_fh);
        return undef;
    }

    if ($pid == 0) {
        # Child: read the file, send content through pipe
        close($read_fh);
        eval {
            open(my $fh, '<', $path) or die "open: $!";
            local $/;
            my $data = <$fh>;
            close($fh);
            print $write_fh ($data // '');
        };
        close($write_fh);
        POSIX::_exit($@ ? 1 : 0);
    }

    # Parent: read from pipe with alarm-based timeout
    close($write_fh);
    my $content = '';

    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm($timeout);

        # Read all data from pipe until EOF
        while (1) {
            my $buf;
            my $bytes = sysread($read_fh, $buf, 65536);
            last if !defined($bytes) || $bytes == 0;
            $content .= $buf;
        }

        alarm(0);
    };
    my $timed_out = $@;
    alarm(0);
    close($read_fh);

    if ($timed_out) {
        warn "sysfs read of $path timed out after ${timeout}s, killing child pid $pid\n";
        kill('KILL', $pid);
        waitpid($pid, POSIX::WNOHANG());
        return undef;
    }

    # Reap child
    waitpid($pid, 0);
    return length($content) ? $content : undef;
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

    # Only rescan iSCSI hosts. Writing "- - -" to a non-iSCSI host's
    # /sys/class/scsi_host/hostN/scan file triggers a driver-side full
    # target rescan, which can hang for hundreds of seconds inside HBA
    # drivers. Observed in production on HPE ProLiant servers with the
    # smartpqi driver (P408i-a controller): writes to the scan file
    # enter D-state for 600+ seconds in sas_user_scan, and every
    # subsequent process that touches /sys/class/scsi_host/hostN
    # serializes behind the first D-state child. This cascades into:
    #   - pvedaemon worker cannot release VM config lock
    #   - pvestatd cannot complete status() poll
    #   - VM operations hit lock timeouts
    #   - pvedaemon restart also hangs on storage scan
    # Fix: source the host list from /sys/class/iscsi_host/ instead of
    # /sys/class/scsi_host/. The scsi_transport_iscsi layer registers
    # every iSCSI host (regardless of underlying driver: iscsi_tcp,
    # iser, bnx2i, qla4xxx, qedi, be2iscsi, cxgb3i, cxgb4i, and any
    # future iSCSI driver that uses iscsi_host_alloc()) into
    # /sys/class/iscsi_host/. Non-iSCSI hosts (SAS HBAs, RAID
    # controllers, USB, NVMe, virtio-scsi, etc.) are categorically
    # absent from that class, so iterating it is both exhaustive and
    # safe.
    #
    # For FC, see rescan_fc_hosts() in FC.pm which uses /sys/class/fc_host/
    # with the same architectural principle.

    my $iscsi_class = '/sys/class/iscsi_host';
    if (! -d $iscsi_class) {
        # iSCSI transport subsystem not loaded at all -- nothing to do.
        # This can happen on FC-only setups; the FC code path uses
        # rescan_fc_hosts() instead and never calls this function.
        return 1;
    }

    opendir(my $dh, $iscsi_class) or return 1;
    my @hosts = grep { /^host\d+$/ } readdir($dh);
    closedir($dh);

    # No iSCSI hosts registered yet (e.g. storage not activated,
    # or all iSCSI sessions disconnected). Nothing for us to rescan.
    return 1 unless @hosts;

    for my $host (@hosts) {
        # Untaint host name (validated by grep above)
        ($host) = $host =~ /^(host\d+)$/;
        next unless $host;

        my $scan_file = SCSI_HOST_PATH . "/$host/scan";
        if (-w $scan_file) {
            sysfs_write_with_timeout($scan_file, "- - -\n", 10);
        }
    }

    # Give the kernel time to discover devices
    sleep($opts{delay} // 2);

    return 1;
}

# Reload multipath configuration
sub multipath_reload {
    my (%opts) = @_;

    _run_cmd([MULTIPATHD, 'reconfigure'],
        allow_nonzero => 1,
        ignore_errors => 1,
        timeout => $opts{timeout} // 15);
    return 1;
}

# Flush a specific multipath map (or all unused if no device given).
# CRITICAL: multipath -f can hang indefinitely on a device with queue_if_no_path
# if all paths are failed and there's pending queued I/O. We use a tight timeout
# and fall back to dmsetup remove --force which bypasses the multipath flush logic.
sub multipath_flush {
    my ($device, %opts) = @_;
    my $timeout = $opts{timeout} // 10;

    if ($device) {
        # Try multipath -f with timeout
        my (undef, undef, $exit) = eval {
            _run_cmd([MULTIPATH, '-f', $device],
                allow_nonzero => 1, ignore_errors => 1, timeout => $timeout);
        };
        my $err = $@;

        # If multipath -f hung or failed, fall back to dmsetup remove --force
        # which doesn't wait for queued I/O.
        if ($err || (defined $exit && $exit != 0)) {
            warn "multipath -f $device failed/timed out, trying dmsetup remove --force\n";
            my $name = basename($device);
            my $safe_name = _untaint_device_name($name);
            if ($safe_name) {
                eval {
                    _run_cmd(['/sbin/dmsetup', 'remove', '--force', '--retry', $safe_name],
                        allow_nonzero => 1, ignore_errors => 1, timeout => 10);
                };
                warn "dmsetup remove also failed for $safe_name: $@" if $@;
            }
        }
    } else {
        # WARNING: multipath -F (capital) flushes ALL unused maps system-wide.
        # This can affect other storage. Use with extreme caution.
        # We DO NOT recommend calling this without a device argument.
        _run_cmd([MULTIPATH, '-F'],
            allow_nonzero => 1, ignore_errors => 1, timeout => $timeout);
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

# List all NETAPP-vendor multipath devices on this host.
# Returns arrayref of { name, wwid, vps } hashrefs.
# Used for orphan detection: caller compares against ONTAP LUN list.
sub list_netapp_multipath_devices {
    my ($stdout) = _run_cmd(
        [MULTIPATHD, 'show', 'maps', 'raw', 'format', '%n %w %s'],
        allow_nonzero => 1,
        ignore_errors => 1,
        timeout => 10,
    );
    return [] unless defined $stdout;

    my @devices;
    for my $line (split /\n/, $stdout) {
        $line =~ s/^\s+|\s+$//g;
        next unless $line;
        my ($name, $wwid, $vps) = split /\s+/, $line, 3;
        next unless $name && $wwid && $vps;
        next unless $vps =~ /NETAPP/i;
        push @devices, { name => $name, wwid => $wwid, vps => $vps };
    }
    return \@devices;
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

# Get device path by WWID
sub get_device_by_wwid {
    my ($wwid, %opts) = @_;

    croak "wwid is required" unless $wwid;

    # First check multipath
    my $mpath = get_multipath_device($wwid);
    return $mpath if $mpath && -b $mpath;

    # Check /dev/disk/by-id (with timeout to prevent hang on unresponsive device)
    (my $safe_wwid = $wwid) =~ s/([\[\]{}*?\\])/\\$1/g;
    my @devices;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(5);
        @devices = glob("/dev/disk/by-id/wwn-*$safe_wwid*");
        push @devices, glob("/dev/disk/by-id/scsi-*$safe_wwid*");
        alarm(0);
    };
    alarm(0);

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

    # Search in /dev/disk/by-id (with timeout to prevent hang)
    my @by_id;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(5);
        @by_id = glob("/dev/disk/by-id/scsi-*");
        alarm(0);
    };
    alarm(0);

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
            my $vpd_data = sysfs_read_with_timeout($vpd_file, 5);
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
        # Sync and flush first (with timeout to prevent hang on unresponsive storage)
        eval { _run_cmd(['/bin/sync'], timeout => 10, allow_nonzero => 1, ignore_errors => 1); };
        if ($safe_device && -b $safe_device) {
            eval { _run_cmd(['/sbin/blockdev', '--flushbufs', $safe_device], timeout => 10, allow_nonzero => 1, ignore_errors => 1); };
        }

        sysfs_write_with_timeout($delete_file, "1\n", 10)
            or croak "Failed to write to $delete_file (timed out or error)";

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
        sysfs_write_with_timeout($rescan_file, "1\n", 10)
            or croak "Failed to write to $rescan_file (timed out or error)";
        return 1;
    }

    croak "Cannot find rescan file for device $device";
}

# Get all slave devices for a multipath device.
# Handles both /dev/mapper/<wwid> (symlink to /dev/dm-N) and /dev/dm-N forms.
sub get_multipath_slaves {
    my ($mpath_device, %opts) = @_;

    croak "mpath_device is required" unless $mpath_device;

    # Resolve symlink: /dev/mapper/<wwid> -> dm-N kernel name
    my $dev_name = _resolve_block_device_name($mpath_device);
    return [] unless $dev_name;

    my $slaves_dir = "/sys/block/$dev_name/slaves";
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
        my $mpath_name = basename($mpath);
        my $safe_name = _untaint_device_name($mpath_name);
        my $safe_mpath = _untaint_device_path($mpath);

        # CRITICAL: Before any flush operation, disable queue_if_no_path on this
        # specific device. Otherwise sync/blockdev/multipath -f will hang forever
        # if all paths are failed and the device has queue_if_no_path enabled.
        if ($safe_name) {
            eval {
                _run_cmd([MULTIPATHD, 'disablequeueing', 'map', $safe_name],
                    allow_nonzero => 1, ignore_errors => 1, timeout => 5);
            };
            # Also use dmsetup to fail any queued I/O immediately
            eval {
                _run_cmd(['/sbin/dmsetup', 'message', $safe_name, '0', 'fail_if_no_path'],
                    allow_nonzero => 1, ignore_errors => 1, timeout => 5);
            };
        }

        # Step 1: Sync all pending writes to this device (with timeout)
        # Now safe because queue_if_no_path is disabled - sync will fail fast
        # if paths are dead instead of hanging.
        eval { _run_cmd(['/bin/sync'], timeout => 10, allow_nonzero => 1, ignore_errors => 1); };

        # Step 2: Flush device buffers (with timeout)
        if ($safe_mpath) {
            eval { _run_cmd(['/sbin/blockdev', '--flushbufs', $safe_mpath],
                timeout => 10, allow_nonzero => 1, ignore_errors => 1); };
        }

        # Step 3: Remove kpartx partition devices before multipath removal.
        # The kernel's partition scanner auto-creates partition dm devices
        # (e.g. <wwid>-part1, <wwid>-part2) when it finds a partition table
        # inside a multipath device. These are present on any VM disk with
        # an OS installed. They must be removed before multipath -f, otherwise
        # the multipath device has holders and the flush fails.
        if ($safe_mpath) {
            eval {
                _run_cmd(['/sbin/kpartx', '-d', $safe_mpath],
                    allow_nonzero => 1, ignore_errors => 1, timeout => 10);
            };
        }

        # Step 4: Remove the multipath device using multipathd (with timeout)
        if ($safe_name) {
            eval {
                _run_cmd([MULTIPATHD, 'remove', 'map', $safe_name],
                    allow_nonzero => 1, ignore_errors => 1, timeout => 10);
            };
        }

        # Step 5: Also try multipath -f as fallback
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

    # Resolve to kernel name (handles /dev/mapper/<wwid> -> dm-N)
    my $dev_name = _resolve_block_device_name($device);
    return 0 unless $dev_name;

    # Check 1a: Is device mounted?
    my $mounts = sysfs_read_with_timeout('/proc/mounts', 5);
    if ($mounts) {
        for my $line (split /\n/, $mounts) {
            if ($line =~ /^\Q$device\E\s/ || $line =~ /^\/dev\/\Q$dev_name\E\s/) {
                return 1;  # Device is mounted
            }
        }
    }

    # Check 1b: Is device used as swap?
    my $swaps = sysfs_read_with_timeout('/proc/swaps', 5);
    if ($swaps) {
        for my $line (split /\n/, $swaps) {
            if ($line =~ /^\Q$device\E\s/ || $line =~ /^\/dev\/\Q$dev_name\E\s/) {
                return 1;  # Device is swap
            }
        }
    }

    # Check 2: Does device have holders (e.g., LVM, dm-crypt)?
    # CRITICAL: must use resolved kernel name (dm-N), not basename of /dev/mapper/<wwid>.
    # Otherwise LVM holders on multipath devices are missed and free_image would
    # happily delete a mounted/in-use volume.
    #
    # HOWEVER: kpartx partition devices are an exception. The kernel's block
    # layer automatically creates partition dm devices (e.g. <wwid>-part1,
    # <wwid>-part2) when it detects a partition table inside a multipath
    # device. This happens on EVERY VM disk that has an OS installed (the VM
    # guest created a GPT/MBR partition table). These partition devices are
    # passive artifacts -- they are not mounted or used by any host process.
    # They will be removed along with the multipath device during cleanup.
    #
    # So: if ALL holders are kpartx partition devices AND none of them have
    # sub-holders of their own (no LVM/dm-crypt on top of the partitions),
    # it's safe to proceed with deletion. If any holder is NOT a partition,
    # or if any partition has its own holders (e.g. checktc-vg LVM on part5),
    # we must block.
    my $holders_dir = "/sys/block/$dev_name/holders";
    if (-d $holders_dir) {
        opendir(my $dh, $holders_dir);
        my @holders = grep { !/^\./ } readdir($dh);
        closedir($dh);

        if (@holders) {
            my $has_real_holders = 0;

            for my $h (@holders) {
                # Read dm-name to check if this is a kpartx partition
                my $dm_name = '';
                my $dm_name_file = "/sys/block/$h/dm/name";
                if (-r $dm_name_file) {
                    $dm_name = sysfs_read_with_timeout($dm_name_file, 3) // '';
                    chomp $dm_name;
                }

                # Kpartx/kernel partition dm-names vary by configuration:
                #   "<wwid>-part1"    (dash-part format)
                #   "<wwid>p1"        (p-suffix, seen on HPE ProLiant)
                #   "<wwid>1"         (digit-only suffix)
                #   "<alias>-part1"   (with user_friendly_names)
                #   "sdf1"            (non-multipath, kpartx on raw sd device)
                my $is_partition = ($dm_name =~ /part\d+$/
                                 || $dm_name =~ /^[0-9a-f]{20,}p?\d+$/
                                 || $dm_name =~ /^sd[a-z]+\d+$/);

                if (!$is_partition) {
                    # Not a partition (could be LVM LV, dm-crypt, etc.)
                    $has_real_holders = 1;
                    last;
                }

                # Even if it IS a partition, check if it's genuinely in use:

                # 2a. Sub-holders (LVM VG, dm-crypt, MD RAID on partition)
                my $sub_dir = "/sys/block/$h/holders";
                if (-d $sub_dir) {
                    opendir(my $sdh, $sub_dir);
                    my @sub = grep { !/^\./ } readdir($sdh);
                    closedir($sdh);
                    if (@sub) {
                        $has_real_holders = 1;
                        last;
                    }
                }

                # 2b. Partition mounted directly (e.g. ext4 on partition)
                # Check both /dev/<dm-N> and /dev/mapper/<dm_name> because
                # /proc/mounts records whichever path was used for mount().
                my $part_dev = "/dev/$h";
                my $part_mapper = $dm_name ? "/dev/mapper/$dm_name" : '';
                if ($mounts) {
                    if ($mounts =~ /^\Q$part_dev\E\s/m ||
                        ($part_mapper && $mounts =~ /^\Q$part_mapper\E\s/m)) {
                        $has_real_holders = 1;
                        last;
                    }
                }

                # 2c. Partition used as swap
                if ($swaps) {
                    if ($swaps =~ /^\Q$part_dev\E\s/m ||
                        ($part_mapper && $swaps =~ /^\Q$part_mapper\E\s/m)) {
                        $has_real_holders = 1;
                        last;
                    }
                }
            }

            return 1 if $has_real_holders;
            # All holders are bare kpartx partitions with no sub-holders.
            # Safe to proceed — cleanup_lun_devices will remove them.
        }
    }

    # Check 3: Is device open by any process? (using fuser with timeout)
    my $safe_device = _untaint_device_path($device);
    return 0 unless $safe_device;
    my (undef, undef, $fuser_exit) = eval {
        _run_cmd(['/bin/fuser', '-s', $safe_device],
            timeout => 10, allow_nonzero => 1, ignore_errors => 1);
    };
    if (!$@ && defined $fuser_exit && $fuser_exit == 0) {
        return 1;  # Device is open by a process
    }

    return 0;  # Device is not in use
}

# Return a detailed human-readable string explaining WHY a device is in use.
# Called from free_image() when is_device_in_use() returns true, to give the
# operator actionable information instead of a generic "device is still in use"
# message. This is especially important when holders are host-level LVM
# auto-activation of VGs from inside VM disks (common on PVE nodes upgraded
# from 7->8->9 with stale /etc/lvm/lvm.conf global_filter).
sub get_device_usage_details {
    my ($device) = @_;

    return "device not specified" unless $device;
    return "device $device does not exist" unless -b $device;

    my $dev_name = _resolve_block_device_name($device);
    return "cannot resolve device $device to kernel name" unless $dev_name;

    my @reasons;

    # Check 1: mounted?
    my $mounts = sysfs_read_with_timeout('/proc/mounts', 5);
    if ($mounts) {
        for my $line (split /\n/, $mounts) {
            if ($line =~ /^\Q$device\E\s+(\S+)/ ||
                $line =~ /^\/dev\/\Q$dev_name\E\s+(\S+)/) {
                push @reasons, "[MOUNTED] Device is mounted on $1";
            }
        }
    }

    # Check 1b: swap?
    my $swaps = sysfs_read_with_timeout('/proc/swaps', 5);
    if ($swaps) {
        for my $line (split /\n/, $swaps) {
            if ($line =~ /^\Q$device\E\s/ || $line =~ /^\/dev\/\Q$dev_name\E\s/) {
                push @reasons, "[SWAP] Device is used as swap";
            }
        }
    }

    # Check 2: holders?
    my $holders_dir = "/sys/block/$dev_name/holders";
    if (-d $holders_dir) {
        opendir(my $dh, $holders_dir);
        my @holders = grep { !/^\./ } readdir($dh);
        closedir($dh);

        if (@holders) {
            my @holder_lines;
            my @detected_vgs;
            my $has_partition = 0;

            for my $h (sort @holders) {
                my $detail = "/dev/$h";

                # Read device-mapper name from sysfs (e.g., "checktc--vg-root")
                my $dm_name_file = "/sys/block/$h/dm/name";
                if (-r $dm_name_file) {
                    my $dm_name = sysfs_read_with_timeout($dm_name_file, 3);
                    if ($dm_name) {
                        chomp $dm_name;
                        $detail .= " (dm-name: $dm_name)";

                        # Classify: is this a kpartx partition or an LVM LV?
                        #
                        # Partition dm-names:
                        #   "<wwid>-part1", "<wwid>1", "<alias>-part1"
                        #   Pattern: ends with "partN" or is <hex30+><digit>
                        #
                        # LVM dm-names:
                        #   "vgname-lvname" (doubled hyphens for literal hyphens)
                        #   Pattern: not a partition, contains single-hyphen separator
                        my $is_part = ($dm_name =~ /part\d+$/
                                    || $dm_name =~ /^[0-9a-f]{20,}p?\d+$/
                                    || $dm_name =~ /^sd[a-z]+\d+$/);

                        if ($is_part) {
                            $has_partition = 1;
                        } elsif ($dm_name =~ /^(.*?[^-])-[^-]/) {
                            my $vg = $1;
                            $vg =~ s/--/-/g;  # un-double hyphens
                            push @detected_vgs, $vg
                                unless grep { $_ eq $vg } @detected_vgs;
                        }
                    }
                }

                push @holder_lines, "    $detail";
            }

            my $holder_msg = "[HOLDERS] Device has " . scalar(@holders) .
                             " holder(s) in /sys/block/$dev_name/holders/:\n" .
                             join("\n", @holder_lines);

            if (@detected_vgs) {
                $holder_msg .= "\n\n  Detected LVM VG(s): " .
                               join(", ", @detected_vgs);
                $holder_msg .= "\n  These are likely host-level LVM auto-activation " .
                               "of VGs found inside the VM disk.";
                $holder_msg .= "\n  The host's LVM scanner (/etc/lvm/lvm.conf " .
                               "global_filter) is not filtering out";
                $holder_msg .= "\n  plugin-managed multipath devices, so it reads " .
                               "VG metadata from inside VM disks";
                $holder_msg .= "\n  and activates them on the host. This is common " .
                               "on PVE nodes upgraded from 7->8->9.";
                $holder_msg .= "\n\n  To resolve:";
                for my $vg (@detected_vgs) {
                    $holder_msg .= "\n    vgchange -an $vg";
                }
                $holder_msg .= "\n  Then retry the delete operation.";
                $holder_msg .= "\n\n  To prevent recurrence after reboot, add to " .
                               "/etc/lvm/lvm.conf devices section:";
                $holder_msg .= "\n    global_filter = [ \"r|/dev/mapper/360.*|\", " .
                               "\"a|.*|\" ]";
                $holder_msg .= "\n  (Adjust the regex to match your environment. " .
                               "Exclude plugin WWID devices, keep local disks.)";
            } elsif ($has_partition) {
                $holder_msg .= "\n\n  Partition table detected on this multipath device.";
                $holder_msg .= "\n  Someone (or the host's LVM/udev) created partitions " .
                               "on a plugin-managed LUN.";
                $holder_msg .= "\n  Use 'dmsetup ls' and 'lsblk /dev/$dev_name' to " .
                               "identify what is using them.";
            }

            push @reasons, $holder_msg;
        }
    }

    # Check 3: open by process?
    my $safe_device = _untaint_device_path($device);
    if ($safe_device) {
        my ($fuser_out, undef, $fuser_exit) = eval {
            _run_cmd(['/bin/fuser', '-v', $safe_device],
                timeout => 10, allow_nonzero => 1, ignore_errors => 1);
        };
        if (!$@ && defined $fuser_exit && $fuser_exit == 0 && $fuser_out) {
            chomp $fuser_out;
            push @reasons, "[PROCESS] Device is open by process(es):\n    $fuser_out";
        }
    }

    if (@reasons) {
        return join("\n\n", @reasons);
    }

    return "No usage detected (device may have become free after the initial check).";
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
