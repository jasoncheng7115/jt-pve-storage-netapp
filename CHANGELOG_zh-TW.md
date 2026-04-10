# 變更紀錄

**jt-pve-storage-purestorage** 所有重要變更皆紀錄於此檔案。
格式參考 [Keep a Changelog](https://keepachangelog.com/),
版本號採用 `MAJOR.MINOR.PATCH-DEBIAN` 規則。

語言 / Language: [English](CHANGELOG.md) | [繁體中文](CHANGELOG_zh-TW.md)

---

## [1.1.6] - 2026-04-10

### postinst 必須 reload 所有 PVE 服務 + LVM global_filter 偵測

來自相關專案 jt-pve-storage-netapp Incident 9 (pvestatd 未 reload) 與
Incident 10 （升級版 PVE 節點上主機 LVM 自動啟用 guest VG) 的兩個問題。

#### 修正
- **[重大] postinst 現在會在安裝後 reload pvedaemon、pvestatd、以及
  pveproxy。** 過去的版本**不會** reload 任何 PVE 服務，代表含舊 bug
  的程式碼會一直留在記憶體中無限期執行。特別是 pvestatd 每 10 秒
  輪詢 `status()` — 若舊程式碼觸發 D-state 子行程 （例如 1.1.5 之前
  的 SCSI host scan bug 在 HPE 硬體上）,D-state 行程會不斷累積，直到
  硬體 watchdog 或手動重新開機介入。

  從 `systemctl restart` 改為 `systemctl reload` (SIGHUP）。若舊程式碼
  已經產生 D-state 子行程，`restart` 的 stop phase 會卡在等待無法
  kill 的行程。`reload` 發送 SIGHUP，讓 `PVE::Daemon` 以 `re-exec()`
  自己載入新程式碼，完全跳過 stop phase。
- **[高] postinst 現在會檢查 `/etc/lvm/lvm.conf` 是否有
  `global_filter`，並在缺少時警告。** 在從 PVE 7/8 升級到 9 的節點上，
  舊的 `lvm.conf` 缺少排除 device-mapper 和 multipath 裝置免於 LVM
  掃描的 filter。主機 LVM 會自動啟用 guest VM 磁碟內的 VG （那些是以
  multipath 裝置形式呈現的原始 LUN)，在 multipath 裝置上方建立
  holder dm 裝置。這些 holder 讓 `is_device_in_use()` 正確擋住
  `free_image()` 的刪除，但舊版錯誤訊息無法讓操作員自行診斷。
- **[高] `free_image()` 現在在 `is_device_in_use()` 擋住刪除時提供
  詳細的使用狀態資訊。** `Multipath.pm` 新增的
  `get_device_usage_details()` helper 會列舉 holder 裝置名稱、
  dm-name，從 dm-name 慣例偵測 LVM VG 名稱，並說明根本原因
  （升級版 PVE 節點上的主機 LVM 自動啟用） 以及精確的修復方式：
  `vgchange -an <vg>` 立即停用，`lvm.conf` 中設定 `global_filter`
  做長期修正。

---

## [1.1.5] - 2026-04-10

### 重大 — `rescan_scsi_hosts()` 可能在 HPE / Dell / Lenovo HBA 上掛起

自 1.0.0 起就存在的潛在 bug，在第一位客戶把外掛部署到 HPE ProLiant、
Dell PERC、Lenovo ThinkSystem 或任何同時有 SAS HBA / 硬體 RAID 控制器
與 iSCSI 卡的伺服器上就會浮現。**所有更早版本都受影響。強烈建議升級。**

#### 修正
- **[重大] `rescan_scsi_hosts()` 過去會迭代 `/sys/class/scsi_host/`
  下的每一個項目，包含非 iSCSI 的 host。** 對 HPE Smart Array 控制器
  (smartpqi 驅動）、Dell PERC (megaraid_sas) 或 LSI HBA (mpt3sas) 的
  scan 檔案寫入 `"- - -"`，會觸發驅動端的完整 target 重新掃描，在
  kernel 中**進入 D-state 達 600+ 秒**。`sysfs_write_with_timeout()`
  保護父行程不被阻擋，但**處於 D-state 的子行程無法被 SIGKILL 收回**,
  而且它會持有 kernel scan lock 直到驅動完成，造成後續每個 VM 操作都
  發生連鎖的 config-lock timeout，再加上 `pvedaemon` 重新啟動會掛起
  必須強制重新開機。

  修法：把 host 清單來源從 `/sys/class/scsi_host/` 改為
  `/sys/class/iscsi_host/`。`scsi_transport_iscsi` 這一層會在任何
  iSCSI 驅動呼叫 `iscsi_host_alloc()` 時把該 host 註冊到這裡，不論
  底層是 `iscsi_tcp`、`iser`、`bnx2i`、`qla4xxx`、`qedi`、`be2iscsi`、
  `cxgb3i`、`cxgb4i`、或任何未來的 iSCSI 驅動。非 iSCSI 驅動絕對
  不會在這裡註冊，所以迭代這個 class 既完整又安全。

  在實機上驗證 （含 8 個 scsi_host:host0-3 非 iSCSI、host4-7 iSCSI):
  `strace` 確認修正後只會對 host4-7 寫入。修正前則會對全部 8 個寫入。

  **教訓：** Timeout 保護涵蓋的是父行程，不是 kernel。對於會持有
  kernel lock 的 sysfs 寫入，正確的修法是「一開始就不執行該操作」，
  而不是「對該操作做 timeout」。
- **[高] `FC.pm rescan_fc_hosts()` 使用 bare `open()`** 寫入
  `/sys/class/fc_host/<host>/issue_lip` 與
  `/sys/class/scsi_host/<host>/scan`。SCSI scan 迴圈本來就只對 FC
  host 過濾 （透過 `get_fc_hosts()` — 沒有 Bug 1 風險），但 bare
  `open()` 代表 HBA 卡死時父行程也會卡住。修法：把兩處寫入都改走
  `sysfs_write_with_timeout()`，與 `Multipath.pm` 中已有的保護一致。

#### 新增
- **`API.pm` 中的 `translate_pure_error()` helper**，把 Pure FlashArray
  原始 API 錯誤訊息轉成對操作員友善的訊息。1.1.5 之前，操作員碰到
  陣列卷數量上限會看到 `Maximum number of volumes is reached`，完全
  沒有任何指引。1.1.5 之後會看到一段說明：碰到哪個上限、為什麼
  「destroyed 但尚未 eradicate 的卷」會占用配額、以及如何恢復。
  比對 Pure 已知的上限錯誤訊息：per-array 卷數量、per-volume 快照
  數量、host 連線數量、protection group 數量、容量耗盡、API rate
  limit。未知的錯誤照原樣傳遞。

  套用在最常見的 die 點：`alloc_image()`、`clone_image()`、
  `volume_snapshot()`。

---

## [1.1.4] - 2026-04-09

### 1.1.3 後內部深度稽核又找到 6 個 bug

套用「同類模式」稽核原則 （每個 bug 修正都觸發全程式庫搜尋同一反模式）
到所有清理路徑、`/sys/block` 存取、以及 API 版本分歧點。**建議用 1.1.4 而非 1.1.3** —
API 1.x normalisation 問題對使用 Pure REST API 1.x 的用戶屬 HIGH 等級。

#### 修正
- **[HIGH] `volume_get_connections()` 沒有正規化 API 1.x 的回傳格式。**
  Pure REST 1.x 回傳
  `[{ host => "h1", lun => 1, name => "myvol" }, ...]`，其中
  `name` 欄位是**卷**名，不是 host 名。2.x 分支已經正規化為
  `{ name => "<host>" }`。所有 caller (`free_image`、
  `_disconnect_from_all_hosts`、`_backup_vm_config`、
  `_cleanup_orphaned_temp_clones`、`_cleanup_temp_snap_clone`、
  `alloc_image` orphan-cleanup) 都迭代 `$conn->{name}`，在 1.x
  上拿到的是**卷名**。後續的 `volume_disconnect_host($vol,
  $conn->{name})` 把卷名當作 host 引數傳入，在 eval 內 silent
  失敗。**結果：在 API 1.x 上每個 disconnect 呼叫都是 no-op,
  孤兒 host 連線永遠留著，而每個 `volume_delete` 清理都走 Bug E
  ghost-LUN 失敗模式。** 修法：在
  `volume_get_connections()` 的 API 1.x 分支正規化為相同的
  `[{ name => "<host>" }]` 形狀，並 fallback 至 `host_name` 與
  `name` 欄位。
- **[HIGH] `path()` 臨時 clone 的 connect 失敗有兩個 bug 串在一起**:
  (a) Bug E 模式 — `volume_delete($temp)` 沒先 disconnect,
  (b) `$@` 被覆寫 — 內部清理 eval 重設 `$@`，所以後續
  `die "...$@"` 顯示的是清理錯誤而非原本的 connect 錯誤。兩者
  都修：先 `$connect_err = $@` 保存，再呼叫
  `_disconnect_from_all_hosts`，然後 `volume_delete`，最後用
  保存的 error die。
- **[HIGH] `_backup_vm_config()` 的 connect 失敗有相同的 Bug E
  模式**:`volume_connect_host` 失敗 → `volume_delete` 沒 disconnect
  → 陣列上孤兒 host 連線。修法：在 connect-fail 分支與
  「Cannot get WWID」分支的 `volume_delete` 之前都呼叫
  `_disconnect_from_all_hosts`。
- **[MEDIUM] `clone_image()` 缺 disk-id collision retry** —
  與 1.1.0 前的 `alloc_image` 同一 TOCTOU 視窗。兩個並行
  `qm clone` 對同一來源 VM 可能都從 `_find_free_diskid` 拿到相同
  diskid，一個會以 "already exists" 失敗。修法：在
  `volume_clone` 呼叫外加 5 次重試迴圈。
- **[LOW] `rescan_scsi_device()` 用 `basename()` 而非
  `_resolve_block_device_name()`。** 目前所有 caller 都傳
  `/dev/sdX` 所以這個 bug 是潛在的，但作為 exported helper,
  未來呼叫者若傳 `/dev/mapper/<wwid>` 就會 silent 失敗。為了
  與 Multipath 模組其他函式一致，做防禦性修正。
- **[LOW] `_backup_vm_config()` 對 `mkfs.ext4` / `mount` / `umount`
  使用 bare `system()`。** 1MB 卷是剛分配的，正常情況下裝置是
  健康的，但若 multipath 卡死，`mount` 會進入 D state。將 4 處
  全部換成 `PVE::Tools::run_command(..., timeout => 30)`，並在
  `umount` 之前加上明確的 `sync`。

---

## [1.1.3] - 2026-04-09

### 主動同類模式稽核發現的 3 個 bug

1.1.2 修了 4 個 bug 之後，相關專案 jt-pve-storage-netapp 的維護者主動稽核了所有
出現相同 bug 模式的位置。又找出 3 個。Pure 外掛全部都中。**建議用
1.1.3 而非 1.1.2** — Bug E 即使不走 resize / rollback 路徑，單純透過
`clone_image` （或 `alloc_image`) 的失敗路徑也能造成節點掛起。

#### 修正
- **[HIGH] Bug E — `alloc_image()` 與 `clone_image()` 失敗清理路徑
  在呼叫 `volume_delete()` 前沒有先 disconnect 卷的所有 host 連線。**
  `_connect_to_all_hosts()` 在 per-node 模式下會迭代每一台叢集 host;
  若它在 host 1..K 成功、在 K+1 失敗，清理執行時卷仍然連著 K 個 host。
  Pure （與 ONTAP 不同） 會直接銷毀仍在連線中的卷，但**孤兒 host 連線
  紀錄**會讓其他叢集節點上的 iSCSI rescan 發現幽靈 LUN，進而變成
  殘留 multipath 裝置。配上 `defaults` 區塊中的 `no_path_retry queue`
  — 與 1.1.0 起源的正式環境掛起事故同一根本原因。修法：新增
  `_disconnect_from_all_hosts()` helper，查詢陣列當前的連線清單，
  逐一 disconnect,**在所有清理路徑的 `volume_delete` 之前**呼叫。
  共修正 4 個位置：`alloc_image()` 主要 connect-fail 清理、
  `alloc_image()` state/cloudinit 「Cannot get WWID」清理、
  `alloc_image()` state/cloudinit 「裝置未出現」清理、以及
  `clone_image()` connect-fail 清理。
- **[LOW] Bug F — `volume_snapshot()` 現在會在呼叫陣列的
  `snapshot_create` 之前先 flush 主機端 dirty buffer**，與
  `volume_snapshot_rollback()` 之前已有的行為對稱。對執行中的 VM,
  qemu 的 freeze 會在檔案系統層處理一致性；但對離線卷或外部 script
  呼叫者 （例如某些備份工具直接對停機 VM 的卷寫入）,dirty page cache
  可能不在快照裡，產生檔案系統不一致的快照。用 `is_device_in_use()`
  防護避免在繁忙的線上遷移時阻擋。

#### 移除
- **[LOW] Bug G + dead export 稽核 — 從 `Multipath.pm` 移除 4 個
  exported 但 0 個 caller 的函式：** `multipath_add`、
  `multipath_remove`、`get_multipath_wwid`、`get_scsi_devices_by_serial`。
  `get_multipath_wwid` 含有與 1.1.2 修正的 `is_device_in_use`
  相同類別的 `/dev/mapper` symlink 潛在 bug；與其修正死碼 （以及未來
  維護者可能看到它在 `@EXPORT_OK` 中而呼叫的風險），不如直接整個
  移除。其他三個也都沒有任何呼叫者。

---

## [1.1.2] - 2026-04-09

### 重大 — 從相關專案 jt-pve-storage-netapp 後續修正中移植的 4 個 bug

jt-pve-storage-netapp 在正式環境上一次 resize 事故揭露 4 個 bug,Pure 外掛**也都有**。
其中一個是沉默資料遺失等級。**所有 1.0.x / 1.1.0 / 1.1.1 的正式環境使用者
應立即升級。**

#### 修正
- **[CRITICAL — 資料遺失] `is_device_in_use()` 對 `/dev/mapper/<wwid>`
  路徑永遠回傳 0。** 它用 `basename($device)` 組成
  `/sys/block/<name>/holders` 路徑，但對 multipath 裝置而言會解析成
  `/sys/block/<wwid>/holders`，這個路徑**不存在** — holders 目錄位於
  `/sys/block/dm-N/` 之下。所以對任何 multipath 裝置都會回傳 "未在
  使用"，不管上面有沒有 LVM volume group、dm-crypt 容器、dm-raid 或
  其他 holder。然後 `free_image()` 就會繼續刪除卷 — 把客戶的 LVM
  資料一起帶走。**任何在 Pure 卷之上使用 LVM （或 dm-crypt / dm-raid /
  bcache / ...) 的正式環境都有風險。** 修正方式：新增
  `_resolve_block_device_name()` helper，在任何 `/sys/block/` 存取之前
  先把 `/dev/mapper/<wwid>` symlink 解析成底層的 `dm-N` 名稱。
- **[HIGH] `get_multipath_slaves()`** 有同樣的破損模式。對
  `/dev/mapper/<wwid>` 路徑永遠回傳空 list，代表 `free_image()` 的
  清理後 SCSI slave 移除步驟會沉默地跳過每個裝置，跨操作累積 SCSI
  殘留。
- **[HIGH] `volume_resize()`** 呼叫的是 `rescan_scsi_hosts()` (host
  scan，用於發現**新**裝置），而不是 per-device rescan （用於重讀
  **既有**裝置的屬性）。Pure 側 resize 後，陣列顯示新大小，但 multipath
  裝置仍回報舊大小，QEMU 的 `block_resize` 對執行中 VM 會失敗並回報
  `Cannot grow device files`。修正方式：對每個 slave 做
  `echo 1 > /sys/block/sdX/device/rescan`，然後呼叫
  `multipathd resize map <name>` （新 helper) 重新整理 device-mapper
  那一層的大小。
- **[HIGH] `volume_snapshot_rollback()`** 有與 resize 相同的錯誤
  rescan，加上第二個問題：即使底層 SCSI 路徑已更新，kernel 緩衝快取
  仍可能持有 rollback 之前的內容頁面。從 rolled-back 卷的後續讀取
  可能會回傳過期資料。修正方式：(1) 每個 slave rescan、
  (2) `multipath_resize_map`、（3) `blockdev --flushbufs <device>`
  讓 kernel 緩衝快取失效。

#### 新增
- `Multipath.pm` 新增 `_resolve_block_device_name()` helper。在對可能是
  `/dev/mapper/<wwid>` 的路徑做任何 `/sys/block/<name>/` 存取之前，
  都應先呼叫此函式。可處理 `/dev/sdX`、`/dev/dm-N` 與
  `/dev/mapper/<name>` （解析 symlink）。
- `Multipath.pm` 新增 `multipath_resize_map()` helper，已 export。

---

## [1.1.1] - 2026-04-09

### Multipath / 防掛起後續修正

對 v1.1.0 與 PVE 儲存外掛開發指南交叉檢查時發現。**建議用 1.1.1 而非
1.1.0** — 1.1.0 雖有叢集清理架構，但 multipath device 區塊仍然缺
`no_path_retry`，代表在 `defaults` 區塊有 `no_path_retry queue` 的主機
上，殘留裝置仍會掛起。本版本補上這個漏洞。

#### 修正
- **Pure multipath device 區塊現在明確設定 `no_path_retry 30` 與
  `fast_io_fail_tmo 5`。** 過去缺這兩項時，per-device 區塊會繼承
  `defaults` 區塊的值，而很多現場 （受歷史 NetApp HA 建議影響） 是 `queue`。
  配上殘留 Pure 裝置，會讓 `sync` / `blockdev` / `multipath -f` 進入
  uninterruptible sleep — 正是 1.1.0 想阻擋的情境。
- **`_ensure_multipath_config` 現在會在產生的設定檔內寫入版本標記**
  (`# pure-multipath-config-version: 2`)，只有帶這個標記的
  plugin-managed 檔案會在版本變動時被外掛重寫。**沒有**標記的檔案
  （操作員手改或第三方產生） 一律不動。這代表從 1.0.x → 1.1.x 升級時
  能真正吃到新的安全設定，而不是繼續沉默地用舊檔。
  > **⚠️ 升級陷阱：** 若你既有的
  > `/etc/multipath/conf.d/pure-storage.conf` 是由更早版本 (1.0.x)
  > 建立的，它**沒有**標記行，所以 1.1.x 會保留不動。你必須手動把它
  > 對齊新版 device 區塊 （見 README「升級 SOP」上方的警告框）,
  > 或是 `rm` 掉該檔讓外掛重新建立。否則新的 `no_path_retry 30` /
  > `fast_io_fail_tmo 5` 安全設定不會生效。
- 將 `is_device_in_use` 中的 bare `system('fuser', ...)` 改為
  timeout-bounded `_run_cmd` (5s）。`fuser` 會開啟裝置路徑，在
  `queue_if_no_path` 的卡住 multipath 裝置上，自身就會 D-state 永不返回。
- 將 `volume_resize` 中的 bare `system('sync')` 與 `system('blockdev', ...)`
  改為 `PVE::Tools::run_command(..., timeout => 10)`。
- 新增 `_udev_refresh()` helper，透過 `PVE::Tools::run_command` 執行
  `udevadm trigger` 與 `udevadm settle`,timeout 10s。將 plugin 與
  Multipath 模組裡所有 13 處 bare `system('udevadm ...')` 統一改為呼叫
  此 helper。

---

## [1.1.0] - 2026-04-09

### 重大可靠性釋出 — 從相關專案 jt-pve-storage-netapp (v0.2.x) 移植正式環境驗證過的修正

由真實正式環境事故驗證：殘留 multipath 裝置加上 `queue_if_no_path`，造成
PVE daemon 進入不可中斷睡眠，只能重新啟動節點復原。

#### 防掛起 (Section 1)
- 在 `Multipath.pm` 新增 `sysfs_write_with_timeout` /
  `sysfs_read_with_timeout` helper。所有對
  `/sys/class/scsi_host/*/scan`、`/sys/class/block/*/device/{delete,rescan}`
  的直接寫入，以及對 `/proc/mounts` 與 `/sys/.../wwid` 的讀取，
  全部改走 fork-bounded 子行程，即使底層 HBA 卡死也不會把父行程
  拖進 D state。
- 將清理路徑中的 bare `system('sync')` / `system('blockdev')` 改為
  timeout-bounded `_run_cmd` 呼叫。
- `cleanup_lun_devices` 在嘗試 `sync` / `blockdev` / `multipath -f` 之前，
  會先呼叫 `multipathd disablequeueing` 與
  `dmsetup message ... fail_if_no_path`。否則 queueing 會讓這些操作在
  死掉的裝置上永遠卡住。
- `multipath_flush` 不再允許在沒有 device 引數的情況下被呼叫
  （過去會 fall through 到 `multipath -F`，該指令會 flush 主機上**所有**
  未使用的 map，可能切斷客戶手動管理的非 Pure 儲存）。
- `multipath_flush` 內建 `dmsetup --force` fallback，當
  `multipath -f <wwid>` 失敗或 timeout 時自動使用。

#### 叢集安全 (Section 2)
- 在 `ISCSI.pm` 新增 `is_portal_logged_in()`，並在 `login_target` 與
  `activate_storage` 中使用。Pure 控制器在多個 LIF 之間共用一個 IQN;
  只用 target 名稱檢查會在第一個 portal 登入後沉默地跳過所有後續 portal,
  讓主機只剩 1 條路徑而非 N 條。
- `login_target` 現在會設定 `node.session.timeo.replacement_timeout` 為
  120，讓暫時性中斷以及 Pure 控制器 failover 在無論 `iscsid.conf` 怎麼
  設定的情況下都能順利恢復。
- `activate_storage` 對已連線的 portal 跳過 `iscsiadm discovery+login`
  （每次 status 輪詢可省下最多 30 秒的 discovery latency）。

#### `free_image` 操作順序 (Section 3)
- **在 unmap 前**先擷取 multipath slave 裝置清單 (unmap 後
  `/sys/block/.../slaves` 目錄會消失）。
- 先 disconnect 所有 host，再清理本地裝置，最後在陣列上刪卷。舊順序會
  讓另一節點正在執行的 iSCSI rescan 重新匯入該 LUN，在我們背後重建
  multipath 裝置。
- `cleanup_lun_devices` 之後，使用擷取的清單再移除殘留的 SCSI slave 裝置，
  並 reload `multipathd` 確保狀態收斂。

#### API 韌性 (Section 4)
- 預設 UA timeout 從 30s 降到 15s,retry 從 3 降到 2 (worst case
  從 ~102s 降到 ~34s）。
- `_request` 接受 per-call `timeout` 選項，單次覆寫 UA timeout，並在
  所有出口路徑還原。
- `volume_delete` 使用 60s per-call timeout，因為當 volume 有許多
  snapshot 時 Pure 銷毀可能很慢。
- 401 retry 在 `_create_session` 重建 LWP::UserAgent 後會重新套用任何
  per-call timeout 覆寫。
- `status()` 現在在 API 錯誤時 fail-fast （回 inactive zeros)，而不是
  讓輪詢執行緒卡住。
- `status()` 現在用 double-fork grandchild 跑 orphan / temp-clone 清理，
  grandchild 被 reparent 到 init，清理永遠不會擋住 storage daemon。

#### 叢集殘留 / orphan 清理 (Section 5)
- 新增 WWID 追蹤架構：per-storage 狀態檔位於
  `/var/lib/pve-storage-purestorage/<storeid>-wwids.json`，鎖檔位於
  `/var/run/pve-storage-purestorage/<storeid>-wwids.lock`。鎖採用
  non-blocking `flock` 配上有上限的重試 (10s deadline)，避免在卡死的
  worker 上永遠等待。
- `path()` 在成功解析出真實裝置後追蹤 WWID。
- `free_image` 只在確認本地 multipath 裝置已消失後才取消追蹤 WWID —
  若清理留下殘留裝置，WWID 維持追蹤狀態，讓下一輪 orphan 清理可以重試。
- `_cleanup_orphaned_devices` 三階段執行：
  1. **自動匯入**：從陣列拿到所有 Pure 管理的 LUN WWID，加入本地追蹤
     (讓所有叢集節點對 alive set 的認知收斂一致)。
  2. **清理**：對每個追蹤中但不在陣列上的 WWID，若本地有殘留 multipath
     裝置就清掉。
  3. **警告**：列出本地有但不在追蹤中也不在陣列上的 Pure multipath 裝置
     (**不**自動清 — 可能是客戶手動管理)。

#### postinst (Section 6)
- 印出「CRITICAL Multipath Safety Rules」橫幅，說明 `multipath -F` 與
  `multipath -f` 的差別、restart 與 reload 的差別，以及建議的
  Pure-friendly multipath.conf 設定。
- 偵測 `/etc/multipath.conf` 中的危險設定 (`no_path_retry queue`、
  `queue_if_no_path`、`dev_loss_tmo infinity`) 並警告，**不**自動修改
  客戶 config。
- 升級時偵測既有的殘留 Pure multipath 裝置，並列出精確的手動清理指令。
- 預先以 mode 0700 建立 `/var/lib/pve-storage-purestorage` 與
  `/var/run/pve-storage-purestorage`。

#### 程式品質 (Section 7)
- `alloc_image` 在磁碟 ID 衝突時重試 (`_find_free_diskid` 與
  `volume_create` 之間的 TOCTOU，兩個 worker 賽跑）。
- `path()` 改用受 `pure-device-timeout` （預設 30s) 限制的重試迴圈，
  而非單次 rescan。
- `list_images` 範本偵測 fallback 加上 10s wall-clock deadline,
  避免慢陣列把 timeout 連環擴散到上百個 volume。

#### 文件 (Section 8)
- README.md 與 README_zh-TW.md 在開頭附近加入醒目的
  **CRITICAL: Multipath Safety Rules** 與 **Upgrade SOP** 段落。
- 新增 `docs/TESTING.md` 與 `docs/TESTING_zh-TW.md`:Pure-Storage-specific
  測試計畫，涵蓋基本連線、VM 生命週期、熱插拔、快照/clone、叢集 orphan
  清理、混合環境安全、失敗注入 （控制器 failover、阻擋 LIF、阻擋 API、
  `queue_if_no_path` + 殘留裝置掛起）、API 1.x 與 2.x 雙覆蓋、命名邊界、
  pod (ActiveCluster) 模式、per-node 與 shared host 模式、效能/sanity、
  以及升級路徑。

---

## [1.0.49] - 2026-02-27

### 第二輪可靠性與正確性稽核修正

- 修正 `volume_snapshot_list` 對 `pve-snap-` 前綴的雙重編碼，造成
  `snapshot_delete` 在重複編碼後的名稱上失敗。
- 修正 `list_images` 將帶 pod 前綴的名稱傳給 `pure_to_pve_volname`,
  造成 pod 環境中 cloudinit / state volume 的解碼失敗。
- 修正 `parse_volname` 在錯誤時返回 undef 而非 die （違反 PVE 儲存
  外掛 API 合約，造成沉默失敗）。
- 修正 `pve-pure-config-get` LXC 偵測的運算子優先權，過去會把帶
  `arch:` 行的 QEMU VM 誤判為 LXC 容器。
- 修正 `pve-pure-config-get` 的 `umount` 呼叫改用 list-form `system()`
  避免 shell injection。
- 修正 `_backup_vm_config` 在錯誤路徑上漏掉 `cleanup_lun_devices`,
  造成備份失敗後留下殘留 SCSI 裝置。
- 修正 API cache 的 fork 安全性，加入 PID 檢查避免在 fork 出來的
  PVE daemon worker 中使用過期的 session token。
- 修正 `deactivate_storage` 在 disconnect 之前先檢查 `is_device_in_use`,
  避免清除其他 VM 仍在使用的 volume。
- 修正 `alloc_image` 的 orphan 清理漏掉 `skip_eradicate`，過去在配置
  重試時可能永久清除 volume。
- 將臨時的 `multipathd reconfigure` shell 呼叫統一改為使用
  `multipath_reload()`。
- 修正 `Multipath.pm` 中的 `SG_INVERT` 拼錯為 `SG_INQ`。
- 修正 `encode_config_volume_name` 的長度檢查，當總長超過 63 字元時
  截斷 `snapname`。
- 將 `IO::Select` import 移到 `ISCSI.pm` 與 `Multipath.pm` 的檔案層級。
- 修正 `pve-pure-config-get` restore 模式的 config 寫入錯誤清理
  (`umount` 與 `disconnect` 現在一定會執行）。
- 移除 `pve-pure-config-get` restore 模式中的死碼。

## [1.0.48] - 2026-02-12

### 安全性與可靠性稽核修正 （跨所有模組）

- 修正 `path()` 在 API 失敗時返回 `/dev/null` 或合成路徑，改為正確 die
  以避免沉默資料損毀 (CRITICAL）。
- 修正 `get_multipath_device` 使用子字串 WWID 比對可能傳回錯裝置，
  改為精確比對 (HIGH）。
- 修正 `get_device_by_wwid` 的 glob pattern 改用精確後綴比對，避免
  裝置碰撞 (HIGH）。
- 修正 ISCSI 的 `_find_multipath_device` 與 `wait_for_device` 改用
  精確序號後綴比對 (HIGH）。
- 修正 `_cleanup_orphaned_temp_clones` 對 API 2.x ISO 8601 時間戳的
  解析 （過去比較字串對 epoch，永遠不會清理）。
- 修正 `clone_image` 磁碟 ID 配置的競態，改用 `_find_free_diskid` 而非
  手動 `max+1` 邏輯。
- 修正 `_find_free_diskid` 在 `decode_volume_name` 之前先剝除 pod 前綴。
- 修正 `pve-pure-config-get` restore 模式的布林邏輯錯誤，過去在 restore
  模式總是 die。
- 修正 `pve-pure-config-get` 的 `san_storage` 改用 `sanitize_for_pure`。
- 修正 `is_device_in_use` 的 `fuser` 呼叫與 `_backup_vm_config` 的
  `system` 呼叫的 shell injection （改用 list 形式）。
- 修正 `_backup_vm_config` 錯誤路徑的 mount 清理。
- 在 `cleanup_lun_devices` 加入 in-use 守衛，避免清掉仍掛載或被持有的
  裝置。
- 修正 `ISCSI.pm` 與 `Multipath.pm` 的 `_run_cmd` 使用 `IO::Select`
  同時讀取 stdout / stderr （避免 deadlock）。
- 修正 `_run_cmd` timeout 時 kill 子行程 （避免 orphan）。

---

## [1.0.0] – [1.0.47]

更早的開發歷史。完整 per-release 詳細請參考 `debian/changelog`。重點：

- **1.0.0** — 初始版本，基本 iSCSI Pure Storage 支援。
- **1.0.x** — 漸進式新增：FC 支援、API 1.x 與 2.x 雙 client、snapshot /
  clone / template / linked-clone、cloudinit 與 state 與 TPM volume、
  LXC 支援、ActiveCluster pod 支援、VM config 備份卷、
  `pve-pure-config-get` CLI、multipath helper 模組、命名模組、
  host get-or-create with race handling、`list_images` 批次 snapshot
  query。

任何 1.0.48 之前的版本應視為已被取代 — 正式環境請安裝 1.1.1 或更新版本。

---

## 作者

Jason Cheng (Jason Tools) — jason@jason.tools — MIT 授權
