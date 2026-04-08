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
