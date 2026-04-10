# NetApp ONTAP SAN/iSCSI Storage Plugin for Proxmox VE

**[English](README.md)** | **[繁體中文](README_zh-TW.md)**

此儲存外掛程式讓 Proxmox VE 能夠透過 iSCSI 或 FC 協定使用 NetApp ONTAP 儲存系統作為虛擬機磁碟儲存。

## 目錄

- [免責聲明](#免責聲明)
- [重要：Multipath 安全規則](#重要multipath-安全規則)
- [功能特色](#功能特色)
- [Web UI 支援](#web-ui-支援)
- [系統需求](#系統需求)
- [安裝](#安裝)
- [升級 SOP](#升級-sop)
- [快速開始](#快速開始)
- [配置選項](#配置選項)
- [架構](#架構)
- [支援功能](#支援功能)
- [測試狀態](#測試狀態)
- [已知限制](#已知限制)

### 文件

| 文件 | 說明 |
|------|------|
| [docs/QUICKSTART_zh-TW.md](docs/QUICKSTART_zh-TW.md) | 逐步設定指南 |
| [docs/CONFIGURATION_zh-TW.md](docs/CONFIGURATION_zh-TW.md) | 完整配置參考（包含 multipath 安全性說明）|
| [docs/TROUBLESHOOTING_zh-TW.md](docs/TROUBLESHOOTING_zh-TW.md) | 常見問題與復原程序 |
| [docs/NAMING_CONVENTIONS_zh-TW.md](docs/NAMING_CONVENTIONS_zh-TW.md) | ONTAP 物件命名規則 |
| [docs/TESTING_zh-TW.md](docs/TESTING_zh-TW.md) | 測試計畫與發版測試結果 |
| [CHANGELOG_zh-TW.md](CHANGELOG_zh-TW.md) | 版本歷史 |

## 免責聲明

> **警告：本外掛程式為新開發軟體，使用風險自負。**
>
> - 本外掛程式以「現狀」提供，不附帶任何形式的保證
> - **iSCSI 協定已經過測試，但尚未在正式環境中進行大量測試**
> - **FC (Fibre Channel) 協定尚未完整驗證**
> - 部署前請務必在測試環境中進行完整測試
> - 作者不對任何資料遺失或系統問題負責
> - 請定期備份資料並備妥復原計畫
>
> **建議使用方式：**
> - 從非關鍵性虛擬機開始進行評估
> - 密切監控儲存操作

## 重要：Multipath 安全規則

> **安裝前務必閱讀。** 這些規則可避免 PVE 節點掛起以及誤斷其他儲存的連線。

### 規則 1：絕對不要使用 `multipath -F`（大寫 F）

`multipath -F` 會清除全系統**所有未使用**的 multipath maps。如果你有其他儲存（手動 iSCSI LVM、其他廠牌等），剛好當下沒有 I/O 在跑，**就會被斷線**。需要手動 `systemctl reload multipathd` 或 `iscsiadm -m session --rescan` 才能恢復。

**請改用針對性清除：**
```bash
# 1. 找出 stale 的 WWID（所有 path 都顯示 "failed faulty"）
multipath -ll

# 2. 只清除一個特定的 stale WWID（小寫 f）
multipath -f 3600a09807770457a795d5a7653705853
```

### 規則 2：編輯 `/etc/multipath.conf` 後，使用 `restart` 而非 `reload`

```bash
# 正確 - 套用新設定並清除 stale 狀態
systemctl restart multipathd

# 錯誤 - 只重新讀取設定，stale maps 不會清除
systemctl reload multipathd
```

### 規則 3：檢查你的 `/etc/multipath.conf` 設定

如果你的設定有以下任何一項，當 LUN 被刪除或變得無法存取時，整個 PVE 節點可能會掛起：

| 設定 | 風險 | 修復方式 |
|------|------|----------|
| `no_path_retry queue` | I/O 永久排隊 | 改為 `no_path_retry 30` |
| `queue_if_no_path`（在 features 中）| 同上 | 從 `features` 行移除 |
| `dev_loss_tmo infinity` | Stale 裝置永遠不會被移除 | 改為 `dev_loss_tmo 60` |

Plugin 安裝時會偵測這些設定並顯示醒目警告。詳見 [docs/CONFIGURATION_zh-TW.md](docs/CONFIGURATION_zh-TW.md#多重路徑-multipath-設定)。

### 規則 4：v0.2.2 之後會自動清理

升級到 v0.2.2 之後，**不需要**再手動清理 stale 裝置。Plugin 會在背景的儲存狀態輪詢時自動偵測並清除它自己建立的殘留裝置。它只會處理自己建立過的 WWID，**永遠不會影響其他儲存**。

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
| `libwww-perl` | HTTP 客戶端，用於 REST API | 是 |
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
dpkg -i jt-pve-storage-netapp_0.2.5-1_all.deb
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
dpkg -i jt-pve-storage-netapp_0.2.5-1_all.deb
```

**叢集安裝順序：**
1. 先在所有節點上安裝外掛程式
2. 然後新增儲存配置（只需在任一節點執行一次）

## 升級 SOP

從舊版本升級時，請在**每個叢集節點**依序執行下列步驟（一次升級一台節點）：

### 步驟 1：升級前備份

```bash
# 備份 multipath.conf（升級可能會顯示需要修改的警告）
cp /etc/multipath.conf /etc/multipath.conf.bak.$(date +%Y%m%d-%H%M%S)

# 記錄目前版本
dpkg -l jt-pve-storage-netapp | tail -1
```

### 步驟 2：停止或遷移 VM（建議）

為了最安全的升級，建議遷移或停止使用此儲存的 VM。執行中的 VM 在升級期間會繼續運作（plugin 只影響新操作），但乾淨的狀態能讓出問題時更容易復原。

```bash
# 列出使用 netapp 儲存的 VM
qm list | while read vmid name rest; do
    [ "$vmid" = "VMID" ] && continue
    qm config $vmid 2>/dev/null | grep -q netapp && echo "VM $vmid 使用 netapp 儲存"
done
```

### 步驟 3：安裝新套件

```bash
# 升級 plugin 套件
dpkg -i jt-pve-storage-netapp_0.2.5-1_all.deb
```

postinst 會自動：
- 偵測到既有 NetApp 設定時跳過 multipath.conf 修改
- 重啟 `pvedaemon` 和 `pveproxy`
- 偵測到危險的 multipath 設定時顯示**醒目警告**

### 步驟 4：檢查 postinst 警告

如果看到關於 `no_path_retry queue`、`queue_if_no_path` 或 `dev_loss_tmo infinity` 的警告，**必須**手動修改 `/etc/multipath.conf`：

```bash
# 編輯 multipath.conf
nano /etc/multipath.conf

# 套用變更：
#   no_path_retry queue    -->  no_path_retry 30
#   queue_if_no_path       -->  (從 features 行移除)
#   dev_loss_tmo infinity  -->  dev_loss_tmo 60
# 若沒有則新增：
#   fast_io_fail_tmo 5

# 套用（使用 restart，不是 reload -- reload 不會清除 stale maps）
systemctl restart multipathd

# 驗證
multipathd show config local | grep -E 'no_path_retry|dev_loss_tmo|fast_io_fail'
```

### 步驟 5：驗證升級

```bash
# 確認套件版本
dpkg -l jt-pve-storage-netapp | grep ii

# 確認儲存狀態
pvesm status | grep netapp

# 確認 multipath 裝置健康（沒有 "failed faulty" 路徑）
multipath -ll

# 確認殘留清理有在執行（幾分鐘後查 journal）
journalctl -u pvedaemon --since "5 minutes ago" | grep -i "orphan" || echo "沒有殘留（正常）"
```

### 步驟 6：在下一個節點重複

移到下一個叢集節點，從步驟 1 重複。**不要同時升級多個節點**。

### 復原（Rollback）

若有問題需要降版：

```bash
# 從 GitHub releases 下載前一版
dpkg -i jt-pve-storage-netapp_<previous-version>-1_all.deb

# 若有修改 multipath.conf，請還原備份
cp /etc/multipath.conf.bak.<timestamp> /etc/multipath.conf
systemctl restart multipathd
```

### 重要提醒

- **絕對不要**在升級前、升級中、升級後執行 `multipath -F`（大寫 F）-- 會清除所有未使用的 maps，包括手動管理的儲存。請參閱上方[Multipath 安全規則](#重要multipath-安全規則)。
- 使用 `systemctl restart multipathd`，**不要用 reload**。reload 不會清除 stale maps。
- v0.2.2+ 的 plugin 會**自動處理殘留清理** -- 升級後**不需要**手動清除 stale 裝置。

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
    --content images,rootdir \
    --shared 1
```

> **注意：** 使用 `--content images` 僅支援 VM 磁碟，或使用 `--content images,rootdir` 同時支援 LXC 容器。

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

詳細配置選項請參閱 [docs/CONFIGURATION_zh-TW.md](docs/CONFIGURATION_zh-TW.md)。

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
| `ontap-cluster-name` | `pve` | 用於 igroup 命名的叢集名稱（見下方說明）|
| `ontap-device-timeout` | `60` | 裝置探索逾時秒數 |

> **同一 SVM 多 storage 設定：** 若在同一個 SVM 上設定多個 storage，請為每個 storage 使用不同的 `ontap-cluster-name`，以避免 igroup 衝突。例如 `--ontap-cluster-name pve-prod` 和 `--ontap-cluster-name pve-dev`。

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
# 線上調整大小（VM 可以在執行中）
qm resize 100 scsi0 +10G

# 或在 VM 停止時調整大小
qm stop 100
qm resize 100 scsi0 +10G
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

### iSCSI 工作階段管理

```bash
# 檢視目前 iSCSI 工作階段
iscsiadm -m session

# 檢視 multipath 裝置
multipathd show maps

# 手動登出所有 iSCSI 目標（選用，停用儲存後）
iscsiadm -m node --logout

# 手動重新掃描 iSCSI 工作階段
iscsiadm -m session --rescan

# 重新掃描 SCSI 主機以偵測新裝置
for host in /sys/class/scsi_host/host*/scan; do echo "- - -" > $host; done

# 重新載入 multipath 配置
multipathd reconfigure
```

### 完整斷線程序

若需完全中斷與 NetApp 儲存的連線：

```bash
# 1. 先停止所有使用此儲存的 VM！
qm list | grep netapp1  # 檢查哪些 VM 使用此儲存

# 2. 停用儲存
pvesm set netapp1 --disable 1

# 3. 登出 iSCSI 目標
iscsiadm -m node --logout

# 4. 驗證工作階段已關閉
iscsiadm -m session  # 應顯示 "No active sessions"

# 5. 若要稍後重新連線，只需啟用儲存
pvesm set netapp1 --disable 0
# 外掛程式會自動重新探索並登入 iSCSI 目標
```

## 架構

### 1:1:1 架構模型

> 註：以下圖示使用英文標籤以確保 ASCII art 對齊正確。

```
Proxmox VE Cluster                    NetApp ONTAP
+------------------+                  +-------------------+
|     PVE Node 1   |                  |   SVM: svm0       |
|   +----------+   |    iSCSI         |   +-------------+ |
|   | VM 100   |<--+----------------->|   | FlexVol     | |
|   | scsi0    |   |   multipath      |   | pve_..._100 | |
|   +----------+   |                  |   | +-------+   | |
+------------------+                  |   | | LUN   |   | |
        |                             |   | | lun0  |   | |
        | live-migration              |   | +-------+   | |
        v                             |   +-------------+ |
+------------------+                  |                   |
|     PVE Node 2   |                  |   igroups:        |
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

詳細命名規範請參閱 [docs/NAMING_CONVENTIONS_zh-TW.md](docs/NAMING_CONVENTIONS_zh-TW.md)。

### 資料流程

**Volume 建立：**
1. PVE 呼叫 `alloc_image()`，傳入 vmid 和大小
2. 外掛程式透過 Naming 模組產生 ONTAP volume 名稱
3. 建立 FlexVol，大小為指定大小 + 64MB 開銷
   - Volume autogrow 已啟用（需要時自動擴展，最大至 2 倍大小）
4. 在 FlexVol 中建立 LUN
5. 將 LUN 對應到節點的 igroup
6. 回傳 PVE volume 名稱（`vm-{vmid}-disk-{diskid}`）

**Volume 啟用：**
1. PVE 呼叫 `activate_volume()`，傳入 volname
2. 確保 LUN 已對應到目前節點的 igroup
3. 重新掃描 iSCSI 工作階段和 SCSI 主機
4. 重新載入 multipath 配置
5. 等待裝置出現（最多 60 秒）
6. 回傳裝置路徑

**快照回復：**
1. PVE 呼叫 `volume_snapshot_rollback()`，傳入 volname 和 snapname
2. 外掛程式將名稱轉換為 ONTAP 格式
3. 呼叫 ONTAP REST API 將 volume 還原至快照
4. 重新掃描 SCSI 主機以偵測大小變更
5. 重新載入 multipath 配置

## igroup 模式

### per-node（預設）

為每個 PVE 節點建立一個 igroup：`pve_{cluster}_{nodename}`

- 每個節點有自己的 initiator group
- LUNs 對應到所有節點的 igroups
- 更細緻的存取控制
- **建議用於正式環境**

### shared

為所有節點建立一個 igroup：`pve_{cluster}_shared`

- 所有 PVE 節點共享一個 initiator group
- 管理更簡單
- 所有節點必須是可信任的
- 適合小型叢集

## 模組架構

```
PVE::Storage::Plugin (Proxmox VE 基礎類別)
    |
    +-- PVE::Storage::Custom::NetAppONTAPPlugin (主外掛程式)
            |
            +-- uses: API.pm        (ONTAP REST API 客戶端)
            +-- uses: Naming.pm     (PVE <-> ONTAP 名稱對應)
            +-- uses: ISCSI.pm      (iSCSI 目標/工作階段管理)
            +-- uses: Multipath.pm  (Linux multipath 與 SCSI 處理)
```

### 模組詳細資訊

| 模組 | 行數 | 說明 |
|------|------|------|
| **NetAppONTAPPlugin.pm** | 825 | 主外掛程式 - 儲存操作、volume 管理、快照 |
| **API.pm** | 787 | ONTAP REST API 客戶端 - volumes、LUNs、igroups、快照 |
| **Multipath.pm** | 482 | Multipath I/O 和 SCSI 裝置管理 |
| **ISCSI.pm** | 412 | iSCSI initiator 管理（iscsiadm 包裝器）|
| **Naming.pm** | 300 | 命名規範工具程式和驗證 |
| **合計** | **2,806** | 完整外掛程式實作 |

### API.pm 函式

**Volume 操作：**
- `volume_create()` - 建立 FlexVol（支援精簡/完整佈建）
- `volume_get()` / `volume_list()` - 查詢 volumes
- `volume_delete()` / `volume_resize()` - 管理 volumes
- `volume_space()` - 取得空間使用量
- `volume_clone()` - 從父 volume 建立 FlexClone
- `volume_clone_split()` - 分離 clone 為獨立 volume
- `volume_is_clone()` / `volume_get_clone_parent()` - 查詢 clone 資訊
- `volume_get_clone_children()` - 列出相依的 clones
- `license_has_flexclone()` - 檢查 FlexClone 授權可用性

**LUN 操作：**
- `lun_create()` - 在 volume 中建立 LUN
- `lun_get()` / `lun_delete()` / `lun_resize()` - 管理 LUNs
- `lun_get_serial()` / `lun_get_wwid()` - 取得識別碼
- `lun_map()` / `lun_unmap()` / `lun_is_mapped()` - igroup 對應

**快照操作：**
- `snapshot_create()` / `snapshot_delete()` - 管理快照
- `snapshot_list()` / `snapshot_get()` - 查詢快照
- `snapshot_rollback()` - 還原至快照

**igroup 操作：**
- `igroup_create()` / `igroup_get()` / `igroup_get_or_create()`
- `igroup_add_initiator()` / `igroup_remove_initiator()`
- `igroup_list()` - 列出 SVM 中的所有 igroups

**其他：**
- `iscsi_get_portals()` - 取得 iSCSI LIF 位址
- `get_managed_capacity()` - 取得儲存容量
- `wait_for_job()` - 處理非同步操作

### ISCSI.pm 函式

- `get_initiator_name()` / `set_initiator_name()` - 管理本機 IQN
- `discover_targets()` - SendTargets 探索
- `login_target()` / `logout_target()` - 工作階段管理
- `get_sessions()` / `is_target_logged_in()` - 查詢工作階段
- `rescan_sessions()` - 重新掃描以偵測新 LUNs
- `wait_for_device()` - 等待裝置出現
- `delete_node()` - 移除 iSCSI node 配置

### Multipath.pm 函式

- `rescan_scsi_hosts()` - 觸發 SCSI 匯流排重新掃描
- `multipath_reload()` / `multipath_flush()` - 管理 multipathd
- `get_multipath_device()` - 透過 WWID 尋找裝置
- `get_device_by_wwid()` - 尋找裝置路徑
- `wait_for_multipath_device()` - 帶逾時等待
- `get_scsi_devices_by_serial()` - 透過序號尋找裝置
- `remove_scsi_device()` / `rescan_scsi_device()` - 裝置生命週期
- `cleanup_lun_devices()` - LUN 刪除後清理

### Naming.pm 函式

- `encode_volume_name()` / `decode_volume_name()` - FlexVol 名稱
- `encode_lun_path()` / `decode_lun_path()` - LUN 路徑
- `encode_snapshot_name()` / `decode_snapshot_name()` - 快照名稱
- `encode_igroup_name()` - igroup 名稱
- `sanitize_for_ontap()` - 清理字串以符合 ONTAP 規範
- `pve_volname_to_ontap()` / `ontap_to_pve_volname()` - 完整轉換
- `is_pve_managed_volume()` - 驗證受管理的 volumes

## 支援功能

| 功能 | 狀態 | 備註 |
|------|------|------|
| 磁碟建立/刪除 | 支援 | FlexVol + LUN 建立 |
| 磁碟調整大小 | 支援 | 支援線上調整大小 |
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
| LXC 容器 (rootdir) | 支援 | 容器 rootfs 儲存於 NetApp LUN（v0.2.0+）|
| EFI 磁碟 | 支援 | OVMF UEFI 變數儲存於 NetApp LUN（v0.2.0+）|
| Cloud-init 磁碟 | 支援 | Cloud-init ISO 儲存於 NetApp LUN（v0.2.0+）|
| TPM 狀態 | 支援 | TPM 2.0 狀態儲存於 NetApp LUN（v0.2.0+）|

## 測試狀態

| 協定 | 狀態 | 備註 |
|------|------|------|
| **iSCSI** | 已測試 | 22 項完整測試套件通過（v0.2.1）|
| **FC (Fibre Channel)** | 尚未完整驗證 | 基本實作已完成，需要實際 FC 環境測試 |

完整測試計畫及發版測試結果：[docs/TESTING_zh-TW.md](docs/TESTING_zh-TW.md)

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

## PVE 版本升級相容性

本節說明 Proxmox VE 版本升級對本外掛程式的影響。

### Storage API 版本相依性

外掛程式在 `NetAppONTAPPlugin.pm` 中宣告其 API 版本：

```perl
use constant APIVERSION => 13;
use constant MIN_APIVERSION => 9;
```

| 情境 | 影響 |
|------|------|
| PVE Storage API 維持 13 | 完全相容 |
| PVE Storage API 升級至 14+ | **可能需要更新外掛程式** |
| PVE Storage API 降級 | 不相容（升級時不會發生）|

### PVE 內部模組相依性

外掛程式依賴以下 PVE 內部模組：

| 模組 | 用途 | 穩定性風險 |
|------|------|------------|
| `PVE::Storage::Plugin` | 儲存外掛程式基礎類別 | 中（核心 API）|
| `PVE::Tools` | 工具函式（`run_command`）| 低 |
| `PVE::JSONSchema` | Schema 驗證 | 低 |
| `PVE::Cluster` | 叢集配置 | 低 |
| `PVE::INotify` | 取得節點名稱 | 低 |
| `PVE::ProcFSTools` | 程序工具 | 低 |

### 系統層級相依性

這些與 PVE 版本無關，但可能受 Debian 基礎系統升級影響：

| 相依性 | 套件 | 風險 |
|--------|------|------|
| `iscsiadm` | open-iscsi | 低（穩定介面）|
| `multipathd` | multipath-tools | 低（穩定介面）|
| `sg_inq` | sg3-utils | 低（穩定介面）|
| Perl 模組 | libwww-perl、libjson-perl、liburi-perl | 低 |

### 升級相容性矩陣

| 升級路徑 | 預期相容性 | 風險等級 |
|----------|------------|----------|
| 9.1 → 9.2 | 相容 | 低 |
| 9.x → 10.x | **需要測試** | 中 |

### 潛在中斷變更

| 情境 | 可能性 | 影響 | 解決方案 |
|------|--------|------|----------|
| Storage API 方法簽章變更 | 中 | 外掛程式故障 | 更新外掛程式程式碼 |
| 新增必要方法 | 低 | 外掛程式無法載入 | 實作新方法 |
| 移除 PVE 函式 | 低 | 執行時錯誤 | 更新外掛程式程式碼 |
| Perl 版本升級 | 低 | 語法問題 | 測試並修復 |

### 建議升級程序

```bash
# 1. 升級前：備份配置
cp /etc/pve/storage.cfg /root/storage.cfg.bak
pvesm status > /root/storage-status-before.txt

# 2. 執行 PVE 升級
apt update && apt dist-upgrade

# 3. 升級後：驗證外掛程式功能
pvesm status                              # 檢查儲存狀態
journalctl -xeu pvedaemon --since "5 min" # 檢查錯誤

# 4. 若發生問題：重新安裝外掛程式
dpkg -i jt-pve-storage-netapp_*.deb
systemctl restart pvedaemon pveproxy

# 5. 驗證 Perl 語法（若需要）
perl -c /usr/share/perl5/PVE/Storage/Custom/NetAppONTAPPlugin.pm
perl -c /usr/share/perl5/PVE/Storage/Custom/NetAppONTAP/API.pm
perl -c /usr/share/perl5/PVE/Storage/Custom/NetAppONTAP/ISCSI.pm
perl -c /usr/share/perl5/PVE/Storage/Custom/NetAppONTAP/Multipath.pm
perl -c /usr/share/perl5/PVE/Storage/Custom/NetAppONTAP/Naming.pm
```

### 主要版本升級最佳實踐

1. **先在測試環境測試**
   - 將 PVE 配置複製到測試系統
   - 執行升級並驗證外掛程式功能

2. **檢查 Proxmox 發行說明**
   - 查找「BREAKING CHANGES」章節
   - 檢查 Storage API 版本變更
   - 檢視 Perl 版本變更

3. **監控官方管道**
   - [Proxmox VE Roadmap](https://pve.proxmox.com/wiki/Roadmap)
   - [Storage Plugin Development Wiki](https://pve.proxmox.com/wiki/Storage_Plugin_Development)
   - Proxmox Forum 公告

4. **準備回復計畫**
   - 保留 `/etc/pve/storage.cfg` 備份
   - 記錄目前正常運作的外掛程式版本
   - 準備好先前 PVE 版本的還原計畫

### 升級後驗證外掛程式

```bash
# 檢查外掛程式是否已載入
pvesm pluginhelp netappontap

# 測試儲存啟用
pvesm set netapp1 --disable 0
pvesm status

# 測試基本操作（在測試 VM 上）
pvesm alloc netapp1 9999 vm-9999-disk-0 1G
pvesm free netapp1:vm-9999-disk-0
```

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
| `Insecure dependency in exec` | Taint 模式問題（舊版外掛程式）| 更新至 v0.1.2+ |
| `Device for LUN ... not found` | Volume 存在於 ONTAP 但裝置無法存取 | 啟動 VM 或檢查 iSCSI 連線 |

### 外掛程式未安裝在所有節點

若在叢集中存取某節點時看到此錯誤：
```
Parameter verification failed. (400)
storage: No such storage
```

**原因：** NetApp 儲存已配置在 `/etc/pve/storage.cfg`（叢集共享），但此特定節點未安裝外掛程式。

**解決方案：**
```bash
# 在受影響的節點上安裝
dpkg -i jt-pve-storage-netapp_0.2.5-1_all.deb
apt install -f
systemctl restart pvedaemon pveproxy
```

### 核心任務掛起（vgs 阻塞）

若在 `dmesg` 中看到以下錯誤：
```
INFO: task vgs:12345 blocked for more than 120 seconds
```

**原因：** multipath 裝置有失敗路徑，等待 I/O 的程序卡在核心 D 狀態。

**解決方案：**
```bash
# 檢查 multipath 狀態
multipath -ll

# 尋找 "failed faulty" 路徑如：
# `- 4:0:0:1 sdd 8:48 failed faulty running

# 移除故障的 SCSI 裝置
echo 1 > /sys/block/sdd/device/delete

# 清除孤立的 multipath 裝置
multipath -f <WWID>

# 重新配置 multipath
multipathd reconfigure
```

**預防：** 在建立/啟用 volumes 前確保 iSCSI 目標可存取。

### 連結複製裝置無法存取

當使用從未啟動過的連結複製 VM 時，本機裝置可能不存在。

**行為（v0.1.3+）：** 外掛程式回傳合成路徑（`/dev/mapper/$wwid`），刪除等操作透過 ONTAP API 正常執行。

**舊版本可能看到：**
```
Device for LUN /vol/pve_netapp1_xxx_disk0/lun0 not found
```

**舊版本解決方案：**
```bash
# 升級至 v0.1.3+ 會自動處理此情況
# 或透過 REST API 或 System Manager 手動從 ONTAP 刪除
```

### Multipath WWID 不符

若 `scsi_id` 和 `multipath` 對同一裝置顯示不同的 WWID：
```bash
# 檢查實際裝置 WWID
/lib/udev/scsi_id -g -u /dev/sdX

# 檢查 multipath WWID
multipathd show maps raw format "%w"
```

**原因：** LUN 替換或重建後的過時 multipath 快取。

**解決方案：**
```bash
# 移除過時的 multipath 裝置
multipathd del map <old_wwid>

# 清除並重新配置
multipath -F
multipathd reconfigure
```

詳細疑難排解請參閱 [docs/TROUBLESHOOTING_zh-TW.md](docs/TROUBLESHOOTING_zh-TW.md)。

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

### 錯誤訊息

外掛程式提供清晰、可操作的錯誤訊息：

```
# 縮小嘗試
Cannot shrink LUN: current size 32.00GB, requested 16.00GB. Shrinking would cause data loss.

# 裝置使用中
Cannot delete volume 'vm-100-disk-0': device /dev/mapper/xxx is still in use
(mounted, has holders, or open by process). Please stop the VM and unmount first.

# Volume 已存在
Volume 'pve_netapp1_100_disk0' already exists on ONTAP. This may indicate a
naming conflict or orphaned volume.

# 空間不足
Insufficient space in aggregate 'aggr1': available 10.50GB, required 32.00GB

# 範本有連結複製
Cannot delete volume 'vm-100-disk-0': it has FlexClone children depending on it.
Dependent volumes: pve_netapp1_101_disk0, pve_netapp1_102_disk0.
Please delete or split the clones first.
```

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
