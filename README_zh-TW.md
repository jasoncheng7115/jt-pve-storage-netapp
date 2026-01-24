# NetApp ONTAP SAN/iSCSI Storage Plugin for Proxmox VE

**[English](README.md)** | **[繁體中文](README_zh-TW.md)**

此儲存外掛程式讓 Proxmox VE 能夠透過 iSCSI 或 FC 協定使用 NetApp ONTAP 儲存系統作為虛擬機磁碟儲存。

## 免責聲明

> **警告：本專案為新開發項目，使用風險自負。**
>
> - 本外掛程式以「現狀」提供，不附帶任何形式的保證
> - **iSCSI 協定已經過測試，但尚未在生產環境中進行大量測試**
> - **FC (Fibre Channel) 協定尚未完整驗證**
> - 部署前請務必在非生產環境中進行完整測試
> - 作者不對任何資料遺失或系統問題負責
> - 請定期備份資料並備妥復原計畫
>
> **建議使用方式：**
> - 從非關鍵性虛擬機開始進行評估
> - 密切監控儲存操作

## 功能特色

- **1 VM 磁碟 = 1 LUN = 1 FlexVol** - 清晰的快照語義，符合 PVE 模型
- **快照建立/刪除/回復** - 透過 ONTAP Volume Snapshots
- **範本與連結複製** - 透過 NetApp FlexClone 實現即時複製（節省空間，無需複製資料）
- **從 VM 快照完整複製** - 從任意快照複製 VM 為獨立 VM
- **即時容量報告** - 透過 ONTAP REST API（以 aggregate 或 volume 為基礎）
- **Multipath I/O 支援** - 提供高可用性並自動探索裝置
- **叢集感知** - 支援 PVE 節點間的線上遷移
- **精簡佈建** - 有效利用儲存空間，並可選擇空間保證選項
- **每節點或共享 igroups** - 彈性的存取控制模式
- **iSCSI 與 FC SAN 支援** - 可為每個儲存選擇傳輸協定
- **自動 iSCSI 管理** - 目標探索、登入和工作階段處理
- **自動 FC HBA 偵測** - WWPN 探索和 igroup 管理
- **SCSI 裝置生命週期** - 刪除 volume 時自動清理裝置

## Web UI 支援

> **注意：** 這是一個自訂/第三方儲存外掛程式。由於 Proxmox VE 的架構限制，自訂外掛程式不會顯示在 Web UI 的「新增儲存」下拉選單中。必須透過 CLI (`pvesm add`) 新增儲存。

**透過 CLI 新增後，儲存將：**
- 出現在 Web UI 儲存清單中（資料中心 -> 儲存）
- 可在 Web UI 中建立 VM 磁碟
- 在 Web UI 中顯示容量和狀態
- 支援所有 VM 操作（建立、快照、遷移等）

## 系統需求

### Proxmox VE

- **Proxmox VE 9.1 或更新版本**（需要 Storage API 版本 13）
- 已測試版本：PVE 9.1

| PVE 版本 | Storage API | 相容性 |
|----------|-------------|--------|
| PVE 9.1+ | 13 | 支援 |

### NetApp ONTAP

- ONTAP 9.8 或更新版本（需要 REST API）
- 已啟用 iSCSI 授權
- 已啟用 iSCSI 服務的 SVM
- 至少配置一個 iSCSI LIF
- 具有可用空間的 Aggregate
- 具有適當 REST API 權限的使用者帳戶

### ONTAP 使用者權限

ONTAP 使用者需要以下權限：
- 對目標 SVM 中 volumes 的讀寫權限
- 對 LUNs 的讀寫權限
- 對 igroups 的讀寫權限
- 對 snapshots 的讀寫權限
- 對 aggregates 的讀取權限（用於容量報告）
- 對網路介面的讀取權限（用於 iSCSI portal 探索）

### PVE 節點相依套件

| 套件 | 用途 | 必要性 |
|------|------|--------|
| `open-iscsi` | iSCSI initiator (iscsiadm) | 是（iSCSI 用）|
| `multipath-tools` | Multipath I/O daemon (multipathd) | 是 |
| `sg3-utils` | SCSI 工具程式 (sg_inq) | 是 |
| `psmisc` | 程序工具程式 (fuser) - 用於裝置使用中偵測 | 是 |
| `libwww-perl` | HTTP 用戶端，用於 REST API | 是 |
| `libjson-perl` | JSON 編碼/解碼 | 是 |
| `liburi-perl` | URI 處理 | 是 |
| `lsscsi` | 列出 SCSI 裝置（除錯用）| 建議 |

## 安裝

### 首次安裝（建議順序）

> **重要：** 請在安裝外掛程式套件之前先安裝相依套件，以避免相依性解析問題。

```bash
# 步驟 1：更新 apt 快取（必要！）
apt update

# 步驟 2：先安裝所有相依套件
apt install -y open-iscsi multipath-tools sg3-utils psmisc \
    libwww-perl libjson-perl liburi-perl lsscsi

# 步驟 3：啟用必要服務
systemctl enable --now iscsid
systemctl enable --now multipathd

# 步驟 4：安裝外掛程式套件
# （自動配置 multipath 並重新啟動 PVE 服務）
dpkg -i jt-pve-storage-netapp_0.1.7-1_all.deb
```

> **注意：** 外掛程式會自動：
> - 將 NetApp 裝置配置加入 `/etc/multipath.conf`
> - 重新啟動 `pvedaemon` 和 `pveproxy` 以載入外掛程式

### 若已先執行 dpkg（修復損壞狀態）

如果您在安裝相依套件之前執行了 `dpkg -i` 並遇到錯誤如：
```
dpkg: dependency problems prevent configuration of jt-pve-storage-netapp
```

執行以下指令修復：
```bash
# 先更新 apt 快取！
apt update

# 修復損壞的相依性（安裝缺少的套件）
apt --fix-broken install -y

# 驗證安裝
dpkg -l | grep jt-pve-storage-netapp
```

### 叢集安裝（所有節點）

> **重要：** 在 Proxmox VE 叢集中，此外掛程式**必須安裝在所有節點上**。

儲存配置透過 `/etc/pve/storage.cfg` 在叢集中共享。未安裝外掛程式的節點將顯示：
```
Parameter verification failed. (400)
storage: No such storage
```

**在每個節點上安裝：**
```bash
# 在叢集中的每個節點上：
apt update
apt install -y open-iscsi multipath-tools sg3-utils psmisc \
    libwww-perl libjson-perl liburi-perl lsscsi
systemctl enable --now iscsid multipathd

# 安裝外掛程式（自動配置 multipath 並重新啟動 PVE 服務）
dpkg -i jt-pve-storage-netapp_0.1.7-1_all.deb
```

**叢集安裝順序：**
1. 先在所有節點上安裝外掛程式
2. 然後新增儲存配置（只需在任一節點執行一次）

## 快速開始

安裝外掛程式後（請參閱上方[安裝](#安裝)），新增儲存：

### 1. 新增儲存

**iSCSI 範例：**
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

**FC (Fibre Channel) 範例：**
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

### 2. 驗證

```bash
pvesm status
# Name        Type           Status  Total   Used  Available
# netapp1     netappontap    active  ...     ...   ...
```

詳細配置選項請參閱 [docs/CONFIGURATION.md](docs/CONFIGURATION.md)。

## 配置選項

所有外掛程式特定選項使用 `ontap-` 前綴，以避免與其他 PVE 儲存外掛程式衝突。

### 必要選項

| 選項 | 說明 | 範例 |
|------|------|------|
| `ontap-portal` | ONTAP 管理 IP 或主機名稱 | `192.168.1.100` |
| `ontap-svm` | Storage Virtual Machine (SVM/Vserver) 名稱 | `svm0` |
| `ontap-aggregate` | 用於建立 volume 的 Aggregate | `aggr1` |
| `ontap-username` | ONTAP API 使用者名稱 | `pveadmin` |
| `ontap-password` | ONTAP API 密碼 | `YourSecurePassword` |

### 選用選項

| 選項 | 預設值 | 說明 |
|------|--------|------|
| `ontap-protocol` | `iscsi` | SAN 協定：`iscsi` 或 `fc`（Fibre Channel）|
| `ontap-ssl-verify` | `1` | 驗證 SSL 憑證（0=停用，用於自簽憑證）|
| `ontap-thin` | `1` | 使用精簡佈建（0=完整佈建）|
| `ontap-igroup-mode` | `per-node` | igroup 模式：`per-node` 或 `shared` |
| `ontap-cluster-name` | `pve` | 用於 igroup 命名的叢集名稱 |
| `ontap-device-timeout` | `60` | 裝置探索逾時秒數 |

### storage.cfg 範例（iSCSI）

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

### storage.cfg 範例（FC SAN）

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

> **注意：** 對於 FC，`ontap-portal` 仍然是 ONTAP REST API 存取所必需的。FC 資料路徑使用 FC fabric，而非管理 IP。

## 使用方式

### 建立 VM 磁碟

```bash
# 使用 qm（建議）
qm set 100 --scsi0 netapp1:32

# 直接使用 pvesm
pvesm alloc netapp1 100 vm-100-disk-0 32G
```

### 快照

```bash
# 建立快照
qm snapshot 100 backup1 --description "升級前"

# 列出快照
qm listsnapshot 100

# 回復（VM 必須停止）
qm stop 100
qm rollback 100 backup1
qm start 100

# 刪除快照
qm delsnapshot 100 backup1
```

### 調整磁碟大小

```bash
# 先停止 VM（建議）
qm stop 100

# 調整大小（增加 10GB）
qm resize 100 scsi0 +10G

# 啟動 VM
qm start 100
```

### 線上遷移

```bash
# 將 VM 100 遷移到節點 pve2
qm migrate 100 pve2 --online
```

### 停用/啟用儲存

```bash
# 停用儲存（防止新操作）
pvesm set netapp1 --disable 1

# 啟用儲存
pvesm set netapp1 --disable 0

# 檢查儲存狀態
pvesm status
```

> **注意：** 停用儲存不會自動中斷 iSCSI 工作階段或 API 連線。外掛程式保持 iSCSI 工作階段活躍以便快速重新啟用。

## 架構

### 1:1:1 架構模型

```
Proxmox VE 叢集                      NetApp ONTAP
+------------------+                  +-------------------+
|   PVE 節點 1     |                  |   SVM: svm0       |
|   +----------+   |    iSCSI         |   +-------------+ |
|   | VM 100   |<--+----------------->|   | FlexVol     | |
|   | scsi0    |   |   multipath      |   | pve_..._100 | |
|   +----------+   |                  |   | +-------+   | |
+------------------+                  |   | | LUN   |   | |
        |                             |   | | lun0  |   | |
        | 線上遷移                     |   | +-------+   | |
        v                             |   +-------------+ |
+------------------+                  |                   |
|   PVE 節點 2     |                  |   igroups:        |
|   +----------+   |    iSCSI         |   - pve_pve_pve1  |
|   | VM 100   |<--+----------------->|   - pve_pve_pve2  |
|   | scsi0    |   |   multipath      |                   |
|   +----------+   |                  +-------------------+
+------------------+
```

### 物件對應

| PVE 物件 | ONTAP 物件 | 命名模式 |
|----------|------------|----------|
| 儲存 | - | 使用者定義（例如 `netapp1`）|
| VM 磁碟 | FlexVol | `pve_{storage}_{vmid}_disk{id}` |
| VM 磁碟 | LUN | `/vol/{flexvol}/lun0` |
| 快照 | Volume Snapshot | `pve_snap_{snapname}` |
| PVE 節點 | igroup | `pve_{cluster}_{node}` |
| Cloud-init | FlexVol | `pve_{storage}_{vmid}_cloudinit` |
| VM 狀態 | FlexVol | `pve_{storage}_{vmid}_state_{snap}` |

詳細命名規範請參閱 [docs/NAMING_CONVENTIONS.md](docs/NAMING_CONVENTIONS.md)。

## igroup 模式

### per-node（預設）

為每個 PVE 節點建立一個 igroup：`pve_{cluster}_{nodename}`

- 每個節點有自己的 initiator group
- LUNs 對應到所有節點的 igroups
- 更細緻的存取控制
- **建議用於生產環境**

### shared

為所有節點建立一個 igroup：`pve_{cluster}_shared`

- 所有 PVE 節點共享一個 initiator group
- 管理更簡單
- 所有節點必須是可信任的
- 適合小型叢集

## 支援功能

| 功能 | 狀態 | 備註 |
|------|------|------|
| 磁碟建立/刪除 | 支援 | FlexVol + LUN 建立 |
| 磁碟調整大小 | 支援 | VM 必須停止 |
| 快照 | 支援 | ONTAP Volume Snapshots |
| 快照回復 | 支援 | VM 必須停止 |
| 線上遷移 | 支援 | 透過共享 iSCSI 存取 |
| 精簡佈建 | 支援 | 預設啟用 |
| Multipath I/O | 支援 | 自動配置 |
| 範本 | 支援 | 將 VM 轉換為範本 |
| 連結複製 | 支援 | 透過 NetApp FlexClone（即時、節省空間）|
| 完整複製 | 支援 | 透過 qemu-img 從目前狀態複製 |
| 從快照完整複製 | 支援 | 透過暫時 FlexClone + qemu-img 複製 |
| 備份 (vzdump) | 支援 | 透過快照 |
| RAM 快照 (vmstate) | 支援 | VM 狀態儲存至專用 LUN（v0.1.7+）|

## 測試狀態

| 協定 | 狀態 | 備註 |
|------|------|------|
| **iSCSI** | 已測試 | 功能測試完成，尚未在生產環境大量測試 |
| **FC (Fibre Channel)** | 尚未完整驗證 | 基本實作已完成，需要實際 FC 環境測試 |

## 已知限制

1. **儲存停用**
   - 停用/移除儲存時，iSCSI 工作階段會被清理
   - 仍被 VM 使用的裝置會被跳過（安全檢查）
   - FC 清理僅依賴 multipath（不需要登出）

2. **FlexClone 授權**
   - 範本和連結複製功能需要 NetApp FlexClone 授權
   - 外掛程式會檢查授權並在缺少時提供有用的錯誤訊息

3. **ONTAP 中繼資料過時**
   - 刪除 FlexClones 後，ONTAP 可能短暫回報過時的 `has_flexclone` 中繼資料
   - 外掛程式包含重試邏輯（5 次嘗試，2 秒間隔）來處理此情況

4. **Web UI 限制**
   - 自訂外掛程式無法透過 Web UI「新增儲存」下拉選單新增
   - 必須使用 CLI (`pvesm add`) 新增儲存
   - 新增後，儲存會正常顯示在 Web UI 中

## 疑難排解

### 儲存未啟用

```bash
# 檢查 ONTAP API 連線
curl -k -u pveadmin:password https://192.168.1.100/api/cluster

# 檢查 iSCSI 工作階段
iscsiadm -m session

# 檢查 multipath
multipathd show maps
```

### 建立後找不到裝置

```bash
# 重新掃描 iSCSI 工作階段
iscsiadm -m session --rescan

# 重新掃描 SCSI 主機
for host in /sys/class/scsi_host/host*/scan; do echo "- - -" > $host; done

# 重新載入 multipath
multipathd reconfigure

# 透過 WWID 檢查裝置
multipathd show maps raw format "%n %w"
```

### 檢查日誌

```bash
# PVE daemon 日誌
journalctl -xeu pvedaemon --since "10 minutes ago"

# iSCSI 日誌
journalctl -u iscsid --since "10 minutes ago"

# Multipath 日誌
journalctl -u multipathd --since "10 minutes ago"
```

### 常見錯誤訊息

| 錯誤 | 原因 | 解決方案 |
|------|------|----------|
| `No such storage` / `Parameter verification failed (400)` | 外掛程式未安裝在節點上 | 在所有叢集節點上安裝外掛程式 |
| `SVM not found` | SVM 名稱錯誤 | 驗證 `ontap-svm` 設定 |
| `No iSCSI portals found` | iSCSI 未配置 | 在 SVM 上啟用 iSCSI 服務 |
| `Device did not appear` | LUN 對應問題 | 檢查 igroup 和 initiator |
| `ONTAP API Error 401` | 認證失敗 | 驗證使用者名稱/密碼 |
| `Cannot get WWID` | LUN 無法存取 | 檢查 iSCSI 工作階段 |
| `Cannot shrink LUN` | 調整大小請求小於目前大小 | 只支援擴展 |
| `device is still in use` | VM 執行中或裝置已掛載 | 刪除磁碟前先停止 VM |

詳細疑難排解請參閱 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)。

## 解除安裝

```bash
# 1. 先移除所有使用此儲存的 VM！

# 2. 移除儲存配置
pvesm remove netapp1

# 3. 解除安裝套件
apt remove jt-pve-storage-netapp

# 4. 重新啟動服務
systemctl restart pvedaemon pveproxy
```

## 開發

### 從原始碼建置

```bash
git clone https://github.com/jasoncheng7115/jt-pve-storage-netapp.git
cd jt-pve-storage-netapp

# 語法檢查
make test

# 建置 deb 套件
make deb

# 直接安裝（開發用）
make install
```

### 專案結構

```
jt-pve-storage-netapp/
├── lib/PVE/Storage/Custom/
│   ├── NetAppONTAPPlugin.pm      # 主外掛程式（儲存操作）
│   └── NetAppONTAP/
│       ├── API.pm                # ONTAP REST API 用戶端
│       ├── ISCSI.pm              # iSCSI 工作階段管理
│       ├── Multipath.pm          # Multipath 裝置管理
│       └── Naming.pm             # 命名規範工具程式
├── debian/                       # Debian 打包檔案
├── docs/                         # 文件
├── tests/                        # 測試目錄
├── Makefile                      # 建置和安裝規則
├── README.md                     # 英文說明文件
└── README_zh-TW.md               # 繁體中文說明文件（本文件）
```

## 安全功能

本外掛程式包含多重安全機制以防止資料遺失和操作錯誤：

### 資料保護

| 保護機制 | 說明 |
|----------|------|
| **縮小防護** | 防止 LUN 縮小以避免資料遺失 |
| **使用中檢查** | 刪除前驗證裝置未掛載/使用中 |
| **Volume 衝突檢查** | 防止建立重複名稱的 volumes |
| **快照衝突檢查** | 防止建立重複名稱的快照 |
| **容量預檢** | 完整佈建前驗證 aggregate 空間 |
| **FlexClone 父層保護** | 防止刪除有連結複製子層的範本 |

### 操作安全

| 功能 | 說明 |
|------|------|
| **API 快取 TTL** | 5 分鐘快取過期防止過時資料問題 |
| **Taint 模式相容** | 所有裝置路徑正確 untaint 以相容 PVE |
| **失敗時清理** | 自動回復部分操作（例如 volume 建立）|

## 授權

MIT License

## 作者

Jason Cheng (Jason Tools)

## 致謝

特別感謝 **NetApp** 慷慨提供開發測試環境，使本專案得以順利完成。

Special thanks to **NetApp** for generously providing the development and testing environment that made this project possible.

## 參考資料

- [Proxmox Storage Plugin Development](https://pve.proxmox.com/wiki/Storage_Plugin_Development)
- [NetApp ONTAP REST API Documentation](https://docs.netapp.com/us-en/ontap-automation/)
