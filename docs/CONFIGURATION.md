# Configuration Reference - NetApp ONTAP Storage Plugin

## Disclaimer

> **WARNING: This is a newly developed project. Use at your own risk.**
>
> - **iSCSI protocol has been tested but not extensively in production environments**
> - **FC (Fibre Channel) protocol has NOT been fully verified**
> - Always test thoroughly in a non-production environment before deployment
> - See README.md for full disclaimer and known limitations

## Overview

This document provides detailed information about all configuration options available for the NetApp ONTAP storage plugin.

## Adding Storage

### Via CLI (Recommended)

```bash
pvesm add netappontap <storage-id> [OPTIONS]
```

### Via storage.cfg

Edit `/etc/pve/storage.cfg`:

```ini
netappontap: <storage-id>
    <option> <value>
    ...
```

## Required Options

### ontap-portal

**Type:** string
**Required:** Yes
**Description:** ONTAP cluster or SVM management IP address or hostname

```bash
--ontap-portal 192.168.1.100
--ontap-portal ontap.example.com
```

**Notes:**
- Use the management LIF IP address
- For SVM-scoped users, use the SVM management LIF
- HTTPS is always used (port 443)

### ontap-svm

**Type:** string
**Required:** Yes
**Description:** Storage Virtual Machine (Vserver) name

```bash
--ontap-svm svm0
--ontap-svm vs_prod
```

**Notes:**
- Must be an existing SVM with iSCSI service enabled
- The API user must have access to this SVM

### ontap-aggregate

**Type:** string
**Required:** Yes
**Description:** Aggregate name for volume creation

```bash
--ontap-aggregate aggr1
--ontap-aggregate aggr_ssd_01
```

**Notes:**
- Must be an existing aggregate with available space
- All volumes created by this storage will use this aggregate
- Choose appropriate aggregate based on performance requirements

### ontap-username

**Type:** string
**Required:** Yes
**Description:** ONTAP API username

```bash
--ontap-username pveadmin
--ontap-username admin
```

**Notes:**
- Recommend using a dedicated user with minimum required permissions
- See [ONTAP User Setup](#ontap-user-setup) section below

### ontap-password

**Type:** string
**Required:** Yes
**Description:** ONTAP API password

```bash
--ontap-password 'YourSecurePassword'
```

**Notes:**
- Use single quotes to prevent shell expansion of special characters
- Password is stored in `/etc/pve/storage.cfg` (cluster-wide, root-only access)

## Optional Options

### ontap-protocol

**Type:** enum (iscsi, fc)
**Default:** iscsi
**Description:** SAN transport protocol

```bash
--ontap-protocol iscsi   # iSCSI over Ethernet (default)
--ontap-protocol fc      # Fibre Channel
```

**iSCSI mode:**
- Requires iSCSI initiator (open-iscsi)
- Automatic target discovery and login
- Uses IQN for initiator identification

**FC mode:**
- Requires FC HBA (Fibre Channel Host Bus Adapter)
- Automatic WWPN discovery from FC HBA
- Uses WWPN for initiator identification
- No target login required (FC fabric handles connectivity)

**Notes:**
- Both protocols use the same multipath configuration
- Both protocols use WWID for device identification
- `ontap-portal` is still required for API access in FC mode

### ontap-ssl-verify

**Type:** boolean (0 or 1)
**Default:** 1
**Description:** Verify ONTAP SSL certificate

```bash
--ontap-ssl-verify 0   # Disable verification
--ontap-ssl-verify 1   # Enable verification (default)
```

**Notes:**
- Set to 0 for self-signed certificates
- For production, use valid certificates and keep verification enabled

### ontap-thin

**Type:** boolean (0 or 1)
**Default:** 1
**Description:** Use thin provisioning for volumes and LUNs

```bash
--ontap-thin 1   # Thin provisioning (default)
--ontap-thin 0   # Thick provisioning
```

**Thin provisioning benefits:**
- Space-efficient - only uses space for actual data
- Faster volume creation
- Enables overcommitment

**Thick provisioning benefits:**
- Guaranteed space allocation
- Predictable performance
- No risk of space exhaustion

### ontap-igroup-mode

**Type:** enum (per-node, shared)
**Default:** per-node
**Description:** igroup management mode

```bash
--ontap-igroup-mode per-node   # One igroup per PVE node (default)
--ontap-igroup-mode shared     # Single shared igroup for all nodes
```

**per-node mode:**
- Creates igroup: `pve_{cluster}_{nodename}`
- Each PVE node has its own initiator group
- More granular access control
- Recommended for production environments

**shared mode:**
- Creates igroup: `pve_{cluster}_shared`
- All PVE nodes share one initiator group
- Simpler management
- All nodes must be trusted

### ontap-cluster-name

**Type:** string
**Default:** pve
**Description:** Cluster name used in igroup naming

```bash
--ontap-cluster-name production
--ontap-cluster-name lab
```

**Notes:**
- Used to create unique igroup names: `pve_{cluster}_{node}`
- Useful when multiple PVE clusters share same ONTAP
- Must be alphanumeric with underscores only

### ontap-device-timeout

**Type:** integer
**Default:** 60
**Description:** Timeout in seconds for device discovery after LUN mapping

```bash
--ontap-device-timeout 60    # Default: 60 seconds
--ontap-device-timeout 120   # Increase for slow storage networks
```

**Notes:**
- The plugin waits for the device to appear after mapping a LUN
- If timeout is exceeded, operation fails with "Device did not appear" error
- Increase this value for networks with high latency
- Lower values may be useful for development/testing

## Standard PVE Options

### content

**Type:** content type list
**Default:** images
**Description:** Allowed content types

```bash
--content images           # VM disk images only
--content images,rootdir   # VM disks and container rootfs
```

**Supported content types:**
- `images` - VM disk images (QEMU)
- `rootdir` - Container root directories (LXC)

**Not supported:**
- `iso` - ISO images (block storage cannot store files)
- `vztmpl` - Container templates
- `backup` - Backup files

### shared

**Type:** boolean (0 or 1)
**Default:** 0
**Description:** Mark storage as shared across cluster nodes

```bash
--shared 1   # Shared storage (recommended)
--shared 0   # Local storage
```

**Notes:**
- Should always be 1 for iSCSI SAN storage
- Required for live migration between nodes

### nodes

**Type:** node list
**Default:** all nodes
**Description:** Restrict storage to specific nodes

```bash
--nodes pve1,pve2      # Only available on pve1 and pve2
--nodes pve1           # Only available on pve1
```

### disable

**Type:** boolean (0 or 1)
**Default:** 0
**Description:** Disable the storage

```bash
--disable 1   # Storage disabled
--disable 0   # Storage enabled (default)
```

## Complete Example

### Minimal Configuration

```bash
pvesm add netappontap netapp1 \
    --ontap-portal 192.168.1.100 \
    --ontap-svm svm0 \
    --ontap-aggregate aggr1 \
    --ontap-username pveadmin \
    --ontap-password 'Password123' \
    --content images \
    --shared 1
```

### Full Configuration

```bash
pvesm add netappontap netapp-prod \
    --ontap-portal ontap-mgmt.example.com \
    --ontap-svm vs_production \
    --ontap-aggregate aggr_ssd_01 \
    --ontap-username pve_api_user \
    --ontap-password 'ComplexP@ssw0rd!' \
    --ontap-ssl-verify 1 \
    --ontap-thin 1 \
    --ontap-igroup-mode per-node \
    --ontap-cluster-name prod \
    --content images \
    --shared 1 \
    --nodes pve1,pve2,pve3
```

### storage.cfg Format

```ini
netappontap: netapp-prod
    ontap-portal ontap-mgmt.example.com
    ontap-svm vs_production
    ontap-aggregate aggr_ssd_01
    ontap-username pve_api_user
    ontap-password ComplexP@ssw0rd!
    ontap-ssl-verify 1
    ontap-thin 1
    ontap-igroup-mode per-node
    ontap-cluster-name prod
    content images
    shared 1
    nodes pve1,pve2,pve3
```

## ONTAP User Setup

### Option A: Cluster-Level Account (Recommended)

Use this if your SVM doesn't have a dedicated management LIF:

```bash
# Create user at cluster level with admin role
security login create -user-or-group-name pveadmin \
    -application http \
    -authmethod password \
    -role admin
```

**Pros:**
- Simple setup
- Works with cluster management LIF
- No need for SVM management LIF

**Cons:**
- Broad permissions (admin role)

### Option B: SVM-Level Account (More Restricted)

Use this if your SVM has its own management LIF:

```bash
# Create custom role with minimum permissions
security login role create -vserver svm0 -role pve_storage \
    -cmddirname "volume" -access all

security login role create -vserver svm0 -role pve_storage \
    -cmddirname "lun" -access all

security login role create -vserver svm0 -role pve_storage \
    -cmddirname "igroup" -access all

security login role create -vserver svm0 -role pve_storage \
    -cmddirname "snapshot" -access all

security login role create -vserver svm0 -role pve_storage \
    -cmddirname "vserver iscsi" -access readonly

# Create user with the custom role
security login create -vserver svm0 \
    -user-or-group-name pveadmin \
    -application http \
    -authmethod password \
    -role pve_storage
```

**Pros:**
- Minimum required permissions
- Limited to specific SVM

**Cons:**
- Requires SVM management LIF (separate from data LIF)
- More complex setup

### Important: Management LIF Requirement

| Account Level | Management LIF Required | Notes |
|---------------|------------------------|-------|
| Cluster | Cluster management LIF | Usually exists (e.g., 192.168.1.194) |
| SVM | SVM management LIF | Often not configured; data LIF won't work |

**Common Issue:** If you create an SVM-level account but your SVM only has a data LIF, authentication will fail with "User is not authorized". Use cluster-level account instead.

### Verify Permissions

```bash
# For cluster-level account
security login show -user-or-group-name pveadmin

# For SVM-level account
security login role show -vserver svm0 -role pve_storage
security login show -vserver svm0 -user-or-group-name pveadmin
```

## Modifying Configuration

### Update Options

```bash
# Change aggregate
pvesm set netapp1 --ontap-aggregate aggr2

# Change password
pvesm set netapp1 --ontap-password 'NewPassword'

# Disable SSL verification
pvesm set netapp1 --ontap-ssl-verify 0
```

### Remove Options

```bash
# Remove node restriction
pvesm set netapp1 --delete nodes
```

### View Configuration

```bash
# Show storage configuration
pvesm config netapp1

# Show all storages
cat /etc/pve/storage.cfg
```

## Troubleshooting Configuration

### Test ONTAP Connectivity

```bash
# Test API access
curl -k -u pveadmin:password https://192.168.1.100/api/cluster

# Expected: JSON response with cluster info
```

### Check Storage Status

```bash
# Check storage status
pvesm status

# Check specific storage
pvesm status -storage netapp1
```

### Validate Configuration

```bash
# Try to activate storage
pvesm set netapp1 --disable 0

# Check for errors
journalctl -xeu pvedaemon | tail -50
```

## Template Support (v0.1.5+)

### How Templates Work

When converting a VM to template (`qm template <vmid>`):

1. Plugin creates `__pve_base__` snapshot on the ONTAP volume
2. PVE renames disk from `vm-XXX-disk-X` to `base-XXX-disk-X`
3. ONTAP FlexVol name stays the same (both names map to same volume)
4. The `__pve_base__` snapshot serves as:
   - Template marker (detected by `list_images`)
   - Base point for FlexClone linked clones

### Template Detection

`pvesm list` shows template volumes with `base-` prefix:

```
Volid                   Format  Type            Size VMID
netapp1:base-107-disk-0 raw     images    1073741824 107   # Template
netapp1:vm-100-disk-0   raw     images    1073741824 100   # Regular VM
```

### Linked Clone from Template

```bash
# Create linked clone from template 107
qm clone 107 200 --name "my-clone" --full 0
```

The clone uses NetApp FlexClone:
- Instant creation (no data copy)
- Space-efficient (shares blocks with parent)
- Independent snapshots

### Fixing Pre-v0.1.5 Templates

Templates created before v0.1.5 need manual fix:

```bash
# 1. Get storage credentials from storage.cfg
grep -A10 "netappontap:" /etc/pve/storage.cfg

# 2. Create __pve_base__ snapshot (replace with your values)
perl -e '
use lib "/usr/share/perl5";
use PVE::Storage::Custom::NetAppONTAP::API;
my $api = PVE::Storage::Custom::NetAppONTAP::API->new(
    host => "YOUR_ONTAP_IP",
    username => "YOUR_USER",
    password => "YOUR_PASSWORD",
    svm => "YOUR_SVM",
    ssl_verify => 0,
);
$api->snapshot_create("pve_STORAGEID_VMID_disk0", "__pve_base__");
'

# 3. Update VM config to use base- prefix
sed -i 's/vm-107-disk-0/base-107-disk-0/g' /etc/pve/qemu-server/107.conf
```

## Security Considerations

### 1. Password Storage

Passwords are stored in plaintext in `/etc/pve/storage.cfg`. This is the **standard PVE design** used by all storage plugins that require authentication (Ceph, iSCSI CHAP, ZFS over iSCSI, etc.).

**File Permissions:**
```
-rw-r----- root www-data /etc/pve/storage.cfg (mode 0640)
```

| User/Group | Access | Reason |
|------------|--------|--------|
| root | Read/Write | System administrator |
| www-data | Read-only | PVE services (pvedaemon, pveproxy) |
| Other users | No access | Protected by file permissions |
| Cluster nodes | Read | Replicated via pmxcfs (cluster filesystem) |

**Risk Assessment:**
- Regular users cannot read the file
- Users who can access it (root, cluster admins) already have full system privileges
- The ONTAP API account should have limited permissions, minimizing impact if compromised

**Additional Hardening (Optional):**

1. **IP Restriction on ONTAP:**
   ```bash
   # On ONTAP CLI - restrict API user to specific IPs
   security login create -vserver svm0 \
       -user-or-group-name pveadmin \
       -application http \
       -authmethod password \
       -role pve_storage \
       -second-authentication-method none

   # Add IP-based access policy (requires ONTAP 9.10+)
   vserver services web access-log config modify \
       -vserver svm0 -access-log-policy <policy>
   ```

2. **Network Segmentation:**
   - Place ONTAP management LIF on isolated management VLAN
   - Use firewall rules to allow only PVE nodes to reach port 443

3. **Regular Password Rotation:**
   ```bash
   # Update password on ONTAP
   security login password -username pveadmin -vserver svm0

   # Update password in PVE
   pvesm set netapp1 --ontap-password 'NewPassword'
   ```

4. **Monitoring:**
   - Enable ONTAP audit logging for API access
   - Monitor for unusual API activity

### 2. SSL/TLS

- HTTPS is always used (enforced by plugin)
- Enable SSL verification for production environments
- Use valid certificates when possible

```bash
# Enable SSL verification (recommended for production)
pvesm set netapp1 --ontap-ssl-verify 1

# Disable for self-signed certificates (development/lab only)
pvesm set netapp1 --ontap-ssl-verify 0
```

**Warning:** When `ontap-ssl-verify` is disabled, the plugin logs a warning message.

### 3. API User Permissions

**Recommended: Create dedicated role with minimum permissions**

```bash
# On ONTAP CLI - Create custom role
security login role create -vserver svm0 -role pve_storage \
    -cmddirname "volume" -access all

security login role create -vserver svm0 -role pve_storage \
    -cmddirname "lun" -access all

security login role create -vserver svm0 -role pve_storage \
    -cmddirname "igroup" -access all

security login role create -vserver svm0 -role pve_storage \
    -cmddirname "snapshot" -access all

security login role create -vserver svm0 -role pve_storage \
    -cmddirname "vserver iscsi" -access readonly

# Create user with the custom role
security login create -vserver svm0 \
    -user-or-group-name pveadmin \
    -application http \
    -authmethod password \
    -role pve_storage
```

**Note on Account Level:**
- **SVM-level account**: Requires SVM management LIF (separate from data LIF)
- **Cluster-level account**: Can use cluster management LIF, but may have broader access
- If your SVM doesn't have a management LIF, use cluster-level account with appropriate role

**Built-in Roles Reference:**

| Role | Level | Permissions |
|------|-------|-------------|
| admin | Cluster | Full access (avoid if possible) |
| vsadmin-volume | SVM | Volume/LUN/Snapshot operations (recommended) |
| vsadmin | SVM | Full SVM administration |
| readonly | Both | Read-only access (insufficient for this plugin) |

### 4. Network Security

- Use dedicated management network for ONTAP API access
- Separate iSCSI/FC data network from management network
- Consider firewall rules:

```bash
# Example: Allow only PVE nodes to reach ONTAP API
iptables -A OUTPUT -d <ontap-mgmt-ip> -p tcp --dport 443 -j ACCEPT
```

**Network Architecture Example:**
```
┌─────────────┐     Management Network (VLAN 10)      ┌─────────────┐
│   PVE Node  │──────────── 192.168.1.0/24 ──────────│ ONTAP Mgmt  │
│  (pc-pve1)  │                                       │    LIF      │
└─────────────┘                                       └─────────────┘
       │
       │            iSCSI/FC Data Network (VLAN 20)
       └─────────────── 10.0.0.0/24 ──────────────────┌─────────────┐
                                                      │ ONTAP Data  │
                                                      │    LIF      │
                                                      └─────────────┘
```

---

## Multipath Configuration

### Automatic Configuration (New Installations)

When this plugin is installed on a system **without** existing NetApp multipath configuration, it automatically adds a safe default configuration to `/etc/multipath.conf`. No manual action is needed.

### Existing Multipath Configuration (Manual Setup)

If you already have NetApp multipath configuration in `/etc/multipath.conf` (e.g., from a previous manual iSCSI setup), the plugin will **not** modify it. You will see a warning during installation if your settings need updating.

### Critical Settings

The following multipath settings directly affect system stability. Incorrect values can cause the **entire PVE node to become unresponsive** when a NetApp LUN is deleted or becomes unavailable.

#### no_path_retry (CRITICAL)

Controls what happens when **all** paths to a LUN fail (e.g., LUN deleted, network down, ONTAP failover).

| Value | Behavior | Risk |
|-------|----------|------|
| `queue` | I/O queued **indefinitely** | **DANGEROUS** - Any process accessing the device hangs forever. PVE node becomes unresponsive. Cannot be killed with `kill -9`. Only reboot recovers. |
| `30` | I/O queued for ~150 seconds, then fails | **Recommended** - Allows time for ONTAP failover recovery while preventing permanent hangs. |
| `fail` | I/O fails immediately | Too aggressive - normal failovers will cause unnecessary errors. |

**Recommended:** `no_path_retry 30`

If your current config uses `no_path_retry queue` or has `features "... queue_if_no_path ..."`, change it:

```
# BEFORE (dangerous):
no_path_retry           queue
features "3 queue_if_no_path pg_init_retries 50"

# AFTER (safe):
no_path_retry           30
features "2 pg_init_retries 50"
```

#### dev_loss_tmo

Controls how long the kernel keeps a SCSI device after the transport (iSCSI session) reports it lost.

| Value | Behavior | Risk |
|-------|----------|------|
| `infinity` | Device kept **forever** | **DANGEROUS** - Stale SCSI devices for deleted LUNs are never removed. Generates I/O errors indefinitely. |
| `60` | Device removed after 60 seconds | **Recommended** - Gives enough time for transient failures while cleaning up dead devices. |

**Recommended:** `dev_loss_tmo 60`

#### fast_io_fail_tmo

Controls how quickly a path is marked as failed when the transport reports an error.

**Recommended:** `fast_io_fail_tmo 5`

### Recommended multipath.conf for NetApp

```
devices {
    device {
        vendor "NETAPP"
        product "LUN C-Mode"
        path_grouping_policy group_by_prio
        path_selector "queue-length 0"
        path_checker tur
        features "2 pg_init_retries 50"
        no_path_retry 30
        hardware_handler "1 alua"
        prio alua
        failback immediate
        rr_weight uniform
        rr_min_io_rq 1
        fast_io_fail_tmo 5
        dev_loss_tmo 60
    }
}
```

### Why queue_if_no_path is Dangerous

When a LUN is deleted from ONTAP while PVE still has active iSCSI sessions:

1. ONTAP removes the LUN, but the host still has SCSI device entries
2. Any process that touches the stale device triggers an I/O request
3. With `queue_if_no_path`, the kernel queues the I/O **forever**
4. The process enters uninterruptible sleep (D state) -- cannot be killed
5. PVE periodically polls storage status, hitting the stale device
6. PVE daemon enters D state -- the entire node becomes unresponsive
7. Only a reboot can recover the node

With `no_path_retry 30`, the I/O is retried for ~150 seconds and then **fails with an error**. The process gets an I/O error (which it can handle) instead of hanging forever. This gives ONTAP failover enough time to complete while preventing permanent hangs.

### Applying Changes

After editing `/etc/multipath.conf`:

```bash
# Restart multipathd to apply new settings AND flush stale maps
# IMPORTANT: Use 'restart', NOT 'reload'.
# 'reload' only re-reads the config file but does NOT remove existing stale
# multipath maps. Stale maps from deleted LUNs will persist until restart.
systemctl restart multipathd

# Verify the new settings are active
multipathd show config local

# Verify no stale maps remain
multipath -ll
```

> **Why not `reload`?** `systemctl reload multipathd` only tells the daemon to re-parse `/etc/multipath.conf`. It applies new settings to *future* devices but does **not** clean up existing multipath maps. If you have stale maps from deleted LUNs (e.g., dm-X devices showing all paths in "failed faulty" state), `reload` will not remove them. Use `restart`.

### Coexistence with Existing Storage

If you have multiple storage systems using multipath (e.g., existing NetApp iSCSI + this plugin), the plugin will:

- **Not modify** your existing multipath.conf
- Share the same multipath daemon and iSCSI infrastructure
- Use device-level filtering (vendor "NETAPP") for its multipath settings

If you configure multiple plugin storage entries on the **same SVM**, use different `ontap-cluster-name` values to prevent igroup conflicts:

```bash
pvesm add netappontap storage-prod --ontap-cluster-name pve-prod ...
pvesm add netappontap storage-dev  --ontap-cluster-name pve-dev ...
```

### Mixed Environment: Manual iSCSI LVM + This Plugin

A common scenario: a PVE node already uses manually-configured iSCSI (e.g., as PVE's "iSCSI" or "LVM on iSCSI" storage type) AND has this plugin installed for additional NetApp storage. **This plugin is fully compatible with such setups, but there are critical rules to follow:**

**DO:**
- Upgrade to **v0.2.2 or later** -- automatic orphan cleanup handles this plugin's stale devices safely without affecting your manual storage.
- Let the plugin manage its own LUNs entirely.
- Only use targeted WWID flushing if manual cleanup is ever needed: `multipath -f <wwid>`.

**DO NOT:**
- **NEVER use `multipath -F` (capital F).** This flushes ALL unused multipath maps system-wide, including your manually-configured iSCSI LVM if it has no active I/O at the moment. Recovery requires `systemctl reload multipathd` or `iscsiadm -m session --rescan`.
- Do not flush WWIDs you do not recognize -- they may belong to manual storage.

**Why v0.2.2 is safe in mixed environments:**

The plugin maintains a per-storage WWID tracking file at `/var/lib/pve-storage-netapp/<storeid>-wwids.json`. It records ONLY WWIDs that came from this plugin's own `path()` calls (i.e., LUNs created by `pvesm alloc` or `qm` operations on this plugin's storage). When the orphan cleanup runs (during `status()` polling), it checks ONLY tracked WWIDs against the ONTAP LUN list. WWIDs from your manual iSCSI setup are NEVER in the tracking file, so they are NEVER touched by automatic cleanup.

**Symptoms of mixing `multipath -F` with manual LVM iSCSI:**

| Symptom | Cause | Fix |
|---------|-------|-----|
| Manual iSCSI LVM disappears from PVE after `multipath -F` on a node with no VMs using it | `multipath -F` flushed the unused map | `systemctl reload multipathd` or `iscsiadm -m session --rescan` |
| VM migration to that node fails or LVM still missing | PVE LVM plugin doesn't auto-rescan multipath | Same as above |
| This plugin's storage works fine, but manual storage is broken | `multipath -F` only affects unused maps; this plugin's active maps were preserved | Same as above |

The lesson: **after upgrading to v0.2.2, never run `multipath -F` again.** The plugin handles its own cleanup automatically and safely.

## Acknowledgments

Special thanks to **NetApp** for generously providing the development and testing environment that made this project possible.

我們特別感謝 **NetApp 原廠**協助提供開發測試環境，使本專案得以順利完成。
