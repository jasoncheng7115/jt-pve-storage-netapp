# NetApp ONTAP SAN/iSCSI Storage Plugin for Proxmox VE

**[English](README.md)** | **[繁體中文](README_zh-TW.md)**

A storage plugin that enables Proxmox VE to use NetApp ONTAP storage systems via iSCSI or FC protocol for VM disk storage.

## Disclaimer

> **WARNING: This is a newly developed project. Use at your own risk.**
>
> - This plugin is provided "AS IS" without warranty of any kind
> - **iSCSI protocol has been tested but not extensively in production environments**
> - **FC (Fibre Channel) protocol has NOT been fully verified**
> - Always test thoroughly in a non-production environment before deployment
> - The authors are not responsible for any data loss or system issues
> - Back up your data regularly and have a recovery plan in place
>
> **Recommended usage:**
> - Start with non-critical VMs for evaluation
> - Monitor storage operations closely

## Features

- **1 VM disk = 1 LUN = 1 FlexVol** - Clean snapshot semantics matching PVE model
- **Snapshot create/delete/rollback** - Via ONTAP Volume Snapshots
- **Template & Linked Clone** - Instant clones via NetApp FlexClone (space-efficient, no data copy)
- **Full Clone from VM Snapshot** - Clone any VM from a specific snapshot to independent VM
- **Real-time capacity reporting** - From ONTAP REST API (aggregate or volume-based)
- **Multipath I/O support** - For high availability with automatic device discovery
- **Cluster-aware** - Supports live migration between PVE nodes
- **Thin provisioning** - Efficient storage utilization with space guarantee options
- **Per-node or shared igroups** - Flexible access control modes
- **iSCSI and FC SAN support** - Choose transport protocol per storage
- **Automatic iSCSI management** - Target discovery, login, and session handling
- **Automatic FC HBA detection** - WWPN discovery and igroup management
- **SCSI device lifecycle** - Automatic device cleanup on volume deletion

## Web UI Support

> **Note:** This is a custom/third-party storage plugin. Due to Proxmox VE's architecture, custom plugins are NOT listed in the Web UI "Add Storage" dropdown menu. Storage must be added via CLI (`pvesm add`).

**After adding via CLI, the storage will:**
- Appear in the Web UI storage list (Datacenter -> Storage)
- Be available for VM disk creation in the Web UI
- Show capacity and status in the Web UI
- Support all VM operations (create, snapshot, migrate, etc.)

## Requirements

### Proxmox VE

- **Proxmox VE 9.1 or later** (Storage API version 13 required)
- Tested on: PVE 9.1

| PVE Version | Storage API | Compatibility |
|-------------|-------------|---------------|
| PVE 9.1+ | 13 | Supported |

### NetApp ONTAP

- ONTAP 9.8 or later (REST API required)
- iSCSI license enabled
- SVM with iSCSI service enabled
- At least one iSCSI LIF configured
- Aggregate with available space
- User account with appropriate REST API permissions

### ONTAP User Permissions

The ONTAP user requires the following permissions:
- Read/Write access to volumes in the target SVM
- Read/Write access to LUNs
- Read/Write access to igroups
- Read/Write access to snapshots
- Read access to aggregates (for capacity reporting)
- Read access to network interfaces (for iSCSI portal discovery)

### PVE Node Dependencies

| Package | Purpose | Required |
|---------|---------|----------|
| `open-iscsi` | iSCSI initiator (iscsiadm) | Yes (for iSCSI) |
| `multipath-tools` | Multipath I/O daemon (multipathd) | Yes |
| `sg3-utils` | SCSI utilities (sg_inq) | Yes |
| `psmisc` | Process utilities (fuser) - for device-in-use detection | Yes |
| `libwww-perl` | HTTP client for REST API | Yes |
| `libjson-perl` | JSON encoding/decoding | Yes |
| `liburi-perl` | URI handling | Yes |
| `lsscsi` | List SCSI devices (troubleshooting) | Recommended |

## Installation

### First-Time Installation (Recommended Order)

> **IMPORTANT:** Install dependencies BEFORE installing the plugin package to avoid dependency resolution issues.

```bash
# Step 1: Update apt cache (required!)
apt update

# Step 2: Install ALL dependencies first
apt install -y open-iscsi multipath-tools sg3-utils psmisc \
    libwww-perl libjson-perl liburi-perl lsscsi

# Step 3: Enable required services
systemctl enable --now iscsid
systemctl enable --now multipathd

# Step 4: Install the plugin package
# (Automatically configures multipath and restarts PVE services)
dpkg -i jt-pve-storage-netapp_0.1.7-1_all.deb
```

> **Note:** The plugin automatically:
> - Adds NetApp device configuration to `/etc/multipath.conf`
> - Restarts `pvedaemon` and `pveproxy` to load the plugin

### If You Already Tried dpkg First (Fix Broken State)

If you ran `dpkg -i` before installing dependencies and got errors like:
```
dpkg: dependency problems prevent configuration of jt-pve-storage-netapp
```

Run these commands to fix:
```bash
# Update apt cache first!
apt update

# Fix broken dependencies (installs missing packages)
apt --fix-broken install -y

# Verify installation
dpkg -l | grep jt-pve-storage-netapp
```

### Cluster Installation (All Nodes)

> **CRITICAL:** In a Proxmox VE cluster, this plugin **MUST be installed on ALL nodes**.

Storage configurations are shared cluster-wide via `/etc/pve/storage.cfg`. Nodes without the plugin will show:
```
Parameter verification failed. (400)
storage: No such storage
```

**Install on EACH node:**
```bash
# On each node in the cluster:
apt update
apt install -y open-iscsi multipath-tools sg3-utils psmisc \
    libwww-perl libjson-perl liburi-perl lsscsi
systemctl enable --now iscsid multipathd

# Install plugin (auto-configures multipath and restarts PVE services)
dpkg -i jt-pve-storage-netapp_0.1.7-1_all.deb
```

**Installation Order for Clusters:**
1. Install the plugin on ALL nodes first
2. Then add the storage configuration (only once, on any node)

## Quick Start

After installing the plugin (see [Installation](#installation) above), add storage:

### 1. Add Storage

**iSCSI Example:**
```bash
pvesm add netappontap netapp1 \
    --ontap-portal 192.168.1.100 \
    --ontap-svm svm0 \
    --ontap-aggregate aggr1 \
    --ontap-username pveadmin \
    --ontap-password 'YourSecurePassword' \
    --content images \
    --shared 1
```

**FC (Fibre Channel) Example:**
```bash
pvesm add netappontap netapp-fc \
    --ontap-portal 192.168.1.100 \
    --ontap-svm svm0 \
    --ontap-aggregate aggr1 \
    --ontap-username pveadmin \
    --ontap-password 'YourSecurePassword' \
    --ontap-protocol fc \
    --content images \
    --shared 1
```

### 2. Verify

```bash
pvesm status
# Name        Type           Status  Total   Used  Available
# netapp1     netappontap    active  ...     ...   ...
```

For detailed configuration options, see [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

## Configuration Options

All plugin-specific options use the `ontap-` prefix to avoid conflicts with other PVE storage plugins.

### Required Options

| Option | Description | Example |
|--------|-------------|---------|
| `ontap-portal` | ONTAP management IP or hostname | `192.168.1.100` |
| `ontap-svm` | Storage Virtual Machine (SVM/Vserver) name | `svm0` |
| `ontap-aggregate` | Aggregate for volume creation | `aggr1` |
| `ontap-username` | ONTAP API username | `pveadmin` |
| `ontap-password` | ONTAP API password | `YourSecurePassword` |

### Optional Options

| Option | Default | Description |
|--------|---------|-------------|
| `ontap-protocol` | `iscsi` | SAN protocol: `iscsi` or `fc` (Fibre Channel) |
| `ontap-ssl-verify` | `1` | Verify SSL certificates (0=disable for self-signed) |
| `ontap-thin` | `1` | Use thin provisioning (0=thick provisioning) |
| `ontap-igroup-mode` | `per-node` | igroup mode: `per-node` or `shared` |
| `ontap-cluster-name` | `pve` | Cluster name for igroup naming |
| `ontap-device-timeout` | `60` | Device discovery timeout in seconds |

### Example storage.cfg (iSCSI)

```ini
netappontap: netapp1
    ontap-portal 192.168.1.100
    ontap-svm svm0
    ontap-aggregate aggr1
    ontap-username pveadmin
    ontap-password YourSecurePassword
    ontap-protocol iscsi
    ontap-thin 1
    ontap-igroup-mode per-node
    content images
    shared 1
```

### Example storage.cfg (FC SAN)

```ini
netappontap: netapp-fc
    ontap-portal 192.168.1.100
    ontap-svm svm0
    ontap-aggregate aggr1
    ontap-username pveadmin
    ontap-password YourSecurePassword
    ontap-protocol fc
    ontap-thin 1
    ontap-igroup-mode per-node
    content images
    shared 1
```

> **Note:** For FC, `ontap-portal` is still required for ONTAP REST API access. FC data path uses FC fabric, not the management IP.

For detailed configuration options, see [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

## Usage

### Create VM Disk

```bash
# Using qm (recommended)
qm set 100 --scsi0 netapp1:32

# Using pvesm directly
pvesm alloc netapp1 100 vm-100-disk-0 32G
```

### Snapshots

```bash
# Create snapshot
qm snapshot 100 backup1 --description "Before upgrade"

# List snapshots
qm listsnapshot 100

# Rollback (VM must be stopped)
qm stop 100
qm rollback 100 backup1
qm start 100

# Delete snapshot
qm delsnapshot 100 backup1
```

### Resize Disk

```bash
# Stop VM first (recommended)
qm stop 100

# Resize (add 10GB)
qm resize 100 scsi0 +10G

# Start VM
qm start 100
```

### Live Migration

```bash
# Migrate VM 100 to node pve2
qm migrate 100 pve2 --online
```

### Disable/Enable Storage

```bash
# Disable storage (prevents new operations)
pvesm set netapp1 --disable 1

# Enable storage
pvesm set netapp1 --disable 0

# Check storage status
pvesm status
```

> **Note:** Disabling storage does NOT automatically disconnect iSCSI sessions or API connections. The plugin keeps iSCSI sessions active for quick re-enablement.

### iSCSI Session Management

```bash
# View current iSCSI sessions
iscsiadm -m session

# View multipath devices
multipathd show maps

# Manual logout from all iSCSI targets (optional, after disabling storage)
iscsiadm -m node --logout

# Manual rescan iSCSI sessions
iscsiadm -m session --rescan

# Rescan SCSI hosts for new devices
for host in /sys/class/scsi_host/host*/scan; do echo "- - -" > $host; done

# Reload multipath configuration
multipathd reconfigure
```

### Complete Disconnection Procedure

If you need to completely disconnect from NetApp storage:

```bash
# 1. Stop all VMs using this storage first!
qm list | grep netapp1  # Check which VMs use this storage

# 2. Disable the storage
pvesm set netapp1 --disable 1

# 3. Logout from iSCSI targets
iscsiadm -m node --logout

# 4. Verify sessions are closed
iscsiadm -m session  # Should show "No active sessions"

# 5. To reconnect later, simply enable the storage
pvesm set netapp1 --disable 0
# The plugin will automatically rediscover and login to iSCSI targets
```

## Architecture

### 1:1:1 Architecture Model

```
Proxmox VE Cluster                    NetApp ONTAP
+------------------+                  +-------------------+
|   PVE Node 1     |                  |   SVM: svm0       |
|   +----------+   |    iSCSI         |   +-------------+ |
|   | VM 100   |<--+----------------->|   | FlexVol     | |
|   | scsi0    |   |   multipath      |   | pve_..._100 | |
|   +----------+   |                  |   | +-------+   | |
+------------------+                  |   | | LUN   |   | |
        |                             |   | | lun0  |   | |
        | live migration              |   | +-------+   | |
        v                             |   +-------------+ |
+------------------+                  |                   |
|   PVE Node 2     |                  |   igroups:        |
|   +----------+   |    iSCSI         |   - pve_pve_pve1  |
|   | VM 100   |<--+----------------->|   - pve_pve_pve2  |
|   | scsi0    |   |   multipath      |                   |
|   +----------+   |                  +-------------------+
+------------------+
```

### Object Mapping

| PVE Object | ONTAP Object | Naming Pattern |
|------------|--------------|----------------|
| Storage | - | User defined (e.g., `netapp1`) |
| VM Disk | FlexVol | `pve_{storage}_{vmid}_disk{id}` |
| VM Disk | LUN | `/vol/{flexvol}/lun0` |
| Snapshot | Volume Snapshot | `pve_snap_{snapname}` |
| PVE Node | igroup | `pve_{cluster}_{node}` |
| Cloud-init | FlexVol | `pve_{storage}_{vmid}_cloudinit` |
| VM State | FlexVol | `pve_{storage}_{vmid}_state_{snap}` |

For detailed naming conventions, see [docs/NAMING_CONVENTIONS.md](docs/NAMING_CONVENTIONS.md).

### Data Flow

**Volume Creation:**
1. PVE calls `alloc_image()` with vmid and size
2. Plugin generates ONTAP volume name via Naming module
3. Creates FlexVol with specified size + 64MB overhead
   - Volume autogrow enabled (expands automatically when needed, up to 2x size)
4. Creates LUN within FlexVol
5. Maps LUN to node's igroup
6. Returns PVE volume name (`vm-{vmid}-disk-{diskid}`)

**Volume Activation:**
1. PVE calls `activate_volume()` with volname
2. Ensures LUN is mapped to current node's igroup
3. Rescans iSCSI sessions and SCSI hosts
4. Reloads multipath configuration
5. Waits for device to appear (up to 60 seconds)
6. Returns device path

**Snapshot Rollback:**
1. PVE calls `volume_snapshot_rollback()` with volname and snapname
2. Plugin converts names to ONTAP format
3. Calls ONTAP REST API to restore volume to snapshot
4. Rescans SCSI hosts for any size changes
5. Reloads multipath configuration

## igroup Modes

### per-node (Default)

Creates one igroup per PVE node: `pve_{cluster}_{nodename}`

- Each node has its own initiator group
- LUNs are mapped to all node igroups
- More granular access control
- **Recommended for production**

### shared

Creates one igroup for all nodes: `pve_{cluster}_shared`

- All PVE nodes share one initiator group
- Simpler management
- All nodes must be trusted
- Suitable for small clusters

## Module Architecture

```
PVE::Storage::Plugin (Proxmox VE base class)
    |
    +-- PVE::Storage::Custom::NetAppONTAPPlugin (main plugin)
            |
            +-- uses: API.pm        (ONTAP REST API client)
            +-- uses: Naming.pm     (PVE <-> ONTAP name mapping)
            +-- uses: ISCSI.pm      (iSCSI target/session management)
            +-- uses: Multipath.pm  (Linux multipath & SCSI handling)
```

### Module Details

| Module | Lines | Description |
|--------|-------|-------------|
| **NetAppONTAPPlugin.pm** | 825 | Main plugin - storage operations, volume management, snapshots |
| **API.pm** | 787 | ONTAP REST API client - volumes, LUNs, igroups, snapshots |
| **Multipath.pm** | 482 | Multipath I/O and SCSI device management |
| **ISCSI.pm** | 412 | iSCSI initiator management (iscsiadm wrapper) |
| **Naming.pm** | 300 | Naming convention utilities and validation |
| **Total** | **2,806** | Complete plugin implementation |

### API.pm Functions

**Volume Operations:**
- `volume_create()` - Create FlexVol with thin/thick provisioning
- `volume_get()` / `volume_list()` - Query volumes
- `volume_delete()` / `volume_resize()` - Manage volumes
- `volume_space()` - Get space usage
- `volume_clone()` - Create FlexClone volume from parent
- `volume_clone_split()` - Split clone for independent volume
- `volume_is_clone()` / `volume_get_clone_parent()` - Query clone info
- `volume_get_clone_children()` - List dependent clones
- `license_has_flexclone()` - Check FlexClone license availability

**LUN Operations:**
- `lun_create()` - Create LUN within volume
- `lun_get()` / `lun_delete()` / `lun_resize()` - Manage LUNs
- `lun_get_serial()` / `lun_get_wwid()` - Get identifiers
- `lun_map()` / `lun_unmap()` / `lun_is_mapped()` - igroup mapping

**Snapshot Operations:**
- `snapshot_create()` / `snapshot_delete()` - Manage snapshots
- `snapshot_list()` / `snapshot_get()` - Query snapshots
- `snapshot_rollback()` - Restore to snapshot

**igroup Operations:**
- `igroup_create()` / `igroup_get()` / `igroup_get_or_create()`
- `igroup_add_initiator()` / `igroup_remove_initiator()`
- `igroup_list()` - List all igroups in SVM

**Other:**
- `iscsi_get_portals()` - Get iSCSI LIF addresses
- `get_managed_capacity()` - Get storage capacity
- `wait_for_job()` - Handle async operations

### ISCSI.pm Functions

- `get_initiator_name()` / `set_initiator_name()` - Manage local IQN
- `discover_targets()` - SendTargets discovery
- `login_target()` / `logout_target()` - Session management
- `get_sessions()` / `is_target_logged_in()` - Query sessions
- `rescan_sessions()` - Rescan for new LUNs
- `wait_for_device()` - Wait for device appearance
- `delete_node()` - Remove iSCSI node configuration

### Multipath.pm Functions

- `rescan_scsi_hosts()` - Trigger SCSI bus rescan
- `multipath_reload()` / `multipath_flush()` - Manage multipathd
- `get_multipath_device()` - Find device by WWID
- `get_device_by_wwid()` - Find device path
- `wait_for_multipath_device()` - Wait with timeout
- `get_scsi_devices_by_serial()` - Find devices by serial
- `remove_scsi_device()` / `rescan_scsi_device()` - Device lifecycle
- `cleanup_lun_devices()` - Clean up after LUN deletion

### Naming.pm Functions

- `encode_volume_name()` / `decode_volume_name()` - FlexVol names
- `encode_lun_path()` / `decode_lun_path()` - LUN paths
- `encode_snapshot_name()` / `decode_snapshot_name()` - Snapshot names
- `encode_igroup_name()` - igroup names
- `sanitize_for_ontap()` - Clean strings for ONTAP
- `pve_volname_to_ontap()` / `ontap_to_pve_volname()` - Full conversion
- `is_pve_managed_volume()` - Validate managed volumes

## Supported Features

| Feature | Status | Notes |
|---------|--------|-------|
| Disk create/delete | Supported | FlexVol + LUN creation |
| Disk resize | Supported | VM must be stopped |
| Snapshots | Supported | ONTAP Volume Snapshots |
| Snapshot rollback | Supported | VM must be stopped |
| Live migration | Supported | Via shared iSCSI access |
| Thin provisioning | Supported | Default enabled |
| Multipath I/O | Supported | Automatic configuration |
| Template | Supported | Convert VM to template |
| Linked Clone | Supported | Via NetApp FlexClone (instant, space-efficient) |
| Full Clone | Supported | Via qemu-img copy from current state |
| Full Clone from Snapshot | Supported | Via temporary FlexClone + qemu-img copy |
| Backup (vzdump) | Supported | Via snapshot |
| RAM Snapshot (vmstate) | Supported | VM state saved to dedicated LUN (v0.1.7+) |

## Testing Status

| Protocol | Status | Notes |
|----------|--------|-------|
| **iSCSI** | Tested | Functional testing completed, not extensively tested in production |
| **FC (Fibre Channel)** | Not Fully Verified | Basic implementation exists, requires real FC environment testing |

## Known Limitations

1. **Storage Deactivation**
   - When disabling/removing storage, iSCSI sessions are cleaned up
   - Devices still in use by VMs are skipped (safety check)
   - FC cleanup relies on multipath only (no logout required)

2. **FlexClone License**
   - Template and Linked Clone features require NetApp FlexClone license
   - The plugin checks for license and provides helpful error message if missing

3. **ONTAP Metadata Staleness**
   - After deleting FlexClones, ONTAP may briefly report stale `has_flexclone` metadata
   - Plugin includes retry logic (5 attempts, 2 second delays) to handle this

4. **Web UI Limitation**
   - Custom plugins cannot be added via Web UI "Add Storage" dropdown
   - Must use CLI (`pvesm add`) to add storage
   - After adding, storage appears in Web UI normally

## PVE Version Upgrade Compatibility

This section describes the impact of Proxmox VE version upgrades on this plugin.

### Storage API Version Dependency

The plugin declares its API version in `NetAppONTAPPlugin.pm`:

```perl
use constant APIVERSION => 13;
use constant MIN_APIVERSION => 9;
```

| Scenario | Impact |
|----------|--------|
| PVE Storage API remains 13 | Fully compatible |
| PVE Storage API upgrades to 14+ | **Plugin update may be required** |
| PVE Storage API downgrade | Not compatible (won't happen on upgrade) |

### PVE Internal Module Dependencies

The plugin depends on these PVE internal modules:

| Module | Usage | Stability Risk |
|--------|-------|----------------|
| `PVE::Storage::Plugin` | Base class for storage plugins | Medium (core API) |
| `PVE::Tools` | Utility functions (`run_command`) | Low |
| `PVE::JSONSchema` | Schema validation | Low |
| `PVE::Cluster` | Cluster configuration | Low |
| `PVE::INotify` | Get node name | Low |
| `PVE::ProcFSTools` | Process utilities | Low |

### System-Level Dependencies

These are independent of PVE version but may be affected by Debian base system upgrades:

| Dependency | Package | Risk |
|------------|---------|------|
| `iscsiadm` | open-iscsi | Low (stable interface) |
| `multipathd` | multipath-tools | Low (stable interface) |
| `sg_inq` | sg3-utils | Low (stable interface) |
| Perl modules | libwww-perl, libjson-perl, liburi-perl | Low |

### Upgrade Compatibility Matrix

| Upgrade Path | Expected Compatibility | Risk Level |
|--------------|------------------------|------------|
| 9.1 → 9.2 | Compatible | Low |
| 9.x → 10.x | **Requires testing** | Medium |

### Potential Breaking Changes

| Scenario | Likelihood | Impact | Resolution |
|----------|------------|--------|------------|
| Storage API method signature change | Medium | Plugin malfunction | Update plugin code |
| New required methods added | Low | Plugin fails to load | Implement new methods |
| Removed PVE functions | Low | Runtime errors | Update plugin code |
| Perl version upgrade | Low | Syntax issues | Test and fix |

### Recommended Upgrade Procedure

```bash
# 1. Pre-upgrade: Backup configuration
cp /etc/pve/storage.cfg /root/storage.cfg.bak
pvesm status > /root/storage-status-before.txt

# 2. Perform PVE upgrade
apt update && apt dist-upgrade

# 3. Post-upgrade: Verify plugin functionality
pvesm status                              # Check storage status
journalctl -xeu pvedaemon --since "5 min" # Check for errors

# 4. If issues occur: Reinstall plugin
dpkg -i jt-pve-storage-netapp_*.deb
systemctl restart pvedaemon pveproxy

# 5. Verify Perl syntax (if needed)
perl -c /usr/share/perl5/PVE/Storage/Custom/NetAppONTAPPlugin.pm
perl -c /usr/share/perl5/PVE/Storage/Custom/NetAppONTAP/API.pm
perl -c /usr/share/perl5/PVE/Storage/Custom/NetAppONTAP/ISCSI.pm
perl -c /usr/share/perl5/PVE/Storage/Custom/NetAppONTAP/Multipath.pm
perl -c /usr/share/perl5/PVE/Storage/Custom/NetAppONTAP/Naming.pm
```

### Best Practices for Major Version Upgrades

1. **Test in non-production environment first**
   - Clone your PVE configuration to a test system
   - Perform the upgrade and verify plugin functionality

2. **Check Proxmox release notes**
   - Look for "BREAKING CHANGES" sections
   - Check Storage API version changes
   - Review Perl version changes

3. **Monitor official channels**
   - [Proxmox VE Roadmap](https://pve.proxmox.com/wiki/Roadmap)
   - [Storage Plugin Development Wiki](https://pve.proxmox.com/wiki/Storage_Plugin_Development)
   - Proxmox Forum announcements

4. **Prepare rollback plan**
   - Keep backup of `/etc/pve/storage.cfg`
   - Document current working plugin version
   - Have previous PVE version restore plan ready

### Verifying Plugin After Upgrade

```bash
# Check if plugin is loaded
pvesm pluginhelp netappontap

# Test storage activation
pvesm set netapp1 --disable 0
pvesm status

# Test basic operations (on test VM)
pvesm alloc netapp1 9999 vm-9999-disk-0 1G
pvesm free netapp1:vm-9999-disk-0
```

## Troubleshooting

### Storage Not Active

```bash
# Check ONTAP API connectivity
curl -k -u pveadmin:password https://192.168.1.100/api/cluster

# Check iSCSI sessions
iscsiadm -m session

# Check multipath
multipathd show maps
```

### Device Not Found After Create

```bash
# Rescan iSCSI sessions
iscsiadm -m session --rescan

# Rescan SCSI hosts
for host in /sys/class/scsi_host/host*/scan; do echo "- - -" > $host; done

# Reload multipath
multipathd reconfigure

# Check device by WWID
multipathd show maps raw format "%n %w"
```

### igroup Issues

```bash
# Check initiator name
cat /etc/iscsi/initiatorname.iscsi

# Verify igroup on ONTAP (via SSH or System Manager)
# Ensure initiator IQN is in the igroup
```

### Check Logs

```bash
# PVE daemon logs
journalctl -xeu pvedaemon --since "10 minutes ago"

# iSCSI logs
journalctl -u iscsid --since "10 minutes ago"

# Multipath logs
journalctl -u multipathd --since "10 minutes ago"
```

### Common Error Messages

| Error | Cause | Solution |
|-------|-------|----------|
| `No such storage` / `Parameter verification failed (400)` | Plugin not installed on node | Install plugin on ALL cluster nodes |
| `SVM not found` | Incorrect SVM name | Verify `ontap-svm` setting |
| `No iSCSI portals found` | iSCSI not configured | Enable iSCSI service on SVM |
| `Device did not appear` | LUN mapping issue | Check igroup and initiator |
| `ONTAP API Error 401` | Authentication failed | Verify username/password |
| `Cannot get WWID` | LUN not accessible | Check iSCSI sessions |
| `Cannot shrink LUN` | Resize request smaller than current | Only expand is supported |
| `device is still in use` | VM running or device mounted | Stop VM before deleting disk |
| `Insecure dependency in exec` | Taint mode issue (old plugin version) | Update to v0.1.2+ |
| `Device for LUN ... not found` | Volume exists on ONTAP but device not accessible | Start VM or check iSCSI connectivity |

### Plugin Not Installed on All Nodes

If you see this error when accessing a node in the cluster:
```
Parameter verification failed. (400)
storage: No such storage
```

**Cause:** The NetApp storage is configured in `/etc/pve/storage.cfg` (cluster-wide), but the plugin is not installed on this specific node.

**Solution:**
```bash
# Install on the affected node
dpkg -i jt-pve-storage-netapp_0.1.7-1_all.deb
apt install -f
systemctl restart pvedaemon pveproxy
```

### Hung Kernel Tasks (vgs blocked)

If you see errors in `dmesg` like:
```
INFO: task vgs:12345 blocked for more than 120 seconds
```

**Cause:** A multipath device has failed paths and processes waiting for I/O are stuck in kernel D state.

**Solution:**
```bash
# Check multipath status
multipath -ll

# Look for "failed faulty" paths like:
# `- 4:0:0:1 sdd 8:48 failed faulty running

# Remove the faulty SCSI device
echo 1 > /sys/block/sdd/device/delete

# Flush orphaned multipath device
multipath -f <WWID>

# Reconfigure multipath
multipathd reconfigure
```

**Prevention:** Ensure iSCSI targets are accessible before creating/activating volumes.

### Linked Clone Device Not Accessible

When working with a linked clone VM that was never started, the local device may not exist.

**Behavior (v0.1.3+):** The plugin returns a synthetic path (`/dev/mapper/$wwid`) and operations like delete proceed normally via ONTAP API.

**For older versions:** You may see:
```
Device for LUN /vol/pve_netapp1_xxx_disk0/lun0 not found
```

**Solution for older versions:**
```bash
# Upgrade to v0.1.3+ which handles this automatically
# Or manually delete from ONTAP via REST API or System Manager
```

### Multipath WWID Mismatch

If `scsi_id` and `multipath` show different WWIDs for the same device:
```bash
# Check actual device WWID
/lib/udev/scsi_id -g -u /dev/sdX

# Check multipath WWID
multipathd show maps raw format "%w"
```

**Cause:** Stale multipath cache after LUN replacement or recreation.

**Solution:**
```bash
# Remove stale multipath device
multipathd del map <old_wwid>

# Flush and reconfigure
multipath -F
multipathd reconfigure
```

For detailed troubleshooting, see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Uninstallation

```bash
# 1. Remove all VMs using this storage first!

# 2. Remove storage configuration
pvesm remove netapp1

# 3. Uninstall package
apt remove jt-pve-storage-netapp

# 4. Restart services
systemctl restart pvedaemon pveproxy
```

## Development

### Building from Source

```bash
git clone https://github.com/jasoncheng7115/jt-pve-storage-netapp.git
cd jt-pve-storage-netapp

# Syntax check
make test

# Build deb package
make deb

# Install directly (development)
make install
```

### Project Structure

```
jt-pve-storage-netapp/
├── lib/PVE/Storage/Custom/
│   ├── NetAppONTAPPlugin.pm      # Main plugin (storage operations)
│   └── NetAppONTAP/
│       ├── API.pm                # ONTAP REST API client
│       ├── ISCSI.pm              # iSCSI session management
│       ├── Multipath.pm          # Multipath device management
│       └── Naming.pm             # Naming convention utilities
├── debian/                       # Debian packaging files
│   ├── control                   # Package metadata & dependencies
│   ├── rules                     # Build rules
│   ├── changelog                 # Version history
│   ├── postinst                  # Post-install script
│   ├── prerm                     # Pre-removal script
│   └── postrm                    # Post-removal script
├── docs/                         # Documentation
│   ├── QUICKSTART.md             # Quick start guide
│   ├── CONFIGURATION.md          # Configuration reference
│   ├── NAMING_CONVENTIONS.md     # Naming patterns
│   └── TROUBLESHOOTING.md        # Troubleshooting guide
├── tests/                        # Test directory
├── Makefile                      # Build and install rules
└── README.md                     # This file
```

### API Constants

```perl
# API.pm
DEFAULT_TIMEOUT     => 30      # HTTP request timeout (seconds)
DEFAULT_RETRY_COUNT => 3       # Number of retry attempts
DEFAULT_RETRY_DELAY => 2       # Delay between retries (seconds)
API_VERSION         => '9.8'   # Minimum ONTAP REST API version

# ISCSI.pm
DISCOVERY_TIMEOUT   => 30      # Target discovery timeout
LOGIN_TIMEOUT       => 60      # Target login timeout
DEVICE_WAIT_TIMEOUT => 30      # Device appearance timeout

# Multipath.pm
DEVICE_WAIT_TIMEOUT   => 60    # Multipath device wait timeout
DEVICE_WAIT_INTERVAL  => 2     # Wait interval between checks

# Naming.pm
MAX_VOLUME_NAME_LENGTH   => 203
MAX_LUN_NAME_LENGTH      => 255
MAX_SNAPSHOT_NAME_LENGTH => 255
MAX_IGROUP_NAME_LENGTH   => 96
```

### Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run `make test` to verify syntax
5. Submit a pull request

## License

MIT License

## Author

Jason Cheng (Jason Tools)

## Acknowledgments

Special thanks to **NetApp** for generously providing the development and testing environment that made this project possible.

我們特別感謝 **NetApp 原廠**協助提供開發測試環境，使本專案得以順利完成。

## References

- [Proxmox Storage Plugin Development](https://pve.proxmox.com/wiki/Storage_Plugin_Development)
- [NetApp ONTAP REST API Documentation](https://docs.netapp.com/us-en/ontap-automation/)
- [PureStorage Plugin](https://github.com/kolesa-team/pve-purestorage-plugin) (reference implementation)
- [StorPool Plugin](https://github.com/storpool/pve-storpool) (reference implementation)

## Safety Features

The plugin includes multiple safety mechanisms to prevent data loss and operational errors:

### Data Protection

| Protection | Description |
|------------|-------------|
| **Shrink Prevention** | Prevents LUN shrinking which would cause data loss |
| **In-Use Check** | Verifies device is not mounted/in-use before deletion |
| **Volume Collision Check** | Prevents creating volumes with duplicate names |
| **Snapshot Collision Check** | Prevents creating snapshots with duplicate names |
| **Capacity Pre-Check** | Verifies aggregate space before thick provisioning |
| **FlexClone Parent Protection** | Prevents deleting templates with linked clone children |

### Operational Safety

| Feature | Description |
|---------|-------------|
| **API Cache TTL** | 5-minute cache expiration prevents stale data issues |
| **Taint Mode Compatible** | All device paths are properly untainted for PVE compatibility |
| **Cleanup on Failure** | Automatic rollback of partial operations (e.g., volume creation) |

### Error Messages

The plugin provides clear, actionable error messages:

```
# Shrink attempt
Cannot shrink LUN: current size 32.00GB, requested 16.00GB. Shrinking would cause data loss.

# Device in use
Cannot delete volume 'vm-100-disk-0': device /dev/mapper/xxx is still in use
(mounted, has holders, or open by process). Please stop the VM and unmount first.

# Volume exists
Volume 'pve_netapp1_100_disk0' already exists on ONTAP. This may indicate a
naming conflict or orphaned volume.

# Insufficient space
Insufficient space in aggregate 'aggr1': available 10.50GB, required 32.00GB

# Template with linked clones
Cannot delete volume 'vm-100-disk-0': it has FlexClone children depending on it.
Dependent volumes: pve_netapp1_101_disk0, pve_netapp1_102_disk0.
Please delete or split the clones first.
```
