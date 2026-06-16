# 變更紀錄

NetApp ONTAP Storage Plugin for Proxmox VE 的所有重要變更都記錄在此。

## [0.2.19] - 2026-06-16

### pvestatd 隔離 + 殘留路徑 reaper + 連線重用 Release

三個各自獨立的韌性修正,分別由客戶的 ONTAP 升級事故與先前的 LUN-ID 重用事故浮現。

**修正 1 — 殘留 SCSI 路徑 reaper（在未執行拆除的節點上發生 LUN-ID 重用）:**

某節點無法為一顆活著的 LUN 建立 multipath map:`device-mapper: error getting device (-EBUSY)`,且 `multipath -ll` 看不到任何東西,其他節點卻一切正常。per-node igroup 模式會把每顆 LUN map 給**所有**節點;從未對該 LUN 執行 `free_image()` 的節點會留下殘留 `sd` 路徑;ONTAP 把釋放的 SCSI LUN-ID 重用給新 LUN;殘留 `sd`（此時已讀不出 WWID）遮蔽了被重用的 LUN-ID,device-mapper 便無法載入新 map。v0.2.18 的拆除掃除以 WWID 比對,因此抓不到這些殘留——它們已不再廣告任何可比對的 WWID。

- **修正:** 新增 `Multipath::list_netapp_scsi_paths()`（裸 `sd` 拓樸列舉）+ `_reap_stale_scsi_paths()`,作為 `_cleanup_orphaned_devices()` 的第三個 pass。只有在以下條件全部成立時才會移除一條 `sd`:廠商為 NETAPP、沒有任何 holder 且未掛載,且符合其一——(Case A) 它是本儲存追蹤過、ONTAP 上已刪除 LUN 的孤兒;或 (Case B) 同一個 iSCSI target IQN + 同一個 LUN-ID 上有另一條 sibling `sd` 讀到活著（ONTAP alive-set）的 WWID,而這一條不同或空白（LUN-ID 被重用）。300s 寬限期;任何不確定一律放著不動。reap 後以 rescan + multipath reload 自我修復。

**修正 2 — pvestatd 逾時隔離（退化的 ONTAP 不再卡住 PVE 或同節點其他儲存）:**

ONTAP 升級期間,某控制器的管理 REST 發生 read timeout。`activate_storage`／`status` 把數個 15s × 2 retry 的呼叫疊成 `status update time (189s)`,而 pvestatd 依序處理所有儲存的迴圈把同節點的另一個 netappontap 儲存一起拖成 `inactive`。

- **修正:** 新增 `ontap-status-timeout` 選項（預設 5s）。pvestatd 健康路徑（`activate_storage`／`status` 前景）改用短逾時、單次嘗試的 API client——下一輪約 10s 的輪詢就是重試。資料路徑（alloc／free／clone）維持原本的韌性 client。實測快速失敗:**5.0s vs 32.0s**。

**修正 3 — HTTP keep-alive（不打爆 ONTAP 的管理閘道）:**

請求風暴（無連線重用 + 每請求 basic auth,再乘上叢集節點數與重試）把 ONTAP 的管理閘道打進持續 read timeout——現場實證:**被打時 15s／請求,一停止輪詢即 0.5s**。`LWP::UserAgent` 改用 `keep_alive => 1`,REST 呼叫重用同一條 TCP+TLS 連線,而非每次新握手 + 重新認證。

**測試:**

- `docs/TESTING.md` 與 zh-TW 版新增 Section 28。
- 模擬器功能測試（真實 ONTAP + 真實主機裝置）:**13/13**——完整 alloc／activate／free lifecycle 含主機端裝置斷言、殘留 `sd` reaper 對健康 live 裝置零誤刪、退化快速失敗 5.0s vs 32.0s。單元測試:reaper 決策邏輯 20/20、status-path client 13/13。ONTAP 與主機端均驗證 0 殘留。

## [0.2.18] - 2026-05-29

### 清理時殘留 SCSI 路徑掃除 Release

**強化（v0.2.17 事故 log 中浮現的獨立議題）:**

kernel 印出 `LUN assignments on this target have changed. The Linux SCSI layer does not automatically remap LUN assignments.`。ONTAP 在 `lun_map` 時自動配 SCSI LUN-ID,unmap 後會把釋放的 LUN-ID 重用給不同的 LUN。若 host 上仍有殘留 `sd` 裝置綁在該 `H:C:T:L`,新 LUN 在該路徑上便無法使用,kernel 也拒絕自動 remap。

- **根本缺口:** `cleanup_lun_devices()` 只移除目前還在 multipath map 內的路徑,且 map 已不在時整段完全 no-op——把孤兒單一 `sd` 路徑留在原地,日後與重用的 LUN-ID 撞號。

- **修正:** 新增 `Multipath::get_scsi_paths_for_wwid()`,列舉該 WWID 的**所有** NETAPP `sd` 路徑（含已脫離 map 的路徑,以裝置的 SCSI `wwid`／VPD 識別碼比對）;`cleanup_lun_devices()` 新增 Step 8 掃除,即使 map 已不在也會移除它們。掃除限定 NETAPP 廠商（絕不碰其他儲存）、以 WWID 比對（無誤判）,並以 wall-clock 預算（預設 30s）界定上限,讓擁有數百個 `sd` 裝置且路徑正在失效的 host 不會卡住拆除（v0.2.12 教訓:per-read timeout 不會界定累積時間）。

**測試:**

- `docs/TESTING.md` 與 zh-TW 版新增 Section 27（helper 比對、Step 8 孤兒掃除、靜態守則）。
- 模擬器（pc-pve1）已驗證:`get_scsi_paths_for_wwid()` 比對到真實裝置路徑、對 bogus WWID 回傳空;Step 8 掃除被 `multipath -f` 變孤兒的 `sd` 路徑（舊版這情況 no-op）;`budget => 0` 安全退出並警告。

## [0.2.17] - 2026-05-29

### 孤兒清理路徑健康閘門 + LUN 清單分頁 Release

**Bug 修正(正式環境事故,客戶回報 2026-05,節點 pve15):**

在**執行中**的 VM 熱加一顆硬碟,可能讓這顆全新硬碟立刻出現 I/O error（`I/O error, dev dm-NN`）。把 VM 關機再開機就「恢復」。

- **根因(兩個缺陷):**
  1. `_cleanup_orphaned_devices()` 以單一 `lun_list()` 快照建立「存活集合」,並清除任何不在集合內的已追蹤 WWID。但剛建立的 LUN 可能有一段時間查不到（ONTAP read-after-write／傳播延遲——與 v0.2.9 ASA 最終一致性同類,如今餵給了 reaper 的存活集合）。LUN 數量龐大時該查詢還可能被截斷。
  2. reaper 呼叫 `cleanup_lun_devices()` 前**完全不檢查 multipath 路徑健康狀態**,因此有 active 路徑的活裝置與真正的殘留無法區分。由於 VM 在執行中,QEMU 開著該裝置:`multipath -f` 失敗,退回的 `dmsetup remove --force` 把 map 從 QEMU 底下強制抽掉,於是產生 I/O error。（注意:QEMU 的開啟檔案描述子不是 sysfs holder,所以 `is_device_in_use()` 偵測不到它——路徑健康閘門才是真正的防線。）

- **修正 1 —— 路徑健康閘門(`Multipath::multipath_path_health()`):** reaper 絕不移除仍有 active 路徑（或狀態無法判定）的裝置。真正的殘留所有路徑都會 failed／faulty。同時套用於第一輪拆除與第二輪「untracked stale」操作者警告,因此 plugin 也不會再對健康裝置建議 `multipath -f`。

- **修正 2 —— 寬限期:** 在過去 300 秒內才被追蹤的 WWID 不拆,涵蓋 read-after-write 窗口。沿用既有的首次追蹤時間戳,不新增任何狀態檔。

- **修正 3 —— LUN 清單分頁(`API::_get_all_records()`):** `lun_list()` 現在會追隨 ONTAP REST 的 `_links.next`,讓超過 1000 顆 LUN 的 SVM 不會被靜默截斷存活集合。同樣的分頁套用於 `volume_list`、`volume_get_clone_children`、`igroup_list`、`snapshot_list`。

**測試:**

- `docs/TESTING.md` 與 zh-TW 版新增 Section 26:路徑健康邏輯（7 案）、分頁完整性、靜態 regression 守則、執行中 VM 功能性重現（含強制 host-side 裝置斷言,v0.2.14 守則）、寬限期守則。
- 模擬器完整測試 PASS:兩道 reaper 防線皆驗證、真正的殘留（ONTAP 上 LUN 已刪、路徑全失效）仍會被清除且 host-side 乾淨拆除、5 個分頁函式對真實 ONTAP 正常回傳、完整硬碟生命週期（alloc／snapshot／rollback／resize／full clone／free）乾淨且零 I/O error。

## [0.2.16] - 2026-05-24

### Temp Clone 背景清理 Idempotency 修正 Release

**Bug 修正(操作雜訊,v0.2.15 測試期間發現):**

- **`_remove_temp_clone()` 現在會在進入時偵測「ONTAP 上 volume 已不存在」並直接回成功**,而不會在後續 `volume_clone_split` 階段 die。先前的行為:tracking 內若有殘留 entry 而對應 ONTAP volume 已被 out-of-band 刪掉(被中斷的清理、跨節點 race、人工管理動作等),TTL 背景 reaper(`_cleanup_temp_clones`)會每 10 秒一次 `status()` poll 重試到天荒地老,journal 持續吐:
  ```
  Cleaning up old temporary FlexClone: tmpclone_<name>
  Failed to cleanup temp clone '...': volume_clone_split on temp clone '...' failed:
    Volume '...' not found at .../NetAppONTAPPlugin.pm line N.
  ```
  且不會自我修復 — 呼叫端的 `eval` 雖然攔住 die,但**不會**刪掉 state file 內的 entry(因為「清理」其實沒成功),所以下次 poll 又重試,結果一樣。v0.2.16 修正後,helper 在**第一次** poll 就直接回成功,呼叫端順利把殘留 entry 從 tracking 移除,下一個 cycle 起就完全安靜。

**正式環境下這種情境怎麼發生:**

- 上次清理中斷:`volume_delete` 在 ONTAP 上成功,但 state file 的 untrack 寫入沒發生(當機、重開機卡在半路等)
- 跨節點 race:另一個叢集節點在我們讀 state 與動作之間把 temp clone 砍了
- ONTAP 管理員手動清:有人在 ONTAP 上 out-of-band 砍掉 temp FlexClone
- 重開機後狀態錯位:tmpfs `/var/run` 沒清,但 ONTAP 側的清理早就完成

**安全性:**

- 區分「確認 not found」(`volume_get` 回 undef 且不 die)與「API transient 失敗」(`volume_get` die)。只有前者觸發 skip 路徑;後者照樣 die 傳遞,讓下次 cycle 重試,不會悄悄漏掉真實的 clone。
- 最壞情境(理論上不會發生但仍納入考量):若 `volume_get` 在 volume 實際存在時錯誤地回 undef,我們會略過清理並 untrack — 留下 ONTAP 端孤兒。但:temp clone 是 FlexClone,實際 unique block 極少;且 `_cleanup_orphaned_devices` 仍會偵測到 host 上殘留的 multipath device。`volume_get` 的契約清楚(undef = SVM 內無 records),不太會出這種 corner case。

## [0.2.15] - 2026-05-24

### 跨儲存孤兒偵測修正 Release

**Bug 修正(正式環境事件,2026-05-21~23 客戶回報):**

- **`_cleanup_orphaned_devices()` 不再把姊妹 netappontap storage 的 WWID 誤判為孤兒。** 客戶現場每個 cluster 節點的 pvestatd journal 都出現重複的 cluster-wide 警告:
  ```
  Orphan cleanup: detected N untracked NETAPP multipath device(s) that may be stale.
  Plugin will NOT auto-clean these (risk of touching manually-managed storage).
  If you confirm they are NOT in use, clean manually:
    multipathd disablequeueing map <wwid>
    dmsetup message <wwid> 0 fail_if_no_path
    multipath -f <wwid>
  (This warning repeats at most once per hour per device.)
  ```
  但跑完整 plugin/ONTAP audit 證實:警告列出的 WWID **全部都是健康的、被 plugin 正常管理的 LUN**,只是它們屬於客戶**另一個** netappontap storage(客戶同節點同時掛了 `netappASA` + `netappFAS_Node2`)。如果操作員照警告手動清,會直接拆掉姊妹 storage 上跑著的 VM 磁碟。
- 根本原因:`list_netapp_multipath_devices()` 回傳 host 上**所有** vendor=NETAPP 的設備,沒按 storage 過濾。`_cleanup_orphaned_devices()` 是 per-storage 跑的,second-pass 偵測在比對「host 全體 NETAPP 設備 vs 單一 storage 的 tracking + ONTAP alive 清單」,姊妹 storage 的 WWID 既不在 alive 也不在 tracking,就被誤判為孤兒。
- 修法:旗標前,先建一份「**其他任何** netappontap storage 所追蹤的 WWID 聯集」(透過 `PVE::Storage::config()` 找出其他 netappontap storeid,讀它們的 tracking JSON),命中聯集的 WWID 跳過 — 屬於姊妹 storage,由它自己的 cleanup 負責。

**會中招的情境**(這 bug 顯現的條件):

- 任一 PVE 節點掛了兩個以上 netappontap storage — **正式環境很常見**(客戶會分 ASA + FAS 做分層儲存)。
- 警告本身有「同 WWID 每節點每小時最多一次」的冷卻,但客戶兩邊加起來 100+ WWID,每小時叢集仍累積幾十條雜訊。

**未改動**(被 fix 保留的正確行為):

- 真正的孤兒偵測仍然有效:一個 WWID 若**不在任何** plugin storage 的 tracking 中,且所有 path 都失效,依然會被標示提示手動清。
- 每個 storage 的 cleanup 仍各自獨立跑 — 各 storage 仍由自己的 first-pass(tracked vs alive 比對)處理自己的孤兒。

## [0.2.14] - 2026-05-14

### Temp Clone Host 端清理修正 Release

**Bug 修正(v0.2.13 部署後一天客戶現場發現 regression):**

- **`volume_snapshot_delete()` 與 `_cleanup_temp_clones` 現在會完整拆掉 host 端 dm-multipath + sd* 殘留設備。** v0.2.13 的 fix 只處理 ONTAP 那邊(`volume_clone_split` + `volume_delete`),temp clone 的 LUN 從 ONTAP 上刪掉後,host 端 `/dev/mapper/<wwid>` 跟底下 4 個 `sd*` 路徑沒清。`multipathd` 之後每隔幾秒就 log 一次 `tur checker reports path is down`,沒完沒了。客戶在 v0.2.13 部署後 24 小時內就回報:對一個 CT 做 create + backup + remove 之後,4 條殘留 path 持續洗版 syslog。同樣的缺漏也存在於 1 小時 TTL 背景清理 `_cleanup_temp_clones`,只是時間延遲讓問題不那麼明顯。
- 新增共用 helper `_remove_temp_clone($api, $temp_clone_name)`,流程對齊 `free_image()` 的 7 步模式:抓 slave 清單 → unmap → `cleanup_lun_devices` → 移除殘留 sd* → `multipath_reload` → `volume_clone_split` → wait → `volume_delete`。兩個 call site(`volume_snapshot_delete` 和 `_cleanup_temp_clones`)都統一走這個 helper。

**測試強化(回應客戶意見「這種問題請加入測試清單」):**

- TESTING.md / TESTING_zh-TW.md 的 Section 24 加上明確的 HOST 端 device 殘留斷言:`volume_snapshot_delete` 跑完後 `get_device_by_wwid` 必須回 undef、sd* slave 不能存在於 `/sys/block`、`/dev/mapper/<wwid>` 必須不存在。這些斷言若在 v0.2.13 的 CI 跑過就會立刻 catch 到 regression;舊版測試只檢查 ONTAP 那層。長期 regression 守則。
- CLAUDE.md 新增 release SOP 規則:**任何測試只要涵蓋「在 ONTAP 上刪 LUN/卷」的路徑,都必須包含 host 端 device 殘留斷言**。只測 ONTAP 不夠 — 清理類 bug 一定要兩邊都驗。

**既存殘留處理建議:**

- v0.2.14 之前備份留下的 host 殘留**不會自動清**(plugin 設計:不主動清不在 tracking 內的 WWID,避免誤動到客戶自己的儲存)。`_cleanup_orphaned_devices` 會在 syslog 警告並列出清理指令。手動清:對每一個殘留 WWID 跑 `multipath -f <wwid>`,然後 `echo 1 > /sys/block/sdX/device/delete` 移除底下的 sd*。

## [0.2.13] - 2026-05-13

### Snapshot 刪除清理修正 Release

**Bug 修正(正式環境事件,2026-05-13 客戶回報):**

- **`volume_snapshot_delete()` 現在會在刪 snapshot 之前,先同步移除依附在該 snapshot 上的暫時 FlexClone。** 客戶的 `vzdump` CT snapshot-mode 備份備份本身成功,但是清理那一步失敗,訊息:
  ```
  snapshot 'vzdump' was not (fully) removed - ONTAP job failed:
    Snapshot copy "pve_snap_vzdump" of volume "..." in SVM "..."
    has not expired or is locked.
  ```
  根本原因:PVE 要讀 snapshot(vzdump CT 備份、`qm clone --snapname`、從 snapshot 做 `qemu-img convert` 等)時,`path($vol, $snap)` 會呼叫 `_get_snapshot_path()`,以該 snapshot 為 parent 建立暫時 FlexClone。只要這個 FlexClone 還在,ONTAP 就會把 parent snapshot 鎖住不准刪。Plugin 原本的清理機制是 1 小時 TTL 的背景任務(`_cleanup_temp_clones`),但 vzdump 在備份完當下立刻呼叫 `volume_snapshot_delete`,還在 TTL 內,所以每次都失敗。本次修正在 `volume_snapshot_delete` 開頭同步檢查 deterministic 的暫時 clone 名稱,若該 clone 的 LUN 仍在本機被佔用(透過 `is_device_in_use` 做 lsof 式 holder 檢查)則拒絕並回報具體裝置,否則做 unmap + 刪除暫時 FlexClone,再進行 snapshot 刪除。

**風險評估(正式環境安全審查):**

- 本機並行讀者:PVE 在 VM/CT 層有 lock,單一節點上不會有兩個並行讀者在同一個 snapshot 上,標準流程不會出現此情境。`is_device_in_use` 檢查為極端情境的安全網,真的撞到會 die 並回報具體裝置與 `lsof` 提示。
- 跨節點並行讀者:從刪除端無法直接觀察。Plugin 依賴「呼叫 `volume_snapshot_delete` 的節點 = 開啟 snapshot 的節點」這個慣例(vzdump 符合)。和既存 `_cleanup_temp_clones` 背景清理的 trade-off 相同。
- 清理過程 API 失敗:每一步都用 `eval` 包。若 `volume_delete` 暫時 clone 失敗,函式 die 並輸出明確訊息,**不再呼叫** `snapshot_delete`(本來也會用舊的 locked 錯誤失敗),讓操作者直接看到具體失敗點而非下游混亂訊息。
- 背景 TTL reaper 競爭:兩條清理路徑同時跑時其中一條會贏,另一條取得「volume not found」,由 `eval` 容忍。
- 未動到:`volume_snapshot_rollback`、`free_image`。ONTAP 對 clone 的行為在這兩個情境下不同(rollback 通常允許,free_image 自己會清 snapshot),需要另外 audit;本版範圍不含。

## [0.2.12] - 2026-05-05

### iSCSI Portal TCP 預先檢查 Release

**Bug 修正(來自姊妹專案 jt-pve-storage-purestorage v1.1.9 的同類型稽核):**

- **`activate_storage()` 現在會在呼叫 `iscsiadm` 之前,先用 TCP probe 確認每一個 iSCSI LIF 是否可達。** 舊行為直接把 `iscsi_get_portals()` 回傳的所有 portal 全部拿去 `iscsiadm -m discovery` 再 `iscsiadm -m node -l`,完全不檢查 TCP 連線是否通。在多 LIF SVM 配置(這正是 ONTAP HA 推薦做法)且主機端線路或 zoning 不對稱時,每個不通的 LIF 都會讓 `iscsiadm` 卡 30 秒(discovery)再加上最多 60 秒(login)。雖然外面包了 `eval` 不會 die,但累積的 timeout 還是會把整次 `activate_storage()` 拖到上百秒。`pvestatd` 每個輪詢都會走 `activate_storage`,所以這個卡頓會連鎖造成 web UI 凍結、其他儲存被排隊餓死。今天 Pure 那邊在客戶現場(4 LIF FlashArray、2 段網路只通到 1 段)修了 v1.1.9 把這個問題解掉,跨專案稽核確認 NetApp 這邊在 `NetAppONTAPPlugin.pm:502-526` 是一模一樣的程式樣式,本版同步修正。
- 這個修正對 NetApp 特別重要 — v0.2.11 的 `_check_lif_redundancy()` 會主動建議使用者「把 LIF 分散到兩個 controller」,而這正是受害面最大的配置。使用者越照建議做,asymmetric 線路下中招機率越高。

**API 新增:**

- `ISCSI.pm` 新增 `probe_portal($ip, $port, timeout => $t)`。內部用 `IO::Socket::INET` 配 `alarm()` 做帶上限的 TCP connect。可達回傳 1,不可達回傳 0。

**新組態選項:**

- `ontap-portal-probe-timeout`(整數 0..30,預設 2 秒)。設 0 可關閉預先檢查,回到 0.2.12 之前的行為。網路延遲較高或壅塞的儲存網路可調高。可用 `pvesm set <storeid> --ontap-portal-probe-timeout <n>` 修改。

**行為變更:**

- 當所有 LIF 都不可達時,`activate_storage()` 現在會 die,訊息會列出不可達的 portals、登入失敗的 portals(連同 `iscsiadm` 錯誤)以及如何用 `pvesm set <storeid> --nodes <list>` 把儲存綁到只在通的節點上。舊版只會說「Failed to connect to any iSCSI portal」。
- 當部分 LIF 不可達但至少有一個通時,會用一行 `warn` 列出被跳過的 portals 與排查提示,然後正常用可達的 LIF 子集繼續啟用儲存。

## [0.2.11] - 2026-04-30

### SAN LIF 冗餘偵測修正 Release

**Bug 修正（NetApp 原廠確認後）：**

- **LIF 冗餘檢查現在會偵測「所有 LIF 都在同一個 home_node」的狀況。** 先前 v0.2.10 只計算 LIF 總數，忽略一個常見的設定錯誤：2 個以上的 iSCSI LIF 都在同一個 controller 上。由於 SAN LIF 不會自動遷移，這種設定毫無 HA 冗餘可言 -- 單一 controller 故障會讓所有 LIF 同時離線。新版本檢查 LIF 是否分散在至少 2 個 home_node 上。
- **SAN LIF 行為文件修正。** 先前的說明錯誤地寫成「iSCSI LIF 會在 takeover 時遷移到 partner controller（30-90 秒）」。NetApp 原廠確認：只有 NAS LIF 會自動遷移，SAN（iSCSI/FC）LIF 不會。路徑切換靠 host 端 MPIO + ALUA 選擇活著的路徑。典型 takeover/giveback 切換時間在 10 秒以內。

**API 新增：**

- `API.pm` 新增 `iscsi_get_lifs_with_home_node()`，回傳 LIF metadata：address、home_node、current_node、state。`_check_lif_redundancy()` 用此進行正確的 HA 驗證。既有的 `iscsi_get_portals()` 不變（仍用於 iSCSI 登入流程）。

**文件修正：**

- `docs/CONFIGURATION.md` 與 zh-TW：重寫「ONTAP HA 配置最佳實踐 > takeover 時會發生什麼」段落，使用正確的 ALUA/MPIO 流程說明。
- `CLAUDE.md` 新增「ONTAP HA / SAN LIF Behavior」參考區段，避免未來文件再次寫錯。

## [0.2.10] - 2026-04-30

### 災難預防與監控 Release

**新增監控功能：**

- **儲存中斷偵測。** `status()` 現在會追蹤連續失敗次數（連續 3 次失敗 = 約 30 秒，pvestatd 每 10 秒 poll），達到門檻後發送 syslog ERROR 給監控系統。中斷期間每約 30 秒再次發送。儲存恢復連線時發送 INFO 恢復訊息。
- **Aggregate 容量健康檢查。** `status()` poll 時查詢 ONTAP aggregate 容量，>=90% 發送 syslog WARNING，>=95% 發送 ERROR（每個 storage 1 小時冷卻）。協助避免精簡配置 over-commit 失敗。
- **LIF 冗餘檢查。** 偵測 SVM iSCSI LIF 少於 2 個（ONTAP HA failover 無路徑冗餘）的情況，發送 syslog WARNING（24 小時冷卻）。
- **進行中操作偵測。** postinst 偵測執行中的 `qm move-disk`、`qm clone`、`qm migrate`、`qmrestore`、`vzdump`、`pvesm alloc/free` 程序，警告並給 5 秒緩衝才繼續 reload 服務。

**文件新增：**

- 「儲存斷線後的恢復程序」-- TROUBLESHOOTING.md 中的 6 步驟 SOP
- 「Proxmox VE 節點突然斷電後的恢復」-- 含 LUN reservation timeout 建議
- 「更新 ONTAP 密碼」-- 完整 SOP，包含必要的服務 reload
- 「ONTAP HA 配置最佳實踐」-- 建議的 LIF 配置、multipath 驗證、reservation timeout
- 「升級會影響執行中的 VM 嗎？」-- 說明外掛升級不影響 VM I/O 路徑
- 「監控與警示」-- syslog 事件對照表，用於監控系統整合
- 文件網站同步更新所有新章節

**Tag：** `pve-storage-netapp`（用 `journalctl -t pve-storage-netapp` 查詢外掛 syslog 訊息）

## [0.2.9] - 2026-04-25

### ASA 最終一致性修復 Release

**Bug 修復：**

- **修復 `lun_map()` 在 NetApp ASA 系統上回報 "LUN not found"。** `lun_create()` 透過 POST 成功建立 LUN 後，`lun_map()` 立即用 GET 查詢 LUN UUID。在 NetApp ASA (All-SAN Array) 系統於高負載下，LUN 可能因 ONTAP 內部傳播延遲 (最終一致性) 而尚未可見。`lun_map()` 現在會重試 UUID 查詢最多 5 次，每次間隔 1 秒，才回報失敗。修復了 move-disk、clone、alloc 操作時間歇性出現的「storage migration failed: Failed to map LUN」錯誤。修復位於 `API.pm lun_map()`，所有呼叫端自動受益：`alloc_image()`、`clone_image()`、`activate_volume()`、`_ensure_temp_clone()`。

## [0.2.8] - 2026-04-11

### 程式碼審查修復 Release

**Bug 修復 (來自自動化程式碼審查)：**

- **修復殘留清理無條件 untrack WWID。** `_cleanup_orphaned_devices()` 之前在 `cleanup_lun_devices()` 後不管裝置是否真的消失都 untrack。現在比照 `free_image()` 邏輯：只有 `get_multipath_device()` 確認裝置已消失才 untrack。避免 cleanup 部分失敗時 (例如 kpartx holders 擋住 multipath -f) 造成永久殘留裝置。

- **修復 `alloc_image()` TOCTOU race retry。** `volume_create()` 碰到 race 時原本只重試一次，現在改用有界 retry loop (最多 5 次)，跟 `clone_image()` 一致。多個並行的 `alloc_image()` 不再在第一次碰撞後就失敗。

- **移除所有 `multipath -F` (大寫 F) 建議**，包含程式碼和文件。`deactivate_storage()` 的 API 無法連線警告不再建議 `multipath -F`。文件 (CONFIGURATION.md、README.md、兩個 zh-TW 版) 也不再推薦。只建議 per-WWID 清理 (`multipath -f <wwid>`)。所有關於 `-F` 危險性的警告都保留。

- **修復 `ISCSI.pm get_device_by_serial()` 的 bare `glob()`。** `/dev/disk/by-id/` 的 glob 呼叫現在用 `alarm(5)` 包裹，符合 anti-hang 規則，跟 codebase 裡其他所有 glob 一致。

## [0.2.7] - 2026-04-11

### kpartx Partition Holder 修復 Release (CRITICAL)

**重大修復：**

- **修復 `is_device_in_use()` 在有 kpartx partition 掃描的系統上擋住所有 volume 刪除。** kernel 的 partition scanner 在 multipath LUN 上偵測到 VM disk 裡面的 partition table 時，會自動建立 partition dm devices (例如 `<wwid>-part1`)。這些被動的 artifact 之前被當成「真正的 holder」，導致每一個 `free_image()` 呼叫都被擋住。現在 `is_device_in_use()` 會檢查是否所有 holders 都是「沒有 sub-holders 的 bare kpartx partition」；如果是，就安全忽略。有 sub-holders 的 partition (例如PVE 主機 LVM VG 建在 partition 上) 仍然正確阻擋刪除。

- **在 `cleanup_lun_devices()` 新增 `kpartx -d` 清理步驟**，在 multipath flush 之前先移除 partition devices。

- **修復 `get_device_usage_details()` 把 partition dm-name** (例如 `3600a...d33-part1`) 誤判為 LVM VG 名稱。

## [0.2.6] - 2026-04-10

### Postinst 服務 Reload + Operator UX Release

**Operator UX -- 詳細的 `is_device_in_use` 錯誤訊息：**

- **`free_image()` 刪除被擋時現在會顯示完整診斷資訊。** 之前只顯示 `device is still in use (mounted, has holders, or open by process)`。現在會顯示：具體的 holder 裝置名稱與 dm-name (例如 `/dev/dm-10 (checktc--vg-root)`)、自動偵測的 LVM VG 名稱、根因說明 (PVE 主機 LVM auto-activation 客體 VG，常見於 PVE 7->8->9 升級且 `lvm.conf` `global_filter` 未設定)、具體修復指令 (`vgchange -an <vg>`)、以及長期解法 (`global_filter` 設定建議)。mount 和 fuser 檢查也會顯示掛載點或 process 詳情。

**殘留警告 Cooldown:**

- **殘留裝置偵測警告從每 10 秒降為每小時一次 (per device)。** `pvestatd` 每 10 秒 poll 一次 `status()`，每次都會跑殘留偵測，對所有 untracked NETAPP multipath 裝置產生警告。在有客戶手動管理 NetApp LUN 的環境下 (非 plugin 管理)，同一條警告每 10 秒重複一次，灌爆 journal。現在使用 per-WWID 的 cooldown flag 存在 `/var/run/pve-storage-netapp/` (tmpfs,reboot 後清除，重開機後會再次警告)。

**Postinst -- `lvm.conf` `global_filter` 偵測：**

- **Postinst 現在會檢查 `/etc/lvm/lvm.conf` 是否有 `global_filter` 設定。** 如果沒有，會顯示醒目警告，說明PVE 主機 LVM 會自動 activate VM disk 裡面的 VG (出現在 plugin 管理的 multipath LUN 上)，導致 `is_device_in_use()` 擋住 volume 刪除以及 `move-disk` 的來源清理。顯示建議的 `global_filter` 設定。這是 PVE 7->8->9 升級節點上最常見的 `Cannot delete volume: device is still in use` 錯誤根因。

**Postinst 修復：**

- **新增 `pvestatd` 到 postinst 的服務 reload 清單。** 之前版本只有 restart `pvedaemon` 和 `pveproxy`,**漏掉 `pvestatd`**，導致 pvestatd 在記憶體中繼續跑舊版 plugin code。pvestatd 每 10 秒 poll 一次 `status()`，用的是舊 code 裡未修復的 `rescan_scsi_hosts()`，繼續對非 iSCSI host 寫入，持續產生 D-state child。在客戶的 HPE ProLiant 上 (同 v0.2.5 事件那台),v0.2.5 安裝後 pvestatd 繼續用舊 code 產生 D-state → **永久性 D-state 累積** → 系統無回應 → iLO 硬體 watchdog 觸發強制重開機。現在 postinst 會 reload 全部三個 PVE 服務 (`pvedaemon`、`pvestatd`、`pveproxy`)。

- **postinst 從 `systemctl restart` 改為 `systemctl reload` (SIGHUP)。** PVE::Daemon 收到 SIGHUP 後會原地 re-exec，從 disk 載入新的 Perl module，不需要經過 stop 階段。這避免了 bootstrapping 問題：舊 code 已經產生了 D-state child (無法被 SIGKILL),`systemctl restart` 的 stop 階段會卡在等待這些不可殺的 child。改用 reload 後，完全不需要 stop — process 在原地替換自己，D-state orphan 被 init 接管。

- **如果安裝時服務沒在運行**,postinst 改用 `systemctl start` (reload 需要 active 的服務)。

**正式環境發現：** 客戶 HPE P408i-a 上的 smartpqi D-state child 持續 **4 小時以上**而沒有任何 timeout。kernel 的 `hung_task_timeout_secs` 在 120 秒後只會 log 警告，不會殺 D-state process。這些 child 實際上在 reboot 前是永久性的。任何在新 code 安裝後仍讓某個 PVE service 跑舊 code 的升級路徑，都會產生新的永久性 D-state child。`reload` 做法完全消除了這個空窗期。

## [0.2.5] - 2026-04-10

### 非 iSCSI SCSI host 掃描修復 Release (CRITICAL)

**重大 Bug 修復 (HPE ProLiant 正式環境事件):**

- **修復 `rescan_scsi_hosts()` 與 `rescan_fc_hosts()` 會對非 iSCSI / 非 FC host 寫入。** 兩個 function 原本都會迭代 `/sys/class/scsi_host/` 下的所有條目，然後對每個 `hostN/scan` 檔案寫入 `"- - -"`。這包含了非 iSCSI / 非 FC 的 host，例如硬體 RAID 控制器、USB 讀卡機、virtio-scsi 等等。對非 iSCSI host 的 scan 檔案寫入會觸發 driver 端的完整 target 重掃，在某些 driver 裡可能卡上數百秒。

  **正式環境觀察到的症狀** 發生在一台 HPE ProLiant 伺服器，使用 `smartpqi` driver (P408i-a 控制器): 寫入 `host1/scan` 進入 D-state 超過 10 分鐘，卡在 `sas_user_scan`，使**每一個**後續存取 `/sys/class/scsi_host/host1` 的 process 都必須排在它後面。連鎖效應：
  - pvedaemon worker 無法釋放 VM config lock，客戶看到 VM 操作反覆出現 `trying to acquire lock... got timeout`
  - pvestatd 無法完成 `status()` poll
  - `pvedaemon` 在 `dpkg --configure` 期間 restart 永遠卡住，plugin 升級變相失敗
  - VM 操作 (move-disk、resize、config update、開機順序調整) 即使 storage 路徑完全健康也會間歇性卡住

  v0.2.0 加的 `sysfs_write_with_timeout()` 保護讓 parent process 不會跟著卡 (10 秒 timeout)，但 child process 進入 D-state (uninterruptible sleep)，持續占著 kernel 對 host1 的 scan lock。`SIGKILL` 無法 reap D-state process，所以 lock 會一直持續直到 kernel driver 自己的 timeout 過期 (約 10 分鐘)，這時下一個 PVE 操作又已經排到後面，循環繼續。

- **修復方式：** `rescan_scsi_hosts()` 改從 `/sys/class/iscsi_host/` 取得 host 清單 (由 kernel 的 `scsi_transport_iscsi` 層維護)。所有 iSCSI SCSI host 都會註冊到這個 class，不論底層 driver 是什麼 (`iscsi_tcp`、`iser`、`bnx2i`、`qla4xxx`、`qedi`、`be2iscsi`、`cxgb3i`、`cxgb4i`，以及任何未來透過 `iscsi_host_alloc()` 註冊的 iSCSI driver)。非 iSCSI host 絕對不會出現在這個 class，所以迭代它既完整又安全。**未來相容**: kernel 新加的 iSCSI driver 會被自動涵蓋，plugin 不用改 code。

- **修復方式：** `FC.pm` 的 `rescan_fc_hosts()` 在 post-LIP 的 SCSI scan loop 有一樣的 bug。現在只迭代從 `/sys/class/fc_host/` 來的 FC host (透過 `get_fc_hosts()` 已經 enumerate 過)。

**架構層級的教訓：**
這個 bug 從 v0.1.0 就存在了。之前的版本只是保護 parent process 不會跟著 hang，並沒有真的阻止寫入到達 kernel。正確的解法是**根本不要對非 iSCSI host 寫入** — 那些 host 跟 plugin 管理的 iSCSI LUN 完全無關。

## [0.2.4] - 2026-04-09

### Cleanup 路徑強化 + 並行 + Operator UX Release

**並行修復：**

- **修復 `clone_image()` disk-id TOCTOU race (HIGH)。** 舊版程式碼先用 `volume_get` 預檢查找空 disk ID，然後在 loop 外面才呼叫 `volume_clone()`。對同一個 VM 兩個並行 `clone_image()` 呼叫(例如來自不同 cluster node 的同時 template clone，或任何繞過 PVE storage cfs lock 的路徑)會兩個都用同一個 disk ID 通過預檢查，然後在 `volume_clone` 上 race，輸的那個會 die "already exists"。現在 `volume_clone` 已移進 retry loop，遇到 "already exists" 錯誤會自動 retry 下一個 disk ID。跟 v0.2.1 `alloc_image` TOCTOU 修復一樣的 pattern，只是補上漏掉的 function。

- **修復暫時 FlexClone (snapshot 讀取存取) 在 `_ensure_temp_clone()` 的 TOCTOU race (MEDIUM)。** 暫時 clone 的命名是 volume+snap 確定性產生，所以兩個並行 `path()` 呼叫讀同一個 snapshot (例如同時 qmrestore + qm clone --full from snapshot) 會在 `volume_clone` 上 race。輸的那個之前會 die。現在把 "already exists" 當成功處理，因為暫時 clone 是共享且可重用的。

**Operator UX:**

- **新增 `_translate_limit_error()` helper，偵測常見 ONTAP 資源上限錯誤並加上 operator 友善訊息。** 涵蓋的 pattern:FlexVol 數量上限 (per-SVM 與 per-node)、SVM/cluster LUN 上限、igroup LUN-map 上限 (預設每 igroup 4096,per-node mode 較快達到)、aggregate 滿 (涵蓋 thin overcommit 情境)、SVM quota 超出。套用於所有 `alloc_image` 與 `clone_image` 的 die 點。Operator 現在會看到 `ONTAP FlexVol limit reached on this SVM/node. This plugin uses 1 FlexVol per VM disk; you may have hit the SVM volume cap (default ~12000) ...` 而不是原始 ONTAP REST API 錯誤代碼。

**正式環境程式碼稽核修復：**

- **修復 `clone_image()` cleanup 缺少 `lun_unmap_all()` (HIGH)。** 跟 v0.2.1 修掉的 `alloc_image()` 是同一個 bug pattern，但 `clone_image()` 漏修。當 `lun_map()` 中途失敗時(例如 per-node 模式下成功 map 到部分節點 igroup 後，在後面的節點失敗),cleanup 會直接對「仍處於 mapped 狀態」的 LUN 呼叫 `volume_delete`。ONTAP 會拒絕這個操作，結果是留下殘留的 igroup mapping 與其它 cluster node 看得到的 ghost LUN。這些 ghost LUN 接著就變成 stale multipath 裝置，任何 process 碰到都會卡住 -- 這就是 v0.2.3 客戶 node hang 的同一個根本原因。`clone_image()` 兩個 cleanup 分支(`unless ($lun)` 與 `lun_map` 失敗)現在都會先 `lun_unmap_all` 再 `volume_delete`。

- **`volume_snapshot()` 加上 snapshot 前的 host-side buffer flush (LOW)。** 對 running VM,qemu 自己的 freeze 會處理 filesystem 層的一致性。但對於關機 VM 的 snapshot 或外部腳本呼叫，page cache 中尚未落盤的資料不會被 flush，可能產生 filesystem 不一致的 snapshot。新增的 flush 邏輯與 `volume_snapshot_rollback()` 相同：先 `is_device_in_use` 檢查，然後 `sync` + `blockdev --flushbufs`(都帶 timeout)。如果裝置被別的 process 使用就完全跳過(live migration 安全)。

- **移除無用程式碼：`Multipath.pm` 的 `get_multipath_wwid()` (LOW)。** 這個 function 有 export 但全 codebase 沒有任何 caller。更糟的是它對 device 路徑直接用 `basename()` 而沒有 symlink resolution -- 任何未來 caller 如果傳 `/dev/mapper/<wwid>` 進來就會踩到跟 v0.2.3 `is_device_in_use` 資料遺失 bug 完全相同的陷阱。直接刪掉比留著當地雷安全。

**背景：**
v0.2.3 客戶事件後(qm resize 卡住 + 潛在的 `is_device_in_use` 資料遺失 bug)，我們對 plugin 做了完整的程式碼稽核，專門找兩種 bug pattern:(1) cleanup 路徑直接 `volume_delete` 而沒先 unmap LUN;(2) function 在存取 `/sys/block/` 之前對 device 路徑用 `basename()`。又找到 3 個問題，在這個 release 修掉。

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
