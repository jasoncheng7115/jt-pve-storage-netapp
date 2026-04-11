# 設定參考文件 - NetApp ONTAP 儲存外掛

## 免責聲明

> **警告：本專案為新開發的外掛，使用風險請自行承擔。**
>
> - **iSCSI 協定已經過測試，但尚未在正式環境中廣泛驗證**
> - **FC (Fibre Channel) 協定尚未完成完整驗證**
> - 部署前請務必在非正式環境中充分測試
> - 完整免責聲明與已知限制請參閱 README_zh-TW.md

## 概述

本文件詳細說明 NetApp ONTAP 儲存外掛所有可用的設定選項。

## 新增儲存

### 透過 CLI (建議方式)

```bash
pvesm add netappontap <storage-id> [OPTIONS]
```

### 透過 storage.cfg

編輯 `/etc/pve/storage.cfg`：

```ini
netappontap: <storage-id>
    <option> <value>
    ...
```

## 必要選項

### ontap-portal

**類型：** string
**必填：** 是
**說明：** ONTAP 叢集 (cluster) 或 SVM 管理 IP 位址或主機名稱

```bash
--ontap-portal 192.168.1.100
--ontap-portal ontap.example.com
```

**備註：**
- 請使用管理 LIF 的 IP 位址
- 對於 SVM 層級的使用者，請使用 SVM 管理 LIF
- 固定使用 HTTPS (port 443)

### ontap-svm

**類型：** string
**必填：** 是
**說明：** 儲存虛擬機器 (Storage Virtual Machine, Vserver) 名稱

```bash
--ontap-svm svm0
--ontap-svm vs_prod
```

**備註：**
- 必須是已啟用 iSCSI 服務的現有 SVM
- API 使用者必須能存取此 SVM

### ontap-aggregate

**類型：** string
**必填：** 是
**說明：** 建立 volume 時所使用的 aggregate 名稱

```bash
--ontap-aggregate aggr1
--ontap-aggregate aggr_ssd_01
```

**備註：**
- 必須是既有且有可用空間的 aggregate
- 本儲存建立的所有 volume 皆會使用此 aggregate
- 請依效能需求選擇適當的 aggregate

### ontap-username

**類型：** string
**必填：** 是
**說明：** ONTAP API 使用者名稱

```bash
--ontap-username pveadmin
--ontap-username admin
```

**備註：**
- 建議建立專用使用者並授予最小必要權限
- 請參閱下方 [ONTAP 使用者設定](#ontap-使用者設定) 章節

### ontap-password

**類型：** string
**必填：** 是
**說明：** ONTAP API 密碼

```bash
--ontap-password 'YourSecurePassword'
```

**備註：**
- 請使用單引號以避免特殊字元被 shell 展開
- 密碼會以明文儲存在 `/etc/pve/storage.cfg` (叢集範圍、僅 root 可存取)

## 選填選項

### ontap-protocol

**類型：** enum (iscsi, fc)
**預設值：** iscsi
**說明：** SAN 傳輸協定

```bash
--ontap-protocol iscsi   # iSCSI over Ethernet (預設)
--ontap-protocol fc      # Fibre Channel
```

**iSCSI 模式：**
- 需要 iSCSI initiator (open-iscsi)
- 自動進行 target 探索與登入
- 使用 IQN 識別 initiator

**FC 模式：**
- 需要 FC HBA (Fibre Channel Host Bus Adapter)
- 自動從 FC HBA 取得 WWPN
- 使用 WWPN 識別 initiator
- 無需 target 登入 (由 FC fabric 處理連線)

**備註：**
- 兩種協定皆使用相同的多重路徑 (multipath) 設定
- 兩種協定皆以 WWID 識別裝置
- FC 模式仍需設定 `ontap-portal` 以進行 API 存取

### ontap-ssl-verify

**類型：** boolean (0 或 1)
**預設值：** 1
**說明：** 是否驗證 ONTAP SSL 憑證

```bash
--ontap-ssl-verify 0   # 關閉驗證
--ontap-ssl-verify 1   # 啟用驗證 (預設)
```

**備註：**
- 若使用自簽憑證，請設為 0
- 正式環境請使用有效憑證並啟用驗證

### ontap-thin

**類型：** boolean (0 或 1)
**預設值：** 1
**說明：** 是否對 volume 與 LUN 使用精簡佈建 (thin provisioning)

```bash
--ontap-thin 1   # 精簡佈建 (預設)
--ontap-thin 0   # 完整佈建 (thick provisioning)
```

**精簡佈建優點：**
- 節省空間 - 僅使用實際資料所佔空間
- 建立 volume 速度較快
- 可支援超額配置 (overcommitment)

**完整佈建優點：**
- 保證空間配置
- 效能較可預期
- 無空間耗盡風險

### ontap-igroup-mode

**類型：** enum (per-node, shared)
**預設值：** per-node
**說明：** igroup 管理模式

```bash
--ontap-igroup-mode per-node   # 每個 PVE 節點一個 igroup (預設)
--ontap-igroup-mode shared     # 所有節點共用單一 igroup
```

**per-node 模式：**
- 建立 igroup：`pve_{cluster}_{nodename}`
- 每個 PVE 節點擁有獨立的 initiator group
- 存取控制更為精細
- 建議正式環境使用

**shared 模式：**
- 建立 igroup：`pve_{cluster}_shared`
- 所有 PVE 節點共用單一 initiator group
- 管理較為簡單
- 所有節點必須為受信任節點

### ontap-cluster-name

**類型：** string
**預設值：** pve
**說明：** igroup 命名時使用的叢集名稱

```bash
--ontap-cluster-name production
--ontap-cluster-name lab
```

**備註：**
- 用於產生獨特的 igroup 名稱：`pve_{cluster}_{node}`
- 當多個 PVE 叢集共用同一 ONTAP 時特別有用
- 僅允許英數字與底線

### ontap-device-timeout

**類型：** integer
**預設值：** 60
**說明：** LUN 映射後等待裝置出現的逾時秒數

```bash
--ontap-device-timeout 60    # 預設：60 秒
--ontap-device-timeout 120   # 儲存網路較慢時可加大
```

**備註：**
- 外掛在映射 LUN 後會等待裝置出現
- 若逾時則作業失敗並回報 "Device did not appear" 錯誤
- 高延遲網路環境建議加大此值
- 開發/測試環境可設較低值

## 標準 PVE 選項

### content

**類型：** content type 清單
**預設值：** images
**說明：** 允許的內容類型

```bash
--content images           # 僅 VM 磁碟映像
--content images,rootdir   # VM 磁碟與容器 rootfs
```

**支援的內容類型：**
- `images` - VM 磁碟映像 (QEMU)
- `rootdir` - 容器根目錄 (LXC)

**不支援：**
- `iso` - ISO 映像 (區塊儲存無法存放檔案)
- `vztmpl` - 容器範本
- `backup` - 備份檔

### shared

**類型：** boolean (0 或 1)
**預設值：** 0
**說明：** 將儲存標記為叢集共用

```bash
--shared 1   # 共用儲存 (建議)
--shared 0   # 本地儲存
```

**備註：**
- iSCSI SAN 儲存應一律設為 1
- 跨節點線上遷移 (live migration) 必須啟用

### nodes

**類型：** node 清單
**預設值：** 所有節點
**說明：** 限制儲存僅於特定節點使用

```bash
--nodes pve1,pve2      # 僅可於 pve1 與 pve2 使用
--nodes pve1           # 僅可於 pve1 使用
```

### disable

**類型：** boolean (0 或 1)
**預設值：** 0
**說明：** 停用此儲存

```bash
--disable 1   # 停用儲存
--disable 0   # 啟用儲存 (預設)
```

## 完整範例

### 最簡設定

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

### 完整設定

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

### storage.cfg 格式

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

## ONTAP 使用者設定

### 方案 A：叢集層級帳號 (建議)

若 SVM 沒有專用的管理 LIF，請採用此方案：

```bash
# 在叢集層級建立具 admin 角色的使用者
security login create -user-or-group-name pveadmin \
    -application http \
    -authmethod password \
    -role admin
```

**優點：**
- 設定簡單
- 可透過叢集管理 LIF 運作
- 無需 SVM 管理 LIF

**缺點：**
- 權限範圍較廣 (admin 角色)

### 方案 B：SVM 層級帳號 (權限較受限)

若 SVM 擁有自己的管理 LIF，可採用此方案：

```bash
# 建立具最小必要權限的自訂角色
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

# 使用自訂角色建立使用者
security login create -vserver svm0 \
    -user-or-group-name pveadmin \
    -application http \
    -authmethod password \
    -role pve_storage
```

**優點：**
- 最小必要權限
- 僅限定於特定 SVM

**缺點：**
- 需要 SVM 管理 LIF (與資料 LIF 分開)
- 設定較為複雜

### 重要：管理 LIF 需求

| 帳號層級 | 需要的管理 LIF | 備註 |
|---------|---------------|------|
| 叢集 (Cluster) | 叢集管理 LIF | 通常已存在 (例如 192.168.1.194) |
| SVM | SVM 管理 LIF | 經常未設定；資料 LIF 無法使用 |

**常見問題：** 若建立了 SVM 層級帳號但 SVM 僅有資料 LIF，認證會失敗並顯示 "User is not authorized"。此時請改用叢集層級帳號。

### 驗證權限

```bash
# 叢集層級帳號
security login show -user-or-group-name pveadmin

# SVM 層級帳號
security login role show -vserver svm0 -role pve_storage
security login show -vserver svm0 -user-or-group-name pveadmin
```

## 修改設定

### 更新選項

```bash
# 變更 aggregate
pvesm set netapp1 --ontap-aggregate aggr2

# 變更密碼
pvesm set netapp1 --ontap-password 'NewPassword'

# 關閉 SSL 驗證
pvesm set netapp1 --ontap-ssl-verify 0
```

### 移除選項

```bash
# 移除節點限制
pvesm set netapp1 --delete nodes
```

### 檢視設定

```bash
# 顯示儲存設定
pvesm config netapp1

# 顯示所有儲存
cat /etc/pve/storage.cfg
```

## 設定問題排查

### 測試 ONTAP 連線

```bash
# 測試 API 存取
curl -k -u pveadmin:password https://192.168.1.100/api/cluster

# 預期：回傳包含叢集資訊的 JSON
```

### 檢查儲存狀態

```bash
# 檢查儲存狀態
pvesm status

# 檢查特定儲存
pvesm status -storage netapp1
```

### 驗證設定

```bash
# 嘗試啟用儲存
pvesm set netapp1 --disable 0

# 檢查錯誤訊息
journalctl -xeu pvedaemon | tail -50
```

## 範本 (Template) 支援 (v0.1.5+)

### 範本運作原理

將 VM 轉為範本時 (`qm template <vmid>`)：

1. 外掛會在 ONTAP volume 上建立 `__pve_base__` 快照
2. PVE 將磁碟由 `vm-XXX-disk-X` 更名為 `base-XXX-disk-X`
3. ONTAP FlexVol 名稱維持不變 (兩個名稱對應至同一 volume)
4. `__pve_base__` 快照的作用：
   - 範本標記 (由 `list_images` 偵測)
   - FlexClone linked clone 的基準點

### 範本偵測

`pvesm list` 會以 `base-` 前綴顯示範本 volume：

```
Volid                   Format  Type            Size VMID
netapp1:base-107-disk-0 raw     images    1073741824 107   # 範本
netapp1:vm-100-disk-0   raw     images    1073741824 100   # 一般 VM
```

### 從範本建立 Linked Clone

```bash
# 從範本 107 建立 linked clone
qm clone 107 200 --name "my-clone" --full 0
```

Clone 採用 NetApp FlexClone：
- 瞬間建立 (不複製資料)
- 節省空間 (與父系共用區塊)
- 獨立快照

### 修正 v0.1.5 之前的範本

v0.1.5 之前建立的範本需手動修正：

```bash
# 1. 從 storage.cfg 取得儲存憑證
grep -A10 "netappontap:" /etc/pve/storage.cfg

# 2. 建立 __pve_base__ 快照 (請替換為實際值)
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

# 3. 更新 VM 設定使其使用 base- 前綴
sed -i 's/vm-107-disk-0/base-107-disk-0/g' /etc/pve/qemu-server/107.conf
```

## 安全考量

### 1. 密碼儲存

密碼以明文儲存在 `/etc/pve/storage.cfg`。這是 **PVE 標準設計**，所有需要認證的儲存外掛皆採此方式 (Ceph、iSCSI CHAP、ZFS over iSCSI 等)。

**檔案權限：**
```
-rw-r----- root www-data /etc/pve/storage.cfg (mode 0640)
```

| 使用者/群組 | 存取權限 | 原因 |
|------------|---------|------|
| root | 讀寫 | 系統管理員 |
| www-data | 唯讀 | PVE 服務 (pvedaemon、pveproxy) |
| 其他使用者 | 無存取 | 由檔案權限保護 |
| 叢集節點 | 讀取 | 由 pmxcfs (叢集檔案系統) 複寫 |

**風險評估：**
- 一般使用者無法讀取此檔案
- 具存取權者 (root、叢集管理員) 本身已擁有完整系統權限
- ONTAP API 帳號應限制權限，以降低外洩時的影響

**額外強化 (選用)：**

1. **ONTAP 端 IP 限制：**
   ```bash
   # 在 ONTAP CLI 上限制 API 使用者只能從特定 IP 存取
   security login create -vserver svm0 \
       -user-or-group-name pveadmin \
       -application http \
       -authmethod password \
       -role pve_storage \
       -second-authentication-method none

   # 新增 IP 存取政策 (需 ONTAP 9.10+)
   vserver services web access-log config modify \
       -vserver svm0 -access-log-policy <policy>
   ```

2. **網路隔離：**
   - 將 ONTAP 管理 LIF 放置於獨立的管理 VLAN
   - 透過防火牆規則僅允許 PVE 節點存取 port 443

3. **定期輪替密碼：**
   ```bash
   # 在 ONTAP 上更新密碼
   security login password -username pveadmin -vserver svm0

   # 在 PVE 上更新密碼
   pvesm set netapp1 --ontap-password 'NewPassword'
   ```

4. **監控：**
   - 啟用 ONTAP API 存取稽核日誌
   - 監控異常 API 活動

### 2. SSL/TLS

- 固定使用 HTTPS (外掛強制)
- 正式環境請啟用 SSL 驗證
- 盡可能使用有效憑證

```bash
# 啟用 SSL 驗證 (正式環境建議)
pvesm set netapp1 --ontap-ssl-verify 1

# 關閉 (僅開發/實驗環境使用自簽憑證時)
pvesm set netapp1 --ontap-ssl-verify 0
```

**警告：** 當 `ontap-ssl-verify` 停用時，外掛會記錄警告訊息。

### 3. API 使用者權限

**建議：建立具最小必要權限的專用角色**

```bash
# 在 ONTAP CLI 上建立自訂角色
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

# 使用自訂角色建立使用者
security login create -vserver svm0 \
    -user-or-group-name pveadmin \
    -application http \
    -authmethod password \
    -role pve_storage
```

**帳號層級說明：**
- **SVM 層級帳號**：需要 SVM 管理 LIF (與資料 LIF 分開)
- **叢集層級帳號**：可使用叢集管理 LIF，但存取範圍較廣
- 若 SVM 沒有管理 LIF，請改用叢集層級帳號並搭配適當角色

**內建角色參考：**

| 角色 | 層級 | 權限 |
|------|------|------|
| admin | 叢集 | 完整存取 (建議避免使用) |
| vsadmin-volume | SVM | Volume/LUN/Snapshot 操作 (建議) |
| vsadmin | SVM | 完整 SVM 管理 |
| readonly | 皆可 | 唯讀存取 (本外掛無法使用) |

### 4. 網路安全

- 使用專用管理網路進行 ONTAP API 存取
- 將 iSCSI/FC 資料網路與管理網路分離
- 考慮設定防火牆規則：

```bash
# 範例：僅允許 PVE 節點連線 ONTAP API
iptables -A OUTPUT -d <ontap-mgmt-ip> -p tcp --dport 443 -j ACCEPT
```

**網路架構範例：**
```
┌─────────────┐     管理網路 (VLAN 10)              ┌─────────────┐
│   PVE Node  │──────────── 192.168.1.0/24 ──────────│ ONTAP Mgmt  │
│  (pc-pve1)  │                                       │    LIF      │
└─────────────┘                                       └─────────────┘
       │
       │            iSCSI/FC 資料網路 (VLAN 20)
       └─────────────── 10.0.0.0/24 ──────────────────┌─────────────┐
                                                      │ ONTAP Data  │
                                                      │    LIF      │
                                                      └─────────────┘
```

---

## 多重路徑 (Multipath) 設定

### 自動設定 (全新安裝)

若系統**尚未**存在 NetApp 多重路徑設定，安裝外掛時會自動於 `/etc/multipath.conf` 加入安全預設值，無須手動處理。

### 既有多重路徑設定 (手動處理)

若 `/etc/multipath.conf` 已存在 NetApp 多重路徑設定 (例如先前手動設定 iSCSI 時留下的)，外掛**不會**自動修改。若設定需要更新，安裝過程中會顯示警告。

### 關鍵設定

以下多重路徑設定直接影響系統穩定性。錯誤設定可能導致 NetApp LUN 被刪除或無法使用時，**整個 PVE 節點失去回應**。

#### no_path_retry (關鍵)

控制 LUN 的**所有**路徑失效時的行為 (例如 LUN 被刪除、網路中斷、ONTAP failover)。

| 值 | 行為 | 風險 |
|----|------|------|
| `queue` | I/O **無限期**排隊 | **危險** - 任何存取此裝置的程序會永久 hang 住，PVE 節點失去回應，連 `kill -9` 也無法終止，只能重開機恢復。 |
| `30` | I/O 排隊約 150 秒後失敗 | **建議值** - 預留足夠時間讓 ONTAP failover 完成，同時避免永久卡住。 |
| `fail` | I/O 立即失敗 | 過於激進 - 正常 failover 亦會引發不必要的錯誤。 |

**建議值：** `no_path_retry 30`

若現行設定為 `no_path_retry queue` 或有 `features "... queue_if_no_path ..."`，請修正為：

```
# 修改前 (危險)：
no_path_retry           queue
features "3 queue_if_no_path pg_init_retries 50"

# 修改後 (安全)：
no_path_retry           30
features "2 pg_init_retries 50"
```

#### dev_loss_tmo

控制當傳輸層 (iSCSI session) 回報裝置遺失後，核心仍保留該 SCSI 裝置的時間。

| 值 | 行為 | 風險 |
|----|------|------|
| `infinity` | 裝置**永不**移除 | **危險** - 已刪除 LUN 的殘留 SCSI 裝置永遠不會清除，會持續產生 I/O 錯誤。 |
| `60` | 裝置於 60 秒後移除 | **建議值** - 預留時間處理暫時性故障，同時清除失效裝置。 |

**建議值：** `dev_loss_tmo 60`

#### fast_io_fail_tmo

控制當傳輸層回報錯誤時，路徑被標記為失效的速度。

**建議值：** `fast_io_fail_tmo 5`

### NetApp 建議的 multipath.conf

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

### queue_if_no_path 為何危險

當 ONTAP 端刪除 LUN，而 PVE 仍維持 iSCSI session 時：

1. ONTAP 已移除 LUN，但主機仍保留 SCSI 裝置項目
2. 任何接觸該殘留裝置的程序皆會觸發 I/O 要求
3. 搭配 `queue_if_no_path` 時，核心會**無限期**將該 I/O 排隊
4. 該程序進入不可中斷睡眠狀態 (D state)，無法被終止
5. PVE 定期輪詢儲存狀態，會觸及該殘留裝置
6. PVE daemon 進入 D state，整個節點失去回應
7. 只能重開機才能恢復

採用 `no_path_retry 30` 後，I/O 會重試約 150 秒後**以錯誤失敗**。程序會收到可處理的 I/O 錯誤，而不會永久 hang 住，同時預留足夠時間讓 ONTAP failover 完成。

### 套用變更

編輯 `/etc/multipath.conf` 之後：

```bash
# 重啟 multipathd 以套用新設定並清除殘留 map
# 重要：請使用 'restart'，不要用 'reload'。
# 'reload' 只會重新讀取設定檔，並不會移除既有的殘留多重路徑 map。
# 已刪除 LUN 的殘留 map 會持續存在直到 restart。
systemctl restart multipathd

# 驗證新設定已生效
multipathd show config local

# 驗證沒有殘留 map
multipath -ll
```

> **為何不用 `reload`？** `systemctl reload multipathd` 只會命令 daemon 重新解析 `/etc/multipath.conf`。新設定僅套用於 *未來* 建立的裝置，**不會**清除既有的多重路徑 map。若系統已有已刪除 LUN 的殘留 map (例如 dm-X 裝置所有路徑顯示為 "failed faulty")，`reload` 並不會移除它們。請使用 `restart`。

### 與既有儲存共存

若系統存在多個使用多重路徑的儲存 (例如既有 NetApp iSCSI 加上本外掛)，外掛會：

- **不修改**既有的 multipath.conf
- 共用相同的 multipath daemon 與 iSCSI 基礎架構
- 以裝置層級過濾 (vendor "NETAPP") 套用其多重路徑設定

若在**同一 SVM**上設定多個外掛儲存項目，請使用不同的 `ontap-cluster-name` 值以避免 igroup 衝突：

```bash
pvesm add netappontap storage-prod --ontap-cluster-name pve-prod ...
pvesm add netappontap storage-dev  --ontap-cluster-name pve-dev ...
```

### 混合環境：手動 iSCSI LVM 與本外掛並存

常見情境：PVE 節點已使用手動設定的 iSCSI (例如 PVE 內建的 "iSCSI" 或 "LVM on iSCSI" 儲存類型)，同時也安裝本外掛以使用額外的 NetApp 儲存。**本外掛完全支援此設定，但必須遵守以下關鍵規則：**

**應該做：**
- 升級至 **v0.2.2 或更新版本** - 自動 orphan 清除會安全地處理本外掛的殘留裝置，不會影響手動設定的儲存。
- 讓外掛完全管理其自有 LUN。
- 若需手動清除，僅針對特定 WWID 進行 flush：`multipath -f <wwid>`。

**不要做：**
- **絕對不要使用 `multipath -F` (大寫 F)。** 此指令會清除系統上所有未使用的多重路徑 map，包含手動設定的 iSCSI LVM (若當下無 I/O 活動)。恢復時需執行 `systemctl reload multipathd` 或 `iscsiadm -m session --rescan`。
- 不要 flush 不熟悉的 WWID - 這些可能屬於手動設定的儲存。

**為何 v0.2.2 在混合環境中安全：**

外掛會在 `/var/lib/pve-storage-netapp/<storeid>-wwids.json` 維護每個儲存的 WWID 追蹤檔。只會紀錄本外掛 `path()` 呼叫所涉及的 WWID (亦即透過 `pvesm alloc` 或 `qm` 操作本外掛儲存所建立的 LUN)。當 orphan 清除執行時 (於 `status()` 輪詢期間)，只會比對追蹤檔中的 WWID 與 ONTAP LUN 清單。手動 iSCSI 設定的 WWID 絕對不會出現在追蹤檔中，因此**絕不會**被自動清除處理到。

**將 `multipath -F` 與手動 LVM iSCSI 混用時的症狀：**

| 症狀 | 原因 | 解法 |
|------|------|------|
| 某節點上沒有 VM 在使用時，執行 `multipath -F` 後手動 iSCSI LVM 從 PVE 中消失 | `multipath -F` 清除了閒置 map | `systemctl reload multipathd` 或 `iscsiadm -m session --rescan` |
| 將 VM 遷移至該節點失敗或 LVM 仍不存在 | PVE LVM 外掛不會自動重新掃描 multipath | 同上 |
| 本外掛儲存正常，手動儲存故障 | `multipath -F` 只影響未使用的 map，本外掛的使用中 map 未受影響 | 同上 |

結論：**升級至 v0.2.2 之後，不要再執行 `multipath -F`。** 外掛會自動且安全地處理自身清除工作。

## 致謝

特別感謝 **NetApp** 慷慨提供開發與測試環境，使本專案得以順利完成。

我們特別感謝 **NetApp 原廠**協助提供開發測試環境，使本專案得以順利完成。
