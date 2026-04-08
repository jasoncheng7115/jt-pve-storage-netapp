# 疑難排解指南 - NetApp ONTAP 儲存外掛

## 快速診斷指令

```bash
# 檢查儲存狀態
pvesm status

# 檢查 PVE daemon 日誌
journalctl -xeu pvedaemon --since "10 minutes ago"

# 檢查 iSCSI session
iscsiadm -m session

# 檢查多重路徑裝置
multipathd show maps

# 檢查 ONTAP API 連線
curl -k -u username:password https://ONTAP_IP/api/cluster
```

---

## 安裝問題

### 外掛未載入

**症狀：**
- `pvesm add --help` 未顯示 `netappontap`
- 錯誤：`unknown storage type 'netappontap'`

**診斷：**

```bash
# 確認外掛檔案存在
ls -la /usr/share/perl5/PVE/Storage/Custom/NetAppONTAPPlugin.pm

# 檢查語法錯誤
perl -I /usr/share/perl5 -c /usr/share/perl5/PVE/Storage/Custom/NetAppONTAPPlugin.pm

# 檢查外掛載入日誌
journalctl -xeu pvedaemon | grep -i "netapp\|plugin\|error"
```

**解決方式：**

1. **重新安裝外掛：**
   ```bash
   dpkg -i jt-pve-storage-netapp_*.deb
   systemctl restart pvedaemon pveproxy
   ```

2. **檢查相依套件：**
   ```bash
   apt install -f
   ```

3. **驗證 Perl 模組：**
   ```bash
   perl -MPVE::Storage -e 'print "OK\n"'
   ```

### API 版本警告

**症狀：**
- 警告：`Plugin ... is implementing an older storage API`

**解決方式：**
此為告知性警告，外掛仍可運作。若要消除警告，請升級至最新版外掛。

---

## 儲存設定問題

### 儲存未啟用

**症狀：**
- `pvesm status` 顯示儲存為 inactive
- 無法在儲存上建立 VM

**診斷：**

```bash
# 檢查儲存設定
pvesm config <storage-id>

# 測試 ONTAP API
curl -k -u <username>:<password> https://<portal>/api/cluster

# 檢查詳細錯誤
journalctl -xeu pvedaemon | grep -i "netapp\|ontap" | tail -20
```

**常見原因與解決方式：**

1. **認證錯誤：**
   ```bash
   # 測試認證
   curl -k -u pveadmin:password https://192.168.1.100/api/cluster

   # 更新密碼
   pvesm set <storage-id> --ontap-password 'NewPassword'
   ```

2. **網路連線問題：**
   ```bash
   # 測試連線
   ping <ontap-portal>
   nc -zv <ontap-portal> 443

   # 檢查防火牆
   iptables -L -n | grep 443
   ```

3. **SSL 憑證問題：**
   ```bash
   # 暫時關閉 SSL 驗證
   pvesm set <storage-id> --ontap-ssl-verify 0
   ```

4. **SVM 無法存取：**
   ```bash
   # 於 ONTAP 檢查 SVM 狀態
   vserver show -vserver <svm-name>

   # 檢查 iSCSI 服務
   vserver iscsi show -vserver <svm-name>
   ```

### 設定錯誤

**症狀：**
- 出現缺少或無效選項的錯誤訊息

**解決方式：**

確認所有必要選項皆已設定：
```bash
pvesm config <storage-id>

# 必要選項：
# - ontap-portal
# - ontap-svm
# - ontap-aggregate
# - ontap-username
# - ontap-password
```

---

## iSCSI 問題

### 沒有 iSCSI Session

**症狀：**
- `iscsiadm -m session` 未顯示任何 session
- 無法存取 LUN

**診斷：**

```bash
# 檢查 iSCSI daemon
systemctl status iscsid

# 檢查 target
iscsiadm -m discovery -t sendtargets -p <ontap-ip>

# 檢查 initiator 名稱
cat /etc/iscsi/initiatorname.iscsi
```

**解決方式：**

1. **啟動 iSCSI daemon：**
   ```bash
   systemctl enable --now iscsid
   ```

2. **探索並登入：**
   ```bash
   # 探索 target
   iscsiadm -m discovery -t sendtargets -p <ontap-data-ip>

   # 登入所有已探索的 target
   iscsiadm -m node --login
   ```

3. **檢查 ONTAP 上的 igroup：**
   ```bash
   # 於 ONTAP CLI
   igroup show -vserver <svm>

   # 驗證 initiator 已加入
   igroup show -vserver <svm> -igroup pve_*
   ```

### 建立後找不到 LUN

**症狀：**
- 磁碟建立成功
- `/dev/` 下未出現對應裝置

**診斷：**

```bash
# 檢查新裝置
lsscsi

# 檢查多重路徑
multipath -ll

# 於 ONTAP 檢查 LUN 映射
# lun show -vserver <svm> -mapped
```

**解決方式：**

1. **重新掃描 iSCSI session：**
   ```bash
   iscsiadm -m session --rescan
   ```

2. **重新掃描 SCSI hosts：**
   ```bash
   for host in /sys/class/scsi_host/host*/scan; do
       echo "- - -" > $host
   done
   ```

3. **重載多重路徑：**
   ```bash
   multipathd reconfigure
   multipath -v2
   ```

4. **完整重新掃描程序：**
   ```bash
   iscsiadm -m session --rescan
   sleep 2
   for host in /sys/class/scsi_host/host*/scan; do echo "- - -" > $host; done
   sleep 2
   multipathd reconfigure
   ```

### Session 逾時

**症狀：**
- iSCSI session 斷線
- 操作過程出現 I/O 錯誤

**解決方式：**

1. **調整 `/etc/iscsi/iscsid.conf` 中的逾時值：**
   ```ini
   node.session.timeo.replacement_timeout = 120
   node.conn[0].timeo.noop_out_interval = 5
   node.conn[0].timeo.noop_out_timeout = 5
   ```

2. **重啟 iSCSI：**
   ```bash
   systemctl restart iscsid
   iscsiadm -m node --logout
   iscsiadm -m node --login
   ```

---

## 多重路徑問題

### 多重路徑裝置未建立

**症狀：**
- `lsscsi` 可見多條路徑
- 沒有 `/dev/mapper/` 裝置

**診斷：**

```bash
# 檢查 multipathd 狀態
systemctl status multipathd

# 檢查設定
cat /etc/multipath.conf

# 顯示路徑
multipathd show paths

# 顯示 map
multipathd show maps
```

**解決方式：**

1. **啟動 multipathd：**
   ```bash
   systemctl enable --now multipathd
   ```

2. **加入 NetApp 設定 (安全設定)：**
   ```bash
   cat >> /etc/multipath.conf << 'EOF'
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
   EOF

   systemctl restart multipathd
   ```

   > **警告：** 請勿使用 `features "3 queue_if_no_path pg_init_retries 50"` 或 `dev_loss_tmo infinity`。這些設定會導致當 LUN 無法使用時，整個 PVE 節點卡住。詳情請參閱 [CONFIGURATION_zh-TW.md](CONFIGURATION_zh-TW.md#多重路徑-multipath-設定)。

3. **重新設定多重路徑：**
   ```bash
   multipathd reconfigure
   multipath -v2
   ```

### 殘留的多重路徑裝置

**症狀：**
- LUN 刪除或 VM 移除後，舊的多重路徑裝置仍然存在
- 裝置顯示所有路徑為 `failed faulty running`
- 可能出現在未執行刪除操作的叢集節點上
- `lsblk` 與 `multipath -ll` 仍顯示已刪除的 LUN

**根本原因：**
- 在某節點刪除 LUN 時，**其他**節點仍保留本地 SCSI 裝置
- 核心不會自動移除已解除映射 LUN 的 SCSI 裝置
- 多重路徑 map 會持續存在直到明確清除

**v0.2.2+ 自動解法：**

此問題現已自動處理。外掛會追蹤曾出現過的 WWID，並於每次 `status()` 輪詢時執行 orphan 清除 (背景 fork、非阻塞)。若從舊版升級，只要等待下一次 status 輪詢，殘留裝置就會被清除。

```bash
# 驗證 orphan 清除是否正常運作
journalctl -u pvedaemon --since "5 minutes ago" | grep "Orphan cleanup"
# 預期：「Orphan cleanup: processed N stale WWID(s)」
```

**手動清除 (僅在 v0.2.2 前遺留情況下需要)：**

```bash
# 1. 識別殘留 WWID - 找出所有路徑顯示為 "failed faulty running" 的項目
multipath -ll

# 2. 僅清除特定殘留 WWID (小寫 -f)
multipath -f 3600a09807770457a795d5a7653705853

# 3. 移除該 WWID 殘留的 SCSI 裝置
for sd in $(lsscsi | grep NETAPP | awk '{print $NF}'); do
    devname=$(basename $sd)
    wwid=$(cat /sys/block/$devname/device/wwid 2>/dev/null)
    if [[ "$wwid" == *"3600a09807770457a795d5a7653705853"* ]]; then
        echo 1 > /sys/block/$devname/device/delete
    fi
done
```

**警告 - 不要使用 `multipath -F`：**

> `multipath -F` (大寫 F) 會清除系統上所有未使用的多重路徑 map。在混合環境中 (例如本外掛加上手動設定的 iSCSI LVM)，會中斷當下沒有 I/O 的任何儲存，包括：
> - 當下沒有執行 VM 的節點上手動設定的 iSCSI/FC LVM 儲存
> - 其他處於閒置狀態的儲存外掛裝置
>
> 恢復時需在各受影響節點執行 `systemctl reload multipathd` 或 `iscsiadm -m session --rescan`，必要時還需重新掃描 LVM。
>
> **請一律使用 `multipath -f <wwid>` (小寫) 以清除特定裝置。**

**混合環境情境 (手動 iSCSI LVM 與本外掛並存)：**

| 症狀 | 原因 | 解法 |
|------|------|------|
| 執行 `multipath -F` 後手動 LVM 消失 | `-F` 清除了閒置節點上未使用的 map | `systemctl reload multipathd` |
| 遷移 VM 至「故障」節點仍顯示儲存離線 | LVM 外掛不會自動重新掃描 multipath | 同上 + `pvesm set <id> --disable 0` 重新啟用 |
| 遠端節點刪除後本外掛出現殘留 | 其他節點不知道 LUN 已消失 | v0.2.2 自動處理；舊版需手動清除 |

---

## 快照問題

### 快照建立失敗

**症狀：**
- 建立 VM 快照時出錯
- ONTAP 上未出現快照

**診斷：**

```bash
# 檢查 ONTAP 快照
# 於 ONTAP：snapshot show -vserver <svm> -volume pve_*

# 檢查 PVE 日誌
journalctl -xeu pvedaemon | grep -i snapshot
```

**解決方式：**

1. **確認 volume 存在：**
   ```bash
   # 於 ONTAP
   vol show -vserver <svm> -volume pve_<storage>_<vmid>_*
   ```

2. **檢查快照空間：**
   ```bash
   # 於 ONTAP
   vol show -vserver <svm> -fields percent-snapshot-space
   ```

3. **驗證 API 權限：**
   ```bash
   # 於 ONTAP
   security login role show -vserver <svm> -role <role> -cmddirname snapshot
   ```

### 快照還原失敗

**症狀：**
- 還原操作失敗
- 錯誤：`volume is busy`

**解決方式：**

1. **確認 VM 已停機：**
   ```bash
   qm stop <vmid>
   ```

2. **檢查是否有活動中的 session：**
   ```bash
   iscsiadm -m session | grep <volume-name>
   ```

3. **中斷 volume 連線：**
   ```bash
   # 可能需要手動中斷連線
   iscsiadm -m node -T <target> -p <portal> --logout
   ```

---

## 權限問題

### ONTAP API 權限遭拒

**症狀：**
- HTTP 403 錯誤
- 日誌出現 `access denied`

**診斷：**

```bash
# 測試 API 存取
curl -k -u <user>:<pass> https://<portal>/api/storage/volumes

# 檢查 ONTAP 上的權限
security login role show -vserver <svm> -role <role>
```

**解決方式：**

加入缺少的權限：
```bash
# 於 ONTAP CLI
security login role create -vserver <svm> -role <role> -cmddirname "volume" -access all
security login role create -vserver <svm> -role <role> -cmddirname "lun" -access all
security login role create -vserver <svm> -role <role> -cmddirname "igroup" -access all
security login role create -vserver <svm> -role <role> -cmddirname "snapshot" -access all
```

---

## 效能問題

### I/O 效能緩慢

**診斷：**

```bash
# 檢查多重路徑狀態
multipathd show maps format "%n %S %P"

# 檢查路徑健康
multipathd show paths format "%d %T %t %s"

# 檢查 iSCSI 統計
iscsiadm -m session -P 3
```

**解決方式：**

1. **啟用 queue_if_no_path：**
   ```bash
   # 於 /etc/multipath.conf
   defaults {
       features "3 queue_if_no_path pg_init_retries 50"
   }
   ```

2. **使用多路徑：**
   - 設定多個 iSCSI 資料 LIF
   - 確認多重路徑設定正確

3. **檢查網路：**
   ```bash
   # 測試吞吐量
   iperf3 -c <ontap-ip>
   ```

---

## 復原程序

### 節點故障後復原

1. **在新節點 / 已復原的節點上：**
   ```bash
   # 確認服務啟動
   systemctl start iscsid multipathd

   # 探索 target
   iscsiadm -m discovery -t sendtargets -p <ontap-ip>

   # 登入
   iscsiadm -m node --login

   # 重新設定多重路徑
   multipathd reconfigure
   ```

2. **重啟 PVE 服務：**
   ```bash
   systemctl restart pvedaemon pveproxy
   ```

### 清除孤立資源

在 ONTAP 上識別並清除孤立 volume：

```bash
# 列出所有由外掛管理的 volume
vol show -vserver <svm> -volume pve_*

# 檢查 volume 是否已映射
lun show -vserver <svm> -path /vol/pve_*/* -mapped

# 若 volume 已孤立 (無對應 VM)：
vol offline -vserver <svm> -volume <vol-name>
vol delete -vserver <svm> -volume <vol-name>
```

---

## 日誌位置

| 元件 | 日誌指令 |
|------|---------|
| PVE Daemon | `journalctl -xeu pvedaemon` |
| iSCSI | `journalctl -u iscsid` |
| Multipath | `journalctl -u multipathd` |
| 系統 | `dmesg \| grep -i scsi` |

---

## 取得協助

1. **收集診斷資訊：**
   ```bash
   pvesm status
   iscsiadm -m session
   multipathd show maps
   journalctl -xeu pvedaemon --since "1 hour ago" > pvedaemon.log
   ```

2. **查閱文件：**
   - [QUICKSTART.md](QUICKSTART.md)
   - [CONFIGURATION_zh-TW.md](CONFIGURATION_zh-TW.md)
   - [NAMING_CONVENTIONS.md](NAMING_CONVENTIONS.md)

3. **回報問題：**
   - GitHub Issues：https://github.com/jasoncheng7115/jt-pve-storage-netapp/issues
   - 請提供：PVE 版本、ONTAP 版本、錯誤訊息、日誌

---

## 致謝

特別感謝 **NetApp** 慷慨提供開發與測試環境，使本專案得以順利完成。

我們特別感謝 **NetApp 原廠**協助提供開發測試環境，使本專案得以順利完成。
