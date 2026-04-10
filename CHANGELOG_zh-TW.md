# 變更紀錄

NetApp ONTAP Storage Plugin for Proxmox VE 的所有重要變更都記錄在此。

## [0.2.5] - 2026-04-10

### 非 iSCSI SCSI host 掃描修復 Release (CRITICAL)

**重大 Bug 修復 (HPE ProLiant 正式環境事件):**

- **修復 `rescan_scsi_hosts()` 與 `rescan_fc_hosts()` 會對非 iSCSI / 非 FC host 寫入。** 兩個 function 原本都會迭代 `/sys/class/scsi_host/` 下的所有條目,然後對每個 `hostN/scan` 檔案寫入 `"- - -"`。這包含了非 iSCSI / 非 FC 的 host,例如硬體 RAID 控制器、USB 讀卡機、virtio-scsi 等等。對非 iSCSI host 的 scan 檔案寫入會觸發 driver 端的完整 target 重掃,在某些 driver 裡可能卡上數百秒。

  **正式環境觀察到的症狀** 發生在一台 HPE ProLiant 伺服器,使用 `smartpqi` driver (P408i-a 控制器): 寫入 `host1/scan` 進入 D-state 超過 10 分鐘,卡在 `sas_user_scan`,使**每一個**後續存取 `/sys/class/scsi_host/host1` 的 process 都必須排在它後面。連鎖效應:
  - pvedaemon worker 無法釋放 VM config lock,客戶看到 VM 操作反覆出現 `trying to acquire lock... got timeout`
  - pvestatd 無法完成 `status()` poll
  - `pvedaemon` 在 `dpkg --configure` 期間 restart 永遠卡住,plugin 升級變相失敗
  - VM 操作 (move-disk、resize、config update、開機順序調整) 即使 storage 路徑完全健康也會間歇性卡住

  v0.2.0 加的 `sysfs_write_with_timeout()` 保護讓 parent process 不會跟著卡 (10 秒 timeout),但 child process 進入 D-state (uninterruptible sleep),持續占著 kernel 對 host1 的 scan lock。`SIGKILL` 無法 reap D-state process,所以 lock 會一直持續直到 kernel driver 自己的 timeout 過期 (約 10 分鐘),這時下一個 PVE 操作又已經排到後面,循環繼續。

- **修復方式:** `rescan_scsi_hosts()` 改從 `/sys/class/iscsi_host/` 取得 host 清單 (由 kernel 的 `scsi_transport_iscsi` 層維護)。所有 iSCSI SCSI host 都會註冊到這個 class,不論底層 driver 是什麼 (`iscsi_tcp`、`iser`、`bnx2i`、`qla4xxx`、`qedi`、`be2iscsi`、`cxgb3i`、`cxgb4i`,以及任何未來透過 `iscsi_host_alloc()` 註冊的 iSCSI driver)。非 iSCSI host 絕對不會出現在這個 class,所以迭代它既完整又安全。**未來相容**: kernel 新加的 iSCSI driver 會被自動涵蓋,plugin 不用改 code。

- **修復方式:** `FC.pm` 的 `rescan_fc_hosts()` 在 post-LIP 的 SCSI scan loop 有一樣的 bug。現在只迭代從 `/sys/class/fc_host/` 來的 FC host (透過 `get_fc_hosts()` 已經 enumerate 過)。

**架構層級的教訓:**
這個 bug 從 v0.1.0 就存在了。之前的版本只是保護 parent process 不會跟著 hang,並沒有真的阻止寫入到達 kernel。正確的解法是**根本不要對非 iSCSI host 寫入** — 那些 host 跟 plugin 管理的 iSCSI LUN 完全無關。

## [0.2.4] - 2026-04-09

### Cleanup 路徑強化 + 並行 + Operator UX Release

**並行修復:**

- **修復 `clone_image()` disk-id TOCTOU race (HIGH)。** 舊版程式碼先用 `volume_get` 預檢查找空 disk ID,然後在 loop 外面才呼叫 `volume_clone()`。對同一個 VM 兩個並行 `clone_image()` 呼叫(例如來自不同 cluster node 的同時 template clone,或任何繞過 PVE storage cfs lock 的路徑)會兩個都用同一個 disk ID 通過預檢查,然後在 `volume_clone` 上 race,輸的那個會 die "already exists"。現在 `volume_clone` 已移進 retry loop,遇到 "already exists" 錯誤會自動 retry 下一個 disk ID。跟 v0.2.1 `alloc_image` TOCTOU 修復一樣的 pattern,只是補上漏掉的 function。

- **修復暫時 FlexClone (snapshot 讀取存取) 在 `_ensure_temp_clone()` 的 TOCTOU race (MEDIUM)。** 暫時 clone 的命名是 volume+snap 確定性產生,所以兩個並行 `path()` 呼叫讀同一個 snapshot (例如同時 qmrestore + qm clone --full from snapshot) 會在 `volume_clone` 上 race。輸的那個之前會 die。現在把 "already exists" 當成功處理,因為暫時 clone 是共享且可重用的。

**Operator UX:**

- **新增 `_translate_limit_error()` helper,偵測常見 ONTAP 資源上限錯誤並加上 operator 友善訊息。** 涵蓋的 pattern:FlexVol 數量上限 (per-SVM 與 per-node)、SVM/cluster LUN 上限、igroup LUN-map 上限 (預設每 igroup 4096,per-node mode 較快達到)、aggregate 滿 (涵蓋 thin overcommit 情境)、SVM quota 超出。套用於所有 `alloc_image` 與 `clone_image` 的 die 點。Operator 現在會看到 `ONTAP FlexVol limit reached on this SVM/node. This plugin uses 1 FlexVol per VM disk; you may have hit the SVM volume cap (default ~12000) ...` 而不是原始 ONTAP REST API 錯誤代碼。

**正式環境程式碼稽核修復:**

- **修復 `clone_image()` cleanup 缺少 `lun_unmap_all()` (HIGH)。** 跟 v0.2.1 修掉的 `alloc_image()` 是同一個 bug pattern,但 `clone_image()` 漏修。當 `lun_map()` 中途失敗時(例如 per-node 模式下成功 map 到部分節點 igroup 後,在後面的節點失敗),cleanup 會直接對「仍處於 mapped 狀態」的 LUN 呼叫 `volume_delete`。ONTAP 會拒絕這個操作,結果是留下殘留的 igroup mapping 與其它 cluster node 看得到的 ghost LUN。這些 ghost LUN 接著就變成 stale multipath 裝置,任何 process 碰到都會卡住 -- 這就是 v0.2.3 客戶 node hang 的同一個根本原因。`clone_image()` 兩個 cleanup 分支(`unless ($lun)` 與 `lun_map` 失敗)現在都會先 `lun_unmap_all` 再 `volume_delete`。

- **`volume_snapshot()` 加上 snapshot 前的 host-side buffer flush (LOW)。** 對 running VM,qemu 自己的 freeze 會處理 filesystem 層的一致性。但對於關機 VM 的 snapshot 或外部腳本呼叫,page cache 中尚未落盤的資料不會被 flush,可能產生 filesystem 不一致的 snapshot。新增的 flush 邏輯與 `volume_snapshot_rollback()` 相同:先 `is_device_in_use` 檢查,然後 `sync` + `blockdev --flushbufs`(都帶 timeout)。如果裝置被別的 process 使用就完全跳過(live migration 安全)。

- **移除無用程式碼:`Multipath.pm` 的 `get_multipath_wwid()` (LOW)。** 這個 function 有 export 但全 codebase 沒有任何 caller。更糟的是它對 device 路徑直接用 `basename()` 而沒有 symlink resolution -- 任何未來 caller 如果傳 `/dev/mapper/<wwid>` 進來就會踩到跟 v0.2.3 `is_device_in_use` 資料遺失 bug 完全相同的陷阱。直接刪掉比留著當地雷安全。

**背景:**
v0.2.3 客戶事件後(qm resize 卡住 + 潛在的 `is_device_in_use` 資料遺失 bug),我們對 plugin 做了完整的程式碼稽核,專門找兩種 bug pattern:(1) cleanup 路徑直接 `volume_delete` 而沒先 unmap LUN;(2) function 在存取 `/sys/block/` 之前對 device 路徑用 `basename()`。又找到 3 個問題,在這個 release 修掉。

## [0.2.3] - 2026-04-09

### 升級前殘留裝置處理 Release (重大修復)

**正式環境升級情境的重大修復：**
- 修復殘留清理機制無法處理升級前殘留的 stale multipath 裝置。v0.2.2 只清理升級後 path() 過的 WWID，從舊版本（v0.1.x）留下的 stale 裝置從來沒被追蹤過，因此無法自動清理。v0.2.3 在每次 status() 輪詢時自動將 ONTAP 上現有的 pve_* LUN WWID 匯入追蹤檔，確保所有叢集節點最終都會收斂到一致的視圖，無論本地節點上次呼叫 path() 是何時。

**Multipath 卡住預防（重大）：**
- 修復 cleanup_lun_devices() 在 multipath 裝置設定了 queue_if_no_path 時會卡住的問題。現在會在任何 sync/flush 操作前先透過 `multipathd disablequeueing map` 與 `dmsetup message ... fail_if_no_path` 停用排隊，讓 I/O 快速失敗而非永久排隊。
- 為所有 multipath_flush() 與 multipath_reload() 操作加上 10 秒 timeout。
- 若 `multipath -f` timeout，會 fallback 到 `dmsetup remove --force --retry`，繞過會在 dead device 上卡住的 multipath flush 邏輯。
- 為 `multipathd remove map` 呼叫加上 10 秒 timeout。

**postinst 殘留裝置偵測：**
- postinst 現在會掃描所有路徑都失敗的 NETAPP multipath 裝置，並顯示醒目警告，列出 WWID 與精確的清理指令。為了不誤碰手動管理的儲存，**不會自動清理**。從 v0.1.x 或 v0.2.0/1 升級時特別重要，因為這些版本可能留下了沒追蹤的殘留裝置。

**重大 Symlink 解析修復（防止資料遺失）：**
- 新增 `_resolve_block_device_name()` 輔助函式，將 `/dev/mapper/<wwid>` symlink 解析為底層的 `dm-N` kernel 名稱。任何對 multipath 裝置路徑的 `/sys/block/` 存取都需要這個。
- 修復 `is_device_in_use()` 使用此輔助函式。之前 `is_device_in_use('/dev/mapper/<wwid>')` 會用 `basename()` 取出 WWID，然後查 `/sys/block/<wwid>/holders/` 這個不存在的路徑。結果：multipath 裝置上的 LVM 等 holder 會被靜默忽略，`free_image()` 會直接刪除使用中的 volume -- **資料遺失風險**。任何在 NetApp multipath 裝置上做 LVM / dm-crypt 等設置的環境都受影響（這正是常見的 production 用法）。
- 修復 `get_multipath_slaves()` 使用此輔助函式。之前對 `/dev/mapper/<wwid>` 路徑會回傳空的 slave 列表，使 `volume_resize` 等需要列舉路徑的操作壞掉。

**Snapshot Rollback 修復：**
- `volume_snapshot_rollback()` 改用 per-device rescan 而非 host scan，並在 rollback 後做 kernel buffer cache 失效。沒有 cache 失效的話，rollback 後的讀取可能會傳回 rollback 前的舊快取資料。

**重大 Resize 修復：**
- 修復 `volume_resize()` 使用 `rescan_scsi_hosts()`（host 掃描）而非 per-device rescan。host 掃描是用來「發現新裝置」的，**不會**觸發重新讀取現有裝置的大小。結果：在 ONTAP 上 resize LUN 之後，kernel 仍看到舊的大小，QEMU 的 `block_resize` 會失敗並顯示 "Cannot grow device files"。此外 host 掃描還會在無回應的 iSCSI host 上卡住。
- `volume_resize()` 現在正確地：
  1. 遍歷 multipath 裝置的所有 SCSI slave devices
  2. 對每個 slave 執行 `echo 1 > /sys/block/sdX/device/rescan`（有 timeout 保護）
  3. 執行 `multipathd resize map <name>` 重新整理 multipath 大小

**慢速操作支援：**
- `volume_delete()` 現在使用延長的 60 秒 API timeout（之前是 15 秒）。FlexClone 刪除可能在 ONTAP 上需要 30 秒以上，特別是在清理 snapshot 相依性時。之前 15 秒的預設值會產生「command timed out」警告訊息，即使操作最終會透過 retry 迴圈成功完成。
- `_request()` 現在支援 per-call timeout override。

**背景：**
客戶環境在磁碟遷移時遇到節點掛起，因為 `vgs` 掃描到一個設定了 `queue_if_no_path` 的 stale multipath 裝置。這個 stale 裝置是從舊版 plugin 留下的，從來沒被 v0.2.2 的殘留清理機制追蹤過。結果：vgs 進入 D state，pvedaemon 等它而卡住，連 `systemctl restart` 也卡住。最終只能重開機。v0.2.3 透過以下方式防止這個問題：
1. 自動匯入存活的 WWID，讓叢集節點都知道所有 LUN
2. 在任何清理操作前停用 queue_if_no_path
3. 安裝時警告升級前已存在的 stale 裝置

## [0.2.2] - 2026-04-08

### 叢集殘留裝置清理 Release

**重大叢集修復：**
- 修復在另一個節點刪除 VM 後，叢集節點上殘留 stale multipath 裝置的問題。之前當 Node A 移除 VM 時，Node B 上對應該 LUN 的 SCSI/multipath 裝置會變成殘留並無限期保留（顯示所有路徑為 failed 狀態）。如果 multipath.conf 設定為**有問題的** `no_path_retry queue`（請務必改為 `no_path_retry 30`，見 [README_zh-TW.md](README_zh-TW.md#規則-3檢查你的-etcmultipathconf-設定)），任何程序觸碰到殘留裝置都可能讓整個節點掛起。v0.2.2 自動清理殘留，無論 `no_path_retry` 設定為何都更安全。

**新功能：自動殘留裝置清理**
- 新增每儲存的 WWID 追蹤狀態檔，位於 `/var/lib/pve-storage-netapp/<storeid>-wwids.json`。每個節點記錄它看過的此儲存的 WWID。
- `path()` 在成功解析到真實裝置後追蹤 WWID。
- `free_image()` 在成功刪除 LUN 後取消追蹤 WWID。
- `status()` 在每次輪詢時於背景 fork 執行殘留清理。比對追蹤的 WWID 與 ONTAP 上目前的 LUN 列表，清理 ONTAP 上已不存在的追蹤 WWID 對應的本機裝置。
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
