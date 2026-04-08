# 快速入門指南 - Proxmox VE 的 NetApp ONTAP 儲存外掛

## 免責聲明

> **警告：本專案為新開發的專案，使用風險請自行承擔。**
>
> - **iSCSI 協定已通過測試，但尚未在正式環境中大量驗證**
> - **FC (Fibre Channel) 協定尚未完整驗證**
> - 部署前請務必在非正式環境中完整測試
> - 完整免責聲明與已知限制請參閱 README_zh-TW.md

## 重要須知

### 支援的 PVE 版本

| PVE 版本 | 相容性 |
|-------------|---------------|
| PVE 9.0+ | 支援 |
| PVE 8.3, 8.4 | 支援 |
| PVE 8.0 - 8.2 | 不支援 |
| PVE 7.x 及更早版本 | 不支援 |

本外掛需要 Storage API 版本 13，該版本自 PVE 8.3 起提供。

### 屬性命名慣例
所有外掛專屬屬性均使用 `ontap-` 前綴，以避免與其他 PVE 儲存外掛衝突：
- `ontap-portal` (而非 `portal`)
- `ontap-svm` (而非 `svm`)
- `ontap-username` (而非 `username`)
- 等等

### Web UI 限制
**注意：** 由於 Proxmox VE 架構的關係，自訂儲存外掛**不會**出現在 Web UI 的「Add Storage」下拉選單中。這是 PVE 外掛系統的已知限制，因為 Web UI 的 JavaScript 將儲存類型硬編碼於程式碼內。

**可正常運作的項目：**
- CLI 指令 (`pvesm add`、`pvesm status` 等) — **完整支援**
- Web UI 儲存清單 — 透過 CLI 新增後可顯示既有儲存
- Web UI 虛擬機磁碟選擇 — 對使用此儲存的 VM 可正常運作
- Web UI 狀態顯示 — 顯示容量與狀態

**無法運作的項目：**
- Web UI 的「Add Storage」下拉選單 — 外掛不會列出 (必須使用 CLI)

---

## 前置需求

### NetApp ONTAP 端

1. **於 SVM 啟用 iSCSI 服務**
   ```bash
   vserver iscsi create -vserver svm0
   ```

2. **建立 API 使用者** (擇一即可)

   **選項 A：叢集層級帳號 (建議)**

   當您的 SVM 沒有專屬的管理 LIF 時使用：
   ```bash
   # 在叢集層級建立使用者
   security login create -user-or-group-name pveadmin \
       -application http -authmethod password -role admin
   ```

   > **注意：** 使用叢集管理 LIF (例如 192.168.1.194)。`admin` 角色權限範圍較廣，但設定較為簡單。

   **選項 B：SVM 層級帳號 (權限較為嚴格)**

   當您的 SVM 具有自己的管理 LIF 時使用：
   ```bash
   # 建立具最小權限的自訂角色
   security login role create -vserver svm0 -role pve_storage -cmddirname "volume" -access all
   security login role create -vserver svm0 -role pve_storage -cmddirname "lun" -access all
   security login role create -vserver svm0 -role pve_storage -cmddirname "igroup" -access all
   security login role create -vserver svm0 -role pve_storage -cmddirname "snapshot" -access all
   security login role create -vserver svm0 -role pve_storage -cmddirname "vserver iscsi" -access readonly

   # 以自訂角色建立使用者
   security login create -vserver svm0 -user-or-group-name pveadmin \
       -application http -authmethod password -role pve_storage
   ```

   > **注意：** SVM 層級帳號需要 SVM 管理 LIF。若 SVM 僅有 data LIF，請改用選項 A。

   **內建角色參考：**
   | 角色 | 層級 | 備註 |
   |------|-------|-------|
   | `admin` | 叢集 | 完整權限，設定簡單 |
   | `vsadmin-volume` | SVM | Volume/LUN/Snapshot 操作 (SVM 層級建議值) |
   | `vsadmin` | SVM | 完整 SVM 管理權限 |

3. **記錄下列資訊**
   - 管理 IP：`192.168.1.100` (選項 A 為叢集管理 LIF，選項 B 為 SVM 管理 LIF)
   - SVM 名稱：`svm0`
   - Aggregate 名稱：`aggr1`
   - API 使用者名稱：`pveadmin`
   - API 密碼：`YourPassword`

### Proxmox VE 節點端

請參閱下方的[安裝](#安裝)章節。

---

## 安裝

### 首次安裝 (建議順序)

> **重要：** 請在安裝外掛套件**之前**先安裝相依套件，以避免相依性解析問題。

```bash
# 步驟 1：更新 apt 快取 (必要!)
apt update

# 步驟 2：先安裝所有相依套件
apt install -y open-iscsi multipath-tools sg3-utils psmisc \
    libwww-perl libjson-perl liburi-perl lsscsi

# 步驟 3：啟用所需服務
systemctl enable --now iscsid
systemctl enable --now multipathd

# 步驟 4：為 NetApp 設定 multipath (建議)
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

# 步驟 5：安裝外掛套件
dpkg -i jt-pve-storage-netapp_0.1.7-1_all.deb

# 步驟 6：重新啟動 PVE 服務
systemctl restart pvedaemon pveproxy
```

### 若已先執行 dpkg (修復損壞狀態)

若您在安裝相依套件前已執行 `dpkg -i`：
```
dpkg: dependency problems prevent configuration of jt-pve-storage-netapp
```

修復方式：
```bash
apt update
apt --fix-broken install -y
```

### 叢集環境安裝

> **關鍵：** 外掛必須安裝於**所有**叢集節點上。

於每個節點執行：
```bash
apt update
apt install -y open-iscsi multipath-tools sg3-utils psmisc \
    libwww-perl libjson-perl liburi-perl lsscsi
systemctl enable --now iscsid multipathd
dpkg -i jt-pve-storage-netapp_0.1.7-1_all.deb
systemctl restart pvedaemon pveproxy
```

### 由原始碼安裝 (開發用)

```bash
cd /root/jt-pve-storage-netapp
make install
systemctl restart pvedaemon pveproxy
```

---

## 設定

### 方法 1：CLI (建議)

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

### 方法 2：直接編輯 storage.cfg

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

## 設定選項

| 選項 | 必填 | 預設值 | 說明 |
|--------|----------|---------|-------------|
| `ontap-portal` | 是 | - | ONTAP 管理 IP 或主機名稱 |
| `ontap-svm` | 是 | - | Storage Virtual Machine 名稱 |
| `ontap-aggregate` | 是 | - | 建立 volume 的 aggregate |
| `ontap-username` | 是 | - | API 使用者名稱 |
| `ontap-password` | 是 | - | API 密碼 |
| `ontap-protocol` | 否 | iscsi | SAN 協定：`iscsi` 或 `fc` |
| `ontap-ssl-verify` | 否 | 1 | 驗證 SSL 憑證 (0=停用) |
| `ontap-thin` | 否 | 1 | 使用精簡佈建 (thin provisioning) |
| `ontap-igroup-mode` | 否 | per-node | igroup 模式：`per-node` 或 `shared` |
| `ontap-cluster-name` | 否 | pve | igroup 命名用的叢集名稱 |
| `ontap-device-timeout` | 否 | 60 | 裝置探索逾時 (秒) |

---

## 驗證安裝

```bash
# 檢查儲存狀態 (不應出現警告)
pvesm status

# 預期輸出：
# Name     Type          Status  Total      Used       Available  %
# netapp1  netappontap   active  1000.00GB  100.00GB   900.00GB   10.00%

# 測試建立磁碟
pvesm alloc netapp1 9999 vm-9999-disk-0 10G

# 於 ONTAP CLI 驗證
# vol show -vserver svm0 pve_*

# 清除測試
pvesm free netapp1:vm-9999-disk-0
```

---

## 基本使用

### 使用 NetApp 儲存建立 VM

```bash
# 建立 VM
qm create 100 --name test-vm --memory 2048 --net0 virtio,bridge=vmbr0

# 於 NetApp 儲存新增磁碟 (32GB)
qm set 100 --scsi0 netapp1:32
```

### 快照操作

```bash
# 建立快照
qm snapshot 100 snap1 --description "Before upgrade"

# 列出快照
qm listsnapshot 100

# 還原 (VM 必須停止)
qm stop 100
qm rollback 100 snap1
qm start 100

# 刪除快照
qm delsnapshot 100 snap1
```

### 調整磁碟大小

```bash
# 先停止 VM
qm stop 100

# 調整大小 (增加 20GB)
qm resize 100 scsi0 +20G

# 啟動 VM
qm start 100
```

---

## 疑難排解

### 外掛未出現於 Web UI

```bash
# 1. 檢查外掛是否已載入
pvesm status 2>&1 | head -5

# 2. 若看到 "older storage API" 警告，請重新安裝最新套件
dpkg -i jt-pve-storage-netapp_0.1.7-1_all.deb

# 3. 重新啟動服務
systemctl restart pvedaemon pveproxy

# 4. 清除瀏覽器快取 (Ctrl+Shift+R)
```

### 儲存未啟用 (Not Active)

```bash
# 檢查 ONTAP 連線
curl -k -u pveadmin:YourPassword https://192.168.1.100/api/cluster

# 檢查 iSCSI sessions
iscsiadm -m session

# 手動探索 targets
iscsiadm -m discovery -t sendtargets -p 192.168.1.100
```

### 建立磁碟後找不到裝置

```bash
# 重新掃描 iSCSI
iscsiadm -m session --rescan

# 重新掃描 SCSI bus
for host in /sys/class/scsi_host/host*/scan; do
    echo "- - -" > $host
done

# 重新載入 multipath
multipathd reconfigure
multipath -v2
```

### 檢查日誌

```bash
# PVE daemon 日誌
journalctl -xeu pvedaemon --since "10 minutes ago"

# iSCSI 日誌
journalctl -u iscsid --since "10 minutes ago"

# Multipath 狀態
multipathd show maps
multipathd show paths
```

### ONTAP API 權限被拒絕

```bash
# 於 ONTAP 驗證 API 使用者權限
security login role show -vserver svm0 -role pve_storage
```

---

## 儲存架構

### VM 磁碟與 ONTAP Volume 對應關係

本外掛採用 **1 個 VM 磁碟 = 1 個 FlexVol = 1 個 LUN** 的架構：

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

**設計優點：**
- 每個 Volume 僅包含一個 LUN
- PVE 快照 = ONTAP Volume Snapshot (語意清晰)
- 快照還原僅影響特定磁碟
- 每個磁碟的容量獨立管理

### 物件命名模式

| PVE 物件 | ONTAP 物件 | 命名模式 | 範例 |
|------------|--------------|----------------|---------|
| VM 磁碟 | FlexVol | `pve_{storage}_{vmid}_disk{id}` | `pve_netapp1_100_disk0` |
| VM 磁碟 | LUN | `/vol/{flexvol}/lun0` | `/vol/pve_netapp1_100_disk0/lun0` |
| 快照 | Volume Snapshot | `pve_snap_{snapname}` | `pve_snap_backup1` |
| PVE 節點 | igroup | `pve_{cluster}_{node}` | `pve_pve_pve1` |

### 範例：具多個磁碟的 VM

| VM | 磁碟 | FlexVol 名稱 | LUN 路徑 |
|----|------|--------------|----------|
| 100 | scsi0 | `pve_netapp1_100_disk0` | `/vol/pve_netapp1_100_disk0/lun0` |
| 100 | scsi1 | `pve_netapp1_100_disk1` | `/vol/pve_netapp1_100_disk1/lun0` |
| 101 | scsi0 | `pve_netapp1_101_disk0` | `/vol/pve_netapp1_101_disk0/lun0` |

### ONTAP CLI 驗證

```bash
# 列出所有外掛管理的 volume
vol show -vserver svm0 -volume pve_*

# 列出特定 VM 的所有 volume
vol show -vserver svm0 -volume pve_*_100_*

# 顯示 LUN 對應關係
lun show -vserver svm0 -path /vol/pve_*/lun0 -mapped
```

---

## 解除安裝

```bash
# 1. 移除儲存設定
pvesm remove netapp1

# 2. 解除安裝套件
apt remove jt-pve-storage-netapp

# 3. 重新啟動服務
systemctl restart pvedaemon pveproxy
```

---

## 支援

- GitHub Issues：https://github.com/jasoncheng7115/jt-pve-storage-netapp/issues
- Proxmox 論壇：https://forum.proxmox.com/

## 致謝

Special thanks to **NetApp** for generously providing the development and testing environment that made this project possible.

我們特別感謝 **NetApp 原廠**協助提供開發測試環境，使本專案得以順利完成。
