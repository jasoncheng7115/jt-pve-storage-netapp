# Changelog

All notable changes to the NetApp ONTAP Storage Plugin for Proxmox VE are documented here.

## [0.2.28] - 2026-08-06

### Credentials: store `ontap-password` under `/etc/pve/priv/`, not in `storage.cfg`

`/etc/pve/storage.cfg` is mode `0640`, owner `root:www-data`, so anything written there is readable by `pveproxy`. Proxmox VE keeps storage secrets under `/etc/pve/priv/` (root-only) instead, via `plugindata()`'s `sensitive-properties` — but our key is `ontap-password`, and `PVE::Storage::Plugin::sensitive_properties()` falls back to a hardcoded list containing the bare name `password`, which does **not** match it. The secret therefore landed in `storage.cfg` verbatim.

The plugin now declares the property as sensitive, so Proxmox VE strips it from the parameters before writing the config and hands it to the hooks instead. It is stored at `/etc/pve/priv/storage/<storeid>.pw` (mode `0600`), the same location and mechanism used by Proxmox VE's own PBS and CIFS plugins.

`PBSPlugin` is the closest reference: same shape as this plugin — a password used to authenticate against an external REST service, read on the `status()` path — which also confirms the read always happens in a root context (every `API2/Storage/` endpoint that reaches a plugin is `protected => 1`, so it runs in `pvedaemon`, not in `pveproxy`).

### Bug fix: the ONTAP password could never be changed

`ontap-password` was declared `fixed => 1`. Proxmox VE drops fixed properties from the update schema **entirely** (`SectionConfig.pm`), so `pvesm set <storeid> --ontap-password ...` was rejected — the parameter was not even recognised — and the only way to change an ONTAP password was to remove and re-add the storage.

It is now `optional`. It cannot be declared required: Proxmox VE extracts a sensitive property from the parameters **before** `check_config()` runs, so a required declaration would fail validation on every add. `on_add_hook()` checks for a missing password instead and fails with an actionable message.

The API client cache now includes the password in its validity check, so a rotation takes effect on the next call instead of after the 5-minute cache TTL.

#### Existing storages are not affected and need no action

The read path prefers the priv file and **falls back** to the inline `ontap-password`, so a storage created before 0.2.28 keeps working exactly as before — on upgraded and not-yet-upgraded nodes alike. Verified against real storage definitions: the password read under the new code is identical to the one read before.

Unrelated configuration changes do not disturb it either. `extract_sensitive_params()` only extracts from the parameters passed in, never from the stored config, so `pvesm set <storeid> --content ...` (or any other option) leaves the inline password in place.

#### Migration is deliberately manual

There is **no automatic migration**. `/etc/pve/storage.cfg` and `/etc/pve/priv` are both cluster-wide, so removing the cleartext takes effect on every node at once, while a node still running an older plugin reads only the inline value. Migrating during a rolling upgrade would break the storage on every not-yet-upgraded node.

**After every node in the cluster runs 0.2.28 or later:**

```bash
pvesm set <storeid> --ontap-password '<password>'
```

This writes the priv file and removes the cleartext from `storage.cfg` in one step.

Downgrading after migrating requires putting `ontap-password` back into `storage.cfg` by hand (the value is in `/etc/pve/priv/storage/<storeid>.pw`); older code does not know about the priv file.

### Other

- New `on_update_hook_full` and `on_delete_hook`. Proxmox VE calls `on_update_hook_full` — **not** `on_update_hook` — for any plugin whose `api()` is >= 13, which is every version this plugin supports; overriding only the latter would have been dead code.
- All 23 `_get_api()` call sites now pass `storeid`, which is required to locate the priv file.
- No change to the data path, device handling or ONTAP API usage.

**Testing:** `make test` 6/6, units **254/254** (26 new). Live verification on Proxmox VE 9.2.0 against the real Proxmox VE config API: add (password absent from `storage.cfg`, priv file `0600` with correct content), rotation, unrelated updates leaving the secret untouched, legacy storages not auto-migrated, explicit migration clearing the cleartext, and storage deletion removing the priv file.

## [0.2.27] - 2026-07-27

### Cluster-to-Cluster Migration: Implement `volume_export` / `volume_import`

`volume_export_formats`, `volume_export`, `volume_import_formats` and `volume_import` were not implemented, so Proxmox VE could find no common transfer format and `qm remote-migrate` / `pct remote-migrate` failed with:

```
no matching import/export format found for storage '<id>'
```

`LVMPlugin`, `RBDPlugin` and `ISCSIPlugin` all implement this, so it was a genuine capability gap rather than a norm. **Local migration was never affected** — `QemuMigrate.pm` and `LXC/Migrate.pm` both return early for `$scfg->{shared}`, and this plugin is registered in `@SHARED_STORAGE`.

The wire format is Proxmox VE's trivial `raw+size`: an 8-byte little-endian size header followed by the raw image.

#### Truncation safety is the load-bearing part

The stream carries an **exact byte count**, `alloc_image()` takes KiB, and ONTAP creates a LUN of exactly that many bytes. A stream that is not a whole number of KiB could therefore be written **past the end of the LUN**, silently producing a short disk that no error would report.

`volume_import()` rounds the size **up** before allocating (`align_size_up`, as LVM does) **and** then re-reads the **real** device size with `blockdev --getsize64`, refusing the write if it is smaller than the stream. Rounding alone is not enough: verify, then write.

#### Two SAN-specific differences from the LVM model

- **The device does not exist the moment `alloc_image()` returns.** It must be mapped to the node's igroup, rediscovered over iSCSI/FC and assembled by multipath. Both directions call `activate_volume()` and fail loudly if the device never appears, rather than `dd`'ing into nothing.
- **A failed import runs `free_image()`** — the full 7-step host-side teardown plus the ONTAP delete — so neither a stale device nor an orphaned FlexVol is left behind.
- Only the **allocation** runs under `cluster_lock_storage`; the transfer is a full disk copy and must not hold the cluster-wide storage lock (the v0.2.24 lesson).

### Bug fix: `path()` ignored `wantarray`

`PVE::Storage::Plugin::path()` ends with `return wantarray ? (...) : $path`. Ours returned a 3-element list unconditionally, so `my $p = $plugin->path(...)` silently yielded the **last** element — the string `'raw'` — instead of the device path, and the failure surfaced far away as `'raw' is not a block device`.

Fixed in all three return paths (`path()`, its synthetic-path branch, and `_get_snapshot_path()`). Found while writing `volume_export`, which hit it immediately.

**Testing:** `make test` 6/6, podchecker OK, units **228/228**, functional against a real ONTAP simulator **61/61** — including the new `tests/sim_export_import.pl` (8/8): a checksummed 4 MiB round-trip between two storages, a deliberately odd-sized 1 MiB + 1 byte stream (LUN rounded up to 1025 KiB, first 1 048 577 bytes byte-identical), and existing-name imports with and without `allow_rename`. ONTAP left clean afterwards.

## [0.2.26] - 2026-07-27

### FC: Stop Issuing a LIP on Every Poll, and Bound the Rescan Loop

**FC only — iSCSI installations are unaffected by both changes.**

#### Fabric disruption: a LIP on every poll

`rescan_fc_hosts()` issued a **Loop Initialization Primitive** on every call, and `activate_storage()` called it unconditionally. Since pvestatd runs `activate_storage` roughly every 10 seconds on every node, an FC installation was issuing a LIP **per HBA port every ~10 seconds, indefinitely**.

`issue_lip` resets the FC port and forces a fabric re-login, briefly disturbing **every LUN behind that HBA** — not only this plugin's. Discovering a newly mapped LUN on a port that is already logged in needs only the plain SCSI `- - -` scan; LIP is for genuine topology changes.

- **Fix:** LIP is now opt-in (`lip => 1`) and **off by default**. Of the five call sites, only the "the device never appeared" fallback in `_get_snapshot_path()` asks for it. `activate_storage()`, `activate_volume()` and the `path()` retry loop are scan-only, so a LIP can never be issued from a poll or from inside a retry loop.

#### Unbounded loop

The same function had no wall-clock budget. Its per-write timeouts (10 s) bound **one** sysfs write, not the loop, so a node with four HBA ports could spend 4 × (10 + 10) = ~80 s inside `activate_storage`. This is the v0.2.20 lesson — a per-call timeout never bounds a loop's total time — which had only ever been applied to the iSCSI login loop.

- **Fix:** `rescan_fc_hosts()` now takes a budget (default 30 s) and both loops honour it.

#### Not testable in our lab

There is no FC HBA available here, so **both changes are code-review fixes covered by static and unit assertions only**. On a real FC system, additionally confirm via `journalctl -k | grep -i lip` that no LIP is issued during normal polling. This limitation is stated in `docs/TESTING.md` section 33.1 rather than left implicit.

### Audit: LXC / vzdump exercised end-to-end and found clean

No defects. Run against the real cluster and real ONTAP: create a CT with its rootfs on the plugin (`alloc_image` → mkfs → mount), start, snapshot **while running**, `vzdump --mode snapshot`, rollback, online rootfs grow, destroy.

- The rollback genuinely restored older content — a file created after the snapshot was gone afterwards.
- The online grow took the CT from 2.0 G to 2.9 G with the LUN at 3.0 GiB.
- Destroy left 0 ONTAP volumes, 0 NETAPP multipath maps and 0 `sd` slaves.
- A backup **interrupted mid-flight** left exactly the expected residue (a `vzdump` snapshot plus `tmpclone_<vol>_pve_snap_vzdump`) and recovered completely when the snapshot was removed — the v0.2.13/v0.2.14 incident scenario, with full host-side teardown and no `tur checker` spam.

Recorded in `docs/TESTING.md` section 33 so it does not have to be re-derived.

**Testing:** `make test` 6/6, podchecker OK, units **208/208**, functional against a real ONTAP simulator **53/53**, plus the LXC/vzdump end-to-end above.

## [0.2.25] - 2026-07-27

### `path()`: Make the Synthetic Device Path Unique per Volume

When a LUN is absent on ONTAP, `path()` returns a placeholder device path so callers that only need a path — and that check `-b` before touching it — can proceed. That placeholder hex-encoded only the **first 12 characters** of the ONTAP volume name, which is the shared `pve_{storage}_` prefix. Every volume of a storage therefore produced the identical fabricated identifier, shaped exactly like a real NetApp WWID (`3600a0980` + 24 hex):

```
pve_netapp1_100_disk0     -> 3600a09807076655f6e6574617070315f
pve_netapp1_200_disk3     -> 3600a09807076655f6e6574617070315f
pve_netapp1_999_cloudinit -> 3600a09807076655f6e6574617070315f
```

- **Fix:** the placeholder is now derived from the whole volume name, so it is unique per volume.
- **Impact was limited, and this was verified rather than assumed:** no destructive code path consumes `path()`. `free_image()`, `_cleanup_orphaned_devices()`, `_reap_stale_scsi_paths()`, `_remove_temp_clone()` and `deactivate_storage()` all obtain the WWID from ONTAP directly, so the placeholder only ever produced a non-existent path that callers reject via `-b`. The defect was that one fabricated identifier stood in for many volumes, which made the accompanying warning useless for diagnosis and left a NetApp-shaped identifier that could in principle alias a real device.
- **No behaviour change** for any working configuration.

### Documentation

- `CONFIGURATION.md` and its zh-TW counterpart gain a **credential handling** section recommending a dedicated, least-privilege ONTAP account scoped to the SVM the plugin uses, rather than the cluster `admin` account, together with guidance on restricting `Datastore.Allocate` and on rotating the credential.

**Testing:** `make test` 6/6, podchecker OK, units **199/199** (`audit_fixes` 151, `status_timeout` 20, `stale_sd_reaper` 20, `activate_budget` 8), functional against a real ONTAP simulator **53/53**.

## [0.2.24] - 2026-07-27

### Data-Safety Audit: Delete, Overwrite, Disconnect and Deadlock Review

**Status: prepared, not yet published.** Tests: `make test` 6/6, podchecker OK, units **194/194**, functional against a real ONTAP simulator **53/53**, plus real-ONTAP verification of the new cross-node I/O guard and the new one-call LUN/igroup query.

A focused review of every destructive path, following the v0.2.23 compatibility audit. Eight issues fixed; the areas found sound are recorded at the end so they are not re-investigated.

#### Data loss: two storages could silently share one ONTAP volume namespace

ONTAP volume names are `pve_{storage}_{vmid}_disk{N}`, with the storage ID passed through `sanitize_for_ontap()` — which **truncates to 32 characters**. Two different Proxmox VE storage IDs can therefore produce the same prefix: `netapp-production-cluster-alpha-one` and `netapp-production-cluster-alpha-two` both become `netapp_production_cluster_alpha_`.

If both storages also point at the same SVM they address literally the same FlexVols: `list_images()` on one reports the other's disks, and **`free_image()` on one destroys the other's volume**.

- **Fix:** the naming scheme cannot change without renaming every existing customer volume, so the collision is prevented instead. A new `on_add_hook()` refuses to create a storage whose (portal, SVM, 32-character sanitized prefix) matches an existing `netappontap` storage, naming the conflicting storage and the consequence. The same prefix under a different SVM or portal is a separate namespace and is still allowed. Configurations predating the check are warned about at `activate_storage` time rather than refused — refusing to activate an in-service storage would take running guests offline.

#### Orphan cleanup could tear down live devices for some storage IDs

`list_images()`, `_cleanup_orphaned_devices()` and `deactivate_storage()` built their ONTAP query prefixes with a naive `s/-/_/g`, which diverges from `sanitize_for_ontap()` for any storage ID containing a dot (Proxmox VE allows `[a-z][a-z0-9\-\_\.]*[a-z0-9]`) or longer than 32 characters.

A prefix that matches nothing is dangerous in the orphan reaper: the alive set comes back **empty**, so every tracked WWID looks like a deleted LUN. The v0.2.17 path-health gate still protects devices with active paths, but a device whose paths are all momentarily down (controller takeover, fabric blip) would then be torn down even though its LUN is alive. `list_images()` would also report "this storage has no disks".

- **Fix:** all three now use `sanitize_for_ontap($storeid, 32)`, the same function that generates the real volume names.

#### Cross-node in-use detection before delete and rollback

`is_device_in_use()` is thorough but **node-local**: mounts, swap, sysfs holders, and — via `fuser` — any process holding the block device open, which does include a running QEMU. (The v0.2.17 note in CLAUDE.md claiming it cannot see QEMU was **wrong** and has been corrected; it sent this audit down a false trail.)

What it cannot cover is the rest of the cluster. On the node servicing a `pvesm free` the LUN may not be mapped at all, so `$device` is undef and **no check runs**. That path is unguarded by Proxmox VE too: `DELETE /nodes/{node}/storage/{storage}/content/{volume}` — the storage content view's **Remove** button — does a permission check and then calls `vdisk_free`, guarding only base volumes.

- **Fix:** `free_image()` and `volume_snapshot_rollback()` now ask ONTAP whether the LUN is transferring data, but only when the local check could not run. New option `ontap-inuse-io-check` (default 1).
- The test is **one-directional**: observed I/O refuses the operation; absence of I/O never blocks one. That distinction is essential — `qm destroy` calls `vdisk_free` while the guest config **still references** the disks, so a "refuse if referenced" test would break destroy entirely.
- The verdict rests on **bytes transferred, not operation counts**: `multipathd` issues TEST UNIT READY on every mapped LUN continuously, which moves no data. An earlier draft counted operations and flagged a genuinely idle LUN (measured: 1 operation, 0 bytes in 8 s), which would have refused nearly every cross-node delete. Measured after the fix: idle = 0 bytes (3/3 samples), active `dd` = ~41 MB in 10 s, clearing about 10 s after the I/O stops.
- Rollback gets the same guard because it is **more** destructive than delete: it silently overwrites the volume with older content, so a mistake is not even visible as a missing disk.

#### A second Proxmox VE cluster can share the volume namespace unnoticed

Volume names carry **no cluster identifier** — `ontap-cluster-name` only ever appears in igroup names. Two clusters that each have a storage called e.g. `netapp1` pointing at the same SVM share `pve_netapp1_*` completely. Allocation is safe (existence checks pick the next free disk ID), but `list_images()` returns the other cluster's volumes as if they were local: they appear in the storage content view and in `qm rescan` as unused disks, and **deleting one there destroys a live disk of the other cluster**.

- **Fix:** `status()` now warns (24 h cooldown, also to syslog) when LUNs in this storage's namespace are mapped to igroups whose name does not begin with this cluster's own `pve_{cluster}_` prefix — proof that another Proxmox VE cluster owns them. Warn only, never refuse.
- Implemented as a single paginated `lun_list_with_maps()` call. An earlier draft looped `lun_get()` per LUN and only stamped its cooldown when a problem was found, which on a healthy setup would have re-run on every ~10 s `status()` poll — reintroducing the v0.2.21 N+1 REST storm. It also parsed the cluster name out of the igroup, which is ambiguous once the cluster name itself contains `_` (or `-`, which sanitizes to `_`); prefix matching is used instead.

#### `free_image`'s delete retry loop is now wall-clock bounded

`free_image()` runs inside Proxmox VE's **cluster-wide** storage lock, and one ONTAP volume delete can take ~240 s (60 s HTTP × 2 retries plus a 120 s job wait), so five attempts could hold that lock for around 20 minutes and block allocate/free for the storage on every node. New option `ontap-delete-deadline` (default 300 s). A per-call timeout does not bound a loop's total time — the v0.2.12 lesson.

#### Recovery-queue purge now fails closed on an API error

`_release_recovery_queue_clone_holds()` decided "this volume is not live" from `if (eval { $api->volume_get($name) })`, which treats a **failed** lookup (network blip, auth, ONTAP busy) identically to a confirmed absence, advancing a live volume toward a destructive purge. This is the v0.2.16 lesson applied to a destructive path, where it matters more. A failure is now reported as "could not verify" and refuses.

#### Snapshot names differing only in `-` vs `_` collide on ONTAP

Proxmox VE snapshot names match `[a-z][a-z0-9_-]+`, so `my-snap` and `my_snap` are distinct; `sanitize_for_ontap()` maps `-` to `_`, so both become the ONTAP snapshot `pve_snap_my_snap`. Creating the second is refused by the existing check — the safe outcome, since two Proxmox VE snapshots must never become one ONTAP snapshot — but the error read "already exists" for a name Proxmox VE lists as free.

- **Fix:** the encoding cannot change without orphaning every existing snapshot, so the error now explains the mapping and names the variant occupying it. The same collision affects vmstate volume names, where `alloc_image` likewise refuses.

#### Reviewed and found sound (recorded so it is not re-litigated)

- **Deadlocks:** both `flock` sites use `LOCK_EX|LOCK_NB` with a bounded 10 s retry and then proceed unlocked — worst case a lost tracking-file update, which is not a data risk, and never a hang. All `alarm()` uses are leaf-level (glob, socket connect, `open3`) with no nesting, so no inner `alarm(0)` can cancel an outer timeout. Every external command has an explicit timeout; every ONTAP wait is bounded.
- **Overwrite:** `alloc_image()` and `clone_image()` use bounded TOCTOU retries with an existence pre-check plus a create-error handler; vmstate and cloud-init allocations die if the volume exists; `rename_volume()` checks the target; `volume_resize()` refuses to shrink.
- **Disconnection:** the orphan reaper aborts entirely if `lun_list` fails, rather than treating a query failure as "everything was deleted"; `activate_storage()` dies when no portal is reachable.

## [0.2.23] - 2026-07-26

### Proxmox VE 9.0/9.1/9.2 Compatibility Audit + Snapshot Safety Fixes

**Status: prepared, not yet published.** All tests pass against the restored ONTAP simulator: units **153/153** (`audit_fixes` 105, `status_timeout` 20, `stale_sd_reaper` 20, `activate_budget` 8), `make test` 6/6, and functional **53/53** (`sim_snapshot_safety` 34, `sim_functional` 13, `cleanup_load` 6). Remaining before publishing: `make deb`, install on this node, the `qm`-level end-to-end (`docs/TESTING.md` 31.8), then the `github/` sync, README deb filenames and tag.

Requirements relaxed from Proxmox VE 9.1 to **Proxmox VE 9.0 or later**.

#### Data safety: silent loss of snapshot restore points (highest severity)

ONTAP SnapRestore (`PATCH /storage/volumes` with `restore_to.snapshot`) deletes **every snapshot created after the restore target**. Proxmox VE had no way to know that:

- The plugin did not implement `volume_rollback_is_possible()`, so PVE's base implementation returned `1` for any snapshot.
- `PVE::AbstractConfig::snapshot_rollback()` does **not** remove newer snapshots from the guest config.

Result: rolling back to an older snapshot silently destroyed the newer ones on ONTAP while Proxmox VE kept listing them in the config and web UI. The operator believed they still held those restore points; the loss only surfaced when a later rollback or delete of them failed. Every core plugin whose rollback is likewise destructive (ZFSPool, LvmThin, LVM, BTRFS) implements this guard for exactly this reason.

- **Fix:** implement `volume_rollback_is_possible()`. It compares ONTAP snapshot creation times, refuses any rollback that is not to the most recent snapshot, and reports the doomed snapshots through PVE's `$blockers` list so the web UI names them. A template's `__pve_base__` snapshot can also block, since SnapRestore past it would destroy the base that linked clones depend on. Unparseable or tied ONTAP timestamps are treated as **blocking** (fail safe), never as "older, therefore harmless".

#### Snapshot delete now detects FlexClones that lock the snapshot

`PVE::Storage::vdisk_clone($cfg, $volid, $vmid, $snapname)` is reachable (`qm clone ... --snapname X` without `--full`, and the LXC equivalent), and `clone_image()` then creates a normal `pve_*` FlexClone whose parent is that snapshot. `volume_snapshot_delete()` only ever looked for the deterministic `tmpclone_<vol>_<snap>`, so ONTAP rejected the delete with a raw `Snapshot ... has not expired or is locked` and nothing told the operator what was holding it — the same symptom class as the v0.2.13 vzdump incident, from a clone this function never looked for.

- **Fix:** after the temp-clone teardown, query `volume_get_clone_children()` and refuse with an actionable message naming each blocking clone and its owning guest, plus how to make them independent. The plugin does **not** auto-split or auto-delete — those are live disks of other guests. The deterministic temp clone is explicitly exempt, because ONTAP metadata can still list a just-deleted FlexClone (the v0.2.13 lesson) and blocking on it would regress the vzdump CT snapshot-mode path.

#### Storage API version negotiation (the actual PVE 9.0-9.2 compatibility issue)

PVE's third-party plugin loader **hard-rejects** a plugin whose `api()` exceeds the running `PVE::Storage::APIVER` — the storage silently disappears from the node — and warns on every load when `api()` is lower. Proxmox VE bumped `APIVER` twice **inside** the 9.1 point releases (verified by unpacking each package):

| libpve-storage-perl | APIVER | APIAGE | accepts |
|---|---|---|---|
| 9.0.16 - 9.1.2 | 13 | 4 | 9-13 |
| 9.1.3 - 9.1.5 | 14 | 5 | 9-14 |
| 9.1.6+ | 15 | 6 | 9-15 |

The hardcoded `api() => 13` therefore made every `pvedaemon` / `pvestatd` / `pveproxy` / `pvesm` invocation on 9.1.3+ print `Plugin ... is implementing an older storage API, an upgrade is recommended`.

- **Fix:** `api()` now returns the highest version the plugin implements that the running PVE understands (capped at 15, floor 9), falling back to 13 when `PVE::Storage` is not loaded. Verified against every available 9.0/9.1 storage library: exact APIVER match and **zero warnings** on 9.0.18, 9.1.0, 9.1.2, 9.1.3, 9.1.5 and 9.1.6.
- `volume_resize()` now accepts the `$snapname` argument added in APIVER 14 and rejects it explicitly, instead of silently resizing the **current** volume when asked to resize a snapshot.
- New `get_identity()` (APIVER 15, exposed via `GET /nodes/{node}/storage/{id}/identity`) returning `netappontap://<portal>/<svm>`. The aggregate is deliberately excluded: it only decides where new FlexVols land.

#### ONTAP management-gateway load: API client cache thrash

`_get_api()` keyed its client cache on `$scfg->{storage} // $scfg->{'ontap-portal'}`, but Proxmox VE **never** populates `$scfg->{storage}`, so the key degraded to portal-only while the validity check compared portal **and** SVM. Two `netappontap` storages sharing one ONTAP management LIF but using different SVMs therefore evicted each other's client on every single `_get_api()` call. Each rebuild discards the keep-alive connection, putting the plugin back into "new TCP + TLS handshake + basic auth per REST request" — the exact behaviour that caused the 2026-06-16 mgwd congestion collapse and that `keep_alive` (v0.2.19) exists to prevent.

- **Fix:** key the cache on `(portal, svm, data|status)`. Sibling storages now keep independent, reused connections; two entries pointing at the same portal **and** SVM still share one client.

#### `multipath -F` removed from the codebase

`Multipath::multipath_flush()` had a no-device branch that executed `multipath -F`, which flushes **all** unused multipath maps system-wide including the customer's manually managed storage. It was unreachable dead code, but left the call site one accidental caller away from a cluster-wide incident, and violated the project's own hard rule. Following the v0.2.4 lesson (delete dead code with a known bug pattern rather than leaving it as a footgun), the branch is gone and the function now croaks without a device argument.

#### `deactivate_storage()`: added the v0.2.17 path-health gate

It tears down multipath devices and all SCSI paths for every LUN of the storage, guarded only by `is_device_in_use()` — which does **not** see a QEMU-held disk of a running VM (an open fd is not a sysfs holder). Reaching it would reproduce the v0.2.17 incident: `multipath -f` fails on the busy map, the `dmsetup remove --force` fallback rips it out from under QEMU, and the guest takes I/O errors.

- **Fix:** gate teardown on `multipath_path_health()`, treating indeterminate (`-1`) exactly like alive (`1`), as the orphan reaper does.
- Also corrected a misleading comment: **nothing in Proxmox VE 9.0-9.2 calls `PVE::Storage::deactivate_storage()`** (verified across the whole `/usr/share/perl5/PVE` tree), so it must not be relied on for cleanup on `pvesm set --disable` or storage removal.

#### `filesystem_path()` no longer fails with a misleading internal error

Its signature carries no `$storeid`, and this plugin needs the storage ID to derive the ONTAP FlexVol name, so it cannot be implemented. The old body passed the never-set `$scfg->{storage}` and died with `storage is required at .../Naming.pm line 213`. It is unreachable in PVE 9.0-9.2 (every base method that calls it is overridden, and `volume_snapshot_info` / `rename_snapshot` are only invoked when `volume_qemu_snapshot_method` returns `'mixed'`, while this plugin returns `'storage'`), but it was a booby trap for the next PVE release that widens the external-snapshot API.

- **Fix:** die with a clear, plugin-level message pointing at `path()`. Also override `volume_snapshot_info()` — now answered from ONTAP as an ordered `name => {order, timestamp}` map — and `rename_snapshot()` (explicitly unsupported), so neither can fall through to the base implementation.

#### ONTAP volume recovery queue holds a deleted clone (found by the new tests)

Discovered while running the new 31.6 test against real ONTAP, and a **correction to the v0.2.13 diagnosis**.

A FlexClone that has been **deleted** still counts as a clone of its parent for as long as ONTAP keeps it in the **volume recovery queue** (enabled by default; retention is per-SVM via `vserver modify -volume-delete-retention-hours`, default 12h). The queued volume is renamed `<original>_<id>` and is invisible to `/storage/volumes`, but ONTAP's own clone view still reports it. Consequences, both reproduced on real ONTAP:

- deleting the parent's snapshot fails with `Snapshot ... has not expired or is locked`
- deleting the parent volume fails with `it has one or more clones`

...for up to the whole retention window, with an error that never mentions the queue. In practice: destroy a linked-clone VM, then try to delete the source snapshot (or the source disk) and it fails for 12 hours for no visible reason. `free_image()`'s old "stale clone metadata, retrying..." loop was hitting exactly this — it burned 5 attempts against a condition that sleeping can never clear, then failed with a message that pointed nowhere.

This also **corrects the v0.2.13 root-cause analysis**, which attributed the sticky `volume_clone_dependent` owner to eventual consistency plus an ONTAP-simulator quirk. The real mechanism is the recovery queue, which is present on real ONTAP too; `volume_clone_split` worked around it because splitting de-clones the volume *before* deletion, so its queue entry is no longer a clone.

- **Fix:** new `API::volume_get_clone_children_cli()` (ONTAP's authoritative clone view, including queued clones), `recovery_queue_list()` and `recovery_queue_purge()`, plus `_release_recovery_queue_clone_holds()`. `volume_snapshot_delete()` and `free_image()` now release such holds instead of failing. Splitting before deleting a linked clone was rejected as the fix: it would copy the clone's entire delta just to throw the volume away, turning `qm destroy` on a linked clone into a minutes-to-hours operation.
- **Safety:** an entry is purged only when ONTAP reports it as a clone of the volume being operated on, it is **not** a live volume, it **is** in the recovery queue, and its name matches the plugin's own scheme (`pve_*_<id>` or `tmpclone_pve_*_<id>`). A live clone is reported for the operator to resolve, never purged. A customer's own clone is never touched. Purging is limited to entries actively blocking the delete the operator just requested, so the recovery queue's safety net is preserved everywhere else, and every purge is logged.
- **Opt-out:** new `ontap-purge-recovery-queue` (boolean, default 1). Set to 0 to leave the queue untouched and receive an actionable error naming the queued volume and the `volume recovery-queue purge` command instead.

#### Smaller correctness and hygiene fixes

- `activate_volume()` now accepts the `$hints` argument Proxmox VE 9.1 passes (`Storage.pm:1411`); it was silently dropped by a too-short signature.
- `volume_size_info()` now honours the `$timeout` PVE passes in (commonly 10s); it was accepted and ignored, so the call was bounded only by the client default of 15s x 2 retries. `API::get()` / `lun_get()` gained a `%opts` pass-through for this.
- `parse_volname()` now dies on an unparseable volume name, as every core plugin does, instead of returning `undef` and letting the failure surface later as `Use of uninitialized value` with no indication of which volume was at fault.
- `API::volume_get_clone_children()` now requests `clone.parent_snapshot.name` explicitly, so callers can tell which parent snapshot each child clone pins.
- Removed the unused `PVE::ProcFSTools` and `PVE::Cluster` imports; import `PVE::INotify`, which is actually used.
- POD: corrected the SYNOPSIS and CONFIGURATION OPTIONS, which still documented pre-0.2.x option names (`portal` / `svm` / `aggregate` / `ssl_verify` / `thin` / `igroup_mode`) instead of the real `ontap-` prefixed ones — copying the old POD example into `storage.cfg` could not work. Added a Proxmox VE compatibility section.

#### Verified as NOT problems (recorded so they are not re-investigated)

- **`-blockdev` conversion (PVE 9.0's largest change):** the plugin does not implement `qemu_blockdev_options()`, and does not need to. The base implementation `stat()`s the path returned by `path()`, sees `S_ISBLK`, and emits `{driver => 'host_device', filename => ...}`; `filename` is on PVE's allow-list for that driver.
- **`multipathd` CLI compatibility with multipath-tools 0.11.1** (Debian 13 / PVE 9, up from 0.9.x on PVE 8): `show maps raw format '%n %w'`, `show paths raw format '%m %t %o'` and `disablequeueing map` all verified working, with output that `multipath_path_health()` parses correctly.
- **`SHARED_STORAGE` registration** still works on PVE 9.2 (`shared` is auto-set to 1).
- **`status()`'s double-forked cleanup grandchild calling `PVE::Storage::config()`** does not misuse the parent's pmxcfs IPC socket: the inherited `$ccache` / `$versions` satisfy the read with **zero** `ipcc_get_config` calls (measured).
- **Running-VM snapshots being crash-consistent without a guest agent**, and `volume_snapshot_needs_fsfreeze()` returning 0 for LXC: both match core PVE behaviour (LVM/LVM-thin), and `PVE::LXC::sync_container_namespace()` does a `syncfs` inside the container's mount namespace.
- **Empty `volume_export_formats()`**: same as LVM/RBD; `qm move-disk` uses `qemu-img convert` via `path()`, and shared storage does not move volumes on migration.

#### Tests

- New `tests/audit_fixes.t` (79 assertions, no ONTAP required): API version negotiation in a fresh process per APIVER, ONTAP timestamp parsing, the rollback guard, the linked-clone lock (including the temp-clone no-regression guard), snapshot info ordering, and static guards for every fix above.
- `tests/status_timeout.t`: distinct test storages now differ by `ontap-svm` instead of a `storage` key. The old version relied on `_get_api()` reading `$scfg->{storage}`, which merely reproduced the caching bug it was meant to guard.
- `docs/TESTING.md` + `docs/TESTING_zh-TW.md`: new **section 31** covering the unit suite, the cross-version APIVER matrix, PVE 9 API contract checks, static guards, and two ONTAP-required functional tests (31.5 SnapRestore destructiveness + rollback guard, with host-side device assertions per the v0.2.14 rule; 31.6 linked-clone lock).

## [0.2.22] - 2026-06-16

### postinst: prominent "restart pvestatd (not reload)" upgrade warning

**Operability fix (follow-on to the v0.2.21 incident):**

postinst reloads PVE services with `systemctl reload` (SIGHUP) to avoid restart stop-phase hangs on D-state children (the v0.2.5/v0.2.6 lesson). But on many PVE versions a SIGHUP re-exec does NOT reload the plugin's Perl modules — pvestatd keeps running the **old code in memory** even though the new files are on disk (the PID stays the same). During the v0.2.21 rollout this made an installed fix appear to have no effect for over an hour, until a full restart.

- **Fix:** postinst now prints a prominent, colored warning after the reload that the operator MUST run `systemctl restart pvestatd` on **every** cluster node to activate the new code, with how to verify the PID changed (reload keeps the same PID = stale code). We keep `reload` (not auto-restart) to preserve the D-state-hang protection; the warning closes the "installed but not active" gap.
- `docs/TROUBLESHOOTING.md` already documents the restart requirement (added in the v0.2.21 cycle).

**No Perl code change** — `lib/` modules are byte-identical to 0.2.21. Testing: postinst `bash -n` OK; warning renders; full plugin regression unchanged from 0.2.21 (`sim_functional` 13/13, units 20/13/8, `cleanup_load` 6/6).

## [0.2.21] - 2026-06-16

### Orphan-Cleanup N+1 REST Storm Fix (ONTAP mgmt-gateway load)

**Bug fix (production incident, customer 2026-06-16 — FAS on ONTAP 9.15.1P19; a sibling ASA on 9.14.1 with the same plugin was unaffected):**

After a firmware upgrade, the FAS management REST became slow (~4s/request) and intermittently refused connections; pvestatd flapped the storage to `inactive`. Disabling the storage cluster-wide drained the backlog *slowly* (19s → 14s → 12s …), proving the load came from PVE polling rather than a FAS outage — and `cluster show` was healthy.

- **Root cause:** `_cleanup_orphaned_devices()` — which runs in the `status()` background cleanup on **every ~10s poll on every cluster node** — called `lun_get_wwid($lun->{name})` once **per LUN** to build its alive-set. That is an N+1 REST storm (`lun_get_serial` → `lun_get` → GET per LUN). An SVM with 75 LUNs × N nodes generated ~75·N REST calls every 10s — enough to overwhelm ONTAP's management gateway (mgwd) into congestion collapse. This is mgwd **capacity exhaustion**, not an explicit rate limit (no HTTP 429). ONTAP 9.15.1P19's mgwd proved far more load-sensitive than the ASA's 9.14.1 under the identical plugin load.
- **Fix:** `lun_list()` already returns `serial_number` for every LUN in ONE paginated call, so the WWID is now computed locally via `serial_to_wwid()` (pure, no REST) instead of the per-LUN call. **~75 calls/poll → 0 extra**; the computed alive-set is byte-identical (verified on real ONTAP). Behaviour is otherwise unchanged.

**Testing:**

- `docs/TESTING.md` Section 30 added (EN + zh-TW).
- New real-ONTAP test `tests/cleanup_load.pl` **6/6**: alloc 3 LUNs, instrument the API, assert **zero** per-LUN `lun_get` calls during cleanup AND every WWID still present in the alive-set, then verify 0 leftover.
- Full regression with no change: `sim_functional` 13/13, unit reaper 20/20 + status-timeout 13/13 + activate-budget 8/8, `make test` all modules OK. The other per-poll calls were audited: `get_managed_capacity` early-returns on the aggregate (1 call, no N+1); `_check_aggregate_capacity` (1h cooldown) and `_check_lif_redundancy` (24h cooldown) already throttle their queries.

## [0.2.20] - 2026-06-16

### activate_storage iSCSI Login Budget Release ("never wedge PVE")

A follow-on to v0.2.19 that completes the "never wedge PVE" rule.

**Hardening:**

v0.2.19 gave the pvestatd health path (`activate_storage`/`status`) a short-timeout, no-retry API client, bounding the ONTAP REST calls. But `activate_storage` also runs an iSCSI discover/login loop whose per-portal timeouts (probe 2s, discovery 30s, login 60s) bound EACH portal but NOT the loop's cumulative time — several reachable-but-hanging LIFs could still add up and stall pvestatd (the same lesson as v0.2.12: per-call timeouts do not bound a loop's total time).

- **Fix:** new `ontap-activate-deadline` option (default 30s) caps the cumulative discover/login work. Once the budget is spent AND at least one portal is already logged in, the remaining portals are deferred to a later activation (picked up via the already-logged-in fast path). An in-progress login is NEVER interrupted, and the loop NEVER skips while zero paths are up — it must obtain at least one path or fail honestly. Multipath redundancy self-heals on the next activation; the alternative (wedging pvestatd) is far worse.
- `CLAUDE.md` gains a "PVE Daemon Isolation (never wedge PVE)" rule section documenting the invariant for all future entry points.
- **Also:** `activate_storage` now snapshots iSCSI sessions ONCE (a single `iscsiadm -m session`) instead of calling it per portal via `is_portal_logged_in()`. The per-portal calls ran BEFORE the budget gate, so a degraded iscsid could add N × up-to-30s that the budget could not bound; one snapshot keeps the loop's setup cost flat.

**Testing:**

- `docs/TESTING.md` Section 29 added (EN + zh-TW).
- Unit test 8/8: past budget with a path up → remaining skipped; past budget with zero up → all attempted (never skip); within budget → all attempted. Simulator functional regression 13/13 (the budget does not break normal activation). `make test` all modules OK.

## [0.2.19] - 2026-06-16

### pvestatd Isolation + Stale-Path Reaper + Connection Reuse Release

Three independent resilience fixes surfaced by a customer's ONTAP upgrade and a prior LUN-ID-reuse incident.

**Fix 1 — stale SCSI-path reaper (LUN-ID reuse on a non-teardown node):**

A node could not build the multipath map for a live LUN: `device-mapper: error getting device (-EBUSY)`, and `multipath -ll` showed nothing while other nodes were fine. Per-node igroup mode maps every LUN to ALL nodes; a node that never ran the LUN's `free_image()` keeps stale `sd` paths; ONTAP reuses the freed SCSI LUN-ID for a new LUN; the stale `sd` (which now reports no WWID) shadows the reused LUN-ID and device-mapper cannot load the new map. The v0.2.18 teardown sweep matches by WWID, so it cannot catch these — they advertise no matchable WWID.

- **Fix:** new `Multipath::list_netapp_scsi_paths()` (raw-`sd` topology enumeration) + `_reap_stale_scsi_paths()` as a third pass in `_cleanup_orphaned_devices()`. An `sd` is removed ONLY when: vendor is NETAPP, it has no holders and is not mounted, AND either (Case A) it is an orphan of a deleted LUN this storage tracked, or (Case B) a sibling `sd` at the same iSCSI target IQN + same LUN-ID reports a live (ONTAP alive-set) WWID while this one differs or is blank (reused LUN-ID). 300s grace; anything indeterminate is left alone. After reaping it self-heals with a rescan + multipath reload.

**Fix 2 — pvestatd timeout isolation (a degraded ONTAP no longer wedges PVE or sibling storages):**

During an ONTAP upgrade, one controller's management REST read-timed-out. `activate_storage`/`status` stacked several 15s × 2-retry calls into `status update time (189s)`, and pvestatd's sequential storage loop dragged a sibling netappontap storage on the same node into `inactive`.

- **Fix:** new `ontap-status-timeout` option (default 5s). The pvestatd health path (`activate_storage`/`status` foreground) uses a short-timeout, single-attempt API client — the next ~10s poll is the retry. The data path (alloc/free/clone) keeps the resilient client. Measured fast-fail: **5.0s vs 32.0s**.

**Fix 3 — HTTP keep-alive (do not overwhelm ONTAP's management gateway):**

A request storm (no connection reuse + per-request basic auth, multiplied across cluster nodes and retries) overwhelmed ONTAP's management gateway into sustained read timeouts — proven in the field: **15s/request while hammered, 0.5s the instant polling stopped**. `LWP::UserAgent` now uses `keep_alive => 1`, so REST calls reuse one TCP+TLS connection instead of a new handshake + re-auth per call.

**Testing:**

- `docs/TESTING.md` Section 28 added (EN + zh-TW).
- Simulator functional test (real ONTAP + real host devices): **13/13** — full alloc/activate/free lifecycle with host-side device assertions, stale-`sd` reaper no-false-positive on a healthy live device, degraded fast-fail 5.0s vs 32.0s. Unit tests: reaper decision logic 20/20, status-path client 13/13. ONTAP and host both verified with 0 leftover.

## [0.2.18] - 2026-05-29

### Stale SCSI Path Sweep on Cleanup Release

**Hardening (independent issue surfaced in the v0.2.17 incident log):**

The kernel logged `LUN assignments on this target have changed. The Linux SCSI layer does not automatically remap LUN assignments.` ONTAP auto-assigns SCSI LUN-IDs on `lun_map` and reuses a freed LUN-ID for a different LUN after unmap. If a stale host `sd` device is still bound to that `H:C:T:L`, the new LUN is not usable on that path and the kernel refuses to remap.

- **Root gap:** `cleanup_lun_devices()` removed only the paths currently in the multipath map, and was a complete no-op when the map was already gone — leaving orphaned single `sd` paths that later collide with reused LUN-IDs.

- **Fix:** new `Multipath::get_scsi_paths_for_wwid()` enumerates ALL NETAPP `sd` paths for a WWID (including paths no longer in the map, matched via the device's SCSI `wwid`/VPD identifiers). `cleanup_lun_devices()` gains a Step 8 sweep that removes them even when the map is gone. The sweep is vendor-gated to NETAPP (never touches other storage), WWID-matched (no false positives), and bounded by a wall-clock budget (default 30s) so a host with hundreds of `sd` devices and failing paths cannot stall teardown (the v0.2.12 lesson: per-read timeouts do not bound cumulative time).

**Testing:**

- `docs/TESTING.md` Section 27 added (helper matching, the Step 8 orphan sweep, static guards), EN + zh-TW.
- Verified on the simulator (pc-pve1): `get_scsi_paths_for_wwid()` matches a real device's paths and returns empty for a bogus WWID; Step 8 sweeps `sd` paths orphaned by a bare `multipath -f` (the case the old code no-op'd on); `budget => 0` bails safely with a warning.

## [0.2.17] - 2026-05-29

### Orphan Reaper Path-Health Gate + LUN List Pagination Release

**Bug Fix (production incident, customer report 2026-05, node pve15):**

Hot-adding a disk to a **running** VM could cause immediate I/O errors on that brand-new disk (`I/O error, dev dm-NN`). Shutting the VM down and starting it again "fixed" it.

- **Root cause (two defects):**
  1. `_cleanup_orphaned_devices()` built its "alive set" from a single `lun_list()` snapshot and reaped any tracked WWID missing from it. A freshly-created LUN can be absent from that bulk query for a window (ONTAP read-after-write / propagation lag — the same class as the v0.2.9 ASA eventual-consistency issue, now feeding the reaper's alive set). With a large LUN count the query could also be truncated.
  2. The reaper called `cleanup_lun_devices()` with **no check of multipath path health**, so a live device with active paths was indistinguishable from a genuine orphan. Because the VM was running, QEMU held the device open: `multipath -f` failed and the `dmsetup remove --force` fallback ripped the map out from under QEMU, producing the I/O errors. (Note: QEMU's open fd is not a sysfs holder, so `is_device_in_use()` does not detect it — the path-health gate is the load-bearing protection.)

- **Fix 1 — path-health gate (`Multipath::multipath_path_health()`):** the reaper NEVER removes a device that still has an active path (or whose state is indeterminate). A genuine orphan has ALL paths failed/faulty. Applied to both the first-pass reap and the second-pass "untracked stale" operator warning, so the plugin no longer suggests `multipath -f` on a healthy device either.

- **Fix 2 — grace period:** a WWID tracked within the last 300 seconds is not reaped, covering the read-after-write window. Reuses the existing first-tracked timestamp; no new state file.

- **Fix 3 — LUN list pagination (`API::_get_all_records()`):** `lun_list()` now follows ONTAP REST `_links.next` so an SVM with 1000+ LUNs never silently truncates the alive set. The same pagination is applied to `volume_list`, `volume_get_clone_children`, `igroup_list`, and `snapshot_list`.

**Testing:**

- `docs/TESTING.md` Section 26 added: path-health logic (7 cases), pagination completeness, static regression guards, a RUNNING-VM functional reproduce with mandatory host-side device assertions (v0.2.14 rule), and the grace-period guard.
- Full simulator test PASS: both reaper defenses verified live; a genuine orphan (LUN deleted on ONTAP, all paths failed) is still reaped with clean host-side teardown; all five paginated API functions return correctly against real ONTAP; full disk lifecycle (alloc / snapshot / rollback / resize / full clone / free) clean with zero I/O errors.

## [0.2.16] - 2026-05-24

### Temp Clone Reaper Idempotency Fix Release

**Bug Fix (operational noise, found during v0.2.15 testing):**

- **`_remove_temp_clone()` now detects "volume already absent on ONTAP" at entry and returns success**, instead of dying at the subsequent `volume_clone_split` call. Previously, a stale tracking entry whose ONTAP volume had been deleted out-of-band would cause the TTL background reaper (`_cleanup_temp_clones`) to retry every 10-second `status()` poll forever, spamming the journal with:
  ```
  Cleaning up old temporary FlexClone: tmpclone_<name>
  Failed to cleanup temp clone '...': volume_clone_split on temp clone '...' failed:
    Volume '...' not found at .../NetAppONTAPPlugin.pm line N.
  ```
  Without auto-recovery — the caller's `eval` caught the die but did NOT delete the state file entry (because cleanup hadn't actually completed), so the next poll retried with the same result. With the v0.2.16 fix, the helper returns success on the FIRST poll, the caller untracks the stale entry, and the noise stops on the next cycle.

**How this scenario arises in production:**

- Interrupted previous cleanup: `volume_delete` succeeded on ONTAP but the state-file untrack write didn't happen (crash, reboot mid-flight, etc.)
- Cross-node race: another cluster node deleted the temp clone between our state read and our action
- Manual ONTAP admin cleanup: someone removed the temp FlexClone out-of-band
- Post-reboot weirdness: tmpfs `/var/run` survived but ONTAP-side cleanup completed before

**Safety:**

- Distinguishes confirmed "not found" (`volume_get` returns undef without error) from transient API errors (`volume_get` dies). Only the former triggers the skip; the latter propagates as `die` so we retry next cycle rather than silently leak a real clone.
- Worst-case (impossible-but-considered): if `volume_get` returns undef erroneously while the volume actually exists, we'd skip cleanup and untrack — leaving an ONTAP orphan. But: temp clones are FlexClones with minimal unique blocks, and `_cleanup_orphaned_devices` would still flag any orphan multipath device on the host. Mitigated by `volume_get`'s clear contract (undef = no records returned by SVM).

## [0.2.15] - 2026-05-24

### Cross-Storage Orphan Detection Fix Release

**Bug Fix (production incident, customer report 2026-05-21~23):**

- **`_cleanup_orphaned_devices()` no longer false-positive flags sibling netappontap storages' WWIDs as orphans.** Customer's `pvestatd` journal showed repeated cluster-wide warnings on every node:
  ```
  Orphan cleanup: detected N untracked NETAPP multipath device(s) that may be stale.
  Plugin will NOT auto-clean these (risk of touching manually-managed storage).
  If you confirm they are NOT in use, clean manually:
    multipathd disablequeueing map <wwid>
    dmsetup message <wwid> 0 fail_if_no_path
    multipath -f <wwid>
  (This warning repeats at most once per hour per device.)
  ```
  But running the full plugin/ONTAP audit revealed all flagged WWIDs were healthy plugin-managed LUNs in the customer's OTHER netappontap storage (customer had `netappASA` + `netappFAS_Node2` on the same PVE nodes). If the operator followed the suggested manual cleanup, they would have torn down active VM disks from the sibling storage.
- Root cause: `list_netapp_multipath_devices()` returns ALL devices with vendor=NETAPP on the host — no per-storage filter. `_cleanup_orphaned_devices()` is called per-storage by `status()`. The second-pass detection compared host-wide NETAPP devices against ONE storage's tracking + ONTAP alive set; sibling storages' WWIDs satisfied "in neither" and got flagged.
- Fix: before flagging, build a union of WWIDs tracked by ANY OTHER netappontap storage (iterates `PVE::Storage::config()` to find sibling netappontap storeids and reads their tracking JSON). WWIDs found there are skipped — they belong to a sibling storage whose own cleanup handles its own orphans.

**Affected scenarios** (when bug manifested):

- Any PVE node with two or more configured `netappontap` storages — extremely common in production (customer separates VM disks across ASA and FAS for tiered performance).
- Warnings rate-limited to once per WWID per hour per node, but with 100+ WWIDs spread across both storages the journal still accumulated dozens of false alarms per hour cluster-wide.

**Not changed** (preserved by the fix):

- Real orphan detection still works: a WWID that is NOT in ANY plugin storage's tracking AND has all paths failed will still be flagged for manual cleanup.
- Per-storage cleanup runs independently — each storage still handles its own orphans via the first-pass tracked-vs-alive comparison.

## [0.2.14] - 2026-05-14

### Temp Clone Host-side Cleanup Release

**Bug Fix (production regression in v0.2.13, found day 1 after deploy):**

- **`volume_snapshot_delete()` and `_cleanup_temp_clones` now fully tear down the host's dm-multipath + sd* devices when removing a temporary FlexClone.** v0.2.13's fix only handled the ONTAP side (`volume_clone_split` + `volume_delete`). After the temp clone's LUN was deleted on ONTAP, the host's `/dev/mapper/<wwid>` and the underlying `sd*` paths were left orphaned. `multipathd` then logged `tur checker reports path is down` for the dead WWID every few seconds, indefinitely. Customer reported the symptom within 24 hours of v0.2.13 deploy: after one CT create + backup + remove cycle, four stale paths spammed syslog continuously. The same gap existed in the TTL-based `_cleanup_temp_clones` background reaper but was less visible (delayed by 1 hour).
- New shared helper `_remove_temp_clone($api, $temp_clone_name)` mirrors `free_image()`'s 7-step pattern: capture slaves → unmap → `cleanup_lun_devices` → remove residual sd* → `multipath_reload` → `volume_clone_split` → wait → `volume_delete`. Both `volume_snapshot_delete` and `_cleanup_temp_clones` route through it.

**Test hardening (response to user feedback "這種問題請加入測試清單"):**

- Section 24 in TESTING.md / TESTING_zh-TW.md updated with explicit HOST-side device residual assertions: after `volume_snapshot_delete`, `get_device_by_wwid` must return undef, sd* slaves must be absent from `/sys/block`, `/dev/mapper/<wwid>` must not exist. These assertions would have caught the v0.2.13 regression in CI; the v0.2.13 test only checked ONTAP-side state. Permanent regression guard.
- CLAUDE.md adds a release-SOP rule: **every test that exercises a delete-on-ONTAP path must include host-side device assertions**. ONTAP-only tests are insufficient for cleanup-class bugs.

**Operational note for existing host-side residuals:**

- Stale devices from backups taken BEFORE v0.2.14 will NOT be auto-cleaned (plugin policy: never auto-clean WWIDs not in tracking, to protect customer's manual storage). `_cleanup_orphaned_devices` will WARN about them via syslog with manual cleanup commands. Operators can sweep them with `multipath -f <wwid>` plus `echo 1 > /sys/block/sdX/device/delete` for each underlying sd path.

## [0.2.13] - 2026-05-13

### Snapshot Delete Cleanup Fix Release

**Bug Fix (production incident, customer report 2026-05-13):**

- **`volume_snapshot_delete()` now removes the dependent temp FlexClone synchronously before deleting the snapshot.** Customer's `vzdump` CT snapshot-mode backup completed successfully but failed at the cleanup step with:
  ```
  snapshot 'vzdump' was not (fully) removed - ONTAP job failed:
    Snapshot copy "pve_snap_vzdump" of volume "..." in SVM "..."
    has not expired or is locked.
  ```
  Root cause: when PVE reads a snapshot (vzdump CT backup, `qm clone --snapname`, `qemu-img convert` from a snapshot, etc.), `path($vol, $snap)` calls `_get_snapshot_path()` which creates a temporary FlexClone with the snapshot as parent. ONTAP locks the parent snapshot from deletion while any FlexClone references it. The plugin's existing cleanup is a TTL-based 1-hour background task (`_cleanup_temp_clones`), but vzdump calls `volume_snapshot_delete` IMMEDIATELY after the backup completes — well within the TTL — so the snapshot delete always fails. The fix synchronously checks for the deterministic temp clone name, refuses to proceed if its LUN is still in use locally (lsof-style holder check via `is_device_in_use`), otherwise unmaps + deletes the temp volume before proceeding with the snapshot delete.

**Risk analysis (production-safety review):**

- Concurrent local readers: PVE locks at VM/CT level, so two parallel readers on the same snapshot inside one node should not happen via standard PVE flows. The `is_device_in_use` check is the safety net for edge cases — refuses with an actionable error message naming the device and `lsof` hint.
- Concurrent cross-node readers: not directly observable from the deleting node. The plugin relies on the convention that `volume_snapshot_delete` is called from the same node that opened the snapshot (which holds for vzdump). Same trade-off as the existing `_cleanup_temp_clones` background reaper.
- API failures during cleanup: each step is `eval`-wrapped. If `volume_delete` of the temp clone fails, the function dies with a clear message and does NOT proceed to call `snapshot_delete` (which would have failed with the original locked error anyway). Operator gets the specific failure instead of the confusing downstream one.
- Background TTL reaper race: if both fire simultaneously and one wins, the other gets "volume not found" — tolerated by `eval`.
- Not changed: `volume_snapshot_rollback`, `free_image`. ONTAP behaviour around clones is different for these (rollback typically allowed, free_image cleans snapshots itself). Separate audit if needed; out of scope for this release.

## [0.2.12] - 2026-05-05

### iSCSI Portal TCP Pre-check Release

**Bug Fixes (sibling-pattern audit from jt-pve-storage-purestorage v1.1.9):**

- **`activate_storage()` now TCP-probes every iSCSI LIF before `iscsiadm` discovery/login.** Previous behaviour iterated every portal returned by `iscsi_get_portals()` and called `iscsiadm -m discovery` followed by `iscsiadm -m node -l` regardless of TCP reachability. On multi-LIF SVMs with asymmetric cabling or partial fabric reach (a common production layout once HA best practices are followed), each unreachable LIF stalled iscsiadm for 30s (discovery) plus up to 60s (login). Wrapping the calls in `eval` prevents the loop from dying but does NOT prevent the cumulative stall. Since `pvestatd` polls `activate_storage` every cycle, the stall cascaded into web UI hangs and starved every other storage on the node. The Pure plugin shipped this exact same fix as v1.1.9 today against a customer field reproducer (4-LIF FlashArray, 2-segment cabling reaching only 1 segment); cross-project audit confirmed the identical pattern existed at `NetAppONTAPPlugin.pm:502-526` and is now fixed.
- The fix is especially important for NetApp because v0.2.11's `_check_lif_redundancy()` actively recommends "distribute LIFs across both controllers" — a configuration that maximises the bug surface when host-side fabric reach is asymmetric.

**API additions:**

- New `probe_portal($ip, $port, timeout => $t)` in `ISCSI.pm`. Bounded `IO::Socket::INET` TCP connect with `alarm()` guard. Returns 1 if reachable within timeout, 0 otherwise.

**New configuration option:**

- `ontap-portal-probe-timeout` (integer 0..30, default 2 seconds). Set to 0 to disable the pre-check (restore pre-0.2.12 behaviour). Raise on high-latency or congested storage networks. Configurable via `pvesm set <storeid> --ontap-portal-probe-timeout <n>`.

**Behavioural change:**

- When all LIFs are unreachable, `activate_storage()` now dies with an actionable message that lists the unreachable portals, the failed portals (with their `iscsiadm` errors), and a hint about `pvesm set <storeid> --nodes <list>` for binding the storage to specific nodes. Previous error said only "Failed to connect to any iSCSI portal".
- When some LIFs are unreachable but at least one is up, a single `warn` lists the skipped portals and recovery hints, then activation continues normally with the reachable subset.

## [0.2.11] - 2026-04-30

### SAN LIF Redundancy Detection Fix Release

**Bug Fixes (after NetApp clarification):**

- **LIF redundancy check now detects "all LIFs share same home_node".** Previous v0.2.10 version only counted total iSCSI LIFs and missed the common misconfiguration where 2+ LIFs are on the same controller. With SAN LIFs not auto-migrating, this configuration provides zero HA redundancy -- a single controller failure takes all LIFs offline simultaneously. The check now verifies LIFs are distributed across at least 2 home_nodes.
- **SAN LIF behavior documentation corrected.** Previous text incorrectly stated iSCSI LIFs migrate to the partner controller during takeover (30-90 seconds). NetApp confirmed: only NAS LIFs auto-migrate; SAN (iSCSI/FC) LIFs do NOT. Path failover relies on host MPIO + ALUA selecting surviving paths. Typical takeover/giveback completes in less than 10 seconds.

**API additions:**

- New `iscsi_get_lifs_with_home_node()` in `API.pm` returns LIF metadata: address, home_node, current_node, state. Used by `_check_lif_redundancy()` for proper HA validation. The existing `iscsi_get_portals()` is unchanged (still used by iSCSI login flow).

**Documentation corrections:**

- `docs/CONFIGURATION.md` and zh-TW: rewrote "ONTAP HA Best Practices > What happens during takeover" section with correct ALUA/MPIO flow.
- `CLAUDE.md` added "ONTAP HA / SAN LIF Behavior" reference section to prevent future documentation errors.

## [0.2.10] - 2026-04-30

### Disaster Prevention & Monitoring Release

**New Monitoring Features:**

- **Storage outage detection.** `status()` now tracks consecutive failures (3 failures = ~30 seconds with 10-second pvestatd polling) and emits syslog ERROR for monitoring system pickup. Re-emits every ~30s while down. Logs INFO recovery message when storage becomes reachable again.
- **Aggregate capacity health check.** During `status()` poll, queries ONTAP aggregate capacity. Emits syslog WARNING at >=90% and ERROR at >=95% (1-hour cooldown per storage). Helps prevent thin-provisioning over-commit failures.
- **LIF redundancy check.** Detects SVMs with fewer than 2 iSCSI LIFs (no path redundancy for ONTAP HA failover) and emits syslog WARNING (24-hour cooldown).
- **In-flight operation detection.** postinst now detects running `qm move-disk`, `qm clone`, `qm migrate`, `qmrestore`, `vzdump`, `pvesm alloc/free` processes and warns with 5-second grace period before service reload.

**Documentation Additions:**

- "Recovery After Storage Disconnect" -- 6-step SOP in TROUBLESHOOTING.md
- "Recovery After Abrupt Power Loss" -- procedure including LUN reservation timeout guidance
- "Updating ONTAP Password" -- complete SOP including service reload requirement
- "ONTAP HA Best Practices" -- recommended LIF layout, multipath verification, reservation timeout
- "Will upgrading affect running VMs?" -- explains plugin upgrade does not affect VM I/O path
- "Monitoring & Alerts" -- syslog event reference table for monitoring integration
- Documentation website updated with all new sections

**Tag:** `pve-storage-netapp` (use `journalctl -t pve-storage-netapp` to query plugin syslog messages)

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
