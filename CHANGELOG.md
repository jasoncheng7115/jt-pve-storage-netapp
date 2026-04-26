# Changelog

All notable changes to the NetApp ONTAP Storage Plugin for Proxmox VE are documented here.

## [0.2.9] - 2026-04-25

### ASA Eventual Consistency Fix Release

**Bug Fix:**

- **Fixed `lun_map()` failing with "LUN not found" on NetApp ASA systems.** After `lun_create()` successfully creates a LUN via POST, `lun_map()` immediately queries the LUN UUID via GET. On NetApp ASA (All-SAN Array) systems under load, the LUN may not be immediately visible due to ONTAP internal propagation delay (eventual consistency). `lun_map()` now retries the UUID lookup up to 5 times with 1-second intervals before failing. This fixes intermittent "storage migration failed: Failed to map LUN" errors during move-disk, clone, and alloc operations. The fix is in `API.pm lun_map()`, so all callers benefit automatically: `alloc_image()`, `clone_image()`, `activate_volume()`, and `_ensure_temp_clone()`.

## [0.2.8] - 2026-04-11

### Code Review Fix Release

**Bug Fixes (from automated code review):**

- **Fixed orphan cleanup unconditionally untracking WWIDs.** `_cleanup_orphaned_devices()` previously called `_untrack_wwid()` after `cleanup_lun_devices()` regardless of whether the device was actually removed. Now mirrors `free_image()` logic: only untracks if `get_multipath_device()` confirms the device is gone. Prevents permanently orphaned devices when cleanup partially fails (e.g. kpartx holders blocking multipath -f).

- **Fixed `alloc_image()` TOCTOU race retry.** The `volume_create()` race handler was single-shot (one retry). Now uses a proper bounded retry loop (max 5 iterations) matching `clone_image()` pattern. Multiple concurrent `alloc_image()` calls on the same VM no longer fail after the first collision.

- **Removed all `multipath -F` (capital F) recommendations** from code and documentation. `deactivate_storage()` API-unreachable warning no longer suggests `multipath -F`. Documentation (CONFIGURATION.md, README.md, both zh-TW) no longer recommends it as a cleanup command. Only per-WWID cleanup (`multipath -f <wwid>`) is recommended. All existing warnings about the dangers of `-F` are preserved.

- **Fixed bare `glob()` without alarm timeout** in `ISCSI.pm get_device_by_serial()`. The `/dev/disk/by-id/` glob call is now wrapped in `alarm(5)` per anti-hang rules, matching all other glob calls in the codebase.

## [0.2.7] - 2026-04-11

### kpartx Partition Holder Fix Release (CRITICAL)

**Critical Fix:**

- **Fixed `is_device_in_use()` blocking ALL volume deletions on systems with kpartx partition scanning.** The kernel's partition scanner auto-creates partition dm devices (e.g. `<wwid>-part1`) on multipath LUNs when it detects a partition table inside a VM disk. These passive artifacts were treated as "real" holders, blocking every `free_image()` call. Now `is_device_in_use()` checks if ALL holders are bare kpartx partitions with no sub-holders; if so, they are safely ignored. Partitions with sub-holders (e.g. host LVM VG on a partition) still correctly block deletion.

- **Added `kpartx -d` cleanup step** in `cleanup_lun_devices()` to remove partition devices before multipath flush.

- **Fixed `get_device_usage_details()` misinterpreting partition dm-names** (e.g. `3600a...d33-part1`) as LVM VG names.

## [0.2.6] - 2026-04-10

### Postinst Service Reload + Operator UX Release

**Operator UX -- Detailed `is_device_in_use` Error Messages:**

- **`free_image()` now shows full diagnostics when deletion is blocked.** Previously showed generic `device is still in use (mounted, has holders, or open by process)`. Now shows: exact holder device names and dm-names (e.g. `/dev/dm-10 (checktc--vg-root)`), auto-detected LVM VG name(s), root cause explanation (host LVM auto-activation of guest VGs, common on PVE 7->8->9 upgrades with stale `lvm.conf` `global_filter`), exact fix command (`vgchange -an <vg>`), and long-term `global_filter` suggestion. For mount and fuser checks, also shows mount point or process details.

**Orphan Warning Cooldown:**

- **Reduced orphan detection warning noise from every 10 seconds to once per hour per device.** `pvestatd` polls `status()` every 10 seconds, and each poll ran orphan detection which warned about any untracked NETAPP multipath devices. On systems with customer-managed NetApp LUNs (not plugin-managed), this produced identical warnings every 10 seconds, flooding the journal. Now uses a per-WWID cooldown flag in `/var/run/pve-storage-netapp/` (tmpfs, cleared on reboot so warnings fire again after reboot).

**Postinst -- `lvm.conf` `global_filter` Detection:**

- **Postinst now checks if `/etc/lvm/lvm.conf` has a `global_filter` setting.** If absent, displays a prominent warning explaining that host-level LVM will auto-activate VGs found inside VM disks on plugin-managed LUNs, causing `is_device_in_use()` to block volume deletion and `move-disk` source cleanup. Shows recommended `global_filter` setting. This is the most common root cause of `Cannot delete volume: device is still in use` errors on PVE nodes upgraded from 7->8->9.

**Postinst Fixes:**

- **Added `pvestatd` to the postinst service reload list.** Previous versions only restarted `pvedaemon` and `pveproxy`, leaving `pvestatd` running with old plugin code in memory. `pvestatd` polls `status()` every 10 seconds; with old code it continued creating D-state children from the pre-v0.2.5 `rescan_scsi_hosts()` that wrote to non-iSCSI hosts. On the customer's HPE ProLiant (same node as the v0.2.5 incident), this caused **permanent D-state accumulation even after v0.2.5 was installed**, eventually triggering an iLO hardware watchdog reboot. Now all three PVE services (`pvedaemon`, `pvestatd`, `pveproxy`) are reloaded.

- **Changed postinst from `systemctl restart` to `systemctl reload` (SIGHUP).** PVE::Daemon handles SIGHUP by re-exec'ing itself with the same PID, picking up new Perl modules from disk without going through a stop phase. This avoids the bootstrapping problem where the OLD code has already created D-state children (unkillable by SIGKILL), and `systemctl restart` hangs waiting for them during the stop phase. With reload, no stop is needed -- the process re-execs in-place and D-state orphans are inherited by init.

- **If a service is not running at install time**, postinst uses `systemctl start` instead of reload (reload requires an active service).

**Production finding:** smartpqi D-state children on the customer's HPE P408i-a lasted **4+ hours** without any timeout. The kernel `hung_task_timeout_secs` warning fires at 120s but does NOT kill D-state processes. These children are effectively immortal until reboot. Any upgrade path that leaves any PVE service running old code while new code is installed creates a window where old rescan behavior generates new permanent D-state children. The `reload` approach eliminates this window entirely.

## [0.2.5] - 2026-04-10

### Non-iSCSI SCSI Host Scan Fix Release (CRITICAL)

**Critical Bug Fix (production incident on HPE ProLiant):**

- **Fixed `rescan_scsi_hosts()` and `rescan_fc_hosts()` writing to non-iSCSI / non-FC hosts.** Both functions iterated all entries in `/sys/class/scsi_host/` and wrote `"- - -"` to every `hostN/scan` file. This included non-iSCSI / non-FC hosts like HBA RAID controllers, USB card readers, virtio-scsi, etc. Writing to a non-iSCSI host's scan file triggers a driver-side full target rescan which can hang for hundreds of seconds inside some drivers.

  **Observed production symptom** on an HPE ProLiant server with `smartpqi` driver (P408i-a controller): writes to `host1/scan` entered D-state for 10+ minutes in `sas_user_scan`, serializing every subsequent process that touched `/sys/class/scsi_host/host1`. This cascaded into:
  - pvedaemon workers unable to release VM config locks, causing repeated `trying to acquire lock... got timeout` errors on VM operations
  - pvestatd unable to complete `status()` polls
  - `pvedaemon` restart hanging indefinitely during `dpkg --configure`, making plugin upgrades silently fail
  - VM operations (move-disk, resize, config update, boot order change) intermittently hanging even on working-path storage

  The `sysfs_write_with_timeout()` protection added in v0.2.0 kept the parent process alive (10s timeout), but the child process was stuck in D-state (uninterruptible sleep) pinning the kernel's scan lock for host1. `SIGKILL` cannot reap D-state processes, so the lock persisted until the kernel driver's own timeout expired (~10 minutes), by which time the next PVE operation had already queued up behind it and the cycle repeated.

- **Fix:** `rescan_scsi_hosts()` now sources the host list from `/sys/class/iscsi_host/` (maintained by the kernel's `scsi_transport_iscsi` layer). Every iSCSI SCSI host registers there regardless of underlying driver (`iscsi_tcp`, `iser`, `bnx2i`, `qla4xxx`, `qedi`, `be2iscsi`, `cxgb3i`, `cxgb4i`, and any future iSCSI driver via `iscsi_host_alloc()`). Non-iSCSI hosts are categorically absent from that class, so iteration is both exhaustive and safe. **Future-proof**: new iSCSI drivers added to the kernel are picked up automatically without plugin code changes.

- **Fix:** `rescan_fc_hosts()` in `FC.pm` had the same bug in its post-LIP SCSI scan loop. Now only iterates FC hosts from `/sys/class/fc_host/` (already enumerated via `get_fc_hosts()`).

**Architectural lesson:**
This bug existed since v0.1.0. Previous releases protected the parent process from hanging but did not prevent the write from reaching the kernel. The correct fix is not to write to non-iSCSI hosts at all -- they are categorically irrelevant to plugin-managed iSCSI LUNs.

## [0.2.4] - 2026-04-09

### Cleanup Path Hardening + Concurrency + Operator UX Release

**Concurrency Fixes:**

- **Fixed `clone_image()` disk-id TOCTOU race (HIGH).** The previous code did a `volume_get` pre-check to find a free disk ID, then called `volume_clone()` outside the loop. Two parallel `clone_image()` calls on the same VM (e.g. concurrent template clones from different cluster nodes, or any path that bypasses PVE's storage cfs lock) would both pass the pre-check with the same disk ID, race on `volume_clone`, and the loser would die with "already exists". Now `volume_clone` is inside the retry loop, and "already exists" errors trigger retry with the next disk ID. Same fix pattern as the v0.2.1 `alloc_image` TOCTOU fix, just applied to the function it was missed in.

- **Fixed temporary FlexClone (snapshot read-access) TOCTOU race in `_ensure_temp_clone()` (MEDIUM).** Temp clone names are deterministic from volume+snap, so two parallel `path()` callers reading the same snapshot (e.g. concurrent qmrestore + qm clone --full from a snapshot) would race on `volume_clone`. The loser used to die. Now treats "already exists" as success since the temp clone is shared and reusable.

**Operator UX:**

- **Added `_translate_limit_error()` helper that detects common ONTAP resource-limit errors and prepends operator-friendly summaries.** Patterns covered: FlexVol count cap (per-SVM and per-node), SVM/cluster LUN cap, igroup LUN-map cap (default 4096 per igroup, hit faster in per-node mode), aggregate full (covers thin overcommit case), SVM quota exceeded. Applied to all `alloc_image` and `clone_image` die sites. Operators now see `ONTAP FlexVol limit reached on this SVM/node. This plugin uses 1 FlexVol per VM disk; you may have hit the SVM volume cap (default ~12000) ...` instead of raw ONTAP REST API error codes.

**Production Audit Fixes:**

- **Fixed `clone_image()` cleanup missing `lun_unmap_all()` (HIGH).** Same bug pattern as the `alloc_image()` fix in v0.2.1, but the equivalent fix was missed in `clone_image()`. When `lun_map()` failed partway through (e.g. mapped to some node igroups but failed on others in per-node mode), cleanup attempted `volume_delete` on a still-mapped LUN. ONTAP rejects this, leaving orphaned igroup mappings AND ghost LUNs visible to other cluster nodes. Those ghost LUNs then become stale multipath devices that can hang any process touching them -- the same root cause as the v0.2.3 customer node hang. Both cleanup branches in `clone_image()` (the `unless ($lun)` branch and the `lun_map` failure branch) now call `lun_unmap_all` before `volume_delete`.

- **Added pre-snapshot host-side buffer flush in `volume_snapshot()` (LOW).** For running VMs, qemu's freeze handles consistency at the filesystem layer. But for offline volumes or external script callers, dirty page cache was not flushed before `snapshot_create`, potentially producing filesystem-inconsistent snapshots. The new flush mirrors what `volume_snapshot_rollback()` already does: `is_device_in_use` check, then `sync` and `blockdev --flushbufs` with timeouts. Skips entirely if device is in use by another process (live migration safety).

- **Removed dead code: `get_multipath_wwid()` in `Multipath.pm` (LOW).** The function was exported but had zero callers across the codebase. Worse, it used `basename()` without symlink resolution -- a latent footgun for any future caller that passed `/dev/mapper/<wwid>`. Same bug class as the v0.2.3 `is_device_in_use` data loss bug. Safer to delete than to leave as a trap.

**Background:**
After the v0.2.3 customer incident (qm resize hang + latent `is_device_in_use` data loss bug), a full audit was done across the plugin looking for similar bug patterns: (1) cleanup paths that call `volume_delete` without first unmapping the LUN, and (2) functions that use `basename()` on a device path before accessing `/sys/block/`. Three more issues were found and fixed in this release.

## [0.2.3] - 2026-04-09

### Pre-Upgrade Stale Device Handling Release (CRITICAL)

**Critical Fixes for Production Upgrade Scenarios:**
- Fixed orphan cleanup not handling pre-upgrade stale multipath devices. v0.2.2 only cleaned WWIDs that `path()` was called on AFTER upgrade. Stale devices left over from earlier plugin versions (v0.1.x) were never tracked and could not be cleaned automatically. v0.2.3 now auto-imports current ONTAP `pve_*` LUN WWIDs into the tracking file on every `status()` poll, ensuring all cluster nodes converge to a consistent view regardless of when `path()` was last called locally.

**Multipath Hang Prevention (CRITICAL):**
- Fixed `cleanup_lun_devices()` hanging on multipath devices with `queue_if_no_path` enabled. Now disables queueing via `multipathd disablequeueing map` and `dmsetup message ... fail_if_no_path` BEFORE attempting any sync/flush, so I/O fails fast instead of queueing forever.
- Added timeout (10s) to all `multipath_flush()` and `multipath_reload()` operations.
- Fallback to `dmsetup remove --force --retry` if `multipath -f` times out, bypassing the multipath flush logic that hangs on dead devices.
- Added timeout (10s) to `multipathd remove map` calls.

**Postinst Stale Device Detection:**
- Postinst now scans for NETAPP multipath devices with all paths failed and displays a prominent warning listing the WWIDs and exact commands to clean them. Does NOT auto-clean to avoid touching manually-managed storage. Especially important when upgrading from v0.1.x or v0.2.0/1 which left orphans without tracking them.

**CRITICAL Symlink Resolution Fix (DATA LOSS PREVENTION):**
- Added `_resolve_block_device_name()` helper that resolves `/dev/mapper/<wwid>` symlinks to the underlying `dm-N` kernel name. Required for any `/sys/block/` access on multipath device paths.
- Fixed `is_device_in_use()` to use the helper. Previously, calling `is_device_in_use('/dev/mapper/<wwid>')` would do `basename()` to get the WWID, then look in `/sys/block/<wwid>/holders/` which doesn't exist. Result: LVM and other holders on multipath devices were silently missed, and `free_image()` would happily delete in-use volumes -- **DATA LOSS RISK**. This affects any environment with LVM / dm-crypt / etc on top of NetApp multipath devices.
- Fixed `get_multipath_slaves()` to use the helper. Previously the slave list was empty for `/dev/mapper/<wwid>` paths, breaking `volume_resize` and any other operation that needed to enumerate paths.

**Snapshot Rollback Fix:**
- `volume_snapshot_rollback()` now uses per-device rescan instead of host scan, and adds post-rollback kernel buffer cache invalidation. Without cache invalidation, reads after rollback could return stale cached data from before the rollback.

**Critical Resize Fix:**
- Fixed `volume_resize()` using `rescan_scsi_hosts()` (host scan) instead of per-device rescan. Host scan is for discovering NEW devices and does NOT trigger re-reading the size of existing devices. Result: after resizing the LUN on ONTAP, the kernel still saw the old size and QEMU's `block_resize` would fail with "Cannot grow device files". Additionally, host scan can hang on unresponsive iSCSI hosts.
- `volume_resize()` now correctly:
  1. Iterates over the multipath device's SCSI slaves
  2. Calls `echo 1 > /sys/block/sdX/device/rescan` on each (with timeout)
  3. Calls `multipathd resize map <name>` to refresh multipath size

**Slow Operation Support:**
- `volume_delete()` now uses an extended 60s API timeout (was 15s). FlexClone deletion can take 30+ seconds on ONTAP, especially when cleaning up snapshot dependencies. The 15s default caused spurious "command timed out" warnings even though the operation eventually succeeded via the retry loop.
- `_request()` now supports per-call timeout override.

**Background:**
Customer environment hit a node hang during disk migration when `vgs` scanned a stale multipath device that had `queue_if_no_path` enabled. The stale device was left over from earlier plugin versions and was never tracked by v0.2.2's orphan cleanup mechanism. Result: `vgs` entered D state, `pvedaemon` hung waiting for it, and `systemctl restart` also hung. Recovery required reboot. v0.2.3 prevents this by:
1. Auto-importing alive WWIDs so cluster nodes know about ALL LUNs
2. Disabling `queue_if_no_path` before any cleanup operation
3. Warning at install time about pre-existing stale devices

## [0.2.2] - 2026-04-08

### Cluster Orphan Device Cleanup Release

**Critical Cluster Fix:**
- Fixed stale multipath devices remaining on cluster nodes after a VM disk is deleted on a different node. Previously, when Node A removed a VM, Node B's local SCSI/multipath devices for that LUN became orphaned and could persist indefinitely (showing all paths in failed state). If multipath.conf used the **dangerous** `no_path_retry queue` setting (which should be changed to `no_path_retry 30`, see [README.md](README.md#critical-multipath-safety-rules)), any process touching the orphaned device could hang the entire node. v0.2.2 automatically cleans orphans, making the system safer regardless of `no_path_retry` setting.

**New Feature: Automatic Orphan Device Cleanup**
- Added per-storage WWID tracking state file at `/var/lib/pve-storage-netapp/<storeid>-wwids.json`. Each node records WWIDs it has seen for this storage.
- `path()` now tracks WWIDs after successfully resolving a real device.
- `free_image()` untracks WWIDs after successful LUN deletion.
- `status()` runs orphan cleanup in a background fork on every poll. It compares tracked WWIDs against the current ONTAP LUN list and cleans up local devices for any tracked WWIDs that no longer exist on ONTAP.
- **Safety:** only WWIDs in the tracking file are eligible for cleanup, so manually-managed NetApp devices and devices from other plugins are never affected.
- If the ONTAP API is unreachable during cleanup, the operation aborts to avoid false positives that could remove valid devices.

**Concurrency Fixes (post-review):**
- Added file locking (`flock`) to WWID tracking state file to prevent race conditions when multiple PVE workers concurrently call `path()` for different volumes (e.g., parallel VM allocation).
- Atomic write via temp file + rename for WWID state persistence.
- Changed `status()` background cleanup to double-fork pattern to prevent zombie process accumulation in long-running `pvedaemon` (grandchild is reparented to init and reaped automatically).

**Documentation:**
- Updated postinst warning to recommend `systemctl restart multipathd` instead of `reload` (reload does not flush stale maps).
- Updated `docs/CONFIGURATION.md` to explain reload vs restart behavior.

**Test Coverage Expanded to 63 tests:**
- Added Section 7: PVE workflow tests (VM start, hot-plug/unplug, vzdump backup, qmrestore, multi-disk VM, vmstate RAM snapshot)
- Added Section 8: Failure scenarios (single LIF failure, total iSCSI blackout, ONTAP API blackout, D-state verification)
- All 63 tests PASS

## [0.2.1] - 2026-04-08

### Production Hardening Release - Edge Case & Race Condition Fixes

**Race Condition Fixes:**
- Fixed `alloc_image()` disk ID TOCTOU race: if `volume_create` fails due to concurrent allocation, retries with next disk ID instead of dying.
- Fixed igroup creation race when multiple cluster nodes activate storage simultaneously. `igroup_get_or_create()` now handles 409 Conflict gracefully.
- Fixed `_ensure_igroup()` to handle concurrent initiator add operations from multiple nodes without failing.

**Multipath Safety (prevents node hang on stale devices):**
- Changed multipath.conf template: replaced `queue_if_no_path` (infinite queue) with `no_path_retry 30` (bounded 150-second retry). Prevents PVE node from hanging indefinitely when LUN paths fail or stale devices remain.
- Changed `dev_loss_tmo` from `infinity` to `60` seconds. SCSI devices for failed LUNs are now removed after 60s instead of kept forever.
- Added `fast_io_fail_tmo 5` for faster path failure detection.
- Existing installations with manual multipath.conf will see a prominent warning during upgrade with recommended changes.

**Stale Device Prevention:**
- Fixed `free_image()` operation order: now unmaps LUN from igroups BEFORE cleaning local SCSI devices, preventing iSCSI session rescans from re-discovering removed LUNs as ghost devices that generate I/O errors.
- Pre-captures multipath slave device list before unmap, ensuring all SCSI paths are cleaned even if multipath map disappears after unmap.
- Final multipath reload after cleanup to flush any residual stale maps.

**Migration Safety:**
- `deactivate_volume()` now skips sync/flush if device is still in use by another process, preventing I/O deadlock during live migration.
- `deactivate_volume()` fails gracefully if API is unreachable.

**Cleanup & Reliability:**
- `alloc_image()` cleanup now calls `lun_unmap_all()` before `lun_delete()` on failure, preventing orphaned igroup mappings on ONTAP.
- Improved error message for disk ID exhaustion to suggest checking for manually created volumes or orphaned volumes.

**Performance:**
- `list_images()` template detection now has 10-second deadline to prevent cascading API timeouts when many volumes exist on ONTAP.
- Non-disk volumes (state, cloudinit) are skipped during template detection.
- Skip iSCSI discovery for portals that already have active sessions, preventing 30-second discovery timeout during repeated storage activation (e.g., linked clone operations).

**Thin Provisioning Safety:**
- Added aggregate space warning when usage exceeds 85% during `alloc_image()` with thin provisioning enabled, alerting operators before overcommit.

**iSCSI Session Recovery:**
- `login_target()` now sets `node.session.timeo.replacement_timeout=120` for automatic session recovery after ONTAP failover/takeover events.

**API Resilience:**
- API client now retries on HTTP 401 with fresh authentication, handling session expiry during long-running operations.

## [0.2.0] - 2026-04-07

### Multipath & Migration Fix Release - Anti-Hang Protection

**Critical Bug Fixes:**
- Fixed iSCSI multipath only establishing 1 session instead of all portals. `login_target()` checked `is_target_logged_in()` by IQN only; all ONTAP LIFs share the same IQN, so after the first portal login all others were skipped. Added `is_portal_logged_in()` to check portal+target pair individually.
- Fixed `alloc_image()` only mapping LUN to current node's igroup in per-node mode. Disk migration (move_disk) would hang because the destination node could not see the new LUN. Now maps to all node igroups, consistent with `clone_image()` behavior.

**Anti-Hang Protection (prevents unkillable PVE task workers):**
- Added `sysfs_write_with_timeout()`: all writes to `/sys/` files (SCSI host scan, device delete, device rescan, FC issue_lip) now execute in a forked child process with 10-second timeout.
- Added `sysfs_read_with_timeout()`: all reads from `/sys/` and `/proc/` files (device WWID, VPD pages, mount table, FC port attributes) now execute in a forked child with 5-second timeout.
- Replaced all bare `system()` calls with timeout-protected alternatives.
- `flock(LOCK_EX)` on temp clone state file changed to non-blocking `LOCK_NB` with 10-second retry loop.
- FC.pm `_read_file()` now uses `sysfs_read_with_timeout()` for all sysfs reads.

**Migration Reliability:**
- Fixed `activate_volume()` only mapping LUN to current node's igroup.
- Fixed `path()` returning synthetic non-existent device path after a single failed rescan. Now retries with a proper wait loop (up to `ontap-device-timeout`, default 30s).

**ONTAP Failure Resilience:**
- Reduced API timeout from 30s to 15s and retries from 3 to 2, cutting worst-case API call blocking from ~102s to ~34s.
- `status()` now fails fast if API is unreachable instead of blocking PVE.
- Temp FlexClone cleanup in `status()` moved to background fork.

**New Features:**
- LXC container (rootdir) support
- EFI Disk, Cloud-init Disk, TPM State disk support

## [0.1.9] - 2026-02-27

### Safety Audit Release - Security & Reliability Fixes

**Critical Security Fixes:**
- Fixed command injection vulnerability in `Multipath.pm is_device_in_use()`
- Fixed IPC::Open3 deadlock in `_run_cmd()` (both ISCSI.pm and Multipath.pm)
- Fixed zombie processes on `_run_cmd()` timeout

**Data Integrity Fixes:**
- Snapshot rollback now checks device in-use status and flushes buffers before ONTAP rollback
- Removed unsafe WWID substring matching in `get_multipath_device()`
- Fixed clone_image disk ID race condition
- Fixed glob() metacharacter injection in device serial lookups

**Reliability Improvements:**
- Temp clone state file now uses `flock()` for concurrent access safety
- `activate_storage` detects and reports portal connection failures
- `list_images` wraps per-volume `snapshot_get` in eval
- Online resize support (removed VM-must-be-stopped restriction)

## [0.1.8] - 2026-02-12

### Bug Fix Release - FC SAN & General Fixes

- Fixed `is_fc_available()` always returning true
- Added missing `lun_unmap_all()` method in API.pm
- Fixed `deactivate_storage` `logout_target()` wrong parameters
- `clone_image` now filters igroups by protocol type
- Eliminated redundant SCSI host rescans in FC paths

## [0.1.7] - 2026-01-25

### RAM Snapshot (vmstate) Support Release

- Full support for VM snapshots with RAM state ("Include RAM" option)
- Automatic multipath configuration on install
- Automatic PVE service restart on install
- Storage deactivation cleanup improvements
- Added README_zh-TW.md (Traditional Chinese)
- License changed to MIT

## [0.1.6] - 2026-01-24

### Full Clone Support Release

- Full Clone from VM Snapshot (via temporary FlexClone + qemu-img)
- Full Clone from Current State
- Automatic cleanup of temporary FlexClones (1 hour expiry)
- Linked Clone from template stays space-efficient (no auto-split)
- Storage deactivation with proper iSCSI session cleanup

## [0.1.5] - 2026-01-03

### Template Support Release

- Full Template Support (create_base, rename_volume)
- `list_images` correctly identifies template volumes (base-XXX-disk-X)
- `path()` handles missing LUNs gracefully (synthetic path for cleanup)

## [0.1.4] - 2026-01-03

### FC SAN Support Release

- Fibre Channel (FC) SAN protocol support
- New FC.pm module (WWPN discovery, LIP rescan)
- Batch LUN query in `list_images` for performance
- Configurable device discovery timeout (`ontap-device-timeout`)

## [0.1.3] - 2026-01-03

### FlexClone Support Release

- Linked Clone via NetApp FlexClone (instant, space-efficient)
- Prevention of template deletion with clone children
- Fixed `path()` causing system hangs when device not accessible
- Volume autogrow enabled, reduced overhead to 64MB

## [0.1.2] - 2026-01-02

### Bug Fix & Dependency Release

- Enabled volume autogrow
- Added psmisc dependency (fuser command)

## [0.1.1] - 2026-01-02

### Safety Improvements Release

- Shrink protection, in-use device check, collision detection
- API cache TTL (5 minutes)
- Fixed taint mode compatibility for PVE

## [0.1.0] - 2026-01-02

### Initial Release

- FlexVol and LUN creation
- igroup management
- iSCSI discovery and login
- Multipath device handling
- Snapshot operations (create, delete, rollback)
- Real-time storage status from ONTAP
