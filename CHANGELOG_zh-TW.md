# 變更紀錄

NetApp ONTAP Storage Plugin for Proxmox VE 的所有重要變更都記錄在此。

## [0.2.2] - 2026-04-08

### 叢集孤兒裝置清理 Release

**重大叢集修復：**
- 修復在另一個節點刪除 VM 後，叢集節點上殘留 stale multipath 裝置的問題。之前當 Node A 移除 VM 時，Node B 上對應該 LUN 的 SCSI/multipath 裝置會變成孤兒並無限期保留（顯示所有路徑為 failed 狀態）。配合 multipath.conf 的 `no_path_retry queue` 設定，任何程序觸碰到孤兒裝置都可能讓整個節點掛起。

**新功能：自動孤兒裝置清理**
- 新增每儲存的 WWID 追蹤狀態檔，位於 `/var/lib/pve-storage-netapp/<storeid>-wwids.json`。每個節點記錄它看過的此儲存的 WWID。
- `path()` 在成功解析到真實裝置後追蹤 WWID。
- `free_image()` 在成功刪除 LUN 後取消追蹤 WWID。
- `status()` 在每次輪詢時於背景 fork 執行孤兒清理。比對追蹤的 WWID 與 ONTAP 上目前的 LUN 列表，清理 ONTAP 上已不存在的追蹤 WWID 對應的本機裝置。
- **安全性：** 只有追蹤檔中的 WWID 才會被清理，因此手動管理的 NetApp 裝置或其他 plugin 的裝置永遠不會被影響。
- 若清理過程中 ONTAP API 無法連線，操作會中止以避免誤刪有效裝置。

**文件：**
- 更新 postinst 警告，建議使用 `systemctl restart multipathd` 而非 `reload`（reload 不會清除 stale map）。
- 更新 `docs/CONFIGURATION.md` 說明 reload vs restart 的差異。

## [0.2.1] - 2026-04-08

### Production Hardening Release - 邊界條件與競爭條件修復

**競爭條件修復：**
- 修復 `alloc_image()` 磁碟 ID 分配的 TOCTOU 競爭：當 `volume_create` 因並行分配失敗時，自動以下一個磁碟 ID 重試。
- 修復多個叢集節點同時啟動儲存時的 igroup 建立競爭。`igroup_get_or_create()` 現在能正確處理 409 Conflict。
- 修復 `_ensure_igroup()` 以處理多節點同時新增 initiator 的情況。

**Multipath 安全性（防止因 stale device 導致節點當機）：**
- 變更 multipath.conf 範本：將 `queue_if_no_path`（無限排隊）改為 `no_path_retry 30`（有限 150 秒重試）。防止 LUN 路徑失敗或殘留 stale device 時 PVE 節點無限期掛起。
- 將 `dev_loss_tmo` 從 `infinity` 改為 `60` 秒。失敗 LUN 的 SCSI 裝置現在會在 60 秒後被移除。
- 新增 `fast_io_fail_tmo 5` 加速路徑失敗偵測。
- 既有安裝若有手動 multipath.conf，升級時會顯示醒目警告及建議修改內容。

**Stale Device 防護：**
- 修復 `free_image()` 操作順序：現在先從 igroup unmap LUN，再清理本機 SCSI 裝置，防止 iSCSI session rescan 重新發現已刪除的 LUN 產生 ghost device 及 I/O error。
- 在 unmap 前預先擷取 multipath slave 裝置清單，確保所有 SCSI 路徑都能被清除。
- 清理後執行最終 multipath reload 以清除任何殘留的 stale map。

**遷移安全性：**
- `deactivate_volume()` 現在在裝置仍被其他程序使用時跳過 sync/flush，防止 live migration 時 I/O deadlock。
- `deactivate_volume()` 在 API 無法連線時優雅失敗。

**清理與可靠性：**
- `alloc_image()` 失敗清理現在會先呼叫 `lun_unmap_all()` 再 `lun_delete()`，防止 ONTAP 上殘留孤立的 igroup mapping。
- 改善磁碟 ID 耗盡時的錯誤訊息，提示檢查手動建立的 volume 或孤立 volume。

**效能：**
- `list_images()` 範本偵測新增 10 秒期限，防止 volume 數量多時 API timeout 連鎖效應。
- 非磁碟 volume（state、cloudinit）在範本偵測時跳過。
- 已有 active session 的 portal 跳過 iSCSI discovery，避免重複啟動儲存時 30 秒的 discovery timeout。

**Thin Provisioning 安全：**
- `alloc_image()` 使用 thin provisioning 時，當 aggregate 使用率超過 85% 會發出警告。

**iSCSI Session 恢復：**
- `login_target()` 現在設定 `node.session.timeo.replacement_timeout=120`，支援 ONTAP failover/takeover 後自動 session 恢復。

**API 韌性：**
- API 客戶端收到 HTTP 401 時會以新認證重試，處理長時間操作期間的 session 過期問題。

## [0.2.0] - 2026-04-07

### Multipath 與遷移修復 Release - 防當機保護

**重大 Bug 修復：**
- 修復 iSCSI multipath 只建立 1 條 session 而非所有 portal 的問題。`login_target()` 只以 IQN 檢查登入狀態，但所有 ONTAP LIF 共用同一個 IQN，導致第一個 portal 登入後其餘全部跳過。新增 `is_portal_logged_in()` 逐一檢查 portal+target。
- 修復 `alloc_image()` 在 per-node 模式下只 map LUN 到當前節點的 igroup。磁碟遷移（move_disk）會因目的節點看不到新 LUN 而掛起。現在 map 到所有節點的 igroups。

**防當機保護（防止 PVE task worker 無法終止）：**
- 新增 `sysfs_write_with_timeout()`：所有 `/sys/` 寫入（SCSI host scan、device delete、FC issue_lip）現在在 fork 的子程序中執行，10 秒 timeout。
- 新增 `sysfs_read_with_timeout()`：所有 `/sys/` 和 `/proc/` 讀取現在在 fork 的子程序中執行，5 秒 timeout。
- 所有 `system()` 呼叫替換為有 timeout 保護的版本。
- `flock(LOCK_EX)` 改為非阻塞 `LOCK_NB` 加 10 秒重試迴圈。

**遷移可靠性：**
- 修復 `activate_volume()` 只 map LUN 到當前節點的 igroup。
- 修復 `path()` 單次 rescan 失敗後回傳不存在的合成路徑。現在以重試迴圈等待裝置出現（最多 30 秒）。

**ONTAP 故障韌性：**
- API timeout 從 30 秒降為 15 秒，重試從 3 次降為 2 次，最差情況從 ~102 秒降為 ~34 秒。
- `status()` 在 API 無法連線時快速失敗，不阻塞 PVE。
- `status()` 中的暫存 FlexClone 清理移至背景 fork 執行。

**新功能：**
- LXC 容器（rootdir）支援
- EFI Disk、Cloud-init Disk、TPM State 磁碟支援

## [0.1.9] - 2026-02-27

### 安全稽核 Release - 安全性與可靠性修復

**重大安全修復：**
- 修復 `Multipath.pm is_device_in_use()` 命令注入漏洞
- 修復 `_run_cmd()` 的 IPC::Open3 deadlock
- 修復 `_run_cmd()` timeout 時的 zombie process

**資料完整性修復：**
- Snapshot rollback 前現在會檢查裝置使用狀態並 flush 緩衝區
- 移除不安全的 WWID 子字串比對
- 修復 clone_image 磁碟 ID 競爭條件
- 支援線上 resize（移除 VM 必須停止的限制）

## [0.1.8] - 2026-02-12

### Bug Fix Release - FC SAN 與一般修復

- 修復 `is_fc_available()` 始終回傳 true 的問題
- 新增遺漏的 `lun_unmap_all()` 方法
- 修復 `deactivate_storage` `logout_target()` 參數錯誤
- `clone_image` 現在按協定類型過濾 igroup
- 消除 FC 路徑中多餘的 SCSI host rescan

## [0.1.7] - 2026-01-25

### RAM 快照（vmstate）支援 Release

- 完整支援包含 RAM 狀態的 VM 快照（「包含記憶體」選項）
- 安裝時自動設定 multipath
- 安裝時自動重啟 PVE 服務
- 儲存停用清理改進
- 新增 README_zh-TW.md（繁體中文）
- 授權變更為 MIT

## [0.1.6] - 2026-01-24

### Full Clone 支援 Release

- 從 VM 快照完整複製（透過暫時 FlexClone + qemu-img）
- 從目前狀態完整複製
- 暫時 FlexClone 自動清理（1 小時過期）
- 範本的 Linked Clone 維持空間效率（不自動 split）
- 儲存停用時正確清理 iSCSI session

## [0.1.5] - 2026-01-03

### Template 支援 Release

- 完整範本支援（create_base、rename_volume）
- `list_images` 正確識別範本 volume（base-XXX-disk-X）
- `path()` 優雅處理遺失的 LUN（合成路徑用於清理）

## [0.1.4] - 2026-01-03

### FC SAN 支援 Release

- Fibre Channel (FC) SAN 協定支援
- 新增 FC.pm 模組（WWPN 探索、LIP rescan）
- `list_images` 批次 LUN 查詢提升效能
- 可設定裝置探索 timeout（`ontap-device-timeout`）

## [0.1.3] - 2026-01-03

### FlexClone 支援 Release

- 透過 NetApp FlexClone 的 Linked Clone（即時、空間效率）
- 防止刪除有 clone children 的範本
- 修復裝置無法存取時 `path()` 導致系統掛起
- 啟用 volume autogrow，overhead 降至 64MB

## [0.1.2] - 2026-01-02

### Bug Fix 與相依套件 Release

- 啟用 volume autogrow
- 新增 psmisc 相依套件（fuser 指令）

## [0.1.1] - 2026-01-02

### 安全性改進 Release

- 縮小保護、裝置使用中檢查、碰撞偵測
- API 快取 TTL（5 分鐘）
- 修復 PVE taint mode 相容性

## [0.1.0] - 2026-01-02

### 初始 Release

- FlexVol 和 LUN 建立
- igroup 管理
- iSCSI 探索和登入
- Multipath 裝置處理
- 快照操作（建立、刪除、回滾）
- 從 ONTAP 即時取得儲存狀態
