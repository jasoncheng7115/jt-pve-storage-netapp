# Naming Conventions for NetApp ONTAP Storage Plugin

## Overview

This document defines the naming conventions used to map Proxmox VE objects to NetApp ONTAP objects. These conventions ensure:

1. **Reversible mapping** - Can derive PVE identifiers from ONTAP names and vice versa
2. **ONTAP compliance** - All names comply with ONTAP naming restrictions
3. **Uniqueness** - No name collisions across VMs, disks, or snapshots
4. **Human readability** - Names are meaningful for debugging and administration

## ONTAP Naming Constraints

| Object Type | Max Length | Allowed Characters | Restrictions |
|-------------|------------|-------------------|--------------|
| FlexVol | 203 | `[a-zA-Z0-9_]` | Must start with letter or underscore |
| LUN | 255 | `[a-zA-Z0-9_.-]` | Path format: `/vol/{volume}/{lun}` |
| Snapshot | 255 | `[a-zA-Z0-9_-]` | Must start with letter or underscore |
| igroup | 96 | `[a-zA-Z0-9_.-]` | Must start with letter |

## Naming Patterns

### FlexVol Naming

**Pattern:** `pve_{storage}_{vmid}_disk{diskid}`

**Examples:**
- VM 100, disk 0, storage "netapp1" → `pve_netapp1_100_disk0`
- VM 205, disk 3, storage "ontap-ssd" → `pve_ontap_ssd_205_disk3`

**Sanitization Rules:**
- Storage name: replace `-` with `_`, truncate to 32 chars
- VMID: integer, no modification
- DiskID: integer, no modification

**Regex for parsing:** `^pve_([a-zA-Z0-9_]+)_(\d+)_disk(\d+)$`

### LUN Naming

**Pattern:** `/vol/{flexvol_name}/lun0`

Since we use 1 LUN per FlexVol, the LUN is always named `lun0`.

**Examples:**
- FlexVol `pve_netapp1_100_disk0` → LUN path `/vol/pve_netapp1_100_disk0/lun0`

### Snapshot Naming

**Pattern:** `pve_snap_{sanitized_snapname}`

**Sanitization Rules:**
- Replace spaces with `_`
- Replace `-` with `_`
- Remove all characters not in `[a-zA-Z0-9_]`
- Truncate to 200 chars (leave room for prefix)
- Prepend `pve_snap_`

**Examples:**
- PVE snapshot "before-upgrade" → `pve_snap_before_upgrade`
- PVE snapshot "clean state 2024" → `pve_snap_clean_state_2024`
- PVE snapshot "test@v1.0" → `pve_snap_testv10`

**Regex for parsing:** `^pve_snap_(.+)$`

### igroup Naming

**Pattern:** `pve_{clustername}_{nodename}`

For single-node setups or shared igroup: `pve_{clustername}_shared`

**Examples:**
- Cluster "prod", node "pve1" → `pve_prod_pve1`
- Cluster "prod", shared → `pve_prod_shared`

## Volume Name Encoding/Decoding

### Perl Implementation Reference

```perl
# Encode PVE volume to ONTAP FlexVol name
sub encode_volume_name {
    my ($storage, $vmid, $diskid) = @_;
    my $san_storage = $storage;
    $san_storage =~ s/-/_/g;
    $san_storage = substr($san_storage, 0, 32);
    return "pve_${san_storage}_${vmid}_disk${diskid}";
}

# Decode ONTAP FlexVol name to PVE components
sub decode_volume_name {
    my ($volname) = @_;
    if ($volname =~ /^pve_([a-zA-Z0-9_]+)_(\d+)_disk(\d+)$/) {
        return {
            storage => $1,
            vmid => $2,
            diskid => $3,
        };
    }
    return undef;
}

# Encode PVE snapshot name to ONTAP snapshot name
sub encode_snapshot_name {
    my ($snapname) = @_;
    my $san_snap = $snapname;
    $san_snap =~ s/[\s-]/_/g;
    $san_snap =~ s/[^a-zA-Z0-9_]//g;
    $san_snap = substr($san_snap, 0, 200);
    return "pve_snap_${san_snap}";
}

# Decode ONTAP snapshot name to PVE snapshot name
sub decode_snapshot_name {
    my ($ontap_snapname) = @_;
    if ($ontap_snapname =~ /^pve_snap_(.+)$/) {
        return $1;
    }
    return undef;
}
```

## PVE Volume ID Format

Proxmox VE uses the following volume ID format:

**Pattern:** `{storage}:{content}/{volname}`

**Examples:**
- `netapp1:images/vm-100-disk-0`
- `netapp1:images/vm-205-disk-3`

### Mapping to ONTAP

| PVE Component | ONTAP Mapping |
|---------------|---------------|
| `{storage}` | Configuration identifier (not stored in ONTAP) |
| `vm-{vmid}-disk-{diskid}` | FlexVol: `pve_{storage}_{vmid}_disk{diskid}` |
| `{snapname}` | Snapshot: `pve_snap_{snapname}` |

## Special Cases

### Cloud-init Disks

Cloud-init volumes use format: `vm-{vmid}-cloudinit`

**ONTAP FlexVol:** `pve_{storage}_{vmid}_cloudinit`

### VM State (Hibernate)

VM state volumes use format: `vm-{vmid}-state-{snapname}`

**ONTAP FlexVol:** `pve_{storage}_{vmid}_state_{snapname}`

### ISO/Template Images

ISO and templates are not supported in SAN mode (block storage).

## Validation Functions

```perl
# Validate ONTAP volume name
sub is_valid_ontap_volume_name {
    my ($name) = @_;
    return 0 if length($name) > 203;
    return 0 unless $name =~ /^[a-zA-Z_][a-zA-Z0-9_]*$/;
    return 1;
}

# Validate ONTAP snapshot name
sub is_valid_ontap_snapshot_name {
    my ($name) = @_;
    return 0 if length($name) > 255;
    return 0 unless $name =~ /^[a-zA-Z_][a-zA-Z0-9_-]*$/;
    return 1;
}

# Check if volume name is managed by this plugin
sub is_pve_managed_volume {
    my ($name) = @_;
    return $name =~ /^pve_[a-zA-Z0-9_]+_\d+_disk\d+$/;
}
```

## Summary Table

| PVE Object | ONTAP Object | Naming Pattern |
|------------|--------------|----------------|
| VM Disk | FlexVol | `pve_{storage}_{vmid}_disk{diskid}` |
| VM Disk | LUN | `/vol/{flexvol}/lun0` |
| Snapshot | Volume Snapshot | `pve_snap_{snapname}` |
| PVE Node | igroup | `pve_{cluster}_{node}` |

## Design Rationale

1. **`pve_` prefix** - Easily identify plugin-managed objects in ONTAP
2. **Storage in name** - Allows multiple PVE storage configs on same ONTAP
3. **Underscore separators** - Maximum compatibility with ONTAP naming rules
4. **Fixed `lun0`** - Simplifies mapping since we use 1:1 volume:LUN ratio
5. **Snapshot prefix** - Distinguishes PVE snapshots from ONTAP-native snapshots

## ONTAP CLI Examples

### List all plugin-managed volumes

```bash
vol show -vserver svm0 -volume pve_*
```

### List all plugin-managed LUNs

```bash
lun show -vserver svm0 -path /vol/pve_*/*
```

### List all plugin-managed snapshots

```bash
snapshot show -vserver svm0 -volume pve_* -snapshot pve_snap_*
```

### List all plugin-managed igroups

```bash
igroup show -vserver svm0 -igroup pve_*
```

### Find volume for specific VM

```bash
# Find all disks for VM 100
vol show -vserver svm0 -volume pve_*_100_*
```

### Find volume for specific storage

```bash
# Find all volumes for storage "netapp1"
vol show -vserver svm0 -volume pve_netapp1_*
```

---

## Acknowledgments

Special thanks to **NetApp** for generously providing the development and testing environment that made this project possible.

我們特別感謝 **NetApp 原廠**協助提供開發測試環境，使本專案得以順利完成。
