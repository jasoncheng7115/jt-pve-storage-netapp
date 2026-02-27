# Changelog

All notable changes to this project will be documented in this file.

## [0.1.9-1] - 2026-02-27

### Safety Audit Release - Security & Reliability Fixes

**Critical Security Fixes:**
- Fixed command injection vulnerability in Multipath.pm `is_device_in_use()` (shell-form `system()` replaced with list-form, device path untainted)
- Fixed IPC::Open3 deadlock in both ISCSI.pm and Multipath.pm `_run_cmd()` (sequential read replaced with IO::Select non-blocking I/O)
- Fixed zombie processes on `_run_cmd()` timeout (child process now killed)
- Fixed `$@` clobbering in `alloc_image` error paths (cleanup eval overwrote original error message)

**Data Integrity Fixes:**
- Snapshot rollback now checks device in-use status and flushes buffers before ONTAP rollback to prevent data corruption
- Removed unsafe WWID substring matching in `get_multipath_device()` that could return wrong device on partial WWID collisions
- Fixed `clone_image` disk ID race condition with retry loop and ONTAP volume existence check
- Fixed `glob()` metacharacter injection in device serial lookups (ISCSI.pm `wait_for_device`, `get_device_by_serial`, Multipath.pm `get_device_by_wwid`)
- Fixed regex injection in `_find_multipath_device()` serial matching

**Reliability Improvements:**
- Temp clone state file now uses `flock()` for concurrent access safety
- `activate_storage` now detects and reports portal connection failures instead of silently continuing
- `list_images` wraps per-volume `snapshot_get` in eval to prevent one volume failure from breaking entire listing
- `lun_unmap_all` collects all errors and warns instead of dying on first
- `free_image` now warns on LUN delete failure instead of silently ignoring
- `deactivate_volume` checks sync/flushbufs return codes
- FC rescan adds proper error handling on open/opendir calls

**Online Resize Support:**
- `volume_resize` now supports online resize (removed VM-must-be-stopped restriction), uses 64MB overhead, triggers device rescan when running

**Other Changes:**
- Renamed `SG_INVERT` constant to `SG_INQ` in Multipath.pm

**Documentation:**
- README_zh-TW.md synced with English README (added Module Architecture, PVE Version Upgrade Compatibility, additional Troubleshooting sections)
- Updated disk resize documentation to reflect online resize support

## [0.1.8-1] - 2026-02-12

### Bug Fix Release - FC SAN & General Fixes

**Critical Bug Fixes:**
- Fixed `is_fc_available()` always returning true when `/sys/class/fc_host` exists but no valid FC HBA present (arrayref vs array comparison)
- Added missing `lun_unmap_all()` method in API.pm - temporary FlexClone LUN mappings were never cleaned up, causing ONTAP mapping accumulation
- Fixed `deactivate_storage` `logout_target()` call passing wrong parameters (hashref instead of address/target args), iSCSI target logout was silently failing on storage deactivation

**FC SAN Improvements:**
- `clone_image` now filters igroups by protocol type, preventing cross-protocol LUN mapping errors in mixed FC/iSCSI environments
- Eliminated redundant SCSI host rescans in FC paths - `rescan_fc_hosts()` already includes SCSI host scanning internally

**Code Quality:**
- Removed shadowed `$protocol` variable declaration in `_get_snapshot_path()`

## [0.1.7-1] - 2026-01-25

### RAM Snapshot (vmstate) Support Release

**New Features:**
- Full support for VM snapshots with RAM state ("Include RAM" option)
- Allocates `vm-{vmid}-state-{snapname}` volumes for RAM state storage
- Works with both iSCSI and FC protocols
- Automatic multipath configuration (postinst adds NetApp device config to `/etc/multipath.conf`)
- Automatic PVE service restart after installation

**Storage Removal Enhancement:**
- `deactivate_storage` cleans up only this storage's multipath devices
- Other storages' devices are not affected
- Properly flushes buffers and removes SCSI devices
- Handles ONTAP unreachable scenarios gracefully

**Documentation:**
- Added README_zh-TW.md (Traditional Chinese)
- Language switch links in both README files
- License changed to MIT

## [0.1.6-1] - 2026-01-24

### Full Clone Support Release

**New Features:**
- Full Clone from VM Snapshot (uses temporary FlexClone for snapshot data access)
- Full Clone from Current State (running or stopped VMs)
- Automatic cleanup of temporary FlexClones (1 hour expiry)
- State tracking in `/var/run/pve-storage-netapp-temp-clones.json`

**New API Methods:**
- `volume_is_splitting()`: Check if clone split is in progress
- `volume_wait_clone_split()`: Wait for clone split to complete

**Bug Fixes:**
- Fixed `list_images` incorrectly showing FlexClones as templates
- Fixed igroup name lookup in temp FlexClone creation
- Fixed `wait_for_multipath_device` parameter format
- Added retry logic for stale `has_flexclone` metadata during template deletion

**Storage Deactivation:**
- `deactivate_storage` now properly cleans up iSCSI sessions
- Flushes device buffers and removes multipath devices
- Safety check: skips cleanup for devices still in use

## [0.1.5-1] - 2025-01-03

### Template Support Release

**New Features:**
- Full Template Support (`create_base`, `rename_volume`, `find_free_diskname`)
- Uses `__pve_base__` snapshot as template marker

**Bug Fixes:**
- Fixed "storage definition has no path" error on template creation
- `list_images` now correctly identifies template volumes
- `path()` now handles missing LUNs gracefully (returns synthetic path for orphaned volumes)

## [0.1.4-1] - 2025-01-03

### FC SAN Support Release

**New Features:**
- Fibre Channel (FC) SAN Protocol Support (`ontap-protocol` option: iscsi|fc)
- Automatic FC HBA WWPN discovery from `/sys/class/fc_host`
- New Module: FC.pm

**Improvements:**
- Concurrent disk allocation retries with next available ID
- Aggregate validation on storage activation
- Configurable device discovery timeout (`ontap-device-timeout`)
- Batch LUN query in `list_images` (reduces API calls)

**Bug Fixes:**
- Fixed `path()` and `snapshot_rollback` to support FC protocol
- Fixed async job handling for DELETE and PATCH API calls
- Volume deletion now properly waits for ONTAP job completion

## [0.1.3-1] - 2025-01-03

### FlexClone Support Release

**New Features:**
- Linked Clone via NetApp FlexClone (instant, space-efficient)
- Automatic LUN identity for cloned volumes
- FlexClone license check with helpful error message

**Bug Fixes:**
- Fixed `path()` method causing system hangs when device not accessible
- Fixed prerm script hanging during upgrade (added 5s timeout)
- Fixed postinst script potential hang (added timeout for systemctl calls)

## [0.1.2-1] - 2025-01-02

### Bug Fix & Dependency Release

- Enabled volume autogrow (auto-expands when needed)
- Reduced initial overhead to 64MB (was 5GB)
- Added missing dependency: psmisc (provides `fuser` for device-in-use detection)

## [0.1.1-1] - 2025-01-02

### Safety Improvements Release

- Added shrink protection, in-use device check, collision detection
- Added API cache TTL (5 minutes)
- Fixed taint mode compatibility for PVE's qemu-img operations

## [0.1.0-1] - 2025-01-02

### Initial Release

- FlexVol and LUN creation
- igroup management
- iSCSI discovery and login
- Multipath device handling
- Snapshot operations (create, delete, rollback)
- Real-time storage capacity reporting from ONTAP
