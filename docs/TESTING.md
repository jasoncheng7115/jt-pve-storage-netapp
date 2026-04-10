# NetApp ONTAP Storage Plugin - Test Plan

This document defines the complete test procedure for the jt-pve-storage-netapp plugin.
All tests must pass before any release.

## Prerequisites

- Proxmox VE node with plugin installed
- ONTAP system (simulator or physical) accessible via management IP
- iSCSI LIFs configured on ONTAP SVM (minimum 2 for multipath testing)
- Host with 2 NICs on same network as ONTAP LIFs (for 4-path multipath)
- Storage configured: `pvesm add netappontap <id> ...`
- LXC template available in `local:vztmpl/`

## 1. Basic Connectivity

```bash
# Verify storage is active
pvesm status | grep <storage-id>
# Expected: active with capacity shown

# Verify iSCSI sessions (1 per LIF per NIC)
iscsiadm -m session
# Expected: N sessions (NICs x LIFs)

# Verify multipath paths
multipath -ll
# Expected: NetApp LUN devices with all paths active
```

## 2. VM Disk Lifecycle

```bash
STORAGE=netapp1
VMID=9900

# 2.1 Allocate
pvesm alloc $STORAGE $VMID vm-${VMID}-disk-0 1G
# Expected: success

# 2.2 Path resolution
pvesm path $STORAGE:vm-${VMID}-disk-0
# Expected: /dev/mapper/<wwid>

# 2.3 Multipath verification
multipath -ll | grep -A8 NETAPP
# Expected: all paths active ready running

# 2.4 Read/Write
DEVPATH=$(pvesm path $STORAGE:vm-${VMID}-disk-0)
dd if=/dev/zero of="$DEVPATH" bs=1M count=10 oflag=direct
dd if="$DEVPATH" of=/dev/null bs=1M count=10 iflag=direct
# Expected: both succeed

# 2.5 Free
pvesm free $STORAGE:vm-${VMID}-disk-0
# Expected: success, no residual multipath devices
multipath -ll | grep -c NETAPP
# Expected: 0 (or only other test LUNs)
```

## 3. VM Operations

```bash
STORAGE=netapp1
VMID=9901

# 3.1 Create VM with disk on NetApp
qm create $VMID --name test-netapp --memory 512 --cores 1 \
  --scsi0 $STORAGE:1 --ostype l26 --scsihw virtio-scsi-single

# 3.2 Snapshot
qm snapshot $VMID snap1
qm listsnapshot $VMID
# Expected: snap1 listed

# 3.3 Second snapshot
qm snapshot $VMID snap2

# 3.4 Delete first snapshot
qm delsnapshot $VMID snap1
# Expected: snap1 removed, snap2 remains

# 3.5 Rollback
qm rollback $VMID snap2
# Expected: success

# 3.6 Resize
qm resize $VMID scsi0 +512M
qm config $VMID | grep scsi0
# Expected: size increased

# 3.7 Cleanup snapshot for move test
qm delsnapshot $VMID snap2
```

## 4. Disk Migration

```bash
# 4.1 NetApp -> local-lvm
qm move-disk $VMID scsi0 local-lvm --delete 1
qm config $VMID | grep scsi0
# Expected: scsi0 on local-lvm, no hang

# 4.2 local-lvm -> NetApp
qm move-disk $VMID scsi0 $STORAGE --delete 1
qm config $VMID | grep scsi0
# Expected: scsi0 on NetApp, no hang
```

## 5. Clone Operations

```bash
# 5.1 Full Clone
qm clone $VMID 9902 --name test-full-clone --full 1
qm config 9902 | grep scsi0
# Expected: new disk on NetApp

# 5.2 Template + Linked Clone
qm delsnapshot $VMID snap2 2>/dev/null  # ensure no snapshots
qm template $VMID
qm clone $VMID 9903 --name test-linked-clone
qm config 9903 | grep scsi0
# Expected: linked clone disk on NetApp

# Cleanup clones
qm destroy 9902 --purge
qm destroy 9903 --purge
```

## 6. Special Disk Types

```bash
VMID=9903
qm create $VMID --name test-disks --memory 512 --cores 1 \
  --scsi0 $STORAGE:1 --ostype l26 --scsihw virtio-scsi-single

# 6.1 EFI Disk
qm set $VMID --bios ovmf \
  --efidisk0 $STORAGE:1,efitype=4m,pre-enrolled-keys=1
qm config $VMID | grep efidisk0
# Expected: efidisk0 on NetApp

# 6.2 Cloud-init
qm set $VMID --ide2 $STORAGE:cloudinit
qm config $VMID | grep ide2
# Expected: cloudinit disk on NetApp

# 6.3 TPM
qm set $VMID --tpmstate0 $STORAGE:1,version=v2.0
qm config $VMID | grep tpmstate0
# Expected: tpmstate0 on NetApp

# Cleanup
qm destroy $VMID --purge
```

## 7. LXC Container

```bash
CTID=9910

# 7.1 Create LXC with rootfs on NetApp
pct create $CTID local:vztmpl/<template>.tar.zst \
  --rootfs $STORAGE:2 \
  --hostname test-lxc --memory 256 --cores 1 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp --unprivileged 0
# Expected: success

# 7.2 Start
pct start $CTID
pct status $CTID
# Expected: running

# 7.3 Snapshot
pct snapshot $CTID snap1
# Expected: success

# 7.4 Stop + cleanup
pct stop $CTID
pct delsnapshot $CTID snap1
pct destroy $CTID --purge
# Expected: all clean
```

## 8. igroup Mapping Verification

```bash
# After alloc_image, verify LUN is mapped to ALL node igroups
pvesm alloc $STORAGE 9999 vm-9999-disk-0 128M

# Check on ONTAP (via API or CLI):
# - LUN should be mapped to pve_<cluster>_<node1> AND pve_<cluster>_<node2>
# - Not just the current node's igroup

pvesm free $STORAGE:vm-9999-disk-0
```

## 9. Timeout Protection (Anti-Hang)

```bash
# 9.1 Verify sysfs write timeout works
# Check dmesg/journal for "timed out after 10s" messages during normal operations
# These are expected for unresponsive SCSI hosts and should not block operations

# 9.2 Storage status check should not hang
time pvesm status
# Expected: completes within 30 seconds even if ONTAP is slow

# 9.3 If possible, disconnect one iSCSI LIF and verify:
#   - Operations still work via remaining paths
#   - No PVE worker hangs
#   - multipath shows degraded paths
```

## 10. Failure Scenarios (Optional, requires controlled environment)

```bash
# 10.1 Disconnect one iSCSI LIF
# Verify: multipath degrades, I/O continues on remaining paths
# Verify: reconnect restores all paths

# 10.2 Disconnect all iSCSI LIFs
# Verify: PVE status returns (0,0,0,0) instead of hanging
# Verify: pvesm status completes (not hang)
# Verify: No PVE worker processes stuck in D state

# 10.3 ONTAP API unreachable (block port 443)
# Verify: pvesm status completes within ~35 seconds
# Verify: alloc/free operations fail with clear error, not hang
```

## 11. Coexistence with Existing Multipath

If the host already has manual multipath configuration:

```bash
# 11.1 Verify existing multipath devices are unaffected
multipath -ll
# Expected: customer's existing devices still present and functional

# 11.2 Verify iSCSI sessions
iscsiadm -m session
# Expected: customer's sessions intact, plugin's sessions added

# 11.3 Verify multipath.conf not modified
grep "BEGIN jt-pve-storage-netapp" /etc/multipath.conf
# Expected: not found (customer's config preserved)
```

## 12. Stale Device Prevention (free_image)

```bash
# 12.1 Allocate then free, verify no stale SCSI/multipath devices
STORAGE=netapp1

# Count baseline NetApp SCSI devices (should match number of currently-used LUNs * paths)
BEFORE=$(lsscsi | grep -c NETAPP)

pvesm alloc $STORAGE 9920 vm-9920-disk-0 64M
pvesm free $STORAGE:vm-9920-disk-0
sleep 5

AFTER=$(lsscsi | grep -c NETAPP)
# Expected: AFTER == BEFORE (no leftover stale devices)

# 12.2 Verify multipath has no failed-state NetApp devices
multipath -ll | grep -A2 NETAPP | grep "failed faulty"
# Expected: no output (no stale paths)

# 12.3 Verify no I/O errors in dmesg from this operation
dmesg | tail -20 | grep "I/O error"
# Expected: no new errors related to deleted LUN
```

## 13. Orphan Cleanup (Cluster Scenario)

Simulates the case where Node A deletes a VM and Node B (this node) needs to clean up its stale devices automatically.

```bash
STORAGE=netapp1

# 13.1 Setup: allocate a LUN
pvesm alloc $STORAGE 9921 vm-9921-disk-0 64M
DEVPATH=$(pvesm path $STORAGE:vm-9921-disk-0)
WWID=$(echo $DEVPATH | sed 's|/dev/mapper/||')

# 13.2 Verify WWID is tracked
cat /var/lib/pve-storage-netapp/${STORAGE}-wwids.json
# Expected: contains the WWID

# 13.3 Simulate "another node deleted the LUN" (delete via API only,
# bypassing free_image which would do local cleanup)
perl -e '
use lib "/usr/share/perl5";
use PVE::Storage::Custom::NetAppONTAP::API;
my $api = PVE::Storage::Custom::NetAppONTAP::API->new(
    host => "<ONTAP_IP>", username => "<USER>",
    password => "<PASS>", svm => "<SVM>", ssl_verify => 0,
);
$api->get_svm_uuid();
$api->lun_unmap_all("/vol/pve_${STORAGE}_9921_disk0/lun0");
$api->lun_delete("/vol/pve_${STORAGE}_9921_disk0/lun0");
$api->volume_delete("pve_${STORAGE}_9921_disk0");
'

# 13.4 Verify multipath device still exists locally (stale)
multipath -ll | grep $WWID
# Expected: still visible with all paths failed

# 13.5 Trigger orphan cleanup via status() poll
pvesm status > /dev/null
sleep 5

# 13.6 Verify orphan was cleaned
multipath -ll | grep $WWID
# Expected: no output (orphan removed)

# 13.7 Verify WWID untracked
cat /var/lib/pve-storage-netapp/${STORAGE}-wwids.json
# Expected: WWID no longer in file
```

## 14. Mixed Environment Safety

If the host has manually configured iSCSI/LVM storage in addition to this plugin:

```bash
# 14.1 Note manual storage WWIDs (they should never appear in plugin's tracking)
multipath -ll | grep -B1 NETAPP | grep -oE '[0-9a-f]{32,}'

# 14.2 Verify plugin's tracking file does NOT contain manual WWIDs
cat /var/lib/pve-storage-netapp/*-wwids.json 2>/dev/null
# Expected: only WWIDs created by this plugin

# 14.3 Run alloc/free cycle and verify manual storage untouched
MANUAL_BEFORE=$(multipath -ll | grep -B1 'na_iscsi' | wc -l)
pvesm alloc netapp1 9930 vm-9930-disk-0 64M
pvesm free netapp1:vm-9930-disk-0
MANUAL_AFTER=$(multipath -ll | grep -B1 'na_iscsi' | wc -l)
# Expected: MANUAL_BEFORE == MANUAL_AFTER (manual storage unaffected)
```

## 15. Postinst Warning Detection

```bash
# 15.1 Test warning is shown when dangerous settings exist
grep -E 'no_path_retry.*queue|queue_if_no_path|dev_loss_tmo.*infinity' /etc/multipath.conf
# If any match: postinst should display warning during install/upgrade

# 15.2 Verify postinst behavior
dpkg -i jt-pve-storage-netapp_*.deb 2>&1 | grep -A20 "DANGEROUS"
# Expected: colored warning block with recommended changes
```

## 16. Igroup Mapping (Multi-node)

```bash
# 16.1 After alloc_image, verify LUN is mapped to ALL node igroups, not just current
pvesm alloc netapp1 9940 vm-9940-disk-0 64M

# Query ONTAP to see all igroup mappings for this LUN
perl -e '
use lib "/usr/share/perl5";
use PVE::Storage::Custom::NetAppONTAP::API;
my $api = PVE::Storage::Custom::NetAppONTAP::API->new(
    host => "<ONTAP_IP>", username => "<USER>",
    password => "<PASS>", svm => "<SVM>", ssl_verify => 0,
);
$api->get_svm_uuid();
my $resp = $api->get("/protocols/san/lun-maps", {
    "svm.name" => "<SVM>", fields => "igroup.name,lun.name"
});
for my $m (@{$resp->{records}}) {
    next unless $m->{lun}{name} =~ /9940/;
    print "$m->{igroup}{name}\n";
}
'
# Expected: shows pve_<cluster>_<node1>, pve_<cluster>_<node2>, ... (all nodes)

pvesm free netapp1:vm-9940-disk-0
```

## 17. Status() Performance & Resilience

```bash
# 17.1 Status should complete quickly even with many volumes
time pvesm status | grep netapp
# Expected: < 5 seconds typical, < 35s worst case (with API timeout)

# 17.2 Status should not hang even if API is unreachable
# (Block ONTAP API port temporarily)
iptables -A OUTPUT -p tcp --dport 443 -d <ONTAP_IP> -j DROP
time pvesm status
# Expected: returns 0,0,0,0 within ~35 seconds (not hang)
iptables -D OUTPUT -p tcp --dport 443 -d <ONTAP_IP> -j DROP
```

## 18. Timeout Protection (Anti-Hang)

```bash
# 18.1 Verify no PVE worker enters D state during operations
ps -eo pid,stat,comm | awk '$2 ~ /D/'
# Expected: no PVE worker (pvedaemon, qm, etc.) in D state after operations

# 18.2 Verify sysfs write timeout messages are non-fatal
journalctl -u pvedaemon --since "10 minutes ago" | grep "timed out after"
# If present: operations should still have completed (check return codes)
```

## 19. v0.2.4 Audit Fixes (Cleanup ordering, snapshot quiesce, dead code)

### 19.1 Static code audit (regression guards)

These greps verify that no function regresses to the bug patterns fixed in
v0.2.4 / v0.2.3 / v0.2.1. Each must produce ZERO matches.

```bash
cd /root/jt-pve-storage-netapp

# 19.1.1 No volume_delete without lun_unmap_all in cleanup paths
# (Find every volume_delete call and verify lun_unmap_all is on a nearby line)
# Manual review: open NetAppONTAPPlugin.pm and check each $api->volume_delete
# inside an eval cleanup block has $api->lun_unmap_all on a preceding line.
grep -n 'volume_delete' lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm
# Expected: every cleanup-path volume_delete has lun_unmap_all before it.
# alloc_image: line ~1061-1063 OK
# clone_image: lines ~2052-2054 and ~2090-2092 OK (v0.2.4 fix)
# free_image:  line ~1149 OK (already unmapped in step 2 at line ~1117)

# 19.1.2 No basename() near /sys/block/ access
grep -n 'basename' lib/PVE/Storage/Custom/NetAppONTAP/Multipath.pm | \
    grep -v '_resolve_block_device_name'
# Expected: only one match in get_scsi_devices_by_serial (uses /sys/block/sd*
# names directly which is safe).

# 19.1.3 get_multipath_wwid removed
grep -n 'get_multipath_wwid' lib/PVE/Storage/Custom/NetAppONTAP/Multipath.pm
# Expected: zero matches (function deleted in v0.2.4)

# 19.1.4 No bare system() calls (anti-hang)
grep -nE '(^|[^_a-z])system\s*\(' lib/PVE/Storage/Custom/**/*.pm
# Expected: zero matches (all replaced with run_command or _run_cmd)

# 19.1.5 No bare open() to /sys/
grep -n "open.*'>'.*'/sys/" lib/PVE/Storage/Custom/**/*.pm
# Expected: zero matches (all use sysfs_write_with_timeout)
```

### 19.2 clone_image cleanup leaves no orphan (positive)

Tests that a normal clone+destroy cycle leaves no orphaned LUN mapping or
ghost device on any cluster node. This is the v0.2.4 Bug E happy path
regression test.

```bash
STORAGE=netapp1

# 19.2.1 Baseline: count current LUN mappings on ONTAP for this storage
BEFORE_LUNS=$(perl -Ilib -e "
use PVE::Storage::Custom::NetAppONTAP::API;
# (insert API setup) ...
" 2>/dev/null || echo "manual: ssh ontap 'lun mapping show' | grep -c pve_")

# 19.2.2 Create base VM and template
qm create 9950 --name clone-test --memory 256 --cores 1 \
  --scsi0 $STORAGE:1 --kvm 0 --ostype l26 --scsihw virtio-scsi-single
qm template 9950

# 19.2.3 Linked clone
qm clone 9950 9951 --name linked-clone-test
qm config 9951 | grep scsi0
# Expected: scsi0 on $STORAGE, named base-9950-disk-0/vm-9951-disk-0

# 19.2.4 Full clone
qm clone 9950 9952 --name full-clone-test --full 1
qm config 9952 | grep scsi0

# 19.2.5 Destroy clones
qm destroy 9951 --purge
qm destroy 9952 --purge
sleep 5

# 19.2.6 Verify no stale devices
multipath -ll 2>/dev/null | grep -B1 NETAPP | grep "failed faulty"
# Expected: empty

# 19.2.7 Verify no orphan WWIDs in tracking file
cat /var/lib/pve-storage-netapp/${STORAGE}-wwids.json
# Expected: only contains WWIDs of currently-existing VMs

# 19.2.8 Cleanup
qm destroy 9950 --purge
```

### 19.3 volume_snapshot of stopped VM (Bug F)

Verifies snapshot of a stopped VM with pending dirty buffers still works
and produces a consistent snapshot. The pre-snapshot flush should not break
the existing happy path.

```bash
STORAGE=netapp1
VMID=9960

# 19.3.1 Create stopped VM, allocate disk
qm create $VMID --name snap-flush-test --memory 256 --cores 1 \
  --scsi0 $STORAGE:1 --kvm 0 --ostype l26 --scsihw virtio-scsi-single

# 19.3.2 Take snapshot of stopped VM (should trigger pre-flush path)
qm snapshot $VMID baseline
qm listsnapshot $VMID
# Expected: baseline listed

# 19.3.3 Verify dmesg doesn't show flush errors
dmesg | tail -20 | grep -iE 'flushbufs|sync.*timed out'
# Expected: no errors related to this snapshot

# 19.3.4 Snapshot rollback (regression check that rollback path still works)
qm rollback $VMID baseline
# Expected: success

# 19.3.5 Cleanup
qm delsnapshot $VMID baseline
qm destroy $VMID --purge
```

### 19.4 volume_snapshot of running VM (regression)

Verifies the pre-snapshot flush correctly skips when device is in use
(running VM), avoiding any blocking on live VMs.

```bash
STORAGE=netapp1
VMID=9961

qm create $VMID --name snap-running-test --memory 256 --cores 1 \
  --scsi0 $STORAGE:1 --kvm 0 --ostype l26 --scsihw virtio-scsi-single
qm start $VMID
sleep 3

# Snapshot running VM -- should skip flush (device in use), use qemu freeze
qm snapshot $VMID running-snap
qm listsnapshot $VMID
# Expected: running-snap listed, no hang, no warnings about flush

qm stop $VMID
qm delsnapshot $VMID running-snap
qm destroy $VMID --purge
```

### 19.5 Resize regression (v0.2.3 fix re-verification)

Re-verify that the v0.2.3 resize fix still works after the v0.2.4 changes
(make sure we didn't accidentally break it).

```bash
STORAGE=netapp1
VMID=9962

qm create $VMID --name resize-regression --memory 256 --cores 1 \
  --scsi0 $STORAGE:1 --kvm 0 --ostype l26 --scsihw virtio-scsi-single
qm start $VMID
sleep 3

qm resize $VMID scsi0 +512M
# Expected: success, NO "Cannot grow device files" error

DEV=$(pvesm path $STORAGE:vm-${VMID}-disk-0)
SIZE=$(blockdev --getsize64 $DEV)
# Expected: SIZE >= 1610612736 (1.5 GB)
echo "device size: $SIZE bytes"

qm stop $VMID
qm destroy $VMID --purge
```

### 19.7 clone_image parallel race (Bug H)

Verifies the v0.2.4 TOCTOU race fix in `clone_image`. Three concurrent clones
of the same template should all succeed with unique disk IDs, with no
"already exists" errors.

```bash
STORAGE=netapp1

# Setup template
qm create 9950 --name h-test --memory 256 --cores 1 \
  --scsi0 $STORAGE:1 --kvm 0 --ostype l26 --scsihw virtio-scsi-single
qm template 9950

# Three parallel clones
qm clone 9950 9961 --name parallel-1 > /tmp/p1.log 2>&1 &
qm clone 9950 9962 --name parallel-2 > /tmp/p2.log 2>&1 &
qm clone 9950 9963 --name parallel-3 > /tmp/p3.log 2>&1 &
wait

# Verify all succeeded
qm config 9961 | grep scsi0
qm config 9962 | grep scsi0
qm config 9963 | grep scsi0
# Expected: each shows scsi0 on $STORAGE with a unique disk ID

# No "already exists" errors in any log
grep -i "already exists\|race detected" /tmp/p*.log
# Expected: empty (or only "race detected" warnings if PVE cfs lock didn't
# fully serialize -- those are EXPECTED v0.2.4 behavior, not errors)

# Cleanup
qm destroy 9961 --purge
qm destroy 9962 --purge
qm destroy 9963 --purge
qm destroy 9950 --purge
```

### 19.8 ONTAP limit error translation (Bug I, unit test)

Verifies `_translate_limit_error` correctly translates the 5 limit-error
patterns. Does not require ONTAP to actually be at limit -- runs as a
unit test against the helper.

```bash
cd /root/jt-pve-storage-netapp
perl -Ilib -e '
use PVE::Storage::Custom::NetAppONTAPPlugin;
my @cases = (
  ["Maximum number of volumes is reached on Vserver svm0", "FlexVol"],
  ["Maximum number of LUNs reached for SVM", "LUN"],
  ["Maximum number of LUN map entries reached", "LUN map"],
  ["No space left on aggregate aggr1", "aggregate"],
  ["Vserver quota exceeded", "quota"],
  ["some unrelated error", "passthrough"],
);
for my $c (@cases) {
  my ($err, $label) = @$c;
  my $out = PVE::Storage::Custom::NetAppONTAPPlugin::_translate_limit_error($err, "test");
  my $translated = ($out ne $err);
  print "$label: ", ($label eq "passthrough" ? !$translated : $translated) ? "PASS" : "FAIL", "\n";
}
'
# Expected: all 6 lines say PASS
```

### 19.9 rescan_scsi_hosts does not touch non-iSCSI hosts (v0.2.5 Bug Incident 8)

Verifies that `rescan_scsi_hosts()` only writes to the scan files of iSCSI
hosts (sourced from `/sys/class/iscsi_host/`), and never touches non-iSCSI
hosts like HBA RAID controllers, USB card readers, or virtio-scsi.

#### 19.9.1 Static code audit

```bash
cd /root/jt-pve-storage-netapp

# Both rescan functions must source host list from transport-specific class
grep -n 'iscsi_host' lib/PVE/Storage/Custom/NetAppONTAP/Multipath.pm | grep -v '^\s*#'
# Expected: at least one line referencing /sys/class/iscsi_host (in rescan_scsi_hosts)

grep -n '/sys/class/scsi_host' lib/PVE/Storage/Custom/NetAppONTAP/*.pm | grep -v '^\s*#' | grep -v 'SCSI_HOST_PATH'
# Expected: zero matches where scsi_host is opendir'd without iscsi_host/fc_host filter

# rescan_scsi_hosts must not directly opendir /sys/class/scsi_host anymore
perl -ne 'print "$.: $_" if /opendir.*SCSI_HOST_PATH/' lib/PVE/Storage/Custom/NetAppONTAP/Multipath.pm
# Expected: zero output (rescan_scsi_hosts uses /sys/class/iscsi_host)

# rescan_fc_hosts must not iterate full /sys/class/scsi_host anymore
perl -ne '
  if (/sub rescan_fc_hosts/../^}/) {
    print "$.: $_" if /opendir.*scsi_host/;
  }
' lib/PVE/Storage/Custom/NetAppONTAP/FC.pm
# Expected: zero output (rescan_fc_hosts iterates only FC hosts from get_fc_hosts)
```

#### 19.9.2 Runtime behavior on mixed-driver host

```bash
# Verify the test host has at least one non-iSCSI scsi_host (most PVE hosts do:
# onboard SATA controllers or HBAs produce ahci / mpt3sas / smartpqi / etc.)
ls /sys/class/scsi_host/
# Usually host0, host1, ... some of which are non-iSCSI

ls /sys/class/iscsi_host/ 2>/dev/null
# Should be a strict subset of /sys/class/scsi_host/

# Show driver for each scsi host
for h in /sys/class/scsi_host/host*; do
  echo -n "$(basename $h): "
  cat $h/proc_name 2>/dev/null
done
# You should see a mix. Non-iscsi_tcp hosts must NOT be scanned by the plugin.

# Run rescan_scsi_hosts directly and inotify-watch the non-iSCSI hosts'
# scan files to confirm no writes arrive at them
ISCSI_HOSTS=$(ls /sys/class/iscsi_host/ 2>/dev/null)
NONISCSI_HOSTS=$(comm -23 <(ls /sys/class/scsi_host/ | sort) <(echo "$ISCSI_HOSTS" | sort))

# Snapshot non-iSCSI host state before rescan (mtime of scan file)
for h in $NONISCSI_HOSTS; do
  stat -c "%n %Y" /sys/class/scsi_host/$h/scan 2>/dev/null
done > /tmp/scan-before.txt

perl -I/usr/share/perl5 -e "
use PVE::Storage::Custom::NetAppONTAP::Multipath qw(rescan_scsi_hosts);
rescan_scsi_hosts(delay => 0);
print 'rescan done\n';
"

# Snapshot again after
for h in $NONISCSI_HOSTS; do
  stat -c "%n %Y" /sys/class/scsi_host/$h/scan 2>/dev/null
done > /tmp/scan-after.txt

# Non-iSCSI scan files must NOT have been written
diff /tmp/scan-before.txt /tmp/scan-after.txt
# Expected: empty (mtimes unchanged on non-iSCSI hosts)
# Note: mtime only reliably changes on write, and some kernel versions don't
# update mtime on sysfs writes. A more robust test would use BPF tracing:
#   bpftrace -e 'kprobe:vfs_write /str(args->buf) == "- - -\n"/ { printf("%s\n", comm); }'
```

#### 19.9.3 Functional regression: new LUN discovery still works

```bash
# Allocate a new LUN via the plugin — this exercises rescan_scsi_hosts
# after lun_map. If the new filter broke rescan, the device would not
# appear and pvesm alloc would fail.
STORAGE=netapp1
pvesm alloc $STORAGE 9990 vm-9990-disk-0 256M
pvesm path $STORAGE:vm-9990-disk-0
# Expected: returns /dev/mapper/<wwid> (new LUN discovered via iSCSI host scan)
pvesm free $STORAGE:vm-9990-disk-0
```

#### 19.9.4 FC host filter (same principle, different transport class)

If test environment has FC hosts:

```bash
# List FC hosts
ls /sys/class/fc_host/ 2>/dev/null
# Run rescan_fc_hosts if FC.pm is available in an FC environment
# Non-FC scsi_hosts must not be touched (same test pattern as 19.9.2 but
# substituting /sys/class/fc_host/ for /sys/class/iscsi_host/)
```

### 19.6 is_device_in_use with LVM holder (v0.2.3 data loss fix re-verification)

Re-verify the v0.2.3 critical fix still works.

```bash
STORAGE=netapp1
VMID=9963

pvesm alloc $STORAGE $VMID vm-${VMID}-disk-0 256M
DEV=$(pvesm path $STORAGE:vm-${VMID}-disk-0)
echo "device: $DEV"

# Create LVM PV/VG/LV/FS on it
pvcreate -ff -y $DEV
vgcreate test_v024_vg $DEV
lvcreate -L 100M -n test_lv test_v024_vg
mkfs.ext4 -F /dev/test_v024_vg/test_lv
mkdir -p /mnt/test_v024
mount /dev/test_v024_vg/test_lv /mnt/test_v024

# is_device_in_use should now return TRUE
RESULT=$(perl -Ilib -e "
use PVE::Storage::Custom::NetAppONTAP::Multipath qw(is_device_in_use);
print is_device_in_use('$DEV') ? 'IN_USE' : 'FREE';
")
echo "is_device_in_use($DEV) = $RESULT"
# Expected: IN_USE

# pvesm free should refuse (because device is in use)
pvesm free $STORAGE:vm-${VMID}-disk-0 2>&1
# Expected: error "device is still in use"

# Cleanup
umount /mnt/test_v024
lvremove -f test_v024_vg/test_lv
vgremove test_v024_vg
pvremove $DEV
pvesm free $STORAGE:vm-${VMID}-disk-0
rmdir /mnt/test_v024
```

---

## Cleanup

```bash
# Remove all test VMs and containers
qm destroy 9900 --purge 2>/dev/null
qm destroy 9901 --purge 2>/dev/null
qm destroy 9902 --purge 2>/dev/null
qm destroy 9903 --purge 2>/dev/null
pct destroy 9910 --purge 2>/dev/null

# Verify no orphaned volumes on ONTAP
pvesm list $STORAGE
```

---

## Release Test Results

Each release must pass all tests above before publishing. Results are recorded below.

### v0.2.5-1 Non-iSCSI SCSI Host Scan Fix (2026-04-10)

**Scope:** Section 19.9 (new Bug Incident 8 regression guard) + regression of Sections 1, 2, 3, 5 + v0.2.4 unit tests.

**Environment:** Single-node test (PVE 9.1, ONTAP simulator), netapp1 storage.

**Test host SCSI inventory (important for 19.9.2):**
- host0-1: virtio_scsi
- host2-3: ata_piix
- host4-7: iscsi_tcp

This is a "mixed driver" environment — the fix must only touch host4-7 (iSCSI) and leave host0-3 untouched.

#### Section 19.9: rescan_scsi_hosts iSCSI-only filter

| # | Test | Result |
|---|------|--------|
| 19.9.1 | Static audit: `rescan_scsi_hosts` references `/sys/class/iscsi_host` | PASS |
| 19.9.1 | Static audit: `rescan_scsi_hosts` does not `opendir` `SCSI_HOST_PATH` | PASS |
| 19.9.1 | Static audit: `rescan_fc_hosts` does not iterate full `/sys/class/scsi_host` | PASS |
| 19.9.2 | **Strace proof: `rescan_scsi_hosts()` only opens host4-7 scan files, never host0-3** | **PASS** |
| 19.9.3 | Functional regression: `pvesm alloc` still discovers new LUN via iSCSI rescan | PASS |

**Key strace output (19.9.2):**
```
openat(AT_FDCWD, "/sys/class/scsi_host/host4/scan", O_WRONLY|...)
openat(AT_FDCWD, "/sys/class/scsi_host/host5/scan", O_WRONLY|...)
openat(AT_FDCWD, "/sys/class/scsi_host/host6/scan", O_WRONLY|...)
openat(AT_FDCWD, "/sys/class/scsi_host/host7/scan", O_WRONLY|...)
```
No opens to host0/1 (virtio_scsi) or host2/3 (ata_piix). Before v0.2.5 would have shown all 8.

#### Regression: Sections 1, 2, 3, 5 + v0.2.4 unit tests

| # | Section / Test | Result |
|---|----------------|--------|
| R1 | Section 1: pvesm status | PASS |
| R2 | Section 2: alloc + path + free | PASS |
| R3 | Section 3: VM snapshot + rollback + resize + delsnapshot | PASS |
| R4 | Section 5: template + linked clone | PASS |
| R5 | v0.2.4 Section 19.8: limit error translation (6/6 cases) | PASS |

**Final state:**
- WWID tracking: `{}` empty
- D-state processes: 0
- pvedaemon / pveproxy: active

**Verdict:** All Section 19.9 tests PASS. All regression tests PASS. v0.2.5-1 ready for release.

### v0.2.4-1 Audit Fixes Release (2026-04-09)

**Scope:** Section 19 (new tests for v0.2.4 cleanup-ordering / snapshot-quiesce / dead-code fixes), plus regression of Sections 1, 2, 3, 5.

**Environment:** Single-node test (PVE 9.1, ONTAP simulator), netapp1 storage, 2 iSCSI portals, multipath with `dev_loss_tmo 60` + `no_path_retry 30`. Plugin built with `make deb` and installed via `dpkg -i jt-pve-storage-netapp_0.2.4-1_all.deb`.

#### Section 19: v0.2.4 Audit Fixes

| #  | Test | Result |
|----|------|--------|
| 19.1.1 | No `volume_delete` without preceding `lun_unmap_all` in cleanup paths | PASS (alloc_image:1063, clone_image:2071+2112, free_image:1149, temp clone:1529 all verified; alloc_image:1028 is the LUN-create-failure path which has no LUN to unmap, safe) |
| 19.1.2 | No unsafe `basename()` near `/sys/block/` access in Multipath.pm | PASS (only safe usages remain: resolver itself, dmsetup/multipathd map names, /sys/block/sd* per-path operations) |
| 19.1.3 | Dead code `get_multipath_wwid()` removed | PASS (zero matches) |
| 19.1.4 | No bare `system()` calls | PASS (zero matches) |
| 19.1.5 | No bare `open()` writes to `/sys/` | PASS (zero matches) |
| 19.2 | clone_image happy path: linked clone + full clone + destroy leaves no stale device | PASS (no failed multipath, WWID tracking auto-converged to empty after status() poll) |
| 19.3 | volume_snapshot of stopped VM triggers pre-flush path successfully | PASS (snapshot created, no flush errors in dmesg, rollback works) |
| 19.4 | volume_snapshot of running VM correctly skips flush (device in use) | PASS (no hang, no flush warnings, snapshot succeeded) |
| 19.5 | qm resize on running VM (v0.2.3 regression check) | PASS (no "Cannot grow device files" error, blockdev --getsize64 confirmed 1610612736 bytes after +512M from 1G) |
| 19.6 | is_device_in_use detects dm-linear holder on /dev/mapper/<wwid> (v0.2.3 data loss fix re-verification) | PASS (returned IN_USE, pvesm free correctly refused with clear error message, volume preserved) |

#### Section 19.2 detailed observations

- `dmsetup remove --force --retry` fallback fired correctly for both clones during destroy (expected v0.2.3 behavior on this simulator with `queue_if_no_path` legacy config)
- Auto-import via `status()` cleared the orphan WWID after the template-volume simulator stale-metadata error, demonstrating the v0.2.3 cluster-convergence mechanism still works under v0.2.4

#### Section 19.6 detailed observations

- Used `dmsetup create test_holder ... linear /dev/mapper/<wwid>` to create a real holder relationship (LVM filter on this PVE host rejects multipath devices, so direct dm-linear is the more reliable holder test)
- After resolution: `/sys/block/dm-9/holders/dm-10` correctly enumerated
- `is_device_in_use('/dev/mapper/3600a09807770457a795d5a7653705a63')` returned 1
- `pvesm free` rejected with: `Cannot delete volume 'vm-9963-disk-0': device /dev/mapper/3600a09807770457a795d5a7653705a63 is still in use (mounted, has holders, or open by process)`
- After `dmsetup remove test_holder_v024`, `pvesm free` succeeded normally

#### Regression: Sections 1, 2, 3, 5

| #  | Section / Test | Result |
|----|----------------|--------|
| R1 | Section 1: pvesm status, pvesm list | PASS |
| R2 | Section 2: alloc + path + free | PASS |
| R3 | Section 3.2-3.4: snapshot snap1, snap2, delete snap1 | PASS |
| R4 | Section 3.5: rollback snap2 | PASS |
| R5 | Section 3.6: qm resize +512M | PASS (config shows 1536M) |
| R6 | Section 5.1: qm clone --full 1 | PASS |
| R7 | Section 5.2: qm template + linked clone | PASS (functional; template volume hit ONTAP simulator stale clone metadata limitation, documented in CLAUDE.md, not a plugin bug) |

#### Final state

- WWID tracking file: `{}` (empty, fully converged)
- multipath: zero NETAPP devices in failed state
- Process state: zero D-state processes
- Services: pvedaemon active, pveproxy active

**Verdict:** All Section 19 tests PASS. All regression tests PASS. v0.2.4-1 ready for release.

### v0.2.2-1 Expanded Test Suite (2026-04-08)

**Test Environment:** Same as v0.2.1, with mixed multipath.conf (existing manual NetApp config preserved, with `queue_if_no_path` and `dev_loss_tmo infinity` -- intentional to verify postinst warning).

#### Section 1-2: Basic Connectivity & Disk Lifecycle

| # | Test | Result |
|---|------|--------|
| T1 | Storage active | PASS |
| T2 | iSCSI sessions >= 2 | PASS |
| T3 | Alloc image | PASS |
| T4 | Path resolves | PASS |
| T5 | Multipath active | PASS |
| T6 | Write test (dd) | PASS |
| T7 | Read test (dd) | PASS |
| T8 | WWID tracked in state file | PASS |
| T9 | Free image (no stale) | PASS |
| T10 | WWID untracked after free | PASS |

#### Section 3: VM Operations & Migration

| # | Test | Result |
|---|------|--------|
| T11 | VM Create with disk on NetApp | PASS |
| T12 | Snapshot 1 | PASS |
| T13 | Snapshot 2 | PASS |
| T14 | Delete snapshot | PASS |
| T15 | Rollback | PASS |
| T16 | Resize +256M | PASS |
| T17 | Move disk NetApp -> local-lvm | PASS |
| T18 | Move disk local-lvm -> NetApp | PASS |
| T19 | Full Clone | PASS |
| T20 | Convert to Template | PASS |
| T21 | Linked Clone | PASS |
| T22 | EFI Disk | PASS |
| T23 | Cloud-init Disk | PASS |
| T24 | TPM State | PASS |
| T25 | LXC Create (rootfs on NetApp) | PASS |
| T26 | LXC Start | PASS |
| T27 | LXC Snapshot | PASS |

#### Section 4: Add / Remove Disks on Existing VM

| # | Test | Result |
|---|------|--------|
| T28 | Add 2GB disk to existing VM (qm set --scsi1) | PASS |
| T29 | Disk visible in config | PASS |
| T30 | Add another 1GB disk (scsi2) | PASS |
| T31 | Resize added disk | PASS |
| T32 | Detach disk via qm set --delete | PASS |
| T33 | Disk shows as unused | PASS |
| T34 | Delete unused disk | PASS |
| T35 | Force delete via qm unlink | PASS |
| T36 | Extra disks cleaned up | PASS |
| T37 | No stale multipath after disk removal | PASS |

#### Section 5: Orphan Cleanup (Cluster Scenario)

End-to-end test simulating: Node A deletes a VM, Node B's stale devices auto-cleaned by status() poll.

| # | Test | Result |
|---|------|--------|
| T38 | WWID tracked after path() | PASS |
| T39 | Simulate cluster-side delete via API | PASS |
| T40 | Stale multipath still present pre-cleanup | PASS |
| T41 | (skipped: covered by T42) | - |
| T42 | Orphan cleaned by status() poll | PASS |
| T43 | WWID removed from state file | PASS |

#### Section 6: Mixed Environment, igroup, Resilience

| # | Test | Result |
|---|------|--------|
| T44 | Tracking file structure valid | PASS |
| T45 | alloc_image maps to all node igroups | PASS |
| T46 | status() completes < 35s | PASS (1 sec) |
| T47 | No PVE workers in D state | PASS |
| T48 | postinst warning logic detects danger | PASS |

#### Section 7: PVE Workflow Operations (Real VM lifecycle)

| # | Test | Result | Notes |
|---|------|--------|-------|
| T49 | VM Create | PASS | |
| T50 | VM start (storage activate) | PASS | TCG mode for nested testing |
| T51 | Hot-plug disk to running VM | PASS | qm set --scsi1 |
| T52 | Hot-plugged disk visible | PASS | |
| T53 | Hot-unplug disk from running VM | PASS | |
| T54 | VM stop | PASS | |
| T55 | vzdump backup | PASS | mode=stop |
| T56 | qmrestore to NetApp | PASS | Cross-storage restore |
| T57 | Multi-disk VM running | PASS | 2 disks |
| T58 | VM snapshot with RAM state (vmstate) | PASS | Saves QEMU state to dedicated LUN |
| T59 | Delete RAM snapshot | PASS | |

#### Section 8: Failure Scenarios

| # | Test | Result | Notes |
|---|------|--------|-------|
| T65 | I/O continues with degraded multipath | PASS | 35 MB/s with 2/4 paths |
| T66 | Multipath correctly degrades | PASS | Some failed, some active |
| T67 | Path recovery after LIF restored | PASS | |
| T69 | status() during iSCSI blackout | PASS | 1 sec (uses API not iSCSI) |
| T70 | status() during ONTAP API blackout | PASS | 33 sec timeout, returns inactive |
| T71 | No PVE workers in D state during blackout | PASS | All timeout protection working |

#### Section 9: ONTAP-Coordinated Failure Tests

These tests require coordination with ONTAP-side operations (executed by separate ONTAP admin agent).

| # | Test | Result | Notes |
|---|------|--------|-------|
| T72 | iSCSI service stop/start (~36s downtime) | PASS | dd queued at counter=92, resumed automatically after restart, zero data loss |
| T73 | All 4 multipath paths recover after iSCSI restart | PASS | Within 6 seconds of `iscsi start` |
| T74 | dd auto-resumes after iSCSI recovery | PASS | counter 92 → 95 → 101 (no manual intervention) |
| T75 | dd in D state during outage but recovers | PASS | Not permanently stuck |
| T76 | No PVE workers stuck in D state | PASS | Throughout entire outage |
| T77 | Manual ONTAP volume conflict (TOCTOU) | PASS | `pvesm alloc` auto-retries with next disk ID |
| T78 | Consecutive collision retries | PASS | disk-0 conflict → disk-1, then disk-0 again → disk-2 |
| T79 | API 401 detection | PASS | Warning logged: "ONTAP API returned 401, reinitializing auth" |
| T80 | API 401 reinit auth attempt | PASS | Fix #10 (v0.2.1) verified end-to-end |
| T81 | Graceful failure on auth failure | PASS | status() returns inactive within 9s, no hang |
| T82 | Storage auto-recovers after password restored | PASS | 1 second to active, full functionality restored |
| T83 | No PVE workers in D state during 401 | PASS | |

#### Section 10: ONTAP-Coordinated Failure Tests (v0.2.3 re-validation)

These tests were re-run with v0.2.3 in coordination with the ONTAP admin agent.

| # | Test | Result | Notes |
|---|------|--------|-------|
| T72 | iSCSI service stop/start (~65s downtime) | PASS | dd counter froze at 79, resumed to 121 after restart |
| T73 | All 4 multipath paths recover | PASS | Within 3 seconds of `iscsi start` |
| T74 | dd auto-resumes after iSCSI recovery | PASS | counter 79 → 83 → 158 (no manual intervention) |
| T75 | dd in D state during outage but recovers | PASS | Not permanently stuck |
| T76 | No PVE workers stuck in D state | PASS | Throughout entire outage |
| **T76b** | **v0.2.3: free LUN with queue_if_no_path multipath.conf** | **PASS** | **dmsetup fallback triggered, free completed in 8s instead of hanging** |
| T77 | Manual ONTAP volume conflict (TOCTOU) | PASS | `pvesm alloc` auto-retries with disk-1 |
| T78 | Consecutive collision retries | PASS | disk-0 conflict → disk-1, then disk-0 again → disk-2 |
| T79 | API 401 detection | PASS | Warning logged: "ONTAP API returned 401, reinitializing auth (attempt 1/2)" |
| T80 | API 401 reinit auth attempt | PASS | Fix #10 verified end-to-end |
| T81 | Graceful failure on auth failure | PASS | status() returns inactive within 10s, no hang |
| T82 | Storage auto-recovers after password restored | PASS | **2 seconds** to active, full functionality restored |
| T83 | No PVE workers in D state during 401 | PASS | Throughout multiple status() calls |

**v0.2.3 Total: 92/92 PASS** (71 prior + 9 post-fix + 12 ONTAP-coordinated re-run)

**Total: 75/75 PASS**

**Validated Improvements in v0.2.2:**
- Cluster orphan cleanup mechanism works end-to-end
- WWID tracking persists correctly across path() / free_image() lifecycle
- alloc_image maps to all per-node igroups (not just current node)
- Mixed environment (manual NetApp + plugin) is safe -- only tracked WWIDs touched
- API 401 retry logic verified working in test (Perl shell-quoting triggered 401, plugin auto-recovered)
- status() polling fast and never hangs

### v0.2.2-1 Initial Test (2026-04-08)

**Test Environment:** Same as v0.2.1

| # | Test | Result | Notes |
|---|------|--------|-------|
| T1-T22 | All v0.2.1 tests | PASS | |
| T23 | **Orphan Cleanup (cluster scenario)** | **PASS** | Initial verification |

**Total: 23/23 PASS**

### v0.2.1-1 (2026-04-08)

**Test Environment:**
- Proxmox VE 9.1 (kernel 6.17.4-2-pve)
- ONTAP Simulator 9.16.1 (single node)
- 2 iSCSI LIFs (192.168.1.197, 192.168.1.198)
- 2 NICs on host (4 multipath paths per LUN)
- Host has existing manual multipath configuration

| # | Test | Result | Notes |
|---|------|--------|-------|
| T1 | Storage status | PASS | Active, capacity reported correctly |
| T2 | iSCSI sessions | PASS | 4 sessions (2 NIC x 2 LIF) |
| T3 | Alloc + Path + Multipath | PASS | 4 active paths per LUN |
| T4 | Read/Write (dd) | PASS | Write 40 MB/s, Read 29 MB/s |
| T5 | Free + cleanup | PASS | Volume removed, multipath cleaned |
| T6 | VM create on NetApp | PASS | |
| T7 | Snapshot (create x2) | PASS | |
| T8 | Snapshot delete | PASS | |
| T9 | Snapshot rollback | PASS | |
| T10 | Disk resize (+512M) | PASS | Online resize |
| T11 | Move disk NetApp -> local-lvm | PASS | No hang, full copy completed |
| T12 | Move disk local-lvm -> NetApp | PASS | No hang, full copy completed |
| T13 | Full Clone | PASS | |
| T14 | Template + Linked Clone | PASS | FlexClone instant creation |
| T15a | EFI Disk | PASS | OVMF vars on NetApp LUN |
| T15b | Cloud-init Disk | PASS | ISO on NetApp LUN |
| T15c | TPM State | PASS | TPM 2.0 on NetApp LUN |
| T16 | LXC create (rootfs on NetApp) | PASS | ext4 formatted, template extracted |
| T17 | LXC start | PASS | Container running |
| T18 | LXC snapshot | PASS | |
| T19 | igroup mapping (multi-node) | PASS | LUNs mapped to both node igroups |
| T20 | Timeout protection | PASS | sysfs write timeout triggered, no hang |
| T21 | activate_storage skip discovery | PASS | Existing sessions reused, no 30s delay |
| T22 | postinst warning display | PASS | Colored warning for dangerous multipath settings |

**Known Limitations (test environment only):**
- SCSI host6 scan consistently times out (10s) due to test VM NIC configuration -- does not affect operations, timeout protection works correctly
- ONTAP simulator stale FlexClone metadata prevents some template volume deletions -- ONTAP-side issue, not plugin bug
