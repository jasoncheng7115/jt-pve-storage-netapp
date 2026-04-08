# NetApp ONTAP 儲存外掛命名慣例

## 概述

本文件定義用於將 Proxmox VE 物件對應至 NetApp ONTAP 物件的命名慣例。這些慣例確保：

1. **可逆對應** — 可由 ONTAP 名稱推導出 PVE 識別碼，反之亦然
2. **符合 ONTAP 規範** — 所有名稱皆符合 ONTAP 命名限制
3. **唯一性** — 不同 VM、磁碟或快照之間不會發生名稱衝突
4. **可讀性** — 名稱具備意義，便於除錯與管理

## ONTAP 命名限制

| 物件類型 | 最大長度 | 允許字元 | 限制 |
|-------------|------------|-------------------|--------------|
| FlexVol | 203 | `[a-zA-Z0-9_]` | 必須以字母或底線開頭 |
| LUN | 255 | `[a-zA-Z0-9_.-]` | 路徑格式：`/vol/{volume}/{lun}` |
| Snapshot | 255 | `[a-zA-Z0-9_-]` | 必須以字母或底線開頭 |
| igroup | 96 | `[a-zA-Z0-9_.-]` | 必須以字母開頭 |

## 命名模式

### FlexVol 命名

**模式：** `pve_{storage}_{vmid}_disk{diskid}`

**範例：**
- VM 100、磁碟 0、storage "netapp1" → `pve_netapp1_100_disk0`
- VM 205、磁碟 3、storage "ontap-ssd" → `pve_ontap_ssd_205_disk3`

**淨化 (sanitization) 規則：**
- Storage 名稱：將 `-` 替換為 `_`，截斷至 32 字元
- VMID：整數，不修改
- DiskID：整數，不修改

**解析用的正規表示式：** `^pve_([a-zA-Z0-9_]+)_(\d+)_disk(\d+)$`

### LUN 命名

**模式：** `/vol/{flexvol_name}/lun0`

由於每個 FlexVol 僅包含 1 個 LUN，因此 LUN 固定命名為 `lun0`。

**範例：**
- FlexVol `pve_netapp1_100_disk0` → LUN 路徑 `/vol/pve_netapp1_100_disk0/lun0`

### 快照命名

**模式：** `pve_snap_{sanitized_snapname}`

**淨化規則：**
- 將空白字元替換為 `_`
- 將 `-` 替換為 `_`
- 移除所有不屬於 `[a-zA-Z0-9_]` 的字元
- 截斷至 200 字元 (保留前綴空間)
- 前綴加上 `pve_snap_`

**範例：**
- PVE 快照 "before-upgrade" → `pve_snap_before_upgrade`
- PVE 快照 "clean state 2024" → `pve_snap_clean_state_2024`
- PVE 快照 "test@v1.0" → `pve_snap_testv10`

**解析用的正規表示式：** `^pve_snap_(.+)$`

### igroup 命名

**模式：** `pve_{clustername}_{nodename}`

對於單節點環境或共享 igroup：`pve_{clustername}_shared`

**範例：**
- 叢集 "prod"、節點 "pve1" → `pve_prod_pve1`
- 叢集 "prod"、共享 → `pve_prod_shared`

## Volume 名稱編碼/解碼

### Perl 實作參考

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

## PVE Volume ID 格式

Proxmox VE 使用下列 volume ID 格式：

**模式：** `{storage}:{content}/{volname}`

**範例：**
- `netapp1:images/vm-100-disk-0`
- `netapp1:images/vm-205-disk-3`

### 對應至 ONTAP

| PVE 元件 | ONTAP 對應 |
|---------------|---------------|
| `{storage}` | 設定識別碼 (不儲存於 ONTAP 中) |
| `vm-{vmid}-disk-{diskid}` | FlexVol：`pve_{storage}_{vmid}_disk{diskid}` |
| `{snapname}` | Snapshot：`pve_snap_{snapname}` |

## 特殊情況

### Cloud-init 磁碟

Cloud-init volume 使用格式：`vm-{vmid}-cloudinit`

**ONTAP FlexVol：** `pve_{storage}_{vmid}_cloudinit`

### VM 狀態 (休眠)

VM 狀態 volume 使用格式：`vm-{vmid}-state-{snapname}`

**ONTAP FlexVol：** `pve_{storage}_{vmid}_state_{snapname}`

### ISO/範本映像檔

SAN 模式 (區塊儲存) 不支援 ISO 與範本。

## 驗證函式

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

## 摘要表

| PVE 物件 | ONTAP 物件 | 命名模式 |
|------------|--------------|----------------|
| VM 磁碟 | FlexVol | `pve_{storage}_{vmid}_disk{diskid}` |
| VM 磁碟 | LUN | `/vol/{flexvol}/lun0` |
| 快照 | Volume Snapshot | `pve_snap_{snapname}` |
| PVE 節點 | igroup | `pve_{cluster}_{node}` |

## 設計理念

1. **`pve_` 前綴** — 可於 ONTAP 中輕易識別由外掛管理的物件
2. **名稱中包含 storage** — 允許同一個 ONTAP 上存在多組 PVE 儲存設定
3. **以底線作為分隔符** — 與 ONTAP 命名規則保有最大相容性
4. **固定 `lun0`** — 簡化對應關係，因採用 1:1 volume:LUN 比例
5. **Snapshot 前綴** — 將 PVE 快照與 ONTAP 原生快照區分開來

## ONTAP CLI 範例

### 列出所有外掛管理的 volume

```bash
vol show -vserver svm0 -volume pve_*
```

### 列出所有外掛管理的 LUN

```bash
lun show -vserver svm0 -path /vol/pve_*/*
```

### 列出所有外掛管理的快照

```bash
snapshot show -vserver svm0 -volume pve_* -snapshot pve_snap_*
```

### 列出所有外掛管理的 igroup

```bash
igroup show -vserver svm0 -igroup pve_*
```

### 查詢特定 VM 的 volume

```bash
# 查詢 VM 100 的所有磁碟
vol show -vserver svm0 -volume pve_*_100_*
```

### 查詢特定 storage 的 volume

```bash
# 查詢 storage "netapp1" 的所有 volume
vol show -vserver svm0 -volume pve_netapp1_*
```

---

## 致謝

Special thanks to **NetApp** for generously providing the development and testing environment that made this project possible.

我們特別感謝 **NetApp 原廠**協助提供開發測試環境，使本專案得以順利完成。
