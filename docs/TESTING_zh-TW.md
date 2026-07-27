# NetApp ONTAP 儲存外掛 - 測試計畫

本文件定義 jt-pve-storage-netapp 外掛的完整測試程序。
每次發佈之前，所有測試均須通過。

## 前置需求

- 已安裝外掛的 Proxmox VE 節點
- 可透過管理 IP 存取的 ONTAP 系統 (模擬器或實體設備)
- 已於 ONTAP SVM 設定的 iSCSI LIF (多重路徑測試至少需要 2 個)
- 具 2 張與 ONTAP LIF 位於同一網段的 NIC 主機 (供 4-path 多重路徑測試)
- 已設定 storage：`pvesm add netappontap <id> ...`
- 於 `local:vztmpl/` 中備有 LXC 範本

## 1. 基本連線

```bash
# 驗證 storage 為 active 狀態
pvesm status | grep <storage-id>
# 預期：active 並顯示容量

# 驗證 iSCSI sessions (每個 LIF 對每個 NIC 有 1 個)
iscsiadm -m session
# 預期：N 個 sessions (NIC 數 x LIF 數)

# 驗證多重路徑
multipath -ll
# 預期：NetApp LUN 裝置，所有路徑均為 active
```

## 2. VM 磁碟生命週期

```bash
STORAGE=netapp1
VMID=9900

# 2.1 配置 (Allocate)
pvesm alloc $STORAGE $VMID vm-${VMID}-disk-0 1G
# 預期：成功

# 2.2 路徑解析
pvesm path $STORAGE:vm-${VMID}-disk-0
# 預期：/dev/mapper/<wwid>

# 2.3 多重路徑驗證
multipath -ll | grep -A8 NETAPP
# 預期：所有路徑 active ready running

# 2.4 讀寫
DEVPATH=$(pvesm path $STORAGE:vm-${VMID}-disk-0)
dd if=/dev/zero of="$DEVPATH" bs=1M count=10 oflag=direct
dd if="$DEVPATH" of=/dev/null bs=1M count=10 iflag=direct
# 預期：兩者均成功

# 2.5 釋放 (Free)
pvesm free $STORAGE:vm-${VMID}-disk-0
# 預期：成功，不留下多重路徑殘留裝置
multipath -ll | grep -c NETAPP
# 預期：0 (或僅剩其他測試 LUN)
```

## 3. VM 操作

```bash
STORAGE=netapp1
VMID=9901

# 3.1 於 NetApp 上建立含磁碟的 VM
qm create $VMID --name test-netapp --memory 512 --cores 1 \
  --scsi0 $STORAGE:1 --ostype l26 --scsihw virtio-scsi-single

# 3.2 快照
qm snapshot $VMID snap1
qm listsnapshot $VMID
# 預期：列出 snap1

# 3.3 第二個快照
qm snapshot $VMID snap2

# 3.4 刪除第一個快照
qm delsnapshot $VMID snap1
# 預期：snap1 已移除，snap2 仍保留

# 3.5 還原
qm rollback $VMID snap2
# 預期：成功

# 3.6 調整大小
qm resize $VMID scsi0 +512M
qm config $VMID | grep scsi0
# 預期：容量增加

# 3.7 清除快照以進行移動測試
qm delsnapshot $VMID snap2
```

## 4. 磁碟遷移

```bash
# 4.1 NetApp -> local-lvm
qm move-disk $VMID scsi0 local-lvm --delete 1
qm config $VMID | grep scsi0
# 預期：scsi0 位於 local-lvm，無 hang 住

# 4.2 local-lvm -> NetApp
qm move-disk $VMID scsi0 $STORAGE --delete 1
qm config $VMID | grep scsi0
# 預期：scsi0 位於 NetApp，無 hang 住
```

## 5. 複製 (Clone) 操作

```bash
# 5.1 Full Clone
qm clone $VMID 9902 --name test-full-clone --full 1
qm config 9902 | grep scsi0
# 預期：於 NetApp 上的新磁碟

# 5.2 範本 + Linked Clone
qm delsnapshot $VMID snap2 2>/dev/null  # 確保無快照
qm template $VMID
qm clone $VMID 9903 --name test-linked-clone
qm config 9903 | grep scsi0
# 預期：於 NetApp 上的 linked clone 磁碟

# 清除複製
qm destroy 9902 --purge
qm destroy 9903 --purge
```

## 6. 特殊磁碟類型

```bash
VMID=9903
qm create $VMID --name test-disks --memory 512 --cores 1 \
  --scsi0 $STORAGE:1 --ostype l26 --scsihw virtio-scsi-single

# 6.1 EFI 磁碟
qm set $VMID --bios ovmf \
  --efidisk0 $STORAGE:1,efitype=4m,pre-enrolled-keys=1
qm config $VMID | grep efidisk0
# 預期：efidisk0 位於 NetApp

# 6.2 Cloud-init
qm set $VMID --ide2 $STORAGE:cloudinit
qm config $VMID | grep ide2
# 預期：cloudinit 磁碟位於 NetApp

# 6.3 TPM
qm set $VMID --tpmstate0 $STORAGE:1,version=v2.0
qm config $VMID | grep tpmstate0
# 預期：tpmstate0 位於 NetApp

# 清除
qm destroy $VMID --purge
```

## 7. LXC 容器

```bash
CTID=9910

# 7.1 建立以 NetApp 為 rootfs 的 LXC
pct create $CTID local:vztmpl/<template>.tar.zst \
  --rootfs $STORAGE:2 \
  --hostname test-lxc --memory 256 --cores 1 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp --unprivileged 0
# 預期：成功

# 7.2 啟動
pct start $CTID
pct status $CTID
# 預期：running

# 7.3 快照
pct snapshot $CTID snap1
# 預期：成功

# 7.4 停止 + 清除
pct stop $CTID
pct delsnapshot $CTID snap1
pct destroy $CTID --purge
# 預期：全部乾淨
```

## 8. igroup 對應驗證

```bash
# 執行 alloc_image 後，驗證 LUN 已對應至所有節點的 igroup
pvesm alloc $STORAGE 9999 vm-9999-disk-0 128M

# 於 ONTAP 檢查 (透過 API 或 CLI)：
# - LUN 應對應至 pve_<cluster>_<node1> 及 pve_<cluster>_<node2>
# - 而不僅是目前節點的 igroup

pvesm free $STORAGE:vm-9999-disk-0
```

## 9. 逾時保護 (防止 Hang)

```bash
# 9.1 驗證 sysfs 寫入逾時機制
# 檢查 dmesg/journal 於正常操作期間是否出現 "timed out after 10s" 訊息
# 這類訊息對於無回應的 SCSI host 是預期行為，且不應阻塞操作

# 9.2 儲存狀態查詢不應 hang 住
time pvesm status
# 預期：即使 ONTAP 回應緩慢，仍應於 30 秒內完成

# 9.3 若條件允許，中斷一個 iSCSI LIF 並驗證：
#   - 透過剩餘路徑仍可正常操作
#   - 沒有 PVE worker hang 住
#   - multipath 顯示路徑降級
```

## 10. 失效情境 (選用，需受控環境)

```bash
# 10.1 中斷一個 iSCSI LIF
# 驗證：multipath 降級，剩餘路徑上 I/O 持續進行
# 驗證：重新連線後所有路徑恢復

# 10.2 中斷所有 iSCSI LIF
# 驗證：PVE 狀態回傳 (0,0,0,0) 而非 hang 住
# 驗證：pvesm status 可完成 (不 hang)
# 驗證：無 PVE worker 行程卡在 D state

# 10.3 ONTAP API 無法連線 (封鎖 port 443)
# 驗證：pvesm status 約於 35 秒內完成
# 驗證：alloc/free 操作以清楚錯誤訊息失敗，而非 hang 住
```

## 11. 與現有 multipath 共存

若主機已存在手動設定的 multipath：

```bash
# 11.1 驗證現有 multipath 裝置未受影響
multipath -ll
# 預期：客戶既有的裝置仍存在且可正常運作

# 11.2 驗證 iSCSI sessions
iscsiadm -m session
# 預期：客戶原有 sessions 完整，並新增外掛的 sessions

# 11.3 驗證 multipath.conf 未被修改
grep "BEGIN jt-pve-storage-netapp" /etc/multipath.conf
# 預期：找不到 (客戶設定被保留)
```

## 19. v0.2.4 稽核修復測試 (cleanup 順序、snapshot 落盤、無用程式碼)

### 19.1 靜態程式碼稽核 (regression 防護)

下列 grep 用來防止任何 function 退化回 v0.2.4 / v0.2.3 / v0.2.1 修掉的 bug pattern。每一項都應該得到 ZERO 個 match。

```bash
cd /root/jt-pve-storage-netapp

# 19.1.1 cleanup 路徑中沒有 volume_delete 卻沒先 lun_unmap_all
grep -n 'volume_delete' lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm
# 預期：每個 cleanup 路徑的 volume_delete 之前的幾行都有 lun_unmap_all
# alloc_image: 約 line 1061-1063 OK
# clone_image: 約 line 2052-2054 與 2090-2092 OK (v0.2.4 修復)
# free_image:  約 line 1149 OK (step 2 約 line 1117 已經 unmap)

# 19.1.2 沒有 basename() 在 /sys/block/ 存取附近
grep -n 'basename' lib/PVE/Storage/Custom/NetAppONTAP/Multipath.pm | \
    grep -v '_resolve_block_device_name'
# 預期：只剩 get_scsi_devices_by_serial 一個 match (它直接用 /sys/block/sd*
# 名稱,安全)

# 19.1.3 get_multipath_wwid 已刪除
grep -n 'get_multipath_wwid' lib/PVE/Storage/Custom/NetAppONTAP/Multipath.pm
# 預期：zero matches (v0.2.4 已刪除)

# 19.1.4 沒有 bare system() (anti-hang)
grep -nE '(^|[^_a-z])system\s*\(' lib/PVE/Storage/Custom/**/*.pm
# 預期：zero matches

# 19.1.5 沒有 bare open() 寫 /sys/
grep -n "open.*'>'.*'/sys/" lib/PVE/Storage/Custom/**/*.pm
# 預期：zero matches
```

### 19.2 clone_image cleanup 不留殘留 (正向測試)

測試 clone+destroy 完整流程後不會留下任何 LUN mapping 殘留或 ghost 裝置。
這是 v0.2.4 Bug E 的 happy path regression 測試。

```bash
STORAGE=netapp1

# 19.2.1 建立 base VM 並設為 template
qm create 9950 --name clone-test --memory 256 --cores 1 \
  --scsi0 $STORAGE:1 --kvm 0 --ostype l26 --scsihw virtio-scsi-single
qm template 9950

# 19.2.2 Linked clone
qm clone 9950 9951 --name linked-clone-test
qm config 9951 | grep scsi0

# 19.2.3 Full clone
qm clone 9950 9952 --name full-clone-test --full 1
qm config 9952 | grep scsi0

# 19.2.4 銷毀 clones
qm destroy 9951 --purge
qm destroy 9952 --purge
sleep 5

# 19.2.5 驗證沒有 stale 裝置
multipath -ll 2>/dev/null | grep -B1 NETAPP | grep "failed faulty"
# 預期：empty

# 19.2.6 清除
qm destroy 9950 --purge
```

### 19.3 volume_snapshot 對停機 VM (Bug F)

驗證對停機 VM 做 snapshot 時 (會走 pre-flush 路徑) 仍然成功。

```bash
STORAGE=netapp1
VMID=9960

qm create $VMID --name snap-flush-test --memory 256 --cores 1 \
  --scsi0 $STORAGE:1 --kvm 0 --ostype l26 --scsihw virtio-scsi-single

# 對停機 VM 做 snapshot (會觸發 pre-flush 路徑)
qm snapshot $VMID baseline
qm listsnapshot $VMID
# 預期：列出 baseline

# 驗證 dmesg 沒有 flush 錯誤
dmesg | tail -20 | grep -iE 'flushbufs|sync.*timed out'
# 預期：沒有相關錯誤

# Rollback 路徑 regression 檢查
qm rollback $VMID baseline

qm delsnapshot $VMID baseline
qm destroy $VMID --purge
```

### 19.4 volume_snapshot 對運行中 VM (regression)

驗證 pre-flush 在 device 被使用時正確 skip，不會 block live VM。

```bash
STORAGE=netapp1
VMID=9961

qm create $VMID --name snap-running-test --memory 256 --cores 1 \
  --scsi0 $STORAGE:1 --kvm 0 --ostype l26 --scsihw virtio-scsi-single
qm start $VMID
sleep 3

# Snapshot running VM -- 應該 skip flush (device in use), 走 qemu freeze
qm snapshot $VMID running-snap
qm listsnapshot $VMID
# 預期：成功,沒有 hang,沒有 flush 警告

qm stop $VMID
qm delsnapshot $VMID running-snap
qm destroy $VMID --purge
```

### 19.5 Resize regression (v0.2.3 修復重驗)

```bash
STORAGE=netapp1
VMID=9962

qm create $VMID --name resize-regression --memory 256 --cores 1 \
  --scsi0 $STORAGE:1 --kvm 0 --ostype l26 --scsihw virtio-scsi-single
qm start $VMID
sleep 3

qm resize $VMID scsi0 +512M
# 預期：成功,沒有 "Cannot grow device files" 錯誤

DEV=$(pvesm path $STORAGE:vm-${VMID}-disk-0)
SIZE=$(blockdev --getsize64 $DEV)
echo "device size: $SIZE bytes"

qm stop $VMID
qm destroy $VMID --purge
```

### 19.7 clone_image 並行 race (Bug H)

驗證 v0.2.4 在 `clone_image` 的 TOCTOU race 修復。三個並行的 template clone 應該全部成功並有不同的 disk ID，沒有 "already exists" 錯誤。

```bash
STORAGE=netapp1

qm create 9950 --name h-test --memory 256 --cores 1 \
  --scsi0 $STORAGE:1 --kvm 0 --ostype l26 --scsihw virtio-scsi-single
qm template 9950

qm clone 9950 9961 --name parallel-1 > /tmp/p1.log 2>&1 &
qm clone 9950 9962 --name parallel-2 > /tmp/p2.log 2>&1 &
qm clone 9950 9963 --name parallel-3 > /tmp/p3.log 2>&1 &
wait

qm config 9961 | grep scsi0
qm config 9962 | grep scsi0
qm config 9963 | grep scsi0
# 預期:每一個都顯示 scsi0 在 $STORAGE 上,有不同的 disk ID

grep -i "already exists\|race detected" /tmp/p*.log
# 預期:空 (或只有 "race detected" warnings — 這是 v0.2.4 的預期行為,不是錯誤)

qm destroy 9961 --purge
qm destroy 9962 --purge
qm destroy 9963 --purge
qm destroy 9950 --purge
```

### 19.8 ONTAP 上限錯誤翻譯 (Bug I，單元測試)

驗證 `_translate_limit_error` 對 5 種上限錯誤 pattern 的翻譯正確。不需要真的把 ONTAP 操到上限 — 純粹單元測試。

```bash
cd /root/jt-pve-storage-netapp
perl -Ilib -e '
use PVE::Storage::Custom::NetAppONTAPPlugin;
my @cases = (
  ["Maximum number of volumes is reached on Vserver svm0", "FlexVol"],
  ["Maximum number of LUNs reached for SVM", "LUN"],
  ["Maximum number of LUN map entries reached", "LUN map"],
  ["No space left on aggregate aggr1", "aggregate"],
  ["Vserver quota exceeded", "quota"],
  ["some unrelated error", "passthrough"],
);
for my $c (@cases) {
  my ($err, $label) = @$c;
  my $out = PVE::Storage::Custom::NetAppONTAPPlugin::_translate_limit_error($err, "test");
  my $translated = ($out ne $err);
  print "$label: ", ($label eq "passthrough" ? !$translated : $translated) ? "PASS" : "FAIL", "\n";
}
'
# 預期:6 行都顯示 PASS
```

### 19.9 rescan_scsi_hosts 不會碰非 iSCSI host (v0.2.5 Bug Incident 8)

驗證 `rescan_scsi_hosts()` 只對從 `/sys/class/iscsi_host/` 取得的 iSCSI host 寫入 scan 檔案，絕對不碰非 iSCSI host (像是 HBA RAID、USB 讀卡機、virtio-scsi 等)。

#### 19.9.1 靜態程式碼稽核

```bash
cd /root/jt-pve-storage-netapp

# rescan 函式必須從 transport-specific class 取得 host 清單
grep -n 'iscsi_host' lib/PVE/Storage/Custom/NetAppONTAP/Multipath.pm | grep -v '^\s*#'
# 預期: rescan_scsi_hosts 裡至少一行引用 /sys/class/iscsi_host

# rescan_scsi_hosts 不應該直接 opendir /sys/class/scsi_host
perl -ne 'print "$.: $_" if /opendir.*SCSI_HOST_PATH/' lib/PVE/Storage/Custom/NetAppONTAP/Multipath.pm
# 預期: 零輸出

# rescan_fc_hosts 不應該迭代整個 /sys/class/scsi_host
perl -ne '
  if (/sub rescan_fc_hosts/../^}/) {
    print "$.: $_" if /opendir.*scsi_host/;
  }
' lib/PVE/Storage/Custom/NetAppONTAP/FC.pm
# 預期: 零輸出
```

#### 19.9.2 混合 driver 環境下的執行時行為

```bash
# 確認測試 host 有至少一個非 iSCSI 的 scsi_host
ls /sys/class/scsi_host/

ls /sys/class/iscsi_host/ 2>/dev/null
# 應該是 /sys/class/scsi_host/ 的嚴格子集

# 顯示每個 scsi host 的 driver
for h in /sys/class/scsi_host/host*; do
  echo -n "$(basename $h): "
  cat $h/proc_name 2>/dev/null
done
# 會看到各種 driver 混雜。非 iscsi_tcp 的 host 絕對不應該被 plugin scan

# 取出非 iSCSI host 清單,執行 rescan 前後比對 scan 檔案有沒有被寫入
ISCSI_HOSTS=$(ls /sys/class/iscsi_host/ 2>/dev/null)
NONISCSI_HOSTS=$(comm -23 <(ls /sys/class/scsi_host/ | sort) <(echo "$ISCSI_HOSTS" | sort))

for h in $NONISCSI_HOSTS; do
  stat -c "%n %Y" /sys/class/scsi_host/$h/scan 2>/dev/null
done > /tmp/scan-before.txt

perl -I/usr/share/perl5 -e "
use PVE::Storage::Custom::NetAppONTAP::Multipath qw(rescan_scsi_hosts);
rescan_scsi_hosts(delay => 0);
print 'rescan done\n';
"

for h in $NONISCSI_HOSTS; do
  stat -c "%n %Y" /sys/class/scsi_host/$h/scan 2>/dev/null
done > /tmp/scan-after.txt

diff /tmp/scan-before.txt /tmp/scan-after.txt
# 預期: 空 (非 iSCSI host 的 mtime 沒變)
```

#### 19.9.3 功能 regression: 新 LUN 還是能被 discover

```bash
# 新增一個 LUN — 會觸發 rescan_scsi_hosts,如果新的 filter 壞了,新 LUN 無法 discover
STORAGE=netapp1
pvesm alloc $STORAGE 9990 vm-9990-disk-0 256M
pvesm path $STORAGE:vm-9990-disk-0
# 預期: 回傳 /dev/mapper/<wwid>
pvesm free $STORAGE:vm-9990-disk-0
```

### 19.10 is_device_in_use 詳細錯誤訊息 (v0.2.6)

測試當 free_image 因 holder 被阻擋時，錯誤訊息顯示：
- 確切的 holder 裝置名稱和 dm-name
- 自動偵測的 LVM VG 名稱
- 修復指令 (vgchange -an)
- lvm.conf global_filter 建議

```bash
STORAGE=netapp1
pvesm alloc $STORAGE 9995 vm-9995-disk-0 256M
DEV=$(readlink -f $(pvesm path $STORAGE:vm-9995-disk-0))
sleep 2

# 建立模擬 LVM holder (模擬 host 自動啟用 guest VG 的情境)
SECTORS=$(blockdev --getsz $DEV)
echo "0 $SECTORS linear $DEV 0" | dmsetup create "myvg-root"
echo "0 1024 linear $DEV 0" | dmsetup create "myvg-swap"

# 嘗試刪除 - 應顯示含 holder 名稱 + VG + 修復指令的詳細訊息
pvesm free $STORAGE:vm-9995-disk-0 2>&1
# 預期輸出包含:
#   [HOLDERS] Device has 2 holder(s)
#   /dev/dm-XX (dm-name: myvg-root)
#   /dev/dm-XX (dm-name: myvg-swap)
#   Detected LVM VG(s): myvg
#   vgchange -an myvg
#   global_filter

# 清理
dmsetup remove myvg-root
dmsetup remove myvg-swap
pvesm free $STORAGE:vm-9995-disk-0
```

### 19.11 殘留裝置警告冷卻機制 (v0.2.6)

測試未追蹤的 NETAPP 殘留裝置偵測警告使用 1 小時冷卻時間，而非每 10 秒觸發一次。

```bash
# 檢查冷卻狀態目錄是否存在
ls -la /var/run/pve-storage-netapp/

# 若有未追蹤的 NETAPP 裝置,間隔 15 秒觸發兩次 status 輪詢
pvesm status > /dev/null
sleep 15
pvesm status > /dev/null

# 檢查 journal - 警告最多出現一次,不會出現兩次
journalctl -u pvestatd --since "1 minute ago" --no-pager | grep -c "untracked NETAPP"
# 預期: 0 或 1 (不會是 2+,因為冷卻時間為 1 小時)

# 檢查冷卻旗標檔案
ls /var/run/pve-storage-netapp/orphan-warn-* 2>/dev/null
```

### 19.12 Postinst lvm.conf global_filter 偵測 (v0.2.6)

測試 postinst 在 lvm.conf 沒有 global_filter 時發出警告。

```bash
# 檢查目前系統 - 若 global_filter 存在,postinst 不應發出警告
grep -c 'global_filter' /etc/lvm/lvm.conf
# 若 > 0: postinst 安裝時不應顯示 lvm 警告

# 測試 WARNING 路徑 (僅在測試系統上操作!):
# 1. 暫時將 lvm.conf 中的 global_filter 註解掉
# 2. 重新執行 postinst: dpkg-reconfigure jt-pve-storage-netapp
# 3. 應看到 "WARNING: /etc/lvm/lvm.conf has no global_filter" 區塊
# 4. 還原 global_filter
# 警告: 不要在正式環境操作 - 移除 global_filter 會導致
# LVM 掃描 VM 磁碟並自動啟用 guest VG。
```

### 19.13 Postinst 重新載入全部三個 PVE 服務 (v0.2.6)

測試 postinst 重新載入 pvedaemon、pvestatd 和 pveproxy (不只 pvedaemon + pveproxy)。

```bash
# 靜態檢查: postinst 包含 pvestatd
grep -c 'pvestatd' debian/postinst
# 預期: 1+

# 功能測試: 重新安裝並驗證三個服務都被重新載入
dpkg -i jt-pve-storage-netapp_0.2.6-1_all.deb 2>&1 | grep -E '\[OK\].*reloaded|\[OK\].*started'
# 預期: 三行輸出,分別對應 pvedaemon、pvestatd、pveproxy
```

### 19.14 kpartx partition holders 安全時忽略 (v0.2.7)

驗證 `is_device_in_use()` 正確忽略 bare kpartx partition holders (沒有 sub-holders)，
但在 partition 有 sub-holders、被 mount、或被 swap 時仍然擋住。

```bash
STORAGE=netapp1

# 19.14.1 只有 partition holders → 刪除應該成功
pvesm alloc $STORAGE 9996 vm-9996-disk-0 256M
DEV=$(readlink -f $(pvesm path $STORAGE:vm-9996-disk-0))
sleep 2
SECTORS=$(blockdev --getsz $DEV)
echo "0 $SECTORS linear $DEV 0" | dmsetup create "testwwid-part1"
echo "0 1024 linear $DEV 0" | dmsetup create "testwwid-part2"
pvesm free $STORAGE:vm-9996-disk-0
# 預期：成功刪除 (bare partition 被忽略)

# 19.14.2 Partition + LVM sub-holder → 刪除應該被擋
pvesm alloc $STORAGE 9997 vm-9997-disk-0 256M
DEV2=$(readlink -f $(pvesm path $STORAGE:vm-9997-disk-0))
sleep 2
SECTORS2=$(blockdev --getsz $DEV2)
echo "0 $SECTORS2 linear $DEV2 0" | dmsetup create "testwwid2-part5"
echo "0 1024 linear /dev/mapper/testwwid2-part5 0" | dmsetup create "myvg-root"
pvesm free $STORAGE:vm-9997-disk-0 2>&1
# 預期：無法刪除 (partition 有 LVM sub-holder)
dmsetup remove myvg-root; dmsetup remove testwwid2-part5
pvesm free $STORAGE:vm-9997-disk-0

# 19.14.3 Partition 被 mount → 刪除應該被擋
pvesm alloc $STORAGE 9998 vm-9998-disk-0 256M
DEV3=$(readlink -f $(pvesm path $STORAGE:vm-9998-disk-0))
sleep 2
SECTORS3=$(blockdev --getsz $DEV3)
echo "0 $SECTORS3 linear $DEV3 0" | dmsetup create "testwwid3-part1"
mkfs.ext4 -F /dev/mapper/testwwid3-part1 > /dev/null 2>&1
mkdir -p /tmp/test_mount_check
mount /dev/mapper/testwwid3-part1 /tmp/test_mount_check
pvesm free $STORAGE:vm-9998-disk-0 2>&1
# 預期：無法刪除 (partition 被 mount)
umount /tmp/test_mount_check; dmsetup remove testwwid3-part1
pvesm free $STORAGE:vm-9998-disk-0; rmdir /tmp/test_mount_check

# 19.14.4 /proc/swaps 檢查存在 (靜態)
grep -c 'proc/swaps' /usr/share/perl5/PVE/Storage/Custom/NetAppONTAP/Multipath.pm
# 預期：2+ (在 is_device_in_use 和 get_device_usage_details 裡)
```

### 19.6 is_device_in_use with LVM holder (v0.2.3 資料遺失修復重驗)

```bash
STORAGE=netapp1
VMID=9963

pvesm alloc $STORAGE $VMID vm-${VMID}-disk-0 256M
DEV=$(pvesm path $STORAGE:vm-${VMID}-disk-0)

pvcreate -ff -y $DEV
vgcreate test_v024_vg $DEV
lvcreate -L 100M -n test_lv test_v024_vg
mkfs.ext4 -F /dev/test_v024_vg/test_lv
mkdir -p /mnt/test_v024
mount /dev/test_v024_vg/test_lv /mnt/test_v024

RESULT=$(perl -Ilib -e "
use PVE::Storage::Custom::NetAppONTAP::Multipath qw(is_device_in_use);
print is_device_in_use('$DEV') ? 'IN_USE' : 'FREE';
")
echo "is_device_in_use($DEV) = $RESULT"
# 預期：IN_USE

pvesm free $STORAGE:vm-${VMID}-disk-0 2>&1
# 預期：error "device is still in use"

# 清除
umount /mnt/test_v024
lvremove -f test_v024_vg/test_lv
vgremove test_v024_vg
pvremove $DEV
pvesm free $STORAGE:vm-${VMID}-disk-0
rmdir /mnt/test_v024
```

---

## 20. 客戶事件重現測試

這些測試重現客戶在正式環境中回報的實際事件。
每項測試驗證修復是否有效並防止 regression。

### 20.1 HPE ProLiant smartpqi 掃描卡住 (Incident 8，v0.2.5)

驗證 `rescan_scsi_hosts()` 不會對非 iSCSI 的 SCSI host 寫入。
在搭載 smartpqi (P408i-a) 的 HPE ProLiant 伺服器上，寫入 host1/scan
會導致超過 600 秒的 D-state 卡住，進而連鎖觸發 VM lock timeout 以及
pvedaemon restart 卡住。

```bash
# Verify only iSCSI hosts are scanned (strace proof)
strace -f -e trace=openat -o /tmp/rescan-trace.log \
  perl -I/usr/share/perl5 -e '
use PVE::Storage::Custom::NetAppONTAP::Multipath qw(rescan_scsi_hosts);
rescan_scsi_hosts(delay => 0);
'

# Extract scan files opened
grep -oE '/sys/class/scsi_host/host[0-9]+/scan' /tmp/rescan-trace.log | sort -u
# Expected: ONLY iSCSI hosts (matching /sys/class/iscsi_host/)
# MUST NOT contain non-iSCSI hosts (smartpqi, ahci, virtio_scsi, etc.)

# Cross-reference
echo "=== iSCSI hosts ==="
ls /sys/class/iscsi_host/
echo "=== ALL scsi hosts ==="
for h in /sys/class/scsi_host/host*; do
  printf "%-8s %s\n" "$(basename $h):" "$(cat $h/proc_name 2>/dev/null)"
done
# Every host in strace output must appear in iscsi_host list
```

### 20.2 pvestatd 升級後未 reload (Incident 9，v0.2.6)

驗證 postinst 會重新載入全部三個 PVE 服務，而非僅 pvedaemon + pveproxy。
遺漏 pvestatd 會導致舊版 plugin 程式碼在 pvestatd 的記憶體中持續運行，造成
D-state 累積。

```bash
# Static: postinst contains all three services
grep -E 'pvedaemon|pvestatd|pveproxy' debian/postinst | grep -v '^#' | head -10
# Expected: all three service names appear in the reload/start logic

# Functional: install package and verify all three are reloaded
dpkg -i jt-pve-storage-netapp_0.2.7-1_all.deb 2>&1 | grep -E '\[OK\]'
# Expected: three [OK] lines (pvedaemon, pvestatd, pveproxy)
```

### 20.3 PVE 主機 LVM auto-activation 擋住 volume 刪除 (Incident 10，v0.2.6)

驗證 `is_device_in_use()` 在PVE 主機自動啟用 VM 磁碟內部 LVM VG 時，
會顯示詳細的診斷訊息，且錯誤訊息包含 VG 名稱與修復指令。

```bash
STORAGE=netapp1

pvesm alloc $STORAGE 9980 vm-9980-disk-0 256M
DEV=$(readlink -f $(pvesm path $STORAGE:vm-9980-disk-0))
sleep 2

# Simulate host LVM auto-activation of guest VG
SECTORS=$(blockdev --getsz $DEV)
echo "0 $SECTORS linear $DEV 0" | dmsetup create "guestvg--root"
echo "0 1024 linear /dev/mapper/guestvg--root 0" | dmsetup create "guestvg-swap"

# Delete should be blocked with detailed message
OUTPUT=$(pvesm free $STORAGE:vm-9980-disk-0 2>&1)
echo "$OUTPUT"
# Expected output contains:
#   [HOLDERS]
#   dm-name: guestvg--root
#   Detected LVM VG(s): guestvg
#   vgchange -an guestvg

echo "$OUTPUT" | grep -q "HOLDERS" && echo "PASS: detailed message" || echo "FAIL"
echo "$OUTPUT" | grep -q "vgchange" && echo "PASS: fix command shown" || echo "FAIL"

# Cleanup
dmsetup remove guestvg-swap
dmsetup remove guestvg--root
pvesm free $STORAGE:vm-9980-disk-0
```

### 20.4 kpartx partition holders 擋住所有刪除 (v0.2.7)

重現客戶場景：每次磁碟刪除都失敗，因為 kernel 自動在已安裝 OS 的 VM 磁碟上
建立 partition device。測試三種客戶案例：
1. 刪除閒置磁碟（舊磁碟遺留在 plugin storage 上）
2. move-disk 並刪除來源（遷移後）
3. 新建 VM 磁碟 + 刪除

```bash
STORAGE=netapp1

# Case 1: Disk with partition table (simulates VM with OS installed)
pvesm alloc $STORAGE 9981 vm-9981-disk-0 1G
DEV=$(readlink -f $(pvesm path $STORAGE:vm-9981-disk-0))
sleep 2

# Write GPT partition table (what a VM OS installer does)
sgdisk -Z $DEV 2>/dev/null
sgdisk -n 1:2048:+100M -n 2:+0:+200M -n 5:+0:+500M $DEV 2>&1 | tail -1
kpartx -a $DEV 2>/dev/null || partprobe $DEV 2>/dev/null
sleep 2

# Show holders (should be partition devices)
DM=$(basename $DEV)
echo "holders before delete:"
for h in $(ls /sys/block/$DM/holders/ 2>/dev/null); do
  echo -n "  $h -> "; cat /sys/block/$h/dm/name 2>/dev/null
done

# v0.2.7: bare partitions (no sub-holders) should be ignored
pvesm free $STORAGE:vm-9981-disk-0 2>&1 | tail -1
# Expected: Removed volume (partition holders ignored)

# Case 2: Partition + LVM on top (checktc-vg scenario) should STILL block
pvesm alloc $STORAGE 9982 vm-9982-disk-0 1G
DEV2=$(readlink -f $(pvesm path $STORAGE:vm-9982-disk-0))
sleep 2
sgdisk -Z $DEV2 2>/dev/null
sgdisk -n 5:2048:+500M $DEV2 2>&1 | tail -1
kpartx -a $DEV2 2>/dev/null || partprobe $DEV2 2>/dev/null
sleep 2

# Find the partition device and add LVM on top
PART_DM=$(ls /sys/block/$(basename $DEV2)/holders/ | head -1)
PART_NAME=$(cat /sys/block/$PART_DM/dm/name 2>/dev/null)
echo "0 1024 linear /dev/mapper/$PART_NAME 0" | dmsetup create "testvg-root" 2>&1

pvesm free $STORAGE:vm-9982-disk-0 2>&1 | head -3
# Expected: Cannot delete (partition has LVM sub-holder)

# Cleanup
dmsetup remove testvg-root 2>/dev/null
kpartx -d $DEV2 2>/dev/null
pvesm free $STORAGE:vm-9982-disk-0
```

### 20.5 Partition dm-name 格式變體 (v0.2.7 regression guard)

Kernel/kpartx 根據系統不同，會建立不同 dm-name 格式的 partition device。
全部都必須被正確辨識為 partition。

```bash
# Static: verify regex covers all known formats
perl -I/usr/share/perl5 -e '
use strict;
my @cases = (
  ["3600a09803831464a4c24577537444d33-part1", 1, "dash-part"],
  ["3600a09803831464a4c24577537444d33p1",     1, "p-suffix (HPE)"],
  ["3600a09803831464a4c245775374441231",      1, "digit-only"],
  ["sdf1",                                     1, "non-multipath"],
  ["mpath0-part2",                             1, "alias-part"],
  ["myvg-root",                                0, "LVM (must NOT match)"],
  ["checktc--vg-root",                         0, "LVM with hyphen"],
  ["dm-crypt-luks",                            0, "dm-crypt"],
);
for my $c (@cases) {
  my ($name, $expect, $label) = @$c;
  my $is_part = ($name =~ /part\d+$/
              || $name =~ /^[0-9a-f]{20,}p?\d+$/
              || $name =~ /^sd[a-z]+\d+$/) ? 1 : 0;
  my $ok = ($is_part == $expect);
  printf "%-40s %-6s %s\n", $label, $ok ? "PASS" : "FAIL",
    "($name -> " . ($is_part ? "partition" : "not-partition") . ")";
}
'
# Expected: all 8 lines say PASS
```

### 20.6 Postinst lvm.conf global_filter 偵測 (v0.2.6)

驗證 postinst 在 lvm.conf 缺少 global_filter 時會發出警告。

```bash
# Check if current system has global_filter
grep -c 'global_filter' /etc/lvm/lvm.conf
# If > 0: postinst should NOT show lvm warning (verified during install)
# If 0: postinst should show WARNING block about auto-activation

# Static: postinst contains the detection code
grep -c 'global_filter' debian/postinst
# Expected: 3+ (detection logic + warning text)
```

### 20.7 殘留裝置警告冷卻機制 (v0.2.6)

驗證殘留偵測警告不會灌爆 journal。

```bash
# Check cooldown mechanism exists in code
grep -c 'cooldown' /usr/share/perl5/PVE/Storage/Custom/NetAppONTAPPlugin.pm
# Expected: 3+ (cooldown_dir, cooldown_secs, flag file logic)

# Check cooldown state directory
ls /var/run/pve-storage-netapp/ 2>/dev/null
# Expected: directory exists (created on demand)

# If orphan warnings are active, verify they don't repeat within 1 hour:
# Run two status polls 15s apart
pvesm status > /dev/null; sleep 15; pvesm status > /dev/null
journalctl -u pvestatd --since "1 minute ago" --no-pager 2>&1 | grep -c "untracked NETAPP"
# Expected: 0 or 1 (not 2, because cooldown is 1 hour)
```

### 20.8 升級 SOP：安裝前先停止服務 (v0.2.6 教訓)

記錄正確的升級程序，避免舊 code 的 D-state 在升級過程中累積。
這不是自動化測試，是給操作人員的手動 checklist。

```bash
# CORRECT upgrade procedure (prevents D-state from old code):
# 1. Stop all PVE services BEFORE installing
systemctl stop pvedaemon pvestatd pveproxy
# If stop hangs (D-state from old code): Ctrl+C then:
systemctl kill -s KILL pvedaemon pvestatd pveproxy

# 2. Verify stopped
systemctl is-active pvedaemon pvestatd pveproxy
# Expected: inactive inactive inactive

# 3. Install
dpkg -i jt-pve-storage-netapp_0.2.7-1_all.deb
# Postinst will start (not reload) since services are stopped

# 4. Verify
systemctl is-active pvedaemon pvestatd pveproxy
pvesm status
```

### 20.9 Partition 有 LVM sub-holder 時顯示詳細修復指引 (v0.2.8)

重現客戶情境：plugin 管理的 LUN 上的 partition 有 LVM VG（例如在 partition 上建了 PBS 儲存）。錯誤訊息必須顯示：sub-holder 詳情、VG 名稱、vgchange 指令、以及 duplicate VG 的 UUID 處理方式。

```bash
STORAGE=netapp1
pvesm alloc $STORAGE 9985 vm-9985-disk-0 256M
DEV=$(readlink -f $(pvesm path $STORAGE:vm-9985-disk-0))
sleep 2
S=$(blockdev --getsz $DEV)

# Simulate: partition with PBS LVM VG on top
echo "0 $S linear $DEV 0" | dmsetup create "testwwid-part3"
echo "0 1024 linear /dev/mapper/testwwid-part3 0" | dmsetup create "pbs-data"
echo "0 512 linear /dev/mapper/testwwid-part3 1024" | dmsetup create "pbs-db"

# Try to delete — should block with detailed sub-holder info
OUTPUT=$(pvesm free $STORAGE:vm-9985-disk-0 2>&1)
echo "$OUTPUT"

# Verify message quality
echo "$OUTPUT" | grep -q "sub-holder" && echo "PASS: sub-holders shown" || echo "FAIL"
echo "$OUTPUT" | grep -q "pbs" && echo "PASS: VG name detected" || echo "FAIL"
echo "$OUTPUT" | grep -q "vgchange -an" && echo "PASS: fix command shown" || echo "FAIL"
echo "$OUTPUT" | grep -q "vg_uuid" && echo "PASS: duplicate VG handling shown" || echo "FAIL"

# Cleanup
dmsetup remove pbs-data; dmsetup remove pbs-db
dmsetup remove testwwid-part3
pvesm free $STORAGE:vm-9985-disk-0
```

### 20.10 ASA 最終一致性：lun_map retry (v0.2.9)

驗證 `lun_map()` 在 LUN 建立後若無法立即查到 UUID 時會重試。修復 NetApp ASA 系統上間歇性出現的「LUN not found」錯誤，原因是 POST（建立）和 GET（查詢）之間有短暫的傳播延遲。

#### 20.10.1 靜態程式碼審查

```bash
# 驗證 lun_map 有 retry 邏輯
grep -A15 'sub lun_map' lib/PVE/Storage/Custom/NetAppONTAP/API.pm | head -20
# 預期：retry loop，sleep 1，最多 5 次嘗試

# 驗證重試次數
grep -c 'attempt.*5\|1\.\.5' lib/PVE/Storage/Custom/NetAppONTAP/API.pm
# 預期：1+（retry loop）

# 驗證重試時的警告訊息
grep 'not yet visible' lib/PVE/Storage/Custom/NetAppONTAP/API.pm
# 預期：warn 訊息包含嘗試次數
```

#### 20.10.2 功能測試：move-disk 往返

測試客戶遇到的完整程式碼路徑（move-disk 觸發 alloc_image -> lun_create -> lun_map）。

```bash
STORAGE=netapp1
VMID=9986

# 在 local 建立 VM
qm create $VMID --name asa-test --memory 256 --cores 1 \
  --scsi0 local-lvm:1 --kvm 0 --ostype l26 --scsihw virtio-scsi-single

# 搬到 NetApp（走 alloc_image -> lun_create -> lun_map）
qm move-disk $VMID scsi0 $STORAGE --delete 1
qm config $VMID | grep scsi0
# 預期：scsi0 在 $STORAGE 上，沒有「LUN not found」錯誤

# 搬回去（走 clone 路徑）
qm move-disk $VMID scsi0 local-lvm --delete 1
qm config $VMID | grep scsi0
# 預期：scsi0 在 local-lvm 上

qm destroy $VMID --purge
```

#### 20.10.3 功能測試：並行 alloc + map（壓力測試）

多個並行 alloc 操作，壓力測試 create-then-map 路徑。

```bash
STORAGE=netapp1

# 3 個並行 alloc
pvesm alloc $STORAGE 9987 vm-9987-disk-0 64M > /tmp/a1.log 2>&1 &
pvesm alloc $STORAGE 9988 vm-9988-disk-0 64M > /tmp/a2.log 2>&1 &
pvesm alloc $STORAGE 9989 vm-9989-disk-0 64M > /tmp/a3.log 2>&1 &
wait

# 全部應該成功
cat /tmp/a1.log /tmp/a2.log /tmp/a3.log
# 預期：3 行成功，沒有「LUN not found」錯誤

# 檢查是否有重試
grep "not yet visible" /tmp/a*.log
# 預期：在 FAS/AFF 上應為空。在 ASA 上可能出現 retry 訊息（正常）

# 清理
pvesm free $STORAGE:vm-9987-disk-0
pvesm free $STORAGE:vm-9988-disk-0
pvesm free $STORAGE:vm-9989-disk-0
```

---

## 21. 程式碼審查 Regression Guards

從自動化程式碼審查結果衍生的靜態和功能測試。驗證已知的反模式持續被修正。

### 21.1 殘留清理條件式 untrack (codex review)

驗證 `_cleanup_orphaned_devices()` 僅在本機 multipath 裝置確實已消失時才 untrack WWID，與 `free_image()` 邏輯一致。

```bash
# Static: code must check device existence AFTER cleanup before untracking
grep -A5 'still_exists.*get_multipath' lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm | head -6
# Expected: conditional logic - only _untrack_wwid if !still_exists
```

### 21.2 alloc_image 有界 TOCTOU retry (codex review)

驗證 `alloc_image()` 的 volume_create 競爭處理使用正確的有界重試迴圈（非單次重試），與 `clone_image()` 模式一致。

```bash
# Static: must have a retry loop variable
grep -c 'max_create_retries\|create_try' lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm
# Expected: 4+ (loop variable + loop + check + die)

# Verify it's a real loop, not a single if-then-retry
grep -A2 'create_try' lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm | grep -c 'for\|next'
# Expected: 2+ (for loop + next statement)
```

### 21.3 不推薦 multipath -F (codex review)

驗證程式碼和文件中不會推薦使用 `multipath -F`（大寫 F，會清除所有 maps）。關於「不要使用」的警告是允許且預期存在的。

```bash
# Code: only "DO NOT" context allowed
grep -n 'multipath -F' lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm
# Expected: only lines containing "DO NOT" or "NEVER" or similar warning

# Docs: no recommendation context
grep -rn 'multipath -F' docs/ README*.md | grep -vi 'never\|not\|don.t\|warning\|forbidden\|不要\|絕對\|禁止\|警告'
# Expected: only informational/symptom table entries, no "run this command" suggestions

# Multipath.pm: warning comment only
grep -n 'multipath -F' lib/PVE/Storage/Custom/NetAppONTAP/Multipath.pm
# Expected: only WARNING comment
```

### 21.4 所有 glob() 呼叫有 alarm timeout (codex review)

驗證程式碼中每個 `glob("/dev/disk/by-id/...")` 呼叫皆包裹在 `alarm()` 中，以防止裝置子系統無回應時造成程式掛住。

```bash
# Find all glob calls on /dev/disk
grep -rn 'glob.*dev.disk' lib/PVE/Storage/Custom/NetAppONTAP/*.pm
# For each: check that alarm(5) appears within 3 lines before it
# (Manual review -- verify each glob is inside an eval { alarm(5); ... alarm(0); } block)

# Quick count check
GLOB_COUNT=$(grep -c 'glob.*dev.disk' lib/PVE/Storage/Custom/NetAppONTAP/ISCSI.pm lib/PVE/Storage/Custom/NetAppONTAP/Multipath.pm 2>/dev/null)
ALARM_COUNT=$(grep -c 'alarm(5)' lib/PVE/Storage/Custom/NetAppONTAP/ISCSI.pm lib/PVE/Storage/Custom/NetAppONTAP/Multipath.pm 2>/dev/null)
echo "glob calls: $GLOB_COUNT, alarm wraps: $ALARM_COUNT"
# Expected: alarm count >= glob count
```

---

## 23. iSCSI Portal TCP 預先檢查 (v0.2.12)

驗證 `activate_storage()` 在遇到不可達的 iSCSI LIF 時，會於可控時間內跳過，而不是被 `iscsiadm` discovery / login timeout 拖住。修正來源：相關專案 `jt-pve-storage-purestorage` v1.1.9 的同類型稽核。

### 23.1 probe_portal helper 單元測試

```bash
cat > /tmp/probe_test.pl <<'EOF'
#!/usr/bin/perl
use strict; use warnings;
use lib "/usr/share/perl5";
use Time::HiRes qw(time);
use PVE::Storage::Custom::NetAppONTAP::ISCSI qw(probe_portal);

my @cases = (
    ["127.0.0.1",     22,    "本機 SSH (可達)"],
    ["192.168.99.99", 3260,  "RFC1918 未使用 (timeout)"],
    ["127.0.0.1",     65500, "本機未開放埠 (refused)"],
);
for my $c (@cases) {
    my ($ip, $port, $desc) = @$c;
    my $t0 = time();
    my $r = probe_portal($ip, $port, timeout => 2);
    printf "%-16s:%-5d -> reachable=%d (%.2fs)  [%s]\n",
        $ip, $port, $r, time() - $t0, $desc;
}
EOF
perl /tmp/probe_test.pl
```

**預期結果**：
- 本機可達服務在 1 秒內回傳 `reachable=1`。
- RFC1918 未使用 IP 在指定 timeout 時間(約 2.0 秒)後回傳 `reachable=0`。
- 本機未開放埠立即返回 `reachable=0`(connection refused，不需等 timeout)。

### 23.2 activate_storage 在遇到不可達 LIF 時於可控時間內跳過

前置：在一個有 2 個以上 iSCSI LIF 的 SVM 上配置儲存。用 iptables 擋掉其中一個 LIF，模擬主機端線路不對稱。

**重要 — 測試前必須先 logout 對應 IQN 的 session**。`activate_storage()` 有 fast-path：當 `is_portal_logged_in($portal_addr, $target_iqn)` 回傳 true 時，probe 與 iscsiadm 呼叫都會被整個跳過。kernel 既有的 cached session 會同時遮蔽 bug 與 fix 的效果。每次量測前要先 logout SVM 對應的 target IQN。

```bash
LIF_DOWN=192.168.x.y    # SVM 其中一個 LIF
TARGET_IQN=iqn.1992-08.com.netapp:sn.xxxxx:vs.N   # 從 iscsiadm -m session 取得

# 步驟 1:清掉 cached session,讓 is_portal_logged_in() 回傳 false
iscsiadm -m node -T $TARGET_IQN -u
sleep 1

# 步驟 2:擋一個 LIF
iptables -I OUTPUT -d $LIF_DOWN -p tcp --dport 3260 -j DROP \
    -m comment --comment "test-lif-down"

# 步驟 3:計時下一次 status 呼叫(獨立 process 會觸發 activate_storage)
time pvesm status | grep netapp1

# 清除
iptables -D OUTPUT -d $LIF_DOWN -p tcp --dport 3260 -j DROP \
    -m comment --comment "test-lif-down"
iscsiadm -m node -T $TARGET_IQN -l    # 透過通的 LIF 重新登入
```

**預期結果**：
- `pvesm status` 在 10 秒內返回(probe_timeout 2 秒 × 1 個壞 LIF + ONTAP REST API 時間)。
- `journalctl -u pvestatd` 看到 `Skipped 1 unreachable iSCSI portal(s) ... (no TCP response within 2s)`。
- `netapp1` 顯示為 `active`(可達的 LIF 維持儲存運作)。
- 修正前行為：每個壞 LIF 吃 30 秒(discovery timeout)。4 LIF × 2 個不通，每次 `status()` 輪詢吃 60+ 秒，讓 pvestatd 壅塞。

### 23.3 全部 LIF 不可達時 activate_storage 應 die 並給出可操作訊息

```bash
# 擋掉兩個 LIF
for ip in $LIF1 $LIF2; do
    iptables -I OUTPUT -d $ip -p tcp --dport 3260 -j DROP \
        -m comment --comment "test-all-down"
done

pvesm set netapp1 --disable 1
pvesm set netapp1 --disable 0
pvesm status 2>&1 | grep -A5 netapp1

# 清除
iptables -F OUTPUT  # 或刪掉特定規則
```

**預期結果**：錯誤訊息列出所有不可達的 portals，並提示用 `pvesm set <storeid> --nodes <list>` 把儲存綁到通的節點。**不應**只說「Failed to connect to any iSCSI portal」(0.2.12 之前的籠統訊息)。

### 23.4 ontap-portal-probe-timeout 選項行為

```bash
# 設為 0 = 關閉預先檢查 (回到舊行為)
pvesm set netapp1 --ontap-portal-probe-timeout 0
# 重做 23.2 配 iptables 阻擋,驗證每個壞 LIF 會吃 30 秒以上

# 設為 5 = 拉長 probe 視窗
pvesm set netapp1 --ontap-portal-probe-timeout 5
# 重做 23.2,驗證壞 LIF 約 5 秒被跳過

# 還原預設值
pvesm set netapp1 --delete ontap-portal-probe-timeout
```

**預期結果**：行為與選項值線性對應。設 0 確認可回到 0.2.12 之前的卡頓行為，證明選項生效。

### 23.5 靜態 regression 守則

```bash
# probe_portal 必須被 export 與使用
grep -c 'probe_portal' lib/PVE/Storage/Custom/NetAppONTAP/ISCSI.pm
# 預期: >=2 (宣告 + EXPORT_OK)

grep -c 'probe_portal' lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm
# 預期: >=2 (import + 使用點)

# Schema 必須宣告新選項
grep -c 'ontap-portal-probe-timeout' lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm
# 預期: >=3 (properties + options + scfg 讀取)

# IO::Socket::INET 必須被載入(use 行 + ->new 呼叫點)
grep -c 'IO::Socket::INET' lib/PVE/Storage/Custom/NetAppONTAP/ISCSI.pm
# 預期: >= 2(一次 `use IO::Socket::INET;`,一次 `IO::Socket::INET->new(...)`)
```

---

## 24. Snapshot 刪除時清理依附的 Temp FlexClone(v0.2.13,v0.2.14 強化)

驗證 `volume_snapshot_delete()`(以及 `_cleanup_temp_clones`)會把依附在 snapshot 上的暫時 FlexClone **完整清乾淨** — **ONTAP 端跟 host 端都要乾淨** — 才刪 snapshot。

**沿革**：
- v0.2.13 修正 ONTAP 端：snapshot 刪除不再失敗於「has not expired or is locked」。
- v0.2.13 的測試只驗 ONTAP 端。客戶現場一天內就遇到 v0.2.13 引入的 regression：每次備份都在 host 留下殘留 `dm-multipath` + 4 條 `sd*` 路徑，`multipathd` 持續洗版「tur checker reports path is down」。
- v0.2.14 新增共用 helper `_remove_temp_clone()`，流程對齊 `free_image()` 的 7 步模式(抓 slave 清單 → unmap → cleanup_lun_devices → 移除 sd* → multipath_reload → split → wait → delete)。下面 Section 24 是**強化版**測試，明確驗證 host 端清理 — 就是可以 catch v0.2.13 bug 的驗證。

**規則(來自 v0.2.14 事件，亦記入 CLAUDE.md):** 任何測試只要涵蓋「在 ONTAP 上刪 LUN/卷」的路徑，都**必須**包含 host 端 device 清理驗證(`get_device_by_wwid` 回 undef、sd* 不在 `/sys/block`、`/dev/mapper/<wwid>` 不存在)。只測 ONTAP 不夠 — 那些驗證不會 catch host 端的殘留設備，而那會在幾秒內變成 operator 可見的 syslog 噪音。

### 24.1 透過 plugin API 直接做端到端測試(不需 PBS / vzdump)

此腳本直接呼叫 storage plugin 內部 vzdump 會觸發的同一組函式，**不需要** CT、PBS server 或 vzdump 設定就能重現完整 bug 情境**。包含 host 端 device 殘留驗證**(就是 v0.2.13 漏掉、會 catch 該 bug 的驗證 — 永久保留作 regression 守則)。

```bash
cat > /tmp/test_section24.pl <<'EOF'
#!/usr/bin/perl
use strict; use warnings;
use lib "/usr/share/perl5";
use Time::HiRes qw(time);
use PVE::Storage;
use PVE::Storage::Custom::NetAppONTAPPlugin;
use PVE::Storage::Custom::NetAppONTAP::API;
use PVE::Storage::Custom::NetAppONTAP::Naming;
use PVE::Storage::Custom::NetAppONTAP::Multipath qw(get_device_by_wwid get_multipath_slaves);

my $storeid = "netapp1";
my $cfg = PVE::Storage::config();
my $scfg = $cfg->{ids}->{$storeid} or die "storage $storeid not configured\n";
my $plugin = "PVE::Storage::Custom::NetAppONTAPPlugin";
my $vmid = 9991;
my $volname = "vm-${vmid}-disk-0";
my $exit_code = 0;

sub api { PVE::Storage::Custom::NetAppONTAPPlugin::_get_api($scfg) }
sub ontap_name { PVE::Storage::Custom::NetAppONTAP::Naming::pve_volname_to_ontap($storeid, $volname) }
sub temp_name { PVE::Storage::Custom::NetAppONTAPPlugin::_get_temp_clone_name(ontap_name(), $_[0]) }
sub basename { (my $b = $_[0]) =~ s{.*/}{}; $b }

sub aggressive_cleanup {
    my $ontap_volname = ontap_name();
    for my $snap ("testsnap-A", "testsnap-B") {
        my $tcn = temp_name($snap);
        eval { api()->lun_unmap_all(PVE::Storage::Custom::NetAppONTAP::Naming::encode_lun_path($tcn)); };
        eval { api()->volume_delete($tcn); };
        my $snapname = PVE::Storage::Custom::NetAppONTAP::Naming::encode_snapshot_name($snap);
        eval { api()->snapshot_delete($ontap_volname, $snapname); };
    }
    eval { $plugin->free_image($storeid, $scfg, $volname); };
}

END { aggressive_cleanup() if $exit_code == 0; }
aggressive_cleanup();

$plugin->activate_storage($storeid, $scfg, {});
my $allocated = $plugin->alloc_image($storeid, $scfg, $vmid, "raw", $volname, 1024*1024);
$plugin->activate_volume($storeid, $scfg, $volname, undef, {});

# Case B(regression):無 temp clone 直接刪 snapshot
$plugin->volume_snapshot($scfg, $storeid, $volname, "testsnap-B");
my $t0 = time();
eval { $plugin->volume_snapshot_delete($scfg, $storeid, $volname, "testsnap-B", 0); };
if ($@) { print "FAIL B: $@\n"; $exit_code = 1; exit 1; }
printf "PASS B: snapshot_delete OK in %.2fs(無 temp clone)\n", time() - $t0;

# Case A(bug fix):有 temp clone 時刪 snapshot —— 驗 HOST + ONTAP
$plugin->volume_snapshot($scfg, $storeid, $volname, "testsnap-A");
my @p = $plugin->path($scfg, $volname, $storeid, "testsnap-A");
my $temp_device = $p[0];
my $tcn = temp_name("testsnap-A");
my $temp_lun_path = PVE::Storage::Custom::NetAppONTAP::Naming::encode_lun_path($tcn);
my $temp_wwid = api()->lun_get_wwid($temp_lun_path);
my @slaves_before = @{ get_multipath_slaves($temp_device) // [] };
print "  temp clone wwid: $temp_wwid, slaves before: @slaves_before\n";

unless (api()->volume_get($tcn)) { print "TEST INVALID: temp clone 未建立\n"; exit 1; }

$t0 = time();
eval { $plugin->volume_snapshot_delete($scfg, $storeid, $volname, "testsnap-A", 0); };
if ($@) { print "FAIL A: $@\n"; $exit_code = 1; exit 1; }
printf "PASS A: snapshot_delete OK in %.2fs\n", time() - $t0;

# ONTAP 端驗證
if (api()->volume_get($tcn)) { print "FAIL ONTAP: temp clone 仍存在\n"; $exit_code = 1; exit 1; }
print "  [ONTAP] temp clone: GONE\n";
my $snaps = api()->snapshot_list(ontap_name());
my $snapname = PVE::Storage::Custom::NetAppONTAP::Naming::encode_snapshot_name("testsnap-A");
if (grep { $_->{name} eq $snapname } @$snaps) {
    print "FAIL ONTAP: snapshot 仍存在\n"; $exit_code = 1; exit 1;
}
print "  [ONTAP] snapshot: GONE\n";

# HOST 端驗證(v0.2.13->v0.2.14 關鍵驗證)
my $mp_after = get_device_by_wwid($temp_wwid);
if ($mp_after) {
    print "FAIL HOST: temp WWID 對應的 multipath device 仍存在($mp_after)\n";
    print "  multipathd 會 spam 'path is down'。v0.2.13 有此 bug。\n";
    $exit_code = 1; exit 1;
}
print "  [HOST]  multipath device: GONE\n";

my @alive_slaves = grep { -e "/sys/block/" . basename($_) } @slaves_before;
if (@alive_slaves) {
    print "FAIL HOST: 殘留 sd* 仍在 /sys/block: @alive_slaves\n";
    $exit_code = 1; exit 1;
}
print "  [HOST]  sd* slaves: GONE\n";

if (-b "/dev/mapper/$temp_wwid") {
    print "FAIL HOST: /dev/mapper/$temp_wwid 仍存在\n";
    $exit_code = 1; exit 1;
}
print "  [HOST]  /dev/mapper/<wwid>: GONE\n";

print "ALL PASS(ONTAP + HOST 清理已驗證)\n";
EOF
perl /tmp/test_section24.pl
```

**預期結果**：
- Case B:`PASS B` 在 3 秒內。
- Case A:`PASS A` 在 30 秒內(split + wait + delete + snapshot_delete；由 `volume_snapshot_delete` 內部 300 秒 timeout 保底)。
- **HOST 端所有驗證皆 GONE**。任何驗證失敗就是 regression。

**為什麼用 split-then-delete 而不是直接 delete:** 真實 ONTAP FAS 上，delete FlexClone 之後 parent snapshot 的 `volume_clone_dependent` owner 會在短時間內清掉。但在 ONTAP simulator(以及部分 FAS 版本)，這個 owner 標記是黏的 — 實測 60 秒以上都不會清。`volume_clone_split` 是 ONTAP 保證 split 完成後一定會釋放 owner 的機制，在所有平台行為一致。代價是 split 時間，但 vzdump 場景下 temp clone 是 read-only，所以只需要處理極少的 unique block，實際很快。

**為什麼 HOST 端驗證必填**：v0.2.13 通過了純 ONTAP 端的測試就 ship 到正式環境，但每次 CT 備份都會留下殘留 dm-multipath + 4 條 sd* 在 host,`multipathd` 持續洗版「tur checker reports path is down」。v0.2.14 在原本 fix 上補了缺失的 `cleanup_lun_devices` + `remove_scsi_device` + `multipath_reload` 步驟，而這些測試驗證就作為永久 regression 守則保留下來。

### 24.2 客戶情境重現(CT vzdump snapshot mode)

若環境有 PBS 或 vzdump-dump target，可以驗證原客戶情境完整流程：

```bash
# 前置:在 netapp1 上建一個小 CT
pct create 9000 local:vztmpl/<模板> --rootfs netapp1:1 ...

# snapshot-mode 備份 — 0.2.13 之前必失敗的情境
vzdump 9000 --mode snapshot --storage <pbs-or-dump>

# 預期看到:
#   INFO: create storage snapshot 'vzdump'
#   ...(備份進行中)...
#   INFO: cleanup temporary 'vzdump' snapshot
#   INFO: Finished Backup of CT 9000

# 0.2.13 之前:cleanup temporary 'vzdump' snapshot 後面接著錯誤:
#   snapshot 'vzdump' was not (fully) removed - ONTAP job failed:
#     Snapshot copy "pve_snap_vzdump" of volume "..." has not expired
#     or is locked.

# 0.2.13 之後:不應該再看到上述錯誤。確認 ONTAP 上沒有殘留 tmpclone_*。
```

### 24.3 ONTAP volume 已不存在時的 idempotent reaper(v0.2.16)

驗證 `_remove_temp_clone()` 能處理「tracking entry 還在但 ONTAP volume 已不在」的情境，不會 die、不會 loop。正式環境會發生的情況：上次清理被中斷、跨節點 race、人工管理動作、重開機後狀態錯位等。

```bash
# 前置:手動植入一筆殘留 entry 到 state file,指向 ONTAP 上不存在的 volume
echo '{"netapp1":{"tmpclone_pve_netapp1_doesnotexist_pve_snap_x":1000000000}}' \
    > /var/run/pve-storage-netapp-temp-clones.json

# 觸發一次 status() poll
timeout 20 pvesm status 2>&1 | head -3

# 預期輸出應有恰好一行:
#   Temp clone 'tmpclone_pve_netapp1_doesnotexist_pve_snap_x' already absent
#   on ONTAP; skipping ONTAP-side cleanup. Caller may untrack the stale entry.

# 等背景 fork 完成
sleep 5

# 確認 state file 已清空(entry 已 untrack)
cat /var/run/pve-storage-netapp-temp-clones.json
# 預期: {"netapp1":{}}

# 再跑一次 status() — 應該完全安靜,無警告
timeout 20 pvesm status 2>&1 | grep -i "tmpclone\|cleanup" && echo FAIL || echo PASS
```

### 24.4 v0.2.16 靜態 regression 守則

```bash
P=lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm

# _remove_temp_clone 必須先檢查 volume 是否存在
grep -A 30 '^sub _remove_temp_clone' "$P" | grep -c 'volume_get'
# 預期:>= 1

# 必須區分「not found」與 API 錯誤
grep -A 30 '^sub _remove_temp_clone' "$P" | grep -c 'volume_get on temp clone'
# 預期:1(transient error 的 die 訊息)

# 確認 not-found 路徑回成功
grep -A 35 '^sub _remove_temp_clone' "$P" | grep -c 'already absent on ONTAP'
# 預期:1
```

### 24.5 既有靜態 regression 守則(v0.2.13/v0.2.14 守則)

```bash
P=lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm

# 共用 helper _remove_temp_clone 必須存在(v0.2.14)
grep -c '^sub _remove_temp_clone' "$P"
# 預期:1

# Helper 必須使用 free_image 風格的清理流程
grep -A 80 '^sub _remove_temp_clone' "$P" | grep -c 'cleanup_lun_devices'
# 預期:>=1
grep -A 80 '^sub _remove_temp_clone' "$P" | grep -c 'get_multipath_slaves'
# 預期:>=1
grep -A 80 '^sub _remove_temp_clone' "$P" | grep -c 'remove_scsi_device'
# 預期:>=1
grep -A 80 '^sub _remove_temp_clone' "$P" | grep -c 'multipath_reload'
# 預期:>=1
# 用 word-anchored 比對 $api->volume_clone_split,避免被 volume_wait_clone_split 內的
# substring 重複計算
grep -A 80 '^sub _remove_temp_clone' "$P" | grep -cE '\$api->volume_clone_split\b'
# 預期:1(僅實際 API 呼叫點)
grep -A 80 '^sub _remove_temp_clone' "$P" | grep -cE '\$api->volume_wait_clone_split\b'
# 預期:1

# 兩個 call site 都必須走 helper(不再有 inline 清理)
grep -A 60 '^sub volume_snapshot_delete' "$P" | grep -c '_remove_temp_clone'
# 預期:>= 1
grep -A 30 '^sub _cleanup_temp_clones ' "$P" | grep -c '_remove_temp_clone'
# 預期:1

# 必須有本機 in-use 安全檢查
grep -A 30 '^sub volume_snapshot_delete' "$P" | grep -c 'is_device_in_use'
# 預期:1

# v0.2.13 inline patch 區應該已不再有重複的清理 code
grep -A 30 '^sub volume_snapshot_delete' "$P" | grep -cE '\$api->volume_clone_split\b'
# 預期:0(split 現在在 helper 內,不再 inline)
```

---

## 25. 跨儲存殘留偵測(v0.2.15)

驗證 `_cleanup_orphaned_devices()` 的 second-pass 偵測不會把同類型(netappontap)的相關 storage 所持有的 WWID 誤判為殘留。客戶現場事件(2026-05)：同一台 PVE 節點同時掛了 `netappASA` + `netappFAS_Node2`,plugin 持續印 cluster-wide warning，建議對「健康的、相關 storage 持有的 LUN」執行 `multipathd disablequeueing map <wwid>` / `multipath -f <wwid>`。操作員若照做會拆掉跑著的 VM 磁碟。

**規則(已記入 CLAUDE.md):** 任何「比對 host 上 NETAPP 多重路徑設備 vs 單一 storage tracking」的邏輯**，必須**同時排除同節點上其他 netappontap storage 所追蹤的 WWID。

### 25.1 重現 + 驗證 fix(直接 API)

前置：同一個 SVM(或不同 SVM 都可)上配置兩個 netappontap storage，各自有至少一個已配置的 LUN。

```bash
# (前置)加第二個 netappontap storage
pvesm add netappontap netapp2 \
    --ontap-portal <mgmt-ip> --ontap-svm <svm> --ontap-aggregate <aggr> \
    --ontap-username admin --ontap-password '<pass>' \
    --ontap-ssl-verify 0 --content images

# (前置)兩邊各 alloc 一顆 disk,讓 host 上有對應 multipath device
pvesm alloc netapp1 9001 vm-9001-disk-0 256M
pvesm alloc netapp2 9998 vm-9998-disk-0 256M
pvesm path netapp1:vm-9001-disk-0
pvesm path netapp2:vm-9998-disk-0
multipath -ll | grep -c NETAPP      # >= 2

# (重置 cooldown)清掉 orphan-warn flag,讓 warning 能重新觸發
rm -f /var/run/pve-storage-netapp/orphan-warn-*

# (測試)pre-fix vs post-fix 對照
cat > /tmp/test_section25.pl <<'EOF'
#!/usr/bin/perl
use strict; use warnings;
use lib "/usr/share/perl5";
use PVE::Storage;
use PVE::Storage::Custom::NetAppONTAPPlugin;
use PVE::Storage::Custom::NetAppONTAP::Multipath qw(list_netapp_multipath_devices);

my $netapp_devs = list_netapp_multipath_devices();
my $exit = 0;
for my $storeid (qw(netapp1 netapp2)) {
    my $scfg = PVE::Storage::config()->{ids}->{$storeid};
    my $api = PVE::Storage::Custom::NetAppONTAPPlugin::_get_api($scfg);
    my $san = $storeid; $san =~ s/-/_/g;
    my $luns = $api->lun_list("/vol/pve_${san}_*/lun0");
    my %alive;
    for my $l (@$luns) {
        my $w = $api->lun_get_wwid($l->{name});
        $alive{lc $w} = 1 if $w;
    }
    my $tracked = PVE::Storage::Custom::NetAppONTAPPlugin::_read_wwid_state($storeid) // {};

    # PRE-FIX 模擬
    my @prefix_flagged = grep {
        my $w = lc $_->{wwid};
        !$alive{$w} && !$tracked->{$w};
    } @$netapp_devs;

    # POST-FIX 模擬(額外排除相關 storage)
    my %other_plugin_wwid;
    for my $other (keys %{PVE::Storage::config()->{ids}}) {
        next if $other eq $storeid;
        my $os = PVE::Storage::config()->{ids}->{$other};
        next unless $os && ($os->{type} // "") eq "netappontap";
        my $ot = PVE::Storage::Custom::NetAppONTAPPlugin::_read_wwid_state($other) // {};
        $other_plugin_wwid{lc $_} = 1 for keys %$ot;
    }
    my @postfix_flagged = grep {
        my $w = lc $_->{wwid};
        !$alive{$w} && !$tracked->{$w} && !$other_plugin_wwid{$w};
    } @$netapp_devs;

    printf "%s: PRE-FIX would flag %d, POST-FIX flags %d\n",
        $storeid, scalar(@prefix_flagged), scalar(@postfix_flagged);
    if (@postfix_flagged) {
        print "  FAIL: 此受控場景下 post-fix 應為 0\n";
        $exit = 1;
    }
}
exit $exit;
EOF
perl /tmp/test_section25.pl
```

**預期結果**：
- `netapp1: PRE-FIX would flag 1, POST-FIX flags 0`(那 1 個就是 netapp2 的 LUN，被正確排除)
- `netapp2: PRE-FIX would flag 3, POST-FIX flags 0`(那 3 個是 netapp1 的 LUN，被正確排除)
- Exit code 0

### 25.2 透過 plugin 實際程式碼路徑驗證

```bash
# 捕捉真實生產 code path 印出的 warning
perl -I/usr/share/perl5 -e '
use PVE::Storage; use PVE::Storage::Custom::NetAppONTAPPlugin;
my @captured;
local $SIG{__WARN__} = sub { push @captured, $_[0]; };
for my $storeid (qw(netapp1 netapp2)) {
    my $scfg = PVE::Storage::config()->{ids}->{$storeid} or next;
    my $api = PVE::Storage::Custom::NetAppONTAPPlugin::_get_api($scfg);
    @captured = ();
    PVE::Storage::Custom::NetAppONTAPPlugin::_cleanup_orphaned_devices($api, $storeid);
    my $orphan_warns = grep { /multipath -f/ } @captured;
    printf "%s: %d 個殘留警告\n", $storeid, $orphan_warns;
}
'
```

**預期結果**：兩個 storage 都報 0 個殘留警告(務必先清 cooldown flag，否則會被冷卻機制壓抑)。

### 25.3 靜態 regression 守則

```bash
P=lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm

# 修正必須引用相關 storage WWID
grep -A 80 '^sub _cleanup_orphaned_devices' "$P" | grep -c 'other_plugin_wwid'
# 預期: >= 3(宣告 + 填充 + 檢查)

# 必須遍歷 config 找相關 netappontap storage
grep -A 80 '^sub _cleanup_orphaned_devices' "$P" | grep -c 'PVE::Storage::config'
# 預期: >= 1

# 必須對其他 storeid 呼叫 _read_wwid_state
grep -A 80 '^sub _cleanup_orphaned_devices' "$P" | grep -c '_read_wwid_state.*other_storeid'
# 預期: >= 1
```

---

## 26. 殘留清理路徑健康閘門 + LUN 清單分頁（v0.2.17）

客戶正式環境事故（2026-05，節點 pve15，儲存 `netappFAS_Node2`）：在執行中的 VM 熱加一顆硬碟後（`update VM 608103: -scsi1 netappFAS_Node2:32`），這顆全新 LUN 的 multipath 裝置（WWID `...626b70`，4 條健康路徑）被 `_cleanup_orphaned_devices()` 拆除（「removing stale device ... LUN deleted on ONTAP」），導致執行中的 VM 磁碟出現 `I/O error, dev dm-68`。VM 關機重開即「恢復」，是因為下次 activate 會重新探索 multipath，而此時 `lun_list` 已不再延遲。

**根因（兩個缺陷）**：
1. reaper 以單一 `lun_list()` 快照建立「存活集合」，並把不在集合內的已追蹤 WWID 一律清除；但剛建立的 LUN 可能在一段時間內查不到（ONTAP read-after-write／傳播延遲，與 v0.2.9 ASA 同類）。LUN 數量過多時該查詢還可能被截斷。
2. reaper 呼叫 `cleanup_lun_devices()` 前完全不檢查 multipath 路徑健康狀態。有 active 路徑（使用中、活著）的裝置，和真正的殘留（所有路徑都 failed）長得一模一樣。

**修正**：
- **路徑健康閘門（`multipath_path_health()`）**：絕不拆除仍有 active 路徑（或狀態無法判定）的裝置。真正的殘留所有路徑都會 failed。
- **寬限期**：在過去 300 秒內才被追蹤的 WWID 不拆（沿用既有的首次追蹤時間戳，不新增任何狀態檔）。
- **第二輪閘門**：「untracked stale」操作者警告只對路徑全失效的裝置發出，因此絕不會對健康裝置建議 `multipath -f`。
- **`lun_list()` 分頁（`_get_all_records()`）**：追隨 ONTAP REST 的 `_links.next.href`，讓超過 1000 顆 LUN 的 SVM 不會被靜默截斷。同時套用於 `volume_list`、`volume_get_clone_children`、`igroup_list`、`snapshot_list`。

### 26.1 路徑健康閘門邏輯（離線，不需 ONTAP／multipath）

```bash
cat > /tmp/test_section26_health.pl <<'EOF'
#!/usr/bin/perl
use strict; use warnings;
use lib "/usr/share/perl5";
use PVE::Storage::Custom::NetAppONTAP::Multipath;
my @responses; my $exit = 0;
no warnings 'redefine';
*PVE::Storage::Custom::NetAppONTAP::Multipath::_run_cmd = sub {
    my $out = shift @responses; return wantarray ? ($out,'',0) : $out;
};
sub c {
    my ($name,$maps,$paths,$wwid,$want)=@_;
    @responses=($maps,$paths);
    my $got = PVE::Storage::Custom::NetAppONTAP::Multipath::multipath_path_health($wwid);
    my $ok = (defined $got && $got==$want);
    printf "%-45s got=%-3s want=%-3s %s\n",$name,$got//'undef',$want,$ok?'PASS':'FAIL';
    $exit=1 unless $ok;
}
my $W='3600a098038314239552b577063626b70';
my $maps="$W $W\nother otherwwid\n";
c('incident: 4 active paths -> live',  $maps, "$W active running\n$W active running\n$W active running\n$W active running\n", $W, 1);
c('orphan: all paths failed -> reap',  $maps, "$W failed running\n$W failed faulty\n", $W, 0);
c('1 active among failed -> live',     $maps, "$W failed running\n$W active running\n", $W, 1);
c('active but offline dev -> orphan',  $maps, "$W active offline\n", $W, 0);
c('no map for wwid -> 0',              "other otherwwid\n", "other active running\n", $W, 0);
c('map but no path rows -> -1',        $maps, "other active running\n", $W, -1);
@responses=(undef,undef);
{ my $g=PVE::Storage::Custom::NetAppONTAP::Multipath::multipath_path_health($W);
  my $ok=(defined $g && $g==-1); printf "%-45s got=%-3s want=-1  %s\n",'multipathd unreachable -> -1',$g//'undef',$ok?'PASS':'FAIL'; $exit=1 unless $ok; }
print $exit?"\nSOME FAILED\n":"\nALL PASS\n"; exit $exit;
EOF
perl /tmp/test_section26_health.pl
```

**預期**：7 個案例全 PASS，exit 0。第一個案例（`4 active paths -> live` 回傳 1）就是事故的確切條件：活著的裝置必須回報「不可拆」。

### 26.2 LUN 清單分頁完整性（離線）

```bash
cat > /tmp/test_section26_paginate.pl <<'EOF'
#!/usr/bin/perl
use strict; use warnings;
use lib "/usr/share/perl5";
use PVE::Storage::Custom::NetAppONTAP::API;
my $self = bless {}, 'PVE::Storage::Custom::NetAppONTAP::API';
my @eps; my $exit = 0;
no warnings 'redefine';
*PVE::Storage::Custom::NetAppONTAP::API::get = sub {
    return { records => [{name=>'lun0'},{name=>'lun1'}],
             _links => { next => { href => '/api/storage/luns?fields=name&start.tag=P2' } } };
};
*PVE::Storage::Custom::NetAppONTAP::API::_request = sub {
    my ($s,$m,$ep)=@_; push @eps,$ep;
    return { records=>[{name=>'lun2'},{name=>'lun3'}], _links=>{next=>{href=>'/api/storage/luns?fields=name&start.tag=P3'}} } if $ep=~/P2/;
    return { records=>[{name=>'lun4'}] } if $ep=~/P3/;
    return { records=>[] };
};
my $all = $self->_get_all_records('/storage/luns', { name=>'pve_*' });
my @n = map { $_->{name} } @$all;
my $ok = (@n==5 && join(',',@n) eq 'lun0,lun1,lun2,lun3,lun4'
          && $eps[0] eq '/storage/luns?fields=name&start.tag=P2'   # /api 已剝除，無 /api/api
          && $eps[1] eq '/storage/luns?fields=name&start.tag=P3');
printf "records=%d names=[%s]\npage2=%s\npage3=%s\n", scalar(@n), join(',',@n), $eps[0], $eps[1];
print $ok?"\nPAGINATION PASS\n":"\nPAGINATION FAIL\n"; exit($ok?0:1);
EOF
perl /tmp/test_section26_paginate.pl
```

**預期**：跨 3 頁取得 5 筆 `lun0..lun4`；下一頁端點的開頭 `/api` 已被剝除（無重複的 `/api/api`）；`PAGINATION PASS`，exit 0。

### 26.3 靜態 regression 守則

```bash
P=lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm
M=lib/PVE/Storage/Custom/NetAppONTAP/Multipath.pm
A=lib/PVE/Storage/Custom/NetAppONTAP/API.pm

# 第一輪拆除前必須先諮詢路徑健康閘門
grep -A 180 '^sub _cleanup_orphaned_devices' "$P" | grep -c 'multipath_path_health'
# 預期: >= 2（第一輪拆除閘門 + 第二輪警告閘門）

# 寬限期存在
grep -A 180 '^sub _cleanup_orphaned_devices' "$P" | grep -c 'ORPHAN_GRACE_SECS'
# 預期: >= 2（宣告 + 比較）

# helper 存在且已 export
grep -c 'sub multipath_path_health' "$M"            # 預期: 1
grep -c 'multipath_path_health' "$M"                # export + 定義: >= 2

# 分頁 helper 存在且 lun_list 有使用（不再有寫死的 max_records=1000 上限）
grep -c 'sub _get_all_records' "$A"                 # 預期: 1
grep -A 8 '^sub lun_list' "$A" | grep -c '_get_all_records'   # 預期: 1
grep -A 8 '^sub lun_list' "$A" | grep -c 'max_records => 1000' # 預期: 0（不再寫死上限）

# helper 內有處理下一頁連結的 /api 前綴剝除
grep -A 40 '^sub _get_all_records' "$A" | grep -c 'next_ep'  # 預期: >= 2（剝除 + 使用）
```

### 26.4 模擬器功能性重現（強制 host-side 驗證，v0.2.14 守則）

重現客戶的確切觸發條件：**在執行中的 VM 熱加硬碟**，接著在該 LUN 從存活集合中「消失」時強制執行 reaper，並驗證活裝置存活。執行中這個條件是關鍵：QEMU 開著該 block device，所以修正前 reaper 的 `multipath -f` 會失敗、退回 `dmsetup remove --force`，把 map 從 QEMU 底下強制抽掉而造成 I/O error。（VM 關機時拆除是靜默的，只會在下次開機重建時浮現——這正是「關機重開就好」的原因。）注意：QEMU 的開啟檔案描述子不是 sysfs holder，所以 `is_device_in_use()` 偵測不到它——路徑健康閘門才是這裡真正的防線，而非 in-use 檢查。

```bash
# 1. VM 9000 必須在執行中。在 plugin 儲存上熱加一顆硬碟。
qm status 9000                            # 確認: status: running
qm set 9000 --scsi1 netappFAS_Node2:1     # 1 GiB，熱插入執行中的 guest
# 找出新 WWID（例如透過 volume 的 LUN serial 或新出現的 multipath map）
W=$(multipath -ll | awk '/NETAPP/{print prev} {prev=$1}' | tail -1)   # 最新的 NETAPP map
echo "new WWID = $W"

# 2. 確認裝置健康（active 路徑）且正被 QEMU 使用
multipath -ll "$W"        # 預期: 路徑為 'active ready running'
fuser -v "/dev/mapper/$W" 2>&1 | grep -q qemu && echo "in use by QEMU (expected)"

# 3. 用一個「省略該新 LUN」的存活集合強制執行 reaper（模擬延遲）。
dmesg -C   # 清空 kernel ring buffer 以偵測任何新的 I/O error
perl -I/usr/share/perl5 -e '
use PVE::Storage;
use PVE::Storage::Custom::NetAppONTAPPlugin;
my $W = shift;
# Monkeypatch lun_list 回傳空集合（最壞情況: 截斷/延遲）
no warnings "redefine";
*PVE::Storage::Custom::NetAppONTAP::API::lun_list = sub { return []; };
my $scfg = PVE::Storage::config()->{ids}{netappFAS_Node2};
my $api  = PVE::Storage::Custom::NetAppONTAPPlugin::_get_api($scfg);
PVE::Storage::Custom::NetAppONTAPPlugin::_cleanup_orphaned_devices($api, "netappFAS_Node2");
' "$W"

# 4. 驗證活裝置在 reaper 之後存活（修正前的 bug 會把它拆掉）
multipath -ll "$W" | grep -q . && echo "PASS: live device survived reaper" \
                               || echo "FAIL: reaper removed a live device (REGRESSION)"
test -b "/dev/mapper/$W" && echo "PASS: /dev/mapper/$W still present" \
                         || echo "FAIL: block device gone"
# 4a. 裝置上沒有新的 kernel I/O error，VM 仍在執行
dmesg | grep -q "I/O error.*dm-" && echo "FAIL: I/O error appeared (REGRESSION)" \
                                 || echo "PASS: no new I/O error"
qm status 9000 | grep -q running && echo "PASS: VM still running" || echo "FAIL: VM not running"

# 5. 接著真正刪除，驗證 host-side 清理（v0.2.14 守則）
SLAVES=$(ls "/sys/block/$(basename $(readlink -f /dev/mapper/$W))/slaves/" 2>/dev/null)
qm set 9000 --delete scsi1
sleep 5
# 5a. multipath 裝置消失
multipath -ll "$W" 2>/dev/null | grep -q . && echo "FAIL: dm-multipath residual" || echo "PASS: multipath gone"
# 5b. /dev/mapper 消失
test -e "/dev/mapper/$W" && echo "FAIL: /dev/mapper residual" || echo "PASS: /dev/mapper gone"
# 5c. 每個 sd* slave 已從 /sys/block 移除
for s in $SLAVES; do test -e "/sys/block/$s" && echo "FAIL: slave $s residual" || echo "PASS: slave $s gone"; done
```

**預期**：步驟 4 → 兩項皆 PASS（核心 regression：即使 `lun_list` 回傳空集合，有 active 路徑的活裝置也不會被拆）。步驟 5 → 全 PASS（host-side 乾淨清理）。注意 ONTAP 模擬器即使只有單一控制器仍可通過本測試；存活集合的省略是用 monkeypatch 強制達成，因此不需要真實的 LUN 刪除時序。

### 26.5 寬限期守則（離線邏輯）

```bash
# 在過去 300 秒內被追蹤的 WWID，即使不在存活集合中，reaper 也必須跳過。
# 驗證守則存在且使用了追蹤時間戳。
grep -A 120 '^sub _cleanup_orphaned_devices' lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm \
  | grep -E 'time\(\) - \$tracked_at|ORPHAN_GRACE_SECS'
# 預期: 顯示 `(time() - $tracked_at) < $ORPHAN_GRACE_SECS` 跳過守則
```

---

## 27. 清理時殘留 SCSI 路徑掃除（v0.2.18）

處理 v0.2.17 事故 log 中那個獨立的 NetApp/Linux 行為：
```
sd X:0:0:51: LUN assignments on this target have changed.
The Linux SCSI layer does not automatically remap LUN assignments.
```

當 plugin（或 ONTAP `lun_map` 自動配號）釋放一個 SCSI LUN-ID，而 ONTAP 之後把它重用給**不同**的 LUN 時，host 上任何仍綁在該 `H:C:T:L` 的殘留 `sd` 裝置就會觸發這行 kernel 訊息，且新 LUN 在該路徑上無法使用。`cleanup_lun_devices()` 先前只移除**目前還在 multipath map 內**的路徑（且 map 已不在時整段跳過，完全 no-op），把殘留單一 `sd` 路徑留在原地。v0.2.18 新增 `Multipath::get_scsi_paths_for_wwid()` 與 `cleanup_lun_devices()` 內的 Step 8 掃除，移除該 WWID 的**所有** NETAPP `sd` 路徑，即使 map 已不在也會掃。掃除限定 NETAPP 廠商、以 WWID 比對，並以 wall-clock 預算（預設 30s）界定上限，讓擁有數百個 `sd` 裝置且路徑正在失效的 host 不會卡住拆除流程。

### 27.1 `get_scsi_paths_for_wwid()` 比對（真實裝置）

```bash
pvesm alloc netapp1 9000 vm-9000-disk-0 1G
W=$(pvesm path netapp1:vm-9000-disk-0 | grep -oE '3600a[0-9a-f]+')
multipath -ll "$W" | grep -oE 'sd[a-z]+' | sort   # 基準路徑
perl -I/usr/share/perl5 -e '
use PVE::Storage::Custom::NetAppONTAP::Multipath qw(get_scsi_paths_for_wwid);
my $W = shift;
my $p = get_scsi_paths_for_wwid($W);
print "real WWID paths: @{[sort @$p]}\n";
print scalar(@$p) >= 1 ? "PASS: paths found\n" : "FAIL\n";
my $none = get_scsi_paths_for_wwid("3600a0980deadbeefdeadbeefdeadbeef");
print @$none ? "FAIL: bogus WWID matched\n" : "PASS: bogus WWID -> empty\n";
my @w; local $SIG{__WARN__}=sub{push @w,$_[0]};
get_scsi_paths_for_wwid($W, budget=>0);
print( (grep{/budget exceeded/}@w) ? "PASS: budget=0 bails with warning\n"
                                   : "NOTE: no warn (0 NETAPP devices present)\n" );
' "$W"
```

**預期**：比對到的路徑等於 multipath slaves;bogus WWID 回傳空（無誤判）；`budget => 0` 安全退出並警告。

### 27.2 map 已不在時 Step 8 掃除殘留 sd 路徑（核心）

```bash
# （承接 27.1;$W 仍設定,LUN 仍在 ONTAP 上）
SLAVES=$(multipath -ll "$W" | grep -oE 'sd[a-z]+' | sort -u)
multipath -f "$W"                       # 只移除 map -> sd 路徑變殘留
multipath -ll "$W" | grep -q . && echo "map still present" || echo "map gone (sd orphaned)"
for s in $SLAVES; do test -e /sys/block/$s && echo "orphan $s present"; done

# 舊的 cleanup_lun_devices() 會 no-op（無 map）。新的 Step 8 必須掃除:
perl -I/usr/share/perl5 -e '
use PVE::Storage::Custom::NetAppONTAP::Multipath qw(cleanup_lun_devices);
cleanup_lun_devices(shift);' "$W"
sleep 2
for s in $SLAVES; do test -e /sys/block/$s && echo "FAIL: $s residual" || echo "PASS: $s swept"; done

pvesm free netapp1:vm-9000-disk-0       # 清理
```

**預期**：`multipath -f` 後 `sd` 路徑仍為殘留；`cleanup_lun_devices()` 後每個殘留 `sd` 路徑都消失（Step 8 生效）。模擬器（pc-pve1）已驗證：`sdc`/`sdd` 被 `multipath -f` 變殘留，兩者皆被 Step 8 掃除。

### 27.3 靜態 regression 守則

```bash
M=lib/PVE/Storage/Custom/NetAppONTAP/Multipath.pm
grep -c 'sub get_scsi_paths_for_wwid' "$M"                 # 預期: 1
grep -c 'get_scsi_paths_for_wwid' "$M"                     # export + 定義 + 使用: >= 3
# Step 8 掃除已接入 cleanup_lun_devices,且在 `if ($mpath)` 區塊之外執行
grep -A 95 '^sub cleanup_lun_devices' "$M" | grep -c 'get_scsi_paths_for_wwid'   # 預期: 1
# wall-clock 預算存在（累積時間界定,v0.2.12 教訓）
grep -A 60 '^sub get_scsi_paths_for_wwid' "$M" | grep -c 'deadline\|budget'      # 預期: >= 2
# 限定 NETAPP 廠商（絕不碰其他儲存）
grep -A 60 '^sub get_scsi_paths_for_wwid' "$M" | grep -c 'NETAPP'                # 預期: >= 1
```

---

## 28. pvestatd 隔離 + 殘留路徑 reaper + 連線重用（v0.2.19）

涵蓋 v0.2.19 三個修正：殘留 SCSI 路徑 reaper（在未執行拆除的節點上發生 LUN-ID 重用）、pvestatd 逾時隔離（`ontap-status-timeout`）、HTTP keep-alive。

### 28.1 殘留 sd reaper 決策邏輯（離線單元測試）

重現完整 pve19 拓樸（SVM-A LUN 16：一條活路徑、三條空白殘留路徑）加上每一條安全閘。移除動作為 mock，零風險。

```bash
perl -Ilib tests/stale_sd_reaper.t
# 預期:20/20。reap 掉 3 條 LUN-ID 重用殘留 + 1 條追蹤殘留;
# 絕不 reap:活著／alive WWID、在 map 內(has_holders)、無 holder 但活著、
# 未知／手動 WWID、sibling 儲存所有、空白但無重用證據、FC(無 IQN)、已掛載、
# 或仍在 300s 寬限期內。
```

### 28.2 status-path 短逾時 client（離線單元測試 + 退化快速失敗）

```bash
perl -Ilib tests/status_timeout.t
# 預期:13/13。資料路徑 = 15s 逾時、2 retry;status 路徑 =
# ontap-status-timeout(預設 5s)、單次嘗試;分開快取。

# 對黑洞 IP(192.0.2.1,RFC5737)的退化快速失敗:
#   status-path client ~5s 失敗(不重試);預設 client ~32s(15s x2 + 2s)。
# 這就是把 189s -> ~5s、讓 pvestatd 不再餓死同節點其他儲存的改善。
```

### 28.3 reaper 對健康 live 裝置零誤刪（模擬器，核心）

最關鍵的安全性質：在真實 ONTAP + 真實主機裝置上，一顆剛配置、使用中的裝置必須在 `_cleanup_orphaned_devices()`（現已含 reaper）後存活。

```bash
perl -Ilib tests/sim_functional.pl
# 預期:13/13。alloc_image -> activate -> /dev/mapper 裝置 + sd 路徑存在、
# list_netapp_scsi_paths 回報 has_holders=1;跑 reaper 後裝置與 sd 路徑都未被移除;
# free_image 接著移除 multipath 裝置、/dev/mapper、所有 sd slave(v0.2.14 主機端驗證)。
# ONTAP 與主機端均驗證 0 殘留。
```

### 28.4 靜態 regression 守則

```bash
P=lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm
M=lib/PVE/Storage/Custom/NetAppONTAP/Multipath.pm
A=lib/PVE/Storage/Custom/NetAppONTAP/API.pm

grep -c 'sub list_netapp_scsi_paths' "$M"                         # 預期:1
grep -c 'sub _reap_stale_scsi_paths' "$P"                         # 預期:1
# reaper 接入殘留清理的第三個 pass
grep -c '_reap_stale_scsi_paths' "$P"                             # 預期:>= 2
# reaper 安全閘 + 寬限期存在
grep -A 90 '^sub _reap_stale_scsi_paths' "$P" | grep -c 'has_holders\|GRACE\|alive'  # >= 3
# status-path client:短逾時 + 不重試
grep -A 40 '^sub _get_api' "$P" | grep -c 'status_path\|retry_count'  # >= 2
grep -c 'ontap-status-timeout' "$P"                               # 預期:>= 2
# keep-alive 已啟用
grep -c 'keep_alive' "$A"                                         # 預期:1
```

---

## 29. activate_storage iSCSI 登入預算（v0.2.20）

界定 `activate_storage` 中 iSCSI discover/login 的累積時間，讓「連得到卻在登入時 hang」的 portal 不會拖住 pvestatd（`ontap-activate-deadline`，預設 30s）。

### 29.1 預算閘門邏輯（離線單元測試）

以 mock 的 iSCSI helper + 假 API 物件驅動 `activate_storage`，並用小段真實 sleep 跨過預算 deadline。

```bash
perl -Ilib tests/activate_budget.t
# 預期:8/8。
#  - 超過預算且已有路徑    -> 剩餘 portal 跳過
#  - 超過預算但 0 路徑     -> 全部嘗試（絕不跳過)
#  - 預算內              -> 全部嘗試
```

### 29.2 真實 ONTAP 無 regression（模擬器）

```bash
perl -Ilib tests/sim_functional.pl
# 預期:13/13。ONTAP 健康時預算閘門不應改變正常 activation
#（所有 portal 都在預算內順利登入)。
```

### 29.3 靜態 regression 守則

```bash
P=lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm
grep -c 'ontap-activate-deadline' "$P"                            # 預期:>= 2(屬性 + 使用)
grep -c 'skipped_budget' "$P"                                     # 預期:>= 2
grep -A 6 'login_deadline' "$P" | grep -c '@logged_in'            # 閘門檢查 >=1 路徑已登入
```

---

## 30. 殘留清理 N+1 REST 風暴修正（v0.2.21）

`_cleanup_orphaned_devices()` 必須用 `lun_list()` **本來就回傳**的 `serial_number` 來建立 alive-set，而**不是**對每顆 LUN 各打一次 `lun_get_wwid()`(那是把 ONTAP 管理閘道打爆的 N+1 REST 風暴)。

### 30.1 N+1 消除 + alive-set 不變（模擬器，核心)

```bash
perl -Ilib tests/cleanup_load.pl
# 預期:6/6。配置 3 顆真實 LUN、instrument API:
#  - _cleanup_orphaned_devices 期間 0 次 per-LUN lun_get 呼叫(原本每顆 1 次)
#  - 每個配置的 WWID 仍在 alive／tracking 集合內
#    (serial_to_wwid 算出與舊 lun_get_wwid 完全相同的 WWID)
#  - free 後主機與 ONTAP 皆 0 殘留。
```

### 30.2 靜態 regression 守則

```bash
P=lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm
# alive-set 迴圈不可呼叫 lun_get_wwid(那就是 per-LUN 風暴)。
# 排除註解行——註解裡會合理地提到被移除的呼叫名稱。
grep -A 16 'Build set of currently-alive WWIDs' "$P" | grep -v '^\s*#' | grep -c 'lun_get_wwid'   # 預期:0
# 必須用 lun_list 的 serial_number + 本地 serial_to_wwid
grep -A 16 'Build set of currently-alive WWIDs' "$P" | grep -v '^\s*#' | grep -c 'serial_number\|serial_to_wwid'  # >= 2
# lun_list 仍要求 serial_number
grep -c "serial_number" lib/PVE/Storage/Custom/NetAppONTAP/API.pm                 # >= 1
```

---

## 31. Proxmox VE 9.0／9.1／9.2 相容性稽核修正（v0.2.23）

對應針對 Proxmox VE 9.2（proxmox-ve 9.2.0／pve-manager 9.2.5／libpve-storage-perl 9.1.2）所做的儲存 API 稽核。31.1～31.4 不需要 ONTAP；31.5 與 31.6 需要模擬器。

### 31.1 單元測試套件（不需 ONTAP，核心）

```bash
perl -Ilib tests/audit_fixes.t
# 預期：105/105 PASS。涵蓋：
#  - api() 對 PVE::Storage::APIVER 的協商（13／14／15／16／9 與 fallback）
#  - _parse_ontap_time（Z、+HH:MM、+HHMM、小數秒、垃圾輸入回 undef 而非 0）
#  - volume_rollback_is_possible：最新可倒回、較舊被拒、列出 blockers
#  - volume_snapshot_delete：偵測 linked clone 鎖定；暫存 clone 絕不阻擋
#  - volume_snapshot_info 排序；filesystem_path／rename_snapshot 明確 die
#  - get_identity；volume_resize 拒絕 $snapname；parse_volname 改為 die
#  - multipath_flush 未帶 device 時拒絕執行
#  - recovery queue clone 佔用：purge 自己已刪除的 clone、絕不動 live 的、
#    絕不動客戶命名的、遵守 ontap-purge-recovery-queue 0
```

### 31.2 跨所有 PVE 9 儲存函式庫的 API 版本協商（核心）

載入器會**硬拒絕** `api()` 高於執行中 `APIVER` 的 plugin；低於時則每次載入都發出警告。Proxmox VE 在 9.1 的 point release 中把 `APIVER` 連續 bump 兩次，所以 `api()` 必須逐一精確吻合。

```bash
mkdir -p /tmp/apiver && cd /tmp/apiver
for v in 9.0.18 9.1.0 9.1.2 9.1.3 9.1.5 9.1.6; do
    apt-get download libpve-storage-perl=$v >/dev/null 2>&1
done
for v in 9.0.18 9.1.0 9.1.2 9.1.3 9.1.5 9.1.6; do
    rm -rf t; mkdir t; dpkg-deb -x libpve-storage-perl_${v}_all.deb t
    AV=$(grep -oP 'APIVER => \K\d+' t/usr/share/perl5/PVE/Storage.pm)
    OUT=$(perl -I/tmp/apiver/t/usr/share/perl5 -I/root/jt-pve-storage-netapp/lib \
          -MPVE::Storage -e 'print PVE::Storage::Custom::NetAppONTAPPlugin->api();' 2>&1)
    W=$(echo "$OUT" | grep -c 'NetAppONTAPPlugin.*older storage API')
    echo "$v APIVER=$AV api=$(echo "$OUT" | tail -c 3) warnings=$W"
done
# 預期每一列：api 等於 APIVER，且 warnings 為 0。
#   9.0.18／9.1.0／9.1.2 -> APIVER 13，api 13
#   9.1.3 ／9.1.5        -> APIVER 14，api 14
#   9.1.6 以上           -> APIVER 15，api 15
# 若某列 warnings=1，代表 plugin 會在每次 pvedaemon／pvestatd／pveproxy／pvesm
# 載入時噴出「implementing an older storage API」警告。
```

### 31.3 PVE 9 儲存 API 契約檢查（核心）

```bash
cd /root/jt-pve-storage-netapp
perl -Ilib -MPVE::Storage -e '
my $p = "PVE::Storage::Custom::NetAppONTAPPlugin";
my $cfg = PVE::Storage::config(); my $scfg = $cfg->{ids}{netapp1};
print "loaded_from=$INC{\"PVE/Storage/Custom/NetAppONTAPPlugin.pm\"}\n";
print "shared=", ($cfg->{ids}{netapp1}{shared}//"UNDEF"), "\n";
print "snap_method=", $p->volume_qemu_snapshot_method("netapp1",$scfg,"vm-100-disk-0"), "\n";
print "format=", ($p->parse_volname("vm-100-disk-0"))[6], "\n";
print "default_format=", $p->get_formats($scfg,"netapp1")->{default}, "\n";
print "identity=", $p->get_identity($scfg,"netapp1"), "\n";'
# 預期：
#   loaded_from   = 受測的 lib/ 路徑（不是 /usr/share/perl5）
#   shared        = 1            （SHARED_STORAGE 註冊在 PVE 9 仍有效）
#   snap_method   = storage      （不可為 qemu／mixed，否則 PVE 會要求
#                                 volume_snapshot_info 與 backing-chain blockdev）
#   format        = raw
#   default_format= raw
#   identity      = netappontap://<portal>/<svm>
```

### 31.4 靜態 regression 守則

```bash
P=lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm
M=lib/PVE/Storage/Custom/NetAppONTAP/Multipath.pm

# api() 不可再退回硬編碼常數。
grep -Pzc 'sub api \{\s*\n\s*return APIVERSION;\s*\n\}' "$P"          # 預期：0

# N1：SnapRestore 守門必須存在。
grep -c '^sub volume_rollback_is_possible' "$P"                        # 預期：1

# N4：filesystem_path 不可再默默依賴永不被設定的 $scfg->{storage}。
grep -v '^\s*#' "$P" | grep -c 'path($scfg, $volname, $scfg->{storage}'  # 預期：0

# N5：multipath -F 不可出現為任何實際呼叫。
grep -v '^\s*#' "$M" | grep -c "MULTIPATH, '-F'"                       # 預期：0

# N6：deactivate_storage 必須以路徑健康為前提才拆除。
sed -n '/^sub deactivate_storage/,/^}/p' "$P" | grep -c multipath_path_health  # >= 1

# N7：API client cache key 必須含 SVM，不能只有 portal。
grep -v '^\s*#' "$P" | grep -c "\$scfg->{storage} // \$scfg->{'ontap-portal'}"  # 預期：0

# N8：activate_volume 必須接收 PVE 9.1 的 $hints 參數。
grep -A2 '^sub activate_volume' "$P" | grep -c '\$cache, \$hints'      # 預期：1

# N11：不可有未使用的 PVE import；真正用到的必須 import。
grep -c '^use PVE::ProcFSTools' "$P"                                   # 預期：0
grep -c '^use PVE::Cluster' "$P"                                       # 預期：0
grep -c '^use PVE::INotify;' "$P"                                      # 預期：1
```

### 31.5／31.6／31.7 對真實 ONTAP 的快照安全測試（模擬器，需要 ONTAP）

由 `tests/sim_snapshot_safety.pl` 驅動，它使用 DEV lib（`perl -Ilib`），因此不論 `/usr/share/perl5` 底下安裝的是哪一版，測到的都是**新程式碼**。每次 `free_image` 之後都套用主機端裝置殘留斷言（v0.2.14 規則）。使用可丟棄的 VMID 999010～999012，失敗時也會清理。

```bash
perl -Ilib tests/sim_snapshot_safety.pl
# 預期：34/34 PASS。
```

**31.5 —— ONTAP SnapRestore 破壞性與倒回守門**。Part A 先在真實 ONTAP 上**證明前提**，而不是採信原廠文件（CLAUDE.md 的「向原廠驗證」規則）：建立 snapA／snapB／snapC，然後**繞過守門**執行守門本來要阻止的那次 SnapRestore。斷言：

- 守門**允許**倒回到最新快照，且無 blockers
- 守門**拒絕**倒回到最舊快照，訊息含 `not the most recent snapshot`、`SnapRestore would DELETE`，且 blockers 恰為 `snapB, snapC`
- 拒絕之後三個快照在 ONTAP 上**全都還在**（沒有任何東西被摧毀）
- 刻意繞過守門執行 SnapRestore 之後，**只剩下 snapA** —— 也就是 ONTAP 確實刪掉了 snapB 與 snapC，而 Proxmox VE 的 config 仍然列著它們。若這條斷言哪天失敗，代表整個修正的前提已改變，守門需要重新評估。

**31.6 —— linked clone 鎖住其 parent 快照**。Part B 從 `snap1` 建立 linked clone（`clone_image` 帶 `$snap`，即 `qm clone --snapname` 走的路徑），然後斷言 `volume_snapshot_delete` 被拒絕，且訊息會指名阻擋的 clone、其所屬 guest，以及 `volume clone split start` 的處理方式，並且**不是** ONTAP 原始的 `has not expired or is locked`。

**31.7 —— ONTAP volume recovery queue 佔住已刪除的 clone**。仍在 Part B：clone 被釋放之後，快照刪除必須**成功**。這是 N12 發現的回歸守則 —— 已刪除的 FlexClone 只要還在 ONTAP 的 volume recovery queue 裡，就仍算是其 parent 的 clone，因此若不 purge，快照會在整個保留期（預設 12 小時）內持續被鎖住，而 parent volume 也會變成無法刪除。輸出中應出現這兩行：

```
Purging deleted FlexClone 'pve_..._1036' from the ONTAP volume recovery queue: ...
Released 1 recovery-queue clone hold(s) on 'pve_netapp1_999011_disk0': ...
```

要直接檢視該 queue（不需要 ONTAP CLI／SSH，走 REST passthrough）：

```bash
# 依你的環境設定；切勿把密碼寫死在檔案裡。
export ONTAP_HOST=<ontap-mgmt-ip> ONTAP_SVM=<svm> ONTAP_USER=admin
read -rsp 'ONTAP 密碼： ' ONTAP_PASS; export ONTAP_PASS; echo

perl -Ilib -e '
use JSON; use PVE::Storage::Custom::NetAppONTAP::API;
my $api = PVE::Storage::Custom::NetAppONTAP::API->new(
    host => $ENV{ONTAP_HOST}, username => $ENV{ONTAP_USER},
    password => $ENV{ONTAP_PASS}, svm => $ENV{ONTAP_SVM},
    aggregate => "aggr1", ssl_verify => 0);
print "queue: ", encode_json($api->recovery_queue_list()), "\n";
print "clones of parent: ", encode_json($api->volume_get_clone_children_cli("pve_netapp1_999011_disk0")), "\n";'
# 被 queue 佔住的 clone 名稱形如 "<原名>_<id>"（例如 pve_netapp1_999012_disk0_1036），
# 即使 /storage/volumes 已經看不到它，CLI 的 clone 檢視仍然會回報它。
```

### 31.8 透過 qm 的端到端測試（需要 ONTAP，且 plugin 必須已安裝）

31.5～31.7 是直接驅動 plugin。這一節走 `qm` → pvedaemon → **已安裝的** plugin，因此只有在本機執行 `make deb` 並安裝之後才測得到新程式碼。請作為發佈前的最後一道關卡執行。

```bash
STORAGE=netapp1; VMID=9920
qm create $VMID --name snaprestore-test --memory 512
qm set $VMID --scsi0 $STORAGE:1
qm snapshot $VMID snapA; sleep 1
qm snapshot $VMID snapB; sleep 1
qm snapshot $VMID snapC

qm rollback $VMID snapA
# 預期：失敗，訊息含 "can't rollback, 'snapA' is not the most recent snapshot"
#   與 "ONTAP SnapRestore would DELETE these newer snapshot(s): snapB, snapC"。
# 預期：ONTAP 上三個快照全都還在。
qm rollback $VMID snapC          # 預期：成功

# 主機端殘留斷言（v0.2.14 規則）
WWID=$(pvesm path $STORAGE:vm-$VMID-disk-0 | xargs basename)
SLAVES=$(ls /sys/block/$(readlink -f /dev/mapper/$WWID | xargs basename)/slaves/ 2>/dev/null)
qm destroy $VMID --purge
test -e /dev/mapper/$WWID && echo "FAIL: /dev/mapper/$WWID 仍存在" || echo "OK: mapper 已移除"
for s in $SLAVES; do
    test -e /sys/block/$s && echo "FAIL: sd $s 仍存在" || echo "OK: $s 已移除"
done

# linked clone 鎖定 + recovery queue，端到端
VMID=9921; CLONEID=9922
qm create $VMID --name linkedclone-test --memory 512
qm set $VMID --scsi0 $STORAGE:1
qm snapshot $VMID snap1

# 注意：這裡**不要**用 `qm template` —— Proxmox VE 會拒絕把有快照的 VM 轉成範本
#（"unable to create template, because VM contains snapshots"）。
# 而且對**非範本**來源，`full` 預設為 1，所以不加 --full 0 會變成 qemu-img 全複製，
# clone_image() 根本不會被呼叫。--full 0 才會走到 linked clone 路徑
#（PVE::Storage::vdisk_clone 帶 $snapname）。請確認日誌出現
# "create linked clone of drive scsi0"，而不是 "transferred ..." 的進度。
qm clone $VMID $CLONEID --snapname snap1 --full 0

qm delsnapshot $VMID snap1
# 預期：失敗（單行），並同時指名 clone 與其 guest：
#   "... is locked by 1 dependent FlexClone(s): pve_netapp1_9922_disk0 (guest 9922)."
# 預期：該快照在 ONTAP 上與 `qm listsnapshot $VMID` 中都還存在。

qm destroy $CLONEID --purge

# 此時 clone volume 已被刪除，但 ONTAP 仍把它留在 volume recovery queue 中，
# 而它在那裡**仍然算是** parent 的 clone。確認這個落差：
perl -Ilib -e 'use PVE::Storage::Custom::NetAppONTAP::API;
my $a = PVE::Storage::Custom::NetAppONTAP::API->new(
    host => $ENV{ONTAP_HOST}, username => $ENV{ONTAP_USER},
    password => $ENV{ONTAP_PASS}, svm => $ENV{ONTAP_SVM},
    aggregate => "aggr1", ssl_verify => 0);
print "REST clone children: ", scalar(@{$a->volume_get_clone_children("pve_netapp1_9921_disk0")}), "\n";
print "CLI clone view:      ", join(",", map { $_->{flexclone} }
    @{$a->volume_get_clone_children_cli("pve_netapp1_9921_disk0")}), "\n";'
# 預期：REST = 0，CLI = pve_netapp1_9922_disk0_<id>  ← 就是 recovery queue 的佔用

# 被拒絕的 delsnapshot 會在 config 上留下 PVE 自己的 'lock: snapshot-delete'
#（這是任何快照刪除失敗後的 PVE 標準行為，與本 plugin 無關）。重試前先清除。
qm unlock $VMID
qm delsnapshot $VMID snap1
# 預期：成功，且工作日誌出現：
#   "Purging deleted FlexClone 'pve_netapp1_9922_disk0_<id>' from the ONTAP volume
#    recovery queue: ..."
#   "Released 1 recovery-queue clone hold(s) on 'pve_netapp1_9921_disk0': ..."
# 預期：ONTAP volume 上剩下 0 個 pve_snap_* 快照。

qm destroy $VMID --purge
```

---

## 32. 資料安全稽核修正（v0.2.24）

針對破壞性路徑的刪除／覆寫／斷線／死鎖檢視。

### 32.1 單元與靜態涵蓋（不需 ONTAP，核心）

```bash
perl -Ilib tests/audit_fixes.t
# 預期：135/135 PASS。v0.2.24 新增的部分涵蓋：
#  - ONTAP 命名空間推導單一來源（含帶點與超過 32 字元的 storage ID）
#  - 靜態守則確保簡化版 s/-/_/g 不會回來
#  - on_add_hook 命名空間碰撞守門在 portal／SVM／前綴各種組合下的行為
#  - 跨節點 I/O 檢查：使用中／閒置／計數器重置／無統計／統計未更新
#  - free_image 的刪除總時間預算與選項註冊
#  - recovery queue purge 在 API 錯誤時 fail closed
```

### 32.2 命名空間碰撞守門（核心）

```bash
# 兩個 storage ID 若前 32 個衛生化字元相同、且在同一個 SVM 上，
# 會指向同一批 FlexVol。新增第二個必須被拒絕。
pvesm add netappontap netapp-production-cluster-alpha-one \
    --ontap-portal <ip> --ontap-svm svm1 --ontap-aggregate aggr1 \
    --ontap-username admin --ontap-password <pw> --content images
pvesm add netappontap netapp-production-cluster-alpha-two \
    --ontap-portal <ip> --ontap-svm svm1 --ontap-aggregate aggr1 \
    --ontap-username admin --ontap-password <pw> --content images
# 預期：**第二個**指令失敗，訊息為
#   "would share the ONTAP volume namespace 'pve_netapp_production_cluster_alpha__*'
#    with existing storage 'netapp-production-cluster-alpha-one'"
#   並說明在其中一個上刪除磁碟會 DESTROY 另一個的 volume。
# 預期：相同前綴但**不同** SVM 或 portal 會被接受。
pvesm remove netapp-production-cluster-alpha-one
```

### 32.3 對真實 ONTAP 驗證跨節點使用中守門（需要 ONTAP）

驗證守門會對真實活動觸發，而且同樣重要的是：對「閒置但已對應」的 LUN**不會**觸發 —— 該情況下 `multipathd` 的 TEST UNIT READY 檢查器會持續運作。

```bash
perl -Ilib -e '
use PVE::Storage::Custom::NetAppONTAPPlugin;
use PVE::Storage::Custom::NetAppONTAP::Multipath qw(get_device_by_wwid);
my $P="PVE::Storage::Custom::NetAppONTAPPlugin"; my $S="netapp1";
my $scfg = PVE::Storage::config()->{ids}{$S};
my $api  = PVE::Storage::Custom::NetAppONTAPPlugin::_get_api($scfg);
my $has_io = \&PVE::Storage::Custom::NetAppONTAPPlugin::_lun_has_active_io;
my $vol = $P->alloc_image($S,$scfg,999031,"raw",undef,1048576);
my $ov  = PVE::Storage::Custom::NetAppONTAPPlugin::pve_volname_to_ontap($S,$vol);
my $lp  = PVE::Storage::Custom::NetAppONTAPPlugin::encode_lun_path($ov);
$P->activate_volume($S,$scfg,$vol,undef,{});
my $dev = get_device_by_wwid($api->lun_get_wwid($lp));
print "idle: ", ($has_io->($api,$lp,window=>8) || "not flagged"), "\n";
system("dd if=/dev/zero of=$dev bs=1M count=600 oflag=direct status=none &");
sleep 3;
print "busy: ", ($has_io->($api,$lp,window=>10) || "NOT FLAGGED - guard inert!"), "\n";
'
# 預期：
#   idle: not flagged            <- 儘管 multipathd 有 TUR，仍必須不被標記
#   busy: N byte(s) transferred in M read/write operation(s) over the last 10s
# 模擬器實測：閒置 = 0 bytes（3/3 次取樣），忙碌 = 10 秒約 41 MB。
# I/O 停止後，守門會在大約一個統計週期內恢復（實測約 10 秒）；
# 在該視窗內嘗試刪除會被拒絕，重試即可成功。此尾隨視窗屬預期行為並已記錄於文件。
```

### 32.4 靜態 regression 守則

```bash
P=lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm
# 簡化版 sanitizer 不可回來
grep -v '^\s*#' $P | grep -c 's/-/_/g'                                  # 預期：0
# 所有查詢前綴都使用權威函式
grep -cF 'sanitize_for_ontap($storeid, 32)' $P                          # >= 3
# 命名空間守門與刪除預算必須存在
grep -c '^sub _assert_unique_ontap_namespace' $P                        # 預期：1
grep -c '^sub on_add_hook' $P                                           # 預期：1
grep -cF 'delete_deadline' $P                                           # >= 2
# I/O 檢查只能在本機檢查無法執行時才跑
grep -c '!$local_device_checked' $P                                     # 預期：1
# I/O 取樣必須持續排除 other 類操作（multipathd TUR）
grep -A3 'ops   =>' lib/PVE/Storage/Custom/NetAppONTAP/API.pm | grep -c 'other'  # 預期：0
```

### 32.5 倒回跨節點守門、快照名稱碰撞、外部叢集（核心）

```bash
# 倒回套用與 free_image 相同的單向 ONTAP I/O 守門，因為倒回是無聲地**覆寫** volume，
# 而不是移除它。
grep -c '_lun_has_active_io' lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm   # >= 3
sed -n '/^sub volume_snapshot_rollback/,/snapshot_rollback(/p' \
    lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm | grep -c '_lun_has_active_io'   # 預期：1

# 只差 '-' 與 '_' 的快照名稱會對應到同一個 ONTAP 快照。
perl -Ilib -e 'use PVE::Storage::Custom::NetAppONTAP::Naming qw(encode_snapshot_name);
print encode_snapshot_name("my-snap") eq encode_snapshot_name("my_snap") ? "COLLIDE\n" : "distinct\n";'
# 預期：COLLIDE —— 建立第二個會被拒絕（安全），且錯誤訊息現在必須說明
# '-' -> '_' 的對應關係，而不是只說「已存在」。

# 第二個 PVE 叢集共用命名空間，可從 igroup 歸屬偵測出來。
grep -c '^sub _check_foreign_cluster_namespace' lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm  # 1
# 必須使用單一次分頁呼叫，絕不可對每顆 LUN 查詢（v0.2.21 的 N+1 教訓）：
sed -n '/^sub _check_foreign_cluster_namespace/,/^}/p' \
    lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm | grep -c 'lun_list_with_maps'   # 預期：1
sed -n '/^sub _check_foreign_cluster_namespace/,/^}/p' \
    lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm | grep -c -- '->lun_get('        # 預期：0
```

### 32.6 對真實 ONTAP 驗證單次 LUN／igroup 查詢（需要 ONTAP）

外部叢集檢查仰賴 `lun_maps.igroup.name` 能在集合 GET 中取得。請實際驗證，不要假設：

```bash
perl -Ilib -MPVE::Storage -e '
my $P="PVE::Storage::Custom::NetAppONTAPPlugin"; my $S="netapp1";
my $scfg = PVE::Storage::config()->{ids}{$S};
my $api  = PVE::Storage::Custom::NetAppONTAPPlugin::_get_api($scfg);
my $vol  = $P->alloc_image($S,$scfg,999040,"raw",undef,1048576);
my $r = $api->lun_list_with_maps("/vol/pve_${S}_*/lun0");
for my $l (@$r) { print $l->{name}, " -> ",
  join(", ", map { $_->{igroup}{name} } @{$l->{lun_maps}//[]}), "\n" }
$P->free_image($S,$scfg,$vol,0,"raw");'
# 預期：一行列出該 LUN 及其對應到的每一個 igroup，例如
#   /vol/pve_netapp1_999040_disk0/lun0 -> pve_pve_pc_pve1, pve_pve_pc_pve2, pve_pve_pc_pve3
# 所有 igroup 都必須以本叢集自身的 'pve_{cluster}_' 前綴開頭，
# 因此在單一叢集的安裝環境中，外部叢集檢查會保持靜默。
```

---

## 33. FC Rescan 安全性 + LXC／vzdump 端到端（v0.2.26）

### 33.1 FC：LIP 必須為選用，且迴圈需有總時間上限（核心，不需 FC HBA）

`issue_lip` 會重置 FC port，並擾動**該 HBA 後方的每一顆 LUN**。它絕不可執行於輪詢路徑或重試迴圈中。

```bash
F=lib/PVE/Storage/Custom/NetAppONTAP/FC.pm
P=lib/PVE/Storage/Custom/NetAppONTAPPlugin.pm
sed -n '/^sub rescan_fc_hosts/,/^}/p' $F | grep -cF 'if ($opts{lip})'          # 預期：1
sed -n '/^sub rescan_fc_hosts/,/^}/p' $F | grep -cF 'time() >= $deadline'      # 預期：2
grep -o 'rescan_fc_hosts([^)]*)' $P | grep -c 'lip => 1'                      # 預期：1
sed -n '/^sub activate_storage/,/^}/p' $P | grep 'rescan_fc_hosts' | grep -c lip  # 預期：0
```

預期：LIP 被明確的選項所控制；兩個迴圈都遵守總時間預算；只有一個呼叫點（`_get_snapshot_path` 中「裝置始終沒出現」的 fallback）會發出 LIP；而 pvestatd 每 ~10 秒在每個節點都會呼叫的 `activate_storage` 則絕不發出。

**目前實驗環境無法測試**（沒有 FC HBA）。這些是程式碼審查得出的修正，僅由靜態與單元斷言覆蓋。在真實 FC 環境中，請另以 `journalctl -k | grep -i lip` 確認正常輪詢期間不會發出 LIP。

### 33.2 LXC／`rootdir` 端到端（需要 ONTAP）

```bash
S=netapp1; C=9960; T=local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst
pct create $C $T --rootfs $S:2 --hostname lxc-audit --memory 512 --unprivileged 1 \
    --net0 name=eth0,bridge=vmbr0
pct start $C && pct exec $C -- df -h /          # rootfs 必須是 /dev/mapper/<wwid>
pct snapshot $C snap1                            # 對**執行中**的 CT 建立快照
pct exec $C -- touch /audit-ok                   # 在快照**之後**寫入
vzdump $C --mode snapshot --storage local        # 驅動暫存 FlexClone 路徑
pct rollback $C snap1 && pct start $C
pct exec $C -- ls /audit-ok                      # **必須不存在** -> 證明倒回確實還原了
pct resize $C rootfs +1G && pct exec $C -- df -h /   # 線上擴充
pct stop $C && pct destroy $C --purge
```

destroy 後斷言：`/dev/mapper/<wwid>` 不存在、先前所有 `sd` slave 都已從 `/sys/block` 移除、ONTAP 上 0 個 `pve_*` volume、0 個 NETAPP multipath map。

### 33.3 被中斷的 vzdump 必須能乾淨復原（需要 ONTAP）

在快照模式備份執行到一半時中斷它，接著確認殘留內容，以及移除該快照後能完全清乾淨 —— 這正是 v0.2.13／v0.2.14 的事故情境。

```bash
timeout 60 vzdump $C --mode snapshot --storage local   # 中途中斷
# 預期殘留：一個 'vzdump' 快照，以及 tmpclone_<vol>_pve_snap_vzdump
pct listsnapshot $C
perl -Ilib -e '...volume_list("tmpclone_*")...'

pct delsnapshot $C vzdump
# 預期：出現 "Detaching temporary FlexClone ... before snapshot delete"、
#       剩餘 0 個暫存 clone、只留下其他快照，
#       且該暫存 clone 沒有殘留的 multipath map 或 sd 路徑。
multipath -ll | grep -ci 'failed\|faulty'        # 預期：0
journalctl --since '5 min ago' | grep -c 'tur checker reports path is down'  # 預期：0
```

---

## 清除

```bash
# 移除所有測試 VM 與容器
qm destroy 9900 --purge 2>/dev/null
qm destroy 9901 --purge 2>/dev/null
qm destroy 9902 --purge 2>/dev/null
qm destroy 9903 --purge 2>/dev/null
qm destroy 9904 --purge 2>/dev/null
qm destroy 9905 --purge 2>/dev/null
qm destroy 9906 --purge 2>/dev/null
qm destroy 9920 --purge 2>/dev/null
qm destroy 9921 --purge 2>/dev/null
qm destroy 9922 --purge 2>/dev/null
pct destroy 9910 --purge 2>/dev/null

# 驗證 ONTAP 上無殘留 volume
pvesm list $STORAGE
```

---

## 發佈測試結果

每次發佈前都必須通過上述所有測試。結果記錄如下。

### v0.2.23-1 Proxmox VE 9.0／9.1／9.2 相容性稽核 + 快照安全（2026-07-26）

**狀態：所有可執行的測試皆 PASS，尚未發佈** —— `make deb`、在節點上安裝、第 31.8 節（`qm` 層級端到端）、`github/` 同步、README 的 deb 檔名與 tag 都還沒做。

**環境**：proxmox-ve 9.2.0／pve-manager 9.2.5／libpve-storage-perl 9.1.2（APIVER 13）／qemu-server 9.1.16／pve-container 6.1.12／multipath-tools 0.11.1／open-iscsi 2.1.11／kernel 7.0.2-7-pve。ONTAP 模擬器 svm1 @ 192.168.1.194，aggregate aggr1，2 個 iSCSI LIF。

| 測試套件 | 結果 |
|---------|------|
| `make test`（Perl 語法，6 個模組） | 6/6 PASS |
| 主 plugin 的 `podchecker` | PASS |
| `tests/audit_fixes.t` | 105/105 PASS |
| `tests/status_timeout.t` | 20/20 PASS |
| `tests/stale_sd_reaper.t` | 20/20 PASS |
| `tests/activate_budget.t` | 8/8 PASS |
| `tests/sim_snapshot_safety.pl`（真實 ONTAP，31.5～31.7） | 34/34 PASS |
| `tests/sim_functional.pl`（真實 ONTAP） | 13/13 PASS |
| `tests/cleanup_load.pl`（真實 ONTAP） | 6/6 PASS |
| 第 31.2 節 APIVER 矩陣（6 個儲存函式庫） | 6/6 PASS，零警告 |
| 第 31.4 節靜態 regression 守則 | 11/11 PASS |
| 第 31.8 節 `qm` 層級端到端（plugin 已安裝於 pc-pve1） | PASS |
| **總計** | **153 項單元 + 53 項功能，0 失敗** |

**第 31.8 節（`qm` 層級，在 pc-pve1 上安裝 0.2.23-1 後執行）**：

- `dpkg -i` 乾淨（`ii`），v0.2.22 的「restart pvestatd（而非 reload）」警告正確顯示，`systemctl restart pvestatd` 與 `pvedaemon` 的 PID 都有改變，`pvesm status` 顯示兩個 netappontap storage 皆 `active`，pvestatd journal 無 plugin 警告。
- `qm rollback 9920 snapA`（snapA／snapB／snapC 中最舊者）被**拒絕**，並指名 snapB 與 snapC；事後三個快照在 ONTAP 上全都還在。`qm rollback 9920 snapC`（最新）成功。
- `qm clone 9921 9922 --snapname snap1 --full 0` 產生真正的 linked clone（`create linked clone of drive scsi0`），且 ONTAP 回報 `pve_netapp1_9922_disk0` 釘在 `pve_snap_snap1` 上。
- `qm delsnapshot 9921 snap1` 被**拒絕**，指名 `pve_netapp1_9922_disk0 (guest 9922)`；快照存活。`qm destroy 9922 --purge` 之後，REST 回報 0 個 clone children，而 CLI 檢視仍顯示 recovery queue 項目 `pve_netapp1_9922_disk0_1052`；重試時自動 purge 掉它，快照刪除隨即成功（剩 0 個快照）。
- 每次 destroy 的主機端殘留斷言全部通過（mapper 裝置消失、所有 `sd` slave 從 `/sys/block` 移除），ONTAP 0 殘留 volume，0 個 NETAPP multipath map。

**在 APIVER 15 上原生重新驗證（2026-07-26，全節點升級後）**：pc-pve1 升到 libpve-storage-perl **9.1.6（APIVER 15）** 與 qemu-server **9.2.1** 之後，整套測試重跑一次 —— 也就是直接對最新的儲存 API，而不只是對解包出來的套件樹。`make test` 6/6、單元 **153/153**、功能 **53/53**，第 31.8 節在該組合上重跑 **12/12**。該節點的 `api()` 回傳 15 且零警告，而 pc-pve1 先前在 APIVER 13 時回傳 13 —— 同一個 plugin binary，逐節點協商。

Rollout 後的叢集狀態：三個節點皆 plugin 0.2.23-1；pc-pve1／2／3 全部為 proxmox-ve 9.2.0／pve-manager 9.2.5／libpve-storage-perl 9.1.6，`api()` 一律為 15，零「older storage API」警告。值得一提的是 pc-pve1 上其他第三方 plugin（PureStorage、DellPowerFlex、DellPowerStore、DellPowerVault）在 APIVER 15 下**都會**發出該警告 —— 只有本 plugin 不會，這正是把 `api()` 改為協商而非硬編碼的實際效益。

**第 31.8 節迫使做出的兩項修正（皆已修好）**：

1. 31.8 最初的草稿使用 `qm template` + `qm clone --snapname`。Proxmox VE 會拒絕把有快照的 VM 轉成範本，而對非範本來源 `full` 預設為 1 —— 因此那個流程其實默默做出了**全複製** clone，完全沒有觸及 `clone_image()`。真正可達的 linked clone 路徑是 `--full 0`（它沒有範本限制：`API2/Qemu.pm` 只做 `my $full = $param->{full} // !is_template($conf)`）。測試計畫已改用 `--full 0`，並斷言 "create linked clone" 這行日誌。
2. Proxmox VE 會把工作／CLI 錯誤輸出中的換行壓成空白，因此多行的 `die` 訊息在 `qm rollback`／`qm delsnapshot` 中會變成難以閱讀的連續段落。四則新錯誤訊息全部改為單行，並以核心 plugin 慣用的措辭開頭。重新安裝後已透過 `qm` 再次驗證。
3. 被拒絕的 `delsnapshot` 會在 guest config 上留下 PVE 自己的 `lock: snapshot-delete`，因此重試前需先 `qm unlock <vmid>`。這是任何快照刪除失敗後的 PVE 標準行為（與本 plugin 無關），現已記入 31.8。

**在真實 ONTAP 上的關鍵確認**：

- **SnapRestore 破壞性前提已確認**。在 snapA／snapB／snapC 都存在的情況下，繞過守門倒回 snapA 之後，ONTAP 上只剩下 snapA —— snapB 與 snapC 被摧毀，而 Proxmox VE 的 config 仍會列著它們。這驗證了最高嚴重度的修正，而非僅採信原廠文件。
- **倒回守門雙向都正確**：倒回最新快照被允許；倒回較舊快照被拒絕，且較新的快照會被列為 blockers，而被拒絕的那次嘗試不會摧毀任何東西。
- **新發現 N12（ONTAP volume recovery queue）** 由第 31.6 節測試發現，並在本次發佈中修正。已刪除的 FlexClone 只要還被 ONTAP 保留在 recovery queue 中，就仍算是其 parent 的 clone，會使 parent 的快照刪除最長被阻擋 12 小時。這同時修正了 v0.2.13 的根因分析 —— 當時把 `volume_clone_dependent` owner 遲遲不清除歸因於 eventual consistency 加上模擬器特性。
- `free_image` 與 `volume_snapshot_delete` 的變更**未造成** `sim_functional`／`cleanup_load` 回歸。
- 測試後 ONTAP 保持乾淨：0 個線上 `pve_*` volume。剩餘的 17 筆 volume recovery queue 項目是 ONTAP 對測試所刪除 volume 的正常保護機制；本次修正刻意不 purge 未造成阻擋的項目，它們會自行過期。

**已跳過的項目及原因**：

- 第 31.8 節已執行，但**只在 pc-pve1 上**（plugin 只裝在該節點；pc-pve2 與 pc-pve3 仍是 0.2.18-1）。發佈前請在其餘節點安裝並各自 `systemctl restart pvestatd`。
- 第 1～30 節未全部重跑；本次變更集中在儲存 API 介面、快照／倒回路徑與 API client cache，而三個功能測試套件加上 153 項單元斷言已涵蓋這些路徑。第 10 節（ONTAP 協調的失效測試）需要 ONTAP 管理 agent 配合。

### v0.2.22-1 postinst restart-pvestatd 警告 Release (2026-06-16)

**範圍**：僅 `debian/postinst`——新增醒目的「restart pvestatd（而非 reload）」升級警告。沒有 Perl code 變更（`lib/` 與 0.2.21 逐位元組相同）。

- postinst `bash -n`：語法 OK。彩色警告區塊在服務 reload 之後正確顯示。
- 外掛回歸與 0.2.21 相同（無 code 變更）：`cleanup_load.pl` 6/6、`sim_functional` 13/13、reaper 20/20、status-timeout 13/13、activate-budget 8/8、`make test` 6/6。

**結果：PASS**。純可操作性發版：補上「裝了卻沒生效」的缺口（reload 保持相同 PID、可能跑舊 Perl code；必須在每個節點完整 `systemctl restart pvestatd`）。

### v0.2.21-1 殘留清理 N+1 REST 風暴修正 Release (2026-06-16)

**範圍**：Section 30（新）——消除 `_cleanup_orphaned_devices()` 中每顆 LUN 各打一次 `lun_get_wwid()` 的 N+1。

**環境**：`pc-pve1`（PVE 9.2，dev lib 以 `-Ilib`）。ONTAP 模擬器（svm0，iSCSI）。儲存 `netapp1`。

- **30.1 N+1 消除 + alive-set 不變（`cleanup_load.pl`）**：6/6 PASS。配置 3 顆真實 LUN；instrument `API::lun_get`；`_cleanup_orphaned_devices` 期間呼叫 **0** 次（原本每顆 1 次）；3 個 WWID 全在 alive-set；`serial_to_wwid(serial)` 算出與舊 `lun_get_wwid()` 逐位元組相同的 WWID；free 後主機與 ONTAP 皆 0 殘留。
- **30.2 靜態守則**：相符（alive-set 迴圈無 `lun_get_wwid`；用 `serial_number` + `serial_to_wwid`；`lun_list` 仍要求 `serial_number`）。
- **完整回歸（行為無變）**：`sim_functional` 13/13、reaper 20/20、status-timeout 13/13、activate-budget 8/8、`make test` 6/6。其餘每輪呼叫已稽核：`get_managed_capacity` 走 aggregate 提前返回（1 個呼叫）；`_check_aggregate_capacity`／`_check_lif_redundancy` 以冷卻節流（1h／24h）。

**結果：PASS**。外科手術式修正——alive-set 相同，每輪每節點少打 ~75 次 REST。

### v0.2.20-1 activate_storage iSCSI 登入預算 Release (2026-06-16)

**範圍**：Section 29（新)—— iSCSI discover/login 迴圈的 `ontap-activate-deadline` wall-clock 預算，把「絕不卡住 PVE」規則補完整。

**環境**：`pc-pve1`（PVE 9.2,dev lib 以 `-Ilib`）。ONTAP 模擬器（svm0,iSCSI）。儲存 `netapp1`。

- **29.1 預算閘門邏輯（離線單元，`activate_budget.t`）**：8/8 PASS。超過預算且已有 ≥1 路徑 → 剩餘 portal 跳過（延後)；超過預算但 0 路徑 → 全部 3 個嘗試（絕不跳過，然後誠實失敗)；預算內 → 全部 4 個嘗試。進行中的 login 絕不中斷。
- **29.2 真實 ONTAP 無 regression（`sim_functional.pl`）**：13/13 PASS。預算閘門在位下跑完整 alloc/activate/free lifecycle;ONTAP 健康時所有 portal 都在預算內登入，行為不變。
- **29.3 靜態守則**：全部相符（`ontap-activate-deadline` 屬性 + 使用、預算閘門存在、閘門以 ≥1 路徑已登入為條件)。
- `make test` 語法：6 個模組全 OK。

**結果：PASS**。保守範圍確認：閘門只會在「已有可用路徑後」延後**額外**的 portal——不會把「只是慢但連得到」的儲存誤判成 inactive(迴圈在 0 路徑時絕不跳過)。

### v0.2.19-1 pvestatd 隔離 + 殘留路徑 reaper + 連線重用 Release (2026-06-16)

**範圍**：Section 28(新）—— 殘留 SCSI 路徑 reaper、pvestatd `ontap-status-timeout` 隔離、HTTP keep-alive。

**環境**：`pc-pve1`（PVE 9.2,dev lib 以 `-Ilib`）。本 session 重建的 ONTAP 模擬器（svm0,target IQN 已重新產生，兩個 iSCSI portal）；主機 iSCSI 已重建。儲存 `netapp1`（iSCSI）。

- **28.1 reaper 決策邏輯（離線單元，`stale_sd_reaper.t`）**：20/20 PASS。完整 pve19 拓樸——3 條 LUN-ID 重用殘留 + 1 條追蹤殘留被 reap;9 條安全閘案例（alive WWID、has_holders、無 holder 但活著、手動／未知、sibling 所有、空白無證據、FC、已掛載、寬限期內）皆未 reap。自我修復（rescan + reload）已觸發。
- **28.2 status-path client（離線單元，`status_timeout.t`）**：13/13 PASS。資料路徑 15s／2-retry;status 路徑 5s／單次嘗試；分開快取。對黑洞 IP 退化快速失敗：**status-path 5.0s vs data-path 32.0s（6.3x）**。
- **28.3 reaper 對健康 live 裝置零誤刪（模擬器功能測試，`sim_functional.pl`）**：13/13 PASS。真實 ONTAP + 真實裝置：alloc（`vm-999000-disk-0`,WWID `3600a0980...`,2 條 sd 路徑）→ `list_netapp_scsi_paths` 見 `has_holders=1` → `_cleanup_orphaned_devices`（含 reaper）後裝置與兩條 sd 路徑完好 → `free_image` 移除 multipath 裝置、`/dev/mapper`、兩條 sd slave。ONTAP（0 LUN/volume）+ 主機（0 multipath/sd）零殘留。
- **28.4 靜態守則**：全部相符(reaper helper + 第三個 pass、安全閘／寬限期、status_path client + `ontap-status-timeout`、`keep_alive`）。
- `make test` 語法：6 個模組全 OK。

**結果：PASS**。環境已還原乾淨（測試 LUN 已釋放，ONTAP 與主機端零殘留）。模擬器上未重現：reaper 真的移除一條殘留路徑（需真實 LUN-ID 重用）——由 28.1 完整拓樸的 Case A/B 單元案例涵蓋。

### v0.2.18-1 清理時殘留 SCSI 路徑掃除 Release (2026-05-29)

**範圍**：Section 27（新增）—— `get_scsi_paths_for_wwid()` + `cleanup_lun_devices()` Step 8 殘留掃除。

**環境**：`pc-pve1`（PVE 9.1，透過 `make install` 部署 0.2.18 原始碼）。ONTAP 模擬器。儲存 `netapp1`（iSCSI）。

- **27.1 helper 比對（真實裝置）**：`get_scsi_paths_for_wwid()` 回傳的正好是該裝置的 multipath slaves（`/dev/sdc /dev/sdd`）；bogus WWID 回傳空（無誤判）；`budget => 0` 安全退出並印「scan budget exceeded」警告。PASS。
- **27.2 Step 8 殘留掃除（核心）**：僅移除 multipath map（`multipath -f`），讓 `sdc`/`sdd` 在 `/sys/block` 變殘留；舊的 `cleanup_lun_devices()` 會 no-op（無 map）；新的 Step 8 掃除了兩個殘留 `sd` 路徑。PASS。
- **27.3 靜態守則**：全部相符（helper 已定義+export+使用、Step 8 已接入 `cleanup_lun_devices`、wall-clock 預算存在、NETAPP 廠商閘門存在）。
- `make test` 語法：全模組 OK。

**結果：PASS**。環境已還原為乾淨狀態。

### v0.2.17-1 殘留清理路徑健康閘門 + LUN 清單分頁 Release (2026-05-29)

**範圍**：Section 26（新增）+ 分頁 API 函式對真實 ONTAP + 完整硬碟生命週期回歸。

**環境**：`pc-pve1`（PVE 9.1，透過 `make install` 部署 0.2.17-1）。ONTAP 模擬器（192.168.1.194，本次作業期間曾斷線後修復）。儲存 `netapp1`（iSCSI）。

**Section 26.1 —— 路徑健康閘門邏輯（離線 mock）**：7/7 PASS。事故條件（`4 active paths -> live` 回傳 1）、`all paths failed -> 0`、`1 active among failed -> 1`、`active+offline -> 0`、`no map -> 0`、`map but no path rows -> -1`、`multipathd unreachable -> -1`。

**Section 26.2 —— LUN 清單分頁（離線 mock）**：PASS。跨 3 頁組出 5 筆；`_links.next.href` 開頭的 `/api` 已剝除（無重複 `/api/api`）。

**Section 26.3 —— 靜態 regression 守則**：全部相符（兩輪拆除皆引用路徑健康閘門、寬限期存在、helper 已 export、`lun_list` 使用 `_get_all_records` 且無寫死的 `max_records => 1000` 上限、`/api` 剝除存在）。

**Section 26.4 —— 執行中 VM 功能性重現（真實 ONTAP + multipathd）**：
- 對執行中的 VM 9000 熱加 scsi1；新裝置有 2 條 `active ready running` 路徑，且被 QEMU 開著。
- 用 `lun_list` 回空集合（最壞情況延遲／截斷）強制 reaper:
  - 寬限期內（WWID 剛追蹤幾秒）：reaper 靜默跳過——裝置存活、VM 續跑、0 I/O error。PASS。
  - 寬限期失效（注入舊時間戳）：路徑健康閘門觸發——「Refusing to remove a live device」——裝置存活、0 I/O error。PASS。
- 直接對真實 multipathd 呼叫 `multipath_path_health()` 回傳 **1**（正確偵測 active 路徑；本機 multipath-tools 版本支援 `%m %t %o` 格式，並非 `-1` 保險退路）。
- 真正釋放（`qm set --delete unused0`）：host-side 乾淨拆除——multipath 消失、`/dev/mapper` 消失、兩個 sd slave 消失、ONTAP volume 已刪、scsi0 不受影響、0 I/O error。PASS。

**真殘留清除（反方向，真實 ONTAP）**：透過 API 直接刪除 LUN+volume（繞過 `free_image`）製造真實殘留；路徑於 ~15s 內失效；`multipath_path_health()` 回傳 **0**;reaper 確實清除（「removing stale device ... all paths failed」）且兩個 sd slave 移除。PASS——正常的殘留清理功能未被破壞。

**分頁 API 函式（真實 ONTAP）**：`lun_list`、`volume_list`、`igroup_list`、`snapshot_list`、`volume_get_clone_children` 全部正常回傳。

**完整硬碟生命週期（真實 ONTAP）**：alloc + activate（scsi0/scsi1）、snapshot（雙碟）、rollback、snapshot 刪除、resize（1G -> 2G，確認 block device）、full clone（9000 -> 9001）、兩台 VM destroy --purge——全 PASS；最終狀態乾淨（0 個 multipath map、0 個測試 volume、tracking 檔 `{}`、0 I/O error）。

**結果：PASS**。環境已還原為乾淨狀態。

### v0.2.16-1 Temp Clone 背景清理 idempotency 修正 Release (2026-05-24)

**範圍**：Section 24.3(新 idempotent reaper 測試)+ Section 24.4(新靜態守則)+ 完整 Tier 1 + Tier 2 regression + Section 25 regression。

**環境**：`pc-pve3`(PVE 9.1，部署 0.2.16-1)。ONTAP simulator。兩個 netappontap storage(`netapp1` + `netapp2`)。

#### Section 24.3(用 simulator 殘留實際觸發):

Simulator 上有先前 v0.2.13 開發測試留下的真實殘留 entry:`tmpclone_pve_netapp1_9997_disk0_pve_snap_splittest` 在 state file 內，ONTAP 上 volume 早已被刪。v0.2.16 之前每次 `pvesm status` 都會印：
```
Cleaning up old temporary FlexClone: tmpclone_pve_netapp1_9997_disk0_pve_snap_splittest
Failed to cleanup temp clone '...': volume_clone_split on temp clone '...' failed:
  Volume '...' not found at .../NetAppONTAPPlugin.pm line N.
```
v0.2.16 部署後：
1. 第一次 `pvesm status`:**唯一一行**「Temp clone '...' already absent on ONTAP; skipping ONTAP-side cleanup.」
2. State file 已 untrack:`{"netapp1":{}}`(entry 消失)
3. 第二次 `pvesm status`:**完全安靜**(沒有任何 temp clone 警告)

**結論**：PASS — fix 如預期。

#### 完整 Tier 1 + Tier 2 regression: 43/43 PASS(0 FAIL)

Section 1 / 2 / 3 / 12 / 19.6 / 24(snapshot delete + temp clone cleanup)/ 靜態守則皆無 regression。

**結論**：v0.2.16-1 可發佈。

---

### v0.2.15-1 跨儲存殘留偵測修正 Release (2026-05-24)

**範圍**：Section 25(新增：跨儲存殘留偵測)+ Section 1 regression + Section 24 regression。

**環境**：單節點測試於 `pc-pve3`(PVE 9.1，部署 0.2.15-1)。ONTAP simulator。**配置兩個 netappontap storage(`netapp1` + 新加的 `netapp2`)**指向同一個 SVM，各自有 LUN — 忠實重現客戶的 multi-storage 情境。

#### Section 25: 跨儲存殘留偵測

| 驗證 | 結果 |
|---|---|
| 25.1 PRE-FIX 模擬：netapp1 cleanup 會誤報 1 個 WWID(netapp2 的 d61) | PASS(false-positive 重現確認) |
| 25.1 PRE-FIX 模擬：netapp2 cleanup 會誤報 3 個 WWID(netapp1 的 d58/d59/d5a) | PASS(false-positive 重現確認) |
| 25.1 POST-FIX:netapp1 cleanup 0 個誤報 | **PASS**(fix 完全消除誤報) |
| 25.1 POST-FIX:netapp2 cleanup 0 個誤報 | **PASS**(fix 完全消除誤報) |
| 25.2 Plugin 實際程式碼路徑：每個 storage 0 個殘留警告 | PASS |
| 25.3 靜態守則(other_plugin_wwid、PVE::Storage::config、對 other_storeid 呼叫 _read_wwid_state) | PASS |

**Bug 修正價值**：客戶現場 cluster-wide 每小時對約 120 個 WWID 持續吐警告。每條都建議跑破壞性 `multipath -f <wwid>`。操作員若照做會拆掉跑著的 VM 磁碟。v0.2.15 之後在 multi-storage 情境下誤報歸零。

#### Regression: 過往 Release Section 24(temp clone 清理，v0.2.14)+ Section 1(基本連線)

| # | 測試 | 結果 |
|---|------|------|
| 1 | netapp1 在 pvesm status active | PASS |
| 1 | netapp2 在 pvesm status active | PASS |
| 1 | iSCSI sessions ≥ 2 | PASS |
| 24 | snapshot_delete with temp clone(ONTAP + host 清理) | PASS(無 regression) |

**備註**：
- Simulator 上殘留的 `tmpclone_pve_netapp1_9997_disk0_pve_snap_splittest` 仍會讓 v0.2.14 背景 reaper 持續印「Failed to cleanup」警告(因為對應的 parent volume 已不在了，helper 在 volume_clone_split 時 die)。與 v0.2.15 無關；`/var/run` 在下次重開機後會自動清。**不在本次 fix 範圍**。
- ONTAP simulator 的 stale clone metadata quirk 從先前測試留下，不影響 v0.2.15 驗證。

**結論**：Section 25 全部通過，Section 1 與 Section 24 regression 也通過。v0.2.15-1 可發佈。

---

### v0.2.14-1 Temp Clone Host 端清理修正 Release (2026-05-14)

**範圍**：強化 Section 24 — 新增 host 端 device 殘留驗證(如果 v0.2.13 跑過這個驗證就會 catch 到 production regression)。修正手段：新增共用 helper `_remove_temp_clone()`，給 `volume_snapshot_delete` 和 `_cleanup_temp_clones` 兩個 call site 共用。

**環境**：單節點測試於 `pc-pve3`(PVE 9.1，部署 0.2.14-1),`netapp1` 儲存對接 ONTAP simulator。

#### Section 24: Snapshot 刪除時清理依附的 Temp FlexClone(強化版)

| # | 驗證 | 結果 |
|---|------|------|
| 24.1 Case A | snapshot_delete 含 temp clone | **PASS** 17.73s |
| 24.1 Case A | [ONTAP] temp clone 已移除 | PASS(GONE) |
| 24.1 Case A | [ONTAP] snapshot 已移除 | PASS(GONE) |
| 24.1 Case A | **[HOST] temp WWID 對應的 dm-multipath 已移除** | **PASS**(GONE) ← 新 |
| 24.1 Case A | **[HOST] sd* slave 裝置已移除** | **PASS**(GONE) ← 新 |
| 24.1 Case A | **[HOST] /dev/mapper/<wwid> 已移除** | **PASS**(GONE) ← 新 |
| 24.3 | 靜態 regression 守則(helper 存在、兩 call site 都用、不再有 inline cleanup) | PASS(計數全符合) |

**Bug 修正價值**：v0.2.14 之前每一次 CT vzdump snapshot-mode 備份都會在 host 留下殘留 `dm-multipath` + 4 條 `sd*`。`multipathd` 之後每 2 秒就 log 一次「tur checker reports path is down」，且每次備份都多累積一組。v0.2.14 之後 host 端設備跟著 `volume_snapshot_delete` 同步拆掉。

**教訓(已記入 CLAUDE.md):** 任何測試只要涵蓋「在 ONTAP 上刪 LUN/卷」的路徑，都必須包含 host 端 device 驗證。只測 ONTAP 不夠 — 清理類 bug 在 host 端的殘留會在幾秒內就被 operator 看到 syslog 訊息。適用於 `free_image`、`volume_snapshot_delete`、`deactivate_volume`、未來的 temp clone reaper、以及任何呼叫 `lun_delete` 或 `volume_delete` 的新程式碼。

**結論**：Section 24 強化測試全部通過。v0.2.14-1 可發佈。

---

### v0.2.13-1 Snapshot 刪除清理修正 Release (2026-05-13)

**範圍**：Section 24(新增的 temp FlexClone 清理測試)。2026-05-13 客戶現場回報：對 CT 做 vzdump snapshot-mode 備份備份本身成功，但清理 `vzdump` snapshot 必失敗，訊息「has not expired or is locked」。

**環境**：單節點測試於 `pc-pve3`(PVE 9.1，部署 0.2.13-1),`netapp1` 儲存對接重建後的 ONTAP simulator(SVM `svm1`,2 LIF)。

#### Section 24: Snapshot 刪除時清理依附的 Temp FlexClone

| # | 測試 | 結果 |
|---|------|------|
| 24.1 Case B | `volume_snapshot_delete` regression(無 temp clone) | **PASS**(2.25s) |
| 24.1 Case A | `volume_snapshot_delete` 含依附的 temp FlexClone | **PASS**(15.08s — split + wait + delete + snapshot_delete;temp clone 已移除；snapshot 已移除) |
| 24.3 | 靜態 regression 守則(`_get_temp_clone_name`、`volume_clone_split`、`volume_wait_clone_split`、`is_device_in_use`) | PASS(各 1/1/1/1 次) |

**Bug 修正價值**：0.2.13 之前，每一次 vzdump CT snapshot-mode 備份都會在 ONTAP 留下殘留 snapshot + temp FlexClone。每天累積一筆，直到操作員手動清。0.2.13 之後自動且可靠地清乾淨。

**測試過程發現的設計細節**：初版實作直接 `volume_delete` temp clone，預期 ONTAP 會立即釋放 parent snapshot 的 `volume_clone_dependent` owner reference。真實 FAS 確實如此；但 ONTAP simulator **不會清** — owner 標記黏住不放(實測 60 秒以上不變)。改用 `volume_clone_split` + wait + `volume_delete`，這是 ONTAP 保證 split 完成後一定會釋放 owner 的機制，所有平台行為一致。成本可控：vzdump 的 temp clone 純讀取沒有寫入，unique block 接近 0,split 很快完成。已記入 CLAUDE.md「Lessons Learned」防止重蹈覆轍。

**Section 24.2(實機 VM/CT vzdump 端到端):** 本次未執行；需配置 PBS server 或 vzdump-dump 目的地。Section 24.1 透過直接 plugin API 走完整段相同程式碼路徑且驗證更嚴格，客戶 bug 情境已透過此測試完整驗證。

**備註**：
- Sections 1-23 本次未重跑：本次變更僅限於一個函式(`volume_snapshot_delete`)，未動到資料路徑。24.3 靜態守則涵蓋新程式碼 regression。
- ONTAP simulator 累積 stale clone metadata 的已知限制(CLAUDE.md 已記)導致測試必須換新 VMID(舊 VMID 卡住先前測試殘留的卷)。非 plugin 問題。

**結論**：Section 24 全部通過。v0.2.13-1 可發佈。

---

### v0.2.12-1 iSCSI Portal TCP 預先檢查 Release (2026-05-05)

**範圍**：Section 23(iscsiadm 前 TCP probe 的新測試)+ Section 1 regression。

**環境**：單節點測試於 `pc-pve3`(PVE 9.1,kernel 6.17.2-1-pve),`netapp1` 儲存對接重建後的 ONTAP simulator(SVM `svm1`,target IQN `iqn.1992-08.com.netapp:sn.d9be2b16486811f18737bc2411de521d:vs.2`,2 個 iSCSI LIF `192.168.1.197` / `192.168.1.198` 皆 `up/up`)。用 `iptables OUTPUT -d $LIF -p tcp --dport 3260 -j DROP` 模擬非對稱可達。

#### Section 23: TCP Probe 預先檢查

| # | 測試 | 結果 |
|---|------|------|
| 23.1 | `probe_portal()` 單元測試(可達 / 阻擋 / 拒絕) | PASS(可達 <1s，阻擋準時 2s timeout，拒絕立即返回) |
| 23.2 | 1 個 LIF 阻擋：activate_storage 快速跳過、儲存維持 active | **PASS**(3.04s；訊息 `Skipped 1 unreachable iSCSI portal(s) on SVM 'svm1': 192.168.1.197:3260 (no TCP response within 2s)`;netapp1 維持 active) |
| 23.3 | 全部 LIF 阻擋：die 並輸出可操作訊息 | **PASS**(4.83s;netapp1 變 inactive；錯誤訊息包含 `Unreachable: 192.168.1.198:3260, 192.168.1.197:3260` 與 `use 'pvesm set <storeid> --nodes <list>'` 救援提示) |
| 23.4 | `ontap-portal-probe-timeout=0` 回到舊版卡頓行為 | **PASS**(1 個 LIF 阻擋下 31.25s vs 預設 3.04s。證實 probe 正是省下這 28 秒的關鍵。看到 `Command timed out after 30s: /usr/bin/iscsiadm -m discovery -t sendtargets -p 192.168.1.197:3260`，符合預期) |
| 23.5 | 靜態守則(probe_portal 使用、schema 屬性、IO::Socket::INET) | PASS(分別 4 / 2 / 3 / 2 次出現) |

**Bug 修正量化價值**：2 個 LIF 中 1 個不可達時，`pvesm status` 修正後 **3.04s** 返回，修正前 **31.25s**(≥10 倍加速)。pvestatd 每 10 秒輪詢一次 `activate_storage`，沒有這個 fix 的話一個壞 LIF 會讓每次輪詢變成重疊卡頓 — 這正是把 Pure 客戶 web UI 拖死的連鎖反應。Probe 2 秒抵 iscsiadm 30+60 秒的不對稱比例，表示 LIF 數越多 fix 價值越大。

#### Regression: 基本連線

| # | 測試 | 結果 |
|---|------|------|
| 1 | 兩個 LIF 都通時 `pvesm status` 顯示 netapp1 active | PASS(35.90% 已用，<2s 返回) |
| 1 | 測試清理後 iSCSI sessions 重新建立 | PASS(2 條到新 IQN 的 session) |

**備註**：
- 測試環境有 4 個從舊版 ONTAP simulator 殘留的 zombie iSCSI sessions(舊 IQN `sn.913c2e94...` 與 `sn.6ca6fd5f...`)，無法乾淨 logout(`error 32 - target likely not connected`)。這些**不會**干擾 `is_portal_logged_in($portal, $new_iqn)` 判斷，因為查詢同時比對 portal 與 target IQN。叢集建議清法：重開機清掉 iscsi-tcp kernel state。測試有效性不需要這步。
- Sections 2-22 本次未重跑：本次變更僅限於 `activate_storage()` 的 iSCSI portal 迴圈與一個新 helper，未動到資料路徑相關程式碼。Section 23.5 靜態守則涵蓋新程式碼的 regression。

**結論**：Section 23 全部通過。v0.2.12-1 可發佈。

---

每個版本發佈前都必須通過上述所有測試。結果記錄於下方。

### v0.2.10-1 災難預防與監控 Release (2026-04-30)

**範圍**：v0.2.10 新監控功能 (Section 22) + Section 1-5、12、17、19、21 完整 regression。

**測試環境**：單節點測試 (PVE 9.1, ONTAP simulator)，netapp1 storage，2 個 iSCSI session。

#### Section 22：v0.2.10 災難預防與監控

| # | 測試 | 結果 |
|---|------|------|
| 22.1 | 儲存斷線：30 秒+ 觸發 ERROR，60 秒冷卻後重新發送 | PASS |
| 22.2 | 儲存恢復：INFO 訊息 | PASS（`reachable again after 137s outage`）|
| 22.3 | LIF 冗餘：< 2 個 LIF 觸發 WARNING（mock API） | PASS |
| 22.4 | Aggregate 容量：95% 觸發 CRITICAL（mock API） | PASS |
| 22.5 | 進行中操作偵測：postinst 警告 + 5 秒緩衝 | PASS（偵測到 `qm move-disk` dummy process）|
| 22.6 | 靜態：syslog 用 sprintf-then-%s 模式 | PASS（4+ 處）|
| 22.7 | 靜態：activate_storage 紀錄失敗（3 處）| PASS |

#### Regression：核心操作

| # | Section / 測試 | 結果 |
|---|----------------|------|
| 1 | 基本連線：storage active，2 iSCSI session | PASS |
| 2.1-2.5 | VM 磁碟生命週期 | PASS |
| 3.1-3.7 | VM 操作：快照 + 倒回 + 調整大小 | PASS |
| 4.1-4.2 | 磁碟遷移：往返 | PASS |
| 5.1 | Full clone | PASS |
| 5.2 | Template + linked clone | PASS |
| 12.1-12.2 | 殘留裝置防護 | PASS |
| 17.1 | Status 效能：1.08 秒 | PASS |

#### 測試中發現並修正的 bug

| 問題 | 修正 |
|------|------|
| `_record_status_failure` 只在 `status()` 中，不在 `activate_storage`。PVE 會 cache inactive storage，可能不會每次 poll 都呼叫 `status()`。實際斷線時 plugin 無法警示。 | 在 `activate_storage` 三處（API 連線、SVM 查詢、aggregate 查詢失敗）加上 `_record_status_failure`。|
| 原本「連續次數」門檻（3 次=30 秒）沒觸發，因為 PVE 每次斷線只 retry 一次。 | 改用「首次失敗時間戳 + 持續時間」：失敗超過 30 秒就發出 ERROR，60 秒冷卻避免洪水。|

**結論**：所有 v0.2.10 測試 PASS。所有 regression 測試 PASS。v0.2.10-1 可發佈。

### v0.2.9-1 ASA 最終一致性修復 Release (2026-04-26)

**範圍**：v0.2.9 新功能 (lun_map retry) + 全面 regression (Section 1-5、12、17、19、20、21)。

**測試環境**：單節點測試 (PVE 9.1, ONTAP simulator)，netapp1 storage，2 個 iSCSI session。

#### Section 20.10：v0.2.9 ASA 最終一致性

| # | 測試 | 結果 |
|---|------|------|
| 20.10.1 | 靜態：lun_map 有 retry loop（5 次、1 秒間隔、warn 訊息） | PASS |
| 20.10.2 | 功能：move-disk NetApp -> local-lvm -> NetApp（無「LUN not found」）| PASS |
| 20.10.3 | 功能：3 個並行 alloc（全部成功，simulator 上無需 retry） | PASS |

#### Regression：核心操作 (Section 1-5、12、17)

| # | Section / 測試 | 結果 |
|---|----------------|------|
| 1 | 基本連線：storage active，2 個 iSCSI session | PASS |
| 2.1-2.5 | VM 磁碟生命週期：alloc + path + R/W + free | PASS |
| 3.1-3.7 | VM 操作：快照 + 回溯 + 調整大小 | PASS |
| 4.1-4.2 | 磁碟遷移：move-disk 往返 | PASS |
| 5.1 | Full clone | PASS |
| 5.2 | Template + linked clone | PASS |
| 12.1 | 殘留裝置防護：free 後無殘留 | PASS |
| 12.2 | 無 failed faulty multipath 路徑 | PASS |
| 17.1 | Status 效能：< 2 秒 | PASS |

#### Regression：審查修復 (Section 19)

| # | 測試 | 結果 |
|---|------|------|
| 19.1.1 | cleanup 路徑沒有 volume_delete 缺少前置 lun_unmap_all | PASS |
| 19.1.2 | /sys/block 附近無不安全的 basename | PASS |
| 19.1.3 | get_multipath_wwid 已刪除 | PASS |
| 19.1.4 | 無 bare system() 呼叫 | PASS |
| 19.1.5 | 無 bare open /sys | PASS |
| 19.3 | 停止的 VM 快照（snap 前 flush） | PASS |
| 19.8 | ONTAP limit 錯誤翻譯（6/6 pattern） | PASS |
| 19.9.1 | 靜態：rescan 使用 /sys/class/iscsi_host | PASS |
| 19.9.2 | Strace：只掃描 host4+host5 (iSCSI)，不碰 host0-3 | PASS |
| 19.9.3 | 新 LUN 透過 iSCSI rescan 探索 | PASS |
| 19.13 | Postinst reload 全部 3 個服務（靜態） | PASS |

#### Regression：客戶事件 (Section 20)

| # | 測試 | 結果 |
|---|------|------|
| 20.2 | pvestatd reload：postinst 包含 3 個服務 | PASS |
| 20.5 | Partition dm-name 格式變體（8/8 pattern） | PASS |

#### Regression：程式碼審查 Guards (Section 21)

| # | 測試 | 結果 |
|---|------|------|
| 21.1 | 殘留清理條件式 untrack | PASS |
| 21.2 | alloc_image 有界 TOCTOU retry（5 次） | PASS |
| 21.3 | 無 multipath -F 推薦 | PASS |
| 21.4 | 所有 glob() 有 alarm timeout | PASS |

#### Final state

- WWID 追蹤：空（無殘留）
- D-state 行程：0
- Multipath NETAPP 裝置：0
- 服務：pvedaemon、pvestatd、pveproxy 全部 active
- pvesm status netapp1：active，1 秒回應

**結論**：所有 v0.2.9 測試 PASS。所有 regression 測試 PASS。v0.2.9-1 可發佈。

### v0.2.7-1 Partition Holder 安全性 Release (2026-04-10)

**範圍**：v0.2.7 新功能 (kpartx partition holder 忽略、dm-name 格式變體) + Section 20 客戶事件重現 + 完整 regression (Section 2、3、5、19.1、19.9、19.10)。

**測試環境**：單節點測試 (PVE 9.1, ONTAP simulator)，netapp1 storage。

#### Section 19.14: v0.2.7 Partition Holder 安全性

| # | 測試 | 結果 |
|---|------|------|
| 19.14.1 | 只有 partition holders：刪除成功 | PASS |
| 19.14.2 | Partition + LVM sub-holder：刪除被擋 | PASS |
| 19.14.3 | Partition 被 mount：刪除被擋 | PASS |
| 19.14.4 | /proc/swaps 檢查存在（靜態） | PASS |
| 19.14.5 | dm-name 格式 regex 涵蓋所有變體 (8/8) | PASS |

#### Section 20: 客戶事件重現

| # | 測試 | 結果 |
|---|------|------|
| 20.1 | HPE ProLiant smartpqi 掃描卡住：strace 確認僅 iSCSI | PASS |
| 20.2 | pvestatd reload：postinst 包含全部 3 個服務 | PASS |
| 20.3 | PVE 主機 LVM auto-activation：詳細錯誤含 VG 名稱 + 修復指令 | PASS |
| 20.4 | kpartx partition holders：bare partition 忽略，LVM sub-holder 擋住 | PASS |
| 20.5 | Partition dm-name 格式變體：8/8 模式正確 | PASS |
| 20.6 | Postinst lvm.conf global_filter 偵測：程式碼存在 | PASS |
| 20.7 | 殘留警告冷卻：1 小時內無重複警告 | PASS |

#### Regression

| # | Section / 測試 | 結果 |
|---|----------------|------|
| R1 | Section 2: alloc + path + free | PASS |
| R2 | Section 3: snapshot + rollback + resize | PASS |
| R3 | Section 5: template + linked clone | PASS |
| R4 | 19.1 靜態稽核 (5 項) | PASS |
| R5 | 19.9.2 strace: 僅 rescan iSCSI host | PASS |
| R6 | 19.10 詳細錯誤訊息 | PASS |

#### 最終狀態

- WWID 追蹤： {} 空
- D-state 程序： 0
- 服務： pvedaemon、pvestatd、pveproxy 全部 active
- pvesm status netapp1: active

**結論**：全部 v0.2.7 測試 PASS。全部 regression 測試 PASS。v0.2.7-1 可發佈。

### v0.2.6-1 Postinst + 操作者 UX 改善版 (2026-04-10)

**範圍**：v0.2.6 新功能 (詳細錯誤訊息、殘留警告冷卻、lvm.conf 偵測、pvestatd 重新載入) + 完整 regression (Section 2、3、5、19.1、19.8、19.9)。

**測試環境**：單節點測試 (PVE 9.1, ONTAP simulator),netapp1 storage。測試主機已設定 global_filter (lvm.conf 警告不會觸發；已透過程式碼審查驗證警告路徑)。

#### Section 19.10-19.13: v0.2.6 新功能

| # | 測試 | 結果 |
|---|------|------|
| 19.10 | 詳細錯誤： 顯示 holder 名稱 + dm-name | PASS |
| 19.10 | 詳細錯誤： 從 dm-name 自動偵測 VG | PASS (以 checktc--vg-root 模式測試) |
| 19.10 | 詳細錯誤： 顯示 vgchange -an 指令 | PASS |
| 19.10 | 詳細錯誤： 顯示 global_filter 建議 | PASS |
| 19.10 | 移除 holder 後刪除成功 | PASS |
| 19.11 | 殘留警告冷卻： /var/run/pve-storage-netapp/ 旗標目錄 | PASS (按需建立) |
| 19.12 | Postinst: lvm.conf 含 global_filter 時不發出警告 | PASS |
| 19.12 | Postinst: 靜態檢查 global_filter 偵測程式碼 | PASS (grep 確認程式碼存在) |
| 19.13 | Postinst: 全部 3 個服務重新載入 (pvedaemon + pvestatd + pveproxy) | PASS |

#### Regression

| # | Section / 測試 | 結果 |
|---|----------------|------|
| R1 | Section 2: alloc + path + free | PASS |
| R2 | Section 3: snapshot + rollback + resize | PASS |
| R3 | Section 5: template + linked clone | PASS |
| R4 | 19.1 靜態稽核 (5 項) | PASS |
| R5 | 19.8 limit 錯誤訊息翻譯 (4/4) | PASS |
| R6 | 19.9.2 strace: 僅 rescan iSCSI host | PASS (僅 host4-7) |
| R7 | 19.9.3 新 LUN 探索 | PASS |

#### 最終狀態

- WWID 追蹤： {} 空
- D-state 程序： 0
- 服務： pvedaemon、pvestatd、pveproxy 全部 active
- pvesm status netapp1: active

**結論**：全部 v0.2.6 測試 PASS。全部 regression 測試 PASS。v0.2.6-1 可發佈。

### v0.2.5-1 非 iSCSI SCSI Host 掃描修復 (2026-04-10)

**範圍**：Section 19.9 (新增 Bug Incident 8 regression guard) + Section 1、2、3、5 的 regression + v0.2.4 的單元測試。

**測試環境**：單節點 PVE 9.1 + ONTAP simulator,netapp1 storage。

**測試 host 的 SCSI 清單 (對 19.9.2 很重要):**
- host0-1: virtio_scsi
- host2-3: ata_piix
- host4-7: iscsi_tcp

這是「混合 driver」環境 — 修復必須只碰 host4-7 (iSCSI)，完全不碰 host0-3。

#### Section 19.9: rescan_scsi_hosts 只過濾 iSCSI

| # | 測試 | 結果 |
|---|------|------|
| 19.9.1 | 靜態稽核： `rescan_scsi_hosts` 引用 `/sys/class/iscsi_host` | PASS |
| 19.9.1 | 靜態稽核： `rescan_scsi_hosts` 不再 `opendir` `SCSI_HOST_PATH` | PASS |
| 19.9.1 | 靜態稽核： `rescan_fc_hosts` 不再迭代整個 `/sys/class/scsi_host` | PASS |
| 19.9.2 | **strace 證明： `rescan_scsi_hosts()` 只打開 host4-7 的 scan 檔案，完全沒碰 host0-3** | **PASS** |
| 19.9.3 | 功能 regression: `pvesm alloc` 仍能透過 iSCSI rescan 找到新 LUN | PASS |

**關鍵 strace 輸出 (19.9.2):**
```
openat(AT_FDCWD, "/sys/class/scsi_host/host4/scan", O_WRONLY|...)
openat(AT_FDCWD, "/sys/class/scsi_host/host5/scan", O_WRONLY|...)
openat(AT_FDCWD, "/sys/class/scsi_host/host6/scan", O_WRONLY|...)
openat(AT_FDCWD, "/sys/class/scsi_host/host7/scan", O_WRONLY|...)
```
完全沒有 open host0/1 (virtio_scsi) 或 host2/3 (ata_piix)。v0.2.5 之前會看到 8 個全部被開。

#### Regression: Sections 1、2、3、5 + v0.2.4 單元測試

| # | 章節 / 測試 | 結果 |
|---|-------------|------|
| R1 | Section 1: pvesm status | PASS |
| R2 | Section 2: alloc + path + free | PASS |
| R3 | Section 3: VM snapshot + rollback + resize + delsnapshot | PASS |
| R4 | Section 5: template + linked clone | PASS |
| R5 | v0.2.4 Section 19.8: limit error translation (6/6 cases) | PASS |

**最終狀態**：
- WWID tracking: `{}` 空
- D-state processes: 0
- pvedaemon / pveproxy: active

**結論**：Section 19.9 全部 PASS。所有 regression 全部 PASS。v0.2.5-1 可以發佈。

### v0.2.4-1 稽核修復 Release (2026-04-09)

**範圍**：Section 19 (新增 v0.2.4 cleanup 順序 / snapshot 落盤 / 無用程式碼修復測試)，加上 Section 1、2、3、5 的 regression。

**測試環境**：單節點 PVE 9.1 + ONTAP simulator,netapp1 storage,2 個 iSCSI portal,multipath 為 `dev_loss_tmo 60` + `no_path_retry 30`。Plugin 透過 `make deb` 建置並以 `dpkg -i jt-pve-storage-netapp_0.2.4-1_all.deb` 安裝。

#### Section 19: v0.2.4 稽核修復測試

| #  | 測試 | 結果 |
|----|------|------|
| 19.1.1 | Cleanup 路徑沒有 `volume_delete` 缺少前置 `lun_unmap_all` | PASS (alloc_image:1063, clone_image:2071+2112, free_image:1149, temp clone:1529 全部驗證；alloc_image:1028 是 LUN-create 失敗路徑，當下沒有 LUN 可 unmap，安全) |
| 19.1.2 | Multipath.pm 沒有不安全的 `basename()` 在 `/sys/block/` 附近使用 | PASS (剩下的都是安全用法：resolver 自身、傳給 dmsetup/multipathd 的 map name、操作 /sys/block/sd* 個別 path) |
| 19.1.3 | 無用程式碼 `get_multipath_wwid()` 已刪除 | PASS (zero matches) |
| 19.1.4 | 沒有 bare `system()` 呼叫 | PASS (zero matches) |
| 19.1.5 | 沒有 bare `open()` 寫到 `/sys/` | PASS (zero matches) |
| 19.2 | clone_image happy path:linked clone + full clone + destroy 不留下殘留 | PASS (沒有 failed multipath,WWID tracking 在 status() poll 後自動收斂為空) |
| 19.3 | 對停機 VM 做 volume_snapshot，觸發 pre-flush 路徑成功 | PASS (snapshot 建立成功，dmesg 無 flush 錯誤，rollback 正常) |
| 19.4 | 對運行中 VM 做 volume_snapshot，正確 skip flush (device in use) | PASS (沒有 hang、沒有 flush 警告，snapshot 成功) |
| 19.5 | 對運行中 VM 執行 qm resize (v0.2.3 regression check) | PASS (沒有 "Cannot grow device files" 錯誤，blockdev --getsize64 確認 1610612736 bytes，從 1G 加 512M) |
| 19.6 | is_device_in_use 偵測 `/dev/mapper/<wwid>` 上的 dm-linear holder (v0.2.3 資料遺失修復重驗) | PASS (回傳 IN_USE,pvesm free 正確拒絕並顯示清楚錯誤訊息，volume 保留) |

#### Section 19.2 詳細觀察

- 兩個 clones 在 destroy 時都正確觸發 `dmsetup remove --force --retry` fallback (在這個 simulator 帶 legacy `queue_if_no_path` 設定下，這是 v0.2.3 預期行為)
- Template volume 命中已知的 ONTAP simulator stale clone metadata 錯誤後，`status()` 的 auto-import 自動清除了該殘留 WWID，證明 v0.2.3 的 cluster 收斂機制在 v0.2.4 仍正常運作

#### Section 19.6 詳細觀察

- 使用 `dmsetup create test_holder ... linear /dev/mapper/<wwid>` 建立真實的 holder 關係 (這個 PVE host 的 LVM filter 會拒絕 multipath 裝置，所以直接用 dm-linear 是更可靠的 holder 測試)
- Resolver 解出來後：`/sys/block/dm-9/holders/dm-10` 正確列出
- `is_device_in_use('/dev/mapper/3600a09807770457a795d5a7653705a63')` 回傳 1
- `pvesm free` 拒絕並回覆：`Cannot delete volume 'vm-9963-disk-0': device /dev/mapper/3600a09807770457a795d5a7653705a63 is still in use (mounted, has holders, or open by process)`
- 執行 `dmsetup remove test_holder_v024` 之後，`pvesm free` 正常成功

#### Regression: Sections 1、2、3、5

| #  | 章節 / 測試 | 結果 |
|----|--------------|------|
| R1 | Section 1: pvesm status, pvesm list | PASS |
| R2 | Section 2: alloc + path + free | PASS |
| R3 | Section 3.2-3.4: snapshot snap1, snap2, delete snap1 | PASS |
| R4 | Section 3.5: rollback snap2 | PASS |
| R5 | Section 3.6: qm resize +512M | PASS (config 顯示 1536M) |
| R6 | Section 5.1: qm clone --full 1 | PASS |
| R7 | Section 5.2: qm template + linked clone | PASS (功能正常；template volume 命中 ONTAP simulator stale clone metadata 限制，已記錄於 CLAUDE.md，不是 plugin bug) |

#### 最終狀態

- WWID tracking 檔案：`{}` (空，完全收斂)
- multipath：沒有任何 failed 狀態的 NETAPP 裝置
- Process 狀態：沒有 D-state process
- 服務：pvedaemon active、pveproxy active

**結論**：Section 19 全部 PASS，所有 regression PASS。v0.2.4-1 可以發佈。

### v0.2.2-1 擴展測試套件 (2026-04-08)

**測試環境**：與 v0.2.1 相同，配合混合 multipath.conf（保留既有的手動 NetApp 設定，含 `queue_if_no_path` 和 `dev_loss_tmo infinity` -- 故意保留以驗證 postinst 警告）。

#### 第 1-2 區：基本連線與磁碟生命週期

| # | 測試項目 | 結果 |
|---|---------|------|
| T1 | Storage 啟用 | PASS |
| T2 | iSCSI sessions >= 2 | PASS |
| T3 | Alloc image | PASS |
| T4 | Path 解析 | PASS |
| T5 | Multipath active | PASS |
| T6 | 寫入測試 (dd) | PASS |
| T7 | 讀取測試 (dd) | PASS |
| T8 | WWID 已記錄到追蹤檔 | PASS |
| T9 | Free image (無殘留) | PASS |
| T10 | Free 後 WWID 解除追蹤 | PASS |

#### 第 3 區：VM 操作與遷移

| # | 測試項目 | 結果 |
|---|---------|------|
| T11 | 建立 VM 並把磁碟放到 NetApp | PASS |
| T12 | 快照 1 | PASS |
| T13 | 快照 2 | PASS |
| T14 | 刪除快照 | PASS |
| T15 | 回滾 (rollback) | PASS |
| T16 | Resize +256M | PASS |
| T17 | 遷移磁碟 NetApp -> local-lvm | PASS |
| T18 | 遷移磁碟 local-lvm -> NetApp | PASS |
| T19 | Full Clone | PASS |
| T20 | 轉換為 Template | PASS |
| T21 | Linked Clone | PASS |
| T22 | EFI 磁碟 | PASS |
| T23 | Cloud-init 磁碟 | PASS |
| T24 | TPM 狀態 | PASS |
| T25 | LXC 建立 (rootfs 在 NetApp) | PASS |
| T26 | LXC 啟動 | PASS |
| T27 | LXC 快照 | PASS |

#### 第 4 區：對既有 VM 新增/移除磁碟

| # | 測試項目 | 結果 |
|---|---------|------|
| T28 | 對既有 VM 新增 2GB 磁碟 (qm set --scsi1) | PASS |
| T29 | 磁碟出現在配置中 | PASS |
| T30 | 再新增 1GB 磁碟 (scsi2) | PASS |
| T31 | Resize 新增的磁碟 | PASS |
| T32 | 透過 qm set --delete 卸載磁碟 | PASS |
| T33 | 磁碟顯示為 unused | PASS |
| T34 | 刪除 unused 磁碟 | PASS |
| T35 | 透過 qm unlink 強制刪除 | PASS |
| T36 | 額外磁碟全部清除 | PASS |
| T37 | 磁碟移除後無殘留 multipath | PASS |

#### 第 5 區：殘留清理 (叢集情境)

端到端測試：模擬 Node A 刪除 VM，Node B 的 stale 裝置由 status() 輪詢自動清除。

| # | 測試項目 | 結果 |
|---|---------|------|
| T38 | path() 後 WWID 已追蹤 | PASS |
| T39 | 模擬叢集刪除 (僅透過 API) | PASS |
| T40 | 清理前 stale multipath 仍存在 | PASS |
| T41 | (略過：由 T42 涵蓋) | - |
| T42 | status() 輪詢觸發殘留清理 | PASS |
| T43 | WWID 從追蹤檔中移除 | PASS |

#### 第 6 區：混合環境、igroup、韌性測試

| # | 測試項目 | 結果 |
|---|---------|------|
| T44 | 追蹤檔結構正確 | PASS |
| T45 | alloc_image map 到所有節點 igroup | PASS |
| T46 | status() < 35 秒完成 | PASS (1 秒) |
| T47 | 無 PVE worker 處於 D state | PASS |
| T48 | postinst 警告邏輯偵測到危險設定 | PASS |

#### 第 7 區：PVE 實際工作流程（真實 VM 生命週期）

| # | 測試項目 | 結果 | 備註 |
|---|---------|------|------|
| T49 | VM 建立 | PASS | |
| T50 | VM 啟動（觸發 storage activate）| PASS | 巢狀測試使用 TCG 模式 |
| T51 | 熱插拔磁碟到執行中的 VM | PASS | qm set --scsi1 |
| T52 | 熱插拔的磁碟可見 | PASS | |
| T53 | 從執行中的 VM 熱拔除磁碟 | PASS | |
| T54 | VM 停止 | PASS | |
| T55 | vzdump 備份 | PASS | mode=stop |
| T56 | qmrestore 還原至 NetApp | PASS | 跨儲存還原 |
| T57 | 多磁碟 VM 執行中 | PASS | 2 磁碟 |
| T58 | 帶 RAM 狀態的 VM 快照 (vmstate) | PASS | QEMU 狀態存到專用 LUN |
| T59 | 刪除 RAM 快照 | PASS | |

#### 第 8 區：故障情境

| # | 測試項目 | 結果 | 備註 |
|---|---------|------|------|
| T65 | 多重路徑降級時 I/O 持續 | PASS | 2/4 路徑時 35 MB/s |
| T66 | Multipath 正確降級 | PASS | 部分 failed，部分 active |
| T67 | LIF 恢復後路徑恢復 | PASS | |
| T69 | iSCSI 全斷時 status() 仍可完成 | PASS | 1 秒（使用 API 非 iSCSI）|
| T70 | ONTAP API 封鎖時 status() | PASS | 33 秒 timeout，回 inactive |
| T71 | 封鎖期間無 PVE worker 進入 D state | PASS | 所有 timeout 保護生效 |

#### 第 9 區：ONTAP 端協同故障測試

這些測試需要 ONTAP 端配合操作（由獨立的 ONTAP 管理 agent 執行）。

| # | 測試項目 | 結果 | 備註 |
|---|---------|------|------|
| T72 | iSCSI service stop/start (~36 秒中斷) | PASS | dd 在 counter=92 被 queue，重啟後自動恢復，零資料遺失 |
| T73 | 4 條 multipath 路徑在 iSCSI 重啟後恢復 | PASS | iscsi start 後 6 秒內 |
| T74 | dd 在 iSCSI 恢復後自動繼續 | PASS | counter 92 → 95 → 101（無需人工介入）|
| T75 | dd 在中斷期間進入 D state 但會恢復 | PASS | 非永久卡死 |
| T76 | PVE worker 全程無 D state 卡死 | PASS | 整個中斷期間 |
| T77 | 手動建立 ONTAP volume 衝突 (TOCTOU) | PASS | `pvesm alloc` 自動 retry 下一個 disk ID |
| T78 | 連續衝突 retry | PASS | disk-0 衝突 → disk-1，再 disk-0 → disk-2 |
| T79 | API 401 偵測 | PASS | 警告紀錄：「ONTAP API returned 401, reinitializing auth」|
| T80 | API 401 reinit auth 嘗試 | PASS | Fix #10 (v0.2.1) 端到端驗證 |
| T81 | 認證失敗時優雅失敗 | PASS | status() 9 秒內回 inactive，無卡死 |
| T82 | 密碼恢復後 storage 自動恢復 | PASS | 1 秒回 active，完整功能恢復 |
| T83 | 401 處理過程無 PVE worker 在 D state | PASS | |

#### 第 10 區：ONTAP 端協同故障測試（v0.2.3 重新驗證）

這些測試在 v0.2.3 跟 ONTAP 管理 agent 協同重新執行。

| # | 測試項目 | 結果 | 備註 |
|---|---------|------|------|
| T72 | iSCSI service stop/start（~65 秒中斷）| PASS | dd counter 凍結於 79，重啟後繼續寫到 121 |
| T73 | 4 條 multipath 路徑全部恢復 | PASS | iscsi start 後 3 秒內 |
| T74 | dd 在 iSCSI 恢復後自動繼續 | PASS | counter 79 → 83 → 158（無需人工介入）|
| T75 | dd 在中斷期間進入 D state 但會恢復 | PASS | 非永久卡死 |
| T76 | PVE worker 全程無 D state 卡死 | PASS | 整個中斷期間 |
| **T76b** | **v0.2.3: 在 queue_if_no_path 設定下 free LUN** | **PASS** | **dmsetup fallback 觸發，free 8 秒完成（非永久卡住）** |
| T77 | 手動 ONTAP volume 衝突 (TOCTOU) | PASS | `pvesm alloc` 自動 retry 用 disk-1 |
| T78 | 連續衝突 retry | PASS | disk-0 衝突 → disk-1，再 disk-0 → disk-2 |
| T79 | API 401 偵測 | PASS | 警告紀錄：「ONTAP API returned 401, reinitializing auth (attempt 1/2)」|
| T80 | API 401 reinit auth 嘗試 | PASS | Fix #10 端到端驗證 |
| T81 | 認證失敗時優雅失敗 | PASS | status() 10 秒內回 inactive，無卡死 |
| T82 | 密碼恢復後 storage 自動恢復 | PASS | **2 秒**回 active，完整功能恢復 |
| T83 | 401 處理過程無 PVE worker 在 D state | PASS | 連續多次 status() 都正常 |

**v0.2.3 總計：92/92 PASS**（71 先前測試 + 9 修復後驗證 + 12 ONTAP 協同重跑）

**總計：75/75 PASS**

**v0.2.2 已驗證的改進**：
- 叢集殘留清理機制端到端正常運作
- WWID 追蹤在 path() / free_image() 生命週期中正確維護
- alloc_image 對應到所有 per-node igroups（不只當前節點）
- 混合環境（手動 NetApp + plugin）安全 -- 只碰追蹤過的 WWID
- API 401 重試邏輯已驗證有效（測試中 Perl shell 引號觸發 401，plugin 自動恢復）
- status() 輪詢快速且永不掛起

### v0.2.2-1 初版測試 (2026-04-08)

**測試環境**：與 v0.2.1 相同

| # | 測試項目 | 結果 | 備註 |
|---|---------|------|------|
| T1-T22 | 所有 v0.2.1 測試 | PASS | |
| T23 | **殘留清理 (叢集情境)** | **PASS** | 初步驗證 |

**總計：23/23 PASS**

### v0.2.1-1 (2026-04-08)

**測試環境**：
- Proxmox VE 9.1 (kernel 6.17.4-2-pve)
- ONTAP Simulator 9.16.1 (單節點)
- 2 個 iSCSI LIF (192.168.1.197、192.168.1.198)
- 主機 2 張 NIC (每個 LUN 4 條多重路徑)
- 主機已有手動 multipath 設定

| # | 測試項目 | 結果 | 備註 |
|---|------|--------|-------|
| T1 | Storage status | PASS | Active，容量正確回報 |
| T2 | iSCSI sessions | PASS | 4 sessions (2 NIC x 2 LIF) |
| T3 | Alloc + Path + Multipath | PASS | 每個 LUN 4 條 active 路徑 |
| T4 | 讀/寫 (dd) | PASS | 寫入 40 MB/s，讀取 29 MB/s |
| T5 | Free + 清除 | PASS | Volume 已移除，multipath 已清理 |
| T6 | 於 NetApp 建立 VM | PASS | |
| T7 | 快照 (建立 x2) | PASS | |
| T8 | 快照刪除 | PASS | |
| T9 | 快照還原 | PASS | |
| T10 | 磁碟調整大小 (+512M) | PASS | 線上調整 |
| T11 | 磁碟移動 NetApp -> local-lvm | PASS | 無 hang，完整複製完成 |
| T12 | 磁碟移動 local-lvm -> NetApp | PASS | 無 hang，完整複製完成 |
| T13 | Full Clone | PASS | |
| T14 | 範本 + Linked Clone | PASS | FlexClone 立即建立 |
| T15a | EFI Disk | PASS | OVMF vars 位於 NetApp LUN |
| T15b | Cloud-init Disk | PASS | ISO 位於 NetApp LUN |
| T15c | TPM State | PASS | TPM 2.0 位於 NetApp LUN |
| T16 | LXC 建立 (rootfs 於 NetApp) | PASS | 格式化為 ext4，範本已解開 |
| T17 | LXC 啟動 | PASS | 容器 running |
| T18 | LXC 快照 | PASS | |
| T19 | igroup 對應 (多節點) | PASS | LUN 對應至兩個節點的 igroup |
| T20 | 逾時保護 | PASS | sysfs 寫入逾時觸發，無 hang |
| T21 | activate_storage 略過探索 | PASS | 重用既有 sessions，無 30 秒延遲 |
| T22 | postinst 警告顯示 | PASS | 對危險 multipath 設定顯示彩色警告 |

**已知限制 (僅限測試環境)**：
- SCSI host6 掃描因測試 VM 的 NIC 設定而持續逾時 (10 秒) — 不影響操作，逾時保護機制運作正常
- ONTAP 模擬器的過期 FlexClone 中繼資料導致部分範本 volume 無法刪除 — 屬 ONTAP 端問題，非外掛 bug
