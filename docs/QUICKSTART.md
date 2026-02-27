# Quick Start Guide - NetApp ONTAP Storage Plugin for Proxmox VE

## Disclaimer

> **WARNING: This is a newly developed project. Use at your own risk.**
>
> - **iSCSI protocol has been tested but not extensively in production environments**
> - **FC (Fibre Channel) protocol has NOT been fully verified**
> - Always test thoroughly in a non-production environment before deployment
> - See README.md for full disclaimer and known limitations

## Important Notes

### Supported PVE Versions

| PVE Version | Compatibility |
|-------------|---------------|
| PVE 9.0+ | ✅ Supported |
| PVE 8.3, 8.4 | ✅ Supported |
| PVE 8.0 - 8.2 | ❌ Not supported |
| PVE 7.x and earlier | ❌ Not supported |

This plugin requires Storage API version 13, which is available in PVE 8.3+.

### Property Naming Convention
All plugin-specific properties use the `ontap-` prefix to avoid conflicts with other PVE storage plugins:
- `ontap-portal` (not `portal`)
- `ontap-svm` (not `svm`)
- `ontap-username` (not `username`)
- etc.

### Web UI Limitation
**Note:** Due to Proxmox VE architecture, custom storage plugins do NOT appear in the Web UI "Add Storage" dropdown menu. This is a known limitation of the PVE plugin system where the Web UI JavaScript has hardcoded storage types.

**What works:**
- CLI commands (`pvesm add`, `pvesm status`, etc.) - **Full support**
- Web UI storage list - Shows existing storage after adding via CLI
- Web UI VM disk selection - Works for VMs using this storage
- Web UI status display - Shows capacity and status

**What doesn't work:**
- Web UI "Add Storage" dropdown - Plugin not listed (must use CLI)

---

## Prerequisites

### On NetApp ONTAP

1. **Enable iSCSI service on SVM**
   ```bash
   vserver iscsi create -vserver svm0
   ```

2. **Create API user** (choose one option)

   **Option A: Cluster-level account (Recommended)**

   Use this if your SVM doesn't have a dedicated management LIF:
   ```bash
   # Create user at cluster level
   security login create -user-or-group-name pveadmin \
       -application http -authmethod password -role admin
   ```

   > **Note:** Uses cluster management LIF (e.g., 192.168.1.194). The `admin` role has broad access but is simpler to set up.

   **Option B: SVM-level account (More Restricted)**

   Use this if your SVM has its own management LIF:
   ```bash
   # Create custom role with minimum permissions
   security login role create -vserver svm0 -role pve_storage -cmddirname "volume" -access all
   security login role create -vserver svm0 -role pve_storage -cmddirname "lun" -access all
   security login role create -vserver svm0 -role pve_storage -cmddirname "igroup" -access all
   security login role create -vserver svm0 -role pve_storage -cmddirname "snapshot" -access all
   security login role create -vserver svm0 -role pve_storage -cmddirname "vserver iscsi" -access readonly

   # Create user with the custom role
   security login create -vserver svm0 -user-or-group-name pveadmin \
       -application http -authmethod password -role pve_storage
   ```

   > **Note:** SVM-level accounts require SVM management LIF. If SVM only has data LIF, use Option A.

   **Built-in Roles Reference:**
   | Role | Level | Notes |
   |------|-------|-------|
   | `admin` | Cluster | Full access, simple setup |
   | `vsadmin-volume` | SVM | Volume/LUN/Snapshot ops (recommended for SVM) |
   | `vsadmin` | SVM | Full SVM administration |

3. **Note down the following information**
   - Management IP: `192.168.1.100` (Cluster mgmt LIF for Option A, SVM mgmt LIF for Option B)
   - SVM name: `svm0`
   - Aggregate name: `aggr1`
   - API username: `pveadmin`
   - API password: `YourPassword`

### On Proxmox VE Node

See [Installation](#installation) section below.

---

## Installation

### First-Time Installation (Recommended Order)

> **IMPORTANT:** Install dependencies BEFORE the plugin package to avoid dependency resolution issues.

```bash
# Step 1: Update apt cache (required!)
apt update

# Step 2: Install ALL dependencies first
apt install -y open-iscsi multipath-tools sg3-utils psmisc \
    libwww-perl libjson-perl liburi-perl lsscsi

# Step 3: Enable required services
systemctl enable --now iscsid
systemctl enable --now multipathd

# Step 4: Configure multipath for NetApp (recommended)
cat >> /etc/multipath.conf << 'EOF'
devices {
    device {
        vendor "NETAPP"
        product "LUN"
        path_grouping_policy group_by_prio
        path_selector "queue-length 0"
        path_checker tur
        features "3 queue_if_no_path pg_init_retries 50"
        hardware_handler "1 alua"
        prio alua
        failback immediate
        rr_weight uniform
        rr_min_io_rq 1
        dev_loss_tmo infinity
    }
}
EOF
systemctl restart multipathd

# Step 5: Install the plugin package
dpkg -i jt-pve-storage-netapp_0.1.7-1_all.deb

# Step 6: Restart PVE services
systemctl restart pvedaemon pveproxy
```

### If You Already Ran dpkg First (Fix Broken State)

If you ran `dpkg -i` before installing dependencies:
```
dpkg: dependency problems prevent configuration of jt-pve-storage-netapp
```

Fix with:
```bash
apt update
apt --fix-broken install -y
```

### Cluster Installation

> **CRITICAL:** Plugin must be installed on **ALL** cluster nodes.

Run on EACH node:
```bash
apt update
apt install -y open-iscsi multipath-tools sg3-utils psmisc \
    libwww-perl libjson-perl liburi-perl lsscsi
systemctl enable --now iscsid multipathd
dpkg -i jt-pve-storage-netapp_0.1.7-1_all.deb
systemctl restart pvedaemon pveproxy
```

### From Source (Development)

```bash
cd /root/jt-pve-storage-netapp
make install
systemctl restart pvedaemon pveproxy
```

---

## Configuration

### Method 1: CLI (Recommended)

```bash
pvesm add netappontap netapp1 \
    --ontap-portal 192.168.1.100 \
    --ontap-svm svm0 \
    --ontap-aggregate aggr1 \
    --ontap-username pveadmin \
    --ontap-password 'YourPassword' \
    --content images \
    --shared 1
```

### Method 2: Edit storage.cfg Directly

```bash
cat >> /etc/pve/storage.cfg << 'EOF'

netappontap: netapp1
    ontap-portal 192.168.1.100
    ontap-svm svm0
    ontap-aggregate aggr1
    ontap-username pveadmin
    ontap-password YourPassword
    content images
    shared 1
EOF
```

---

## Configuration Options

| Option | Required | Default | Description |
|--------|----------|---------|-------------|
| `ontap-portal` | Yes | - | ONTAP management IP or hostname |
| `ontap-svm` | Yes | - | Storage Virtual Machine name |
| `ontap-aggregate` | Yes | - | Aggregate for volume creation |
| `ontap-username` | Yes | - | API username |
| `ontap-password` | Yes | - | API password |
| `ontap-protocol` | No | iscsi | SAN protocol: `iscsi` or `fc` |
| `ontap-ssl-verify` | No | 1 | Verify SSL certificate (0=disable) |
| `ontap-thin` | No | 1 | Use thin provisioning |
| `ontap-igroup-mode` | No | per-node | igroup mode: `per-node` or `shared` |
| `ontap-cluster-name` | No | pve | Cluster name for igroup naming |
| `ontap-device-timeout` | No | 60 | Device discovery timeout (seconds) |

---

## Verify Installation

```bash
# Check storage status (no warnings should appear)
pvesm status

# Expected output:
# Name     Type          Status  Total      Used       Available  %
# netapp1  netappontap   active  1000.00GB  100.00GB   900.00GB   10.00%

# Test creating a disk
pvesm alloc netapp1 9999 vm-9999-disk-0 10G

# Verify on ONTAP CLI
# vol show -vserver svm0 pve_*

# Clean up test
pvesm free netapp1:vm-9999-disk-0
```

---

## Basic Usage

### Create VM with NetApp Storage

```bash
# Create VM
qm create 100 --name test-vm --memory 2048 --net0 virtio,bridge=vmbr0

# Add disk on NetApp storage (32GB)
qm set 100 --scsi0 netapp1:32
```

### Snapshot Operations

```bash
# Create snapshot
qm snapshot 100 snap1 --description "Before upgrade"

# List snapshots
qm listsnapshot 100

# Rollback (VM must be stopped)
qm stop 100
qm rollback 100 snap1
qm start 100

# Delete snapshot
qm delsnapshot 100 snap1
```

### Resize Disk

```bash
# Stop VM first
qm stop 100

# Resize (add 20GB)
qm resize 100 scsi0 +20G

# Start VM
qm start 100
```

---

## Troubleshooting

### Plugin Not Visible in Web UI

```bash
# 1. Check if plugin is loaded
pvesm status 2>&1 | head -5

# 2. If you see "older storage API" warning, reinstall the latest package
dpkg -i jt-pve-storage-netapp_0.1.7-1_all.deb

# 3. Restart services
systemctl restart pvedaemon pveproxy

# 4. Clear browser cache (Ctrl+Shift+R)
```

### Storage Not Active

```bash
# Check ONTAP connectivity
curl -k -u pveadmin:YourPassword https://192.168.1.100/api/cluster

# Check iSCSI sessions
iscsiadm -m session

# Manually discover targets
iscsiadm -m discovery -t sendtargets -p 192.168.1.100
```

### Device Not Found After Disk Creation

```bash
# Rescan iSCSI
iscsiadm -m session --rescan

# Rescan SCSI bus
for host in /sys/class/scsi_host/host*/scan; do
    echo "- - -" > $host
done

# Reload multipath
multipathd reconfigure
multipath -v2
```

### Check Logs

```bash
# PVE daemon logs
journalctl -xeu pvedaemon --since "10 minutes ago"

# iSCSI logs
journalctl -u iscsid --since "10 minutes ago"

# Multipath status
multipathd show maps
multipathd show paths
```

### Permission Denied on ONTAP API

```bash
# Verify API user permissions on ONTAP
security login role show -vserver svm0 -role pve_storage
```

---

## Storage Architecture

### VM Disk to ONTAP Volume Mapping

This plugin uses a **1 VM disk = 1 FlexVol = 1 LUN** architecture:

```
PVE VM 100                          NetApp ONTAP SVM
+------------------+                +----------------------------------+
| disk 0 (32GB)    | <-- iSCSI --> | FlexVol: pve_netapp1_100_disk0   |
|                  |               |   └── LUN: lun0 (32GB)           |
+------------------+               +----------------------------------+
| disk 1 (64GB)    | <-- iSCSI --> | FlexVol: pve_netapp1_100_disk1   |
|                  |               |   └── LUN: lun0 (64GB)           |
+------------------+               +----------------------------------+
```

**Design Benefits:**
- Each Volume contains exactly one LUN
- PVE snapshot = ONTAP Volume Snapshot (clean semantics)
- Snapshot rollback only affects the specific disk
- Independent capacity management per disk

### Object Naming Patterns

| PVE Object | ONTAP Object | Naming Pattern | Example |
|------------|--------------|----------------|---------|
| VM disk | FlexVol | `pve_{storage}_{vmid}_disk{id}` | `pve_netapp1_100_disk0` |
| VM disk | LUN | `/vol/{flexvol}/lun0` | `/vol/pve_netapp1_100_disk0/lun0` |
| Snapshot | Volume Snapshot | `pve_snap_{snapname}` | `pve_snap_backup1` |
| PVE node | igroup | `pve_{cluster}_{node}` | `pve_pve_pve1` |

### Example: VM with Multiple Disks

| VM | Disk | FlexVol Name | LUN Path |
|----|------|--------------|----------|
| 100 | scsi0 | `pve_netapp1_100_disk0` | `/vol/pve_netapp1_100_disk0/lun0` |
| 100 | scsi1 | `pve_netapp1_100_disk1` | `/vol/pve_netapp1_100_disk1/lun0` |
| 101 | scsi0 | `pve_netapp1_101_disk0` | `/vol/pve_netapp1_101_disk0/lun0` |

### ONTAP CLI Verification

```bash
# List all plugin-managed volumes
vol show -vserver svm0 -volume pve_*

# List all volumes for a specific VM
vol show -vserver svm0 -volume pve_*_100_*

# Show LUN mapping
lun show -vserver svm0 -path /vol/pve_*/lun0 -mapped
```

---

## Uninstall

```bash
# 1. Remove storage configuration
pvesm remove netapp1

# 2. Uninstall package
apt remove jt-pve-storage-netapp

# 3. Restart services
systemctl restart pvedaemon pveproxy
```

---

## Support

- GitHub Issues: https://github.com/jasoncheng7115/jt-pve-storage-netapp/issues
- Proxmox Forum: https://forum.proxmox.com/

## Acknowledgments

Special thanks to **NetApp** for generously providing the development and testing environment that made this project possible.

我們特別感謝 **NetApp 原廠**協助提供開發測試環境，使本專案得以順利完成。
