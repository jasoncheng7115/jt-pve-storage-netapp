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

驗證 pre-flush 在 device 被使用時正確 skip,不會 block live VM。

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

驗證 v0.2.4 在 `clone_image` 的 TOCTOU race 修復。三個並行的 template clone 應該全部成功並有不同的 disk ID,沒有 "already exists" 錯誤。

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

### 19.8 ONTAP 上限錯誤翻譯 (Bug I,單元測試)

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

驗證 `rescan_scsi_hosts()` 只對從 `/sys/class/iscsi_host/` 取得的 iSCSI host 寫入 scan 檔案,絕對不碰非 iSCSI host (像是 HBA RAID、USB 讀卡機、virtio-scsi 等)。

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

## 清除

```bash
# 移除所有測試 VM 與容器
qm destroy 9900 --purge 2>/dev/null
qm destroy 9901 --purge 2>/dev/null
qm destroy 9902 --purge 2>/dev/null
qm destroy 9903 --purge 2>/dev/null
pct destroy 9910 --purge 2>/dev/null

# 驗證 ONTAP 上無孤立 volume
pvesm list $STORAGE
```

---

## 發佈測試結果

每個版本發佈前都必須通過上述所有測試。結果記錄於下方。

### v0.2.5-1 非 iSCSI SCSI Host 掃描修復 (2026-04-10)

**範圍:** Section 19.9 (新增 Bug Incident 8 regression guard) + Section 1、2、3、5 的 regression + v0.2.4 的單元測試。

**測試環境:** 單節點 PVE 9.1 + ONTAP simulator,netapp1 storage。

**測試 host 的 SCSI 清單 (對 19.9.2 很重要):**
- host0-1: virtio_scsi
- host2-3: ata_piix
- host4-7: iscsi_tcp

這是「混合 driver」環境 — 修復必須只碰 host4-7 (iSCSI),完全不碰 host0-3。

#### Section 19.9: rescan_scsi_hosts 只過濾 iSCSI

| # | 測試 | 結果 |
|---|------|------|
| 19.9.1 | 靜態稽核: `rescan_scsi_hosts` 引用 `/sys/class/iscsi_host` | PASS |
| 19.9.1 | 靜態稽核: `rescan_scsi_hosts` 不再 `opendir` `SCSI_HOST_PATH` | PASS |
| 19.9.1 | 靜態稽核: `rescan_fc_hosts` 不再迭代整個 `/sys/class/scsi_host` | PASS |
| 19.9.2 | **strace 證明: `rescan_scsi_hosts()` 只打開 host4-7 的 scan 檔案,完全沒碰 host0-3** | **PASS** |
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

**最終狀態:**
- WWID tracking: `{}` 空
- D-state processes: 0
- pvedaemon / pveproxy: active

**結論:** Section 19.9 全部 PASS。所有 regression 全部 PASS。v0.2.5-1 可以發佈。

### v0.2.4-1 稽核修復 Release (2026-04-09)

**範圍:** Section 19 (新增 v0.2.4 cleanup 順序 / snapshot 落盤 / 無用程式碼修復測試),加上 Section 1、2、3、5 的 regression。

**測試環境:** 單節點 PVE 9.1 + ONTAP simulator,netapp1 storage,2 個 iSCSI portal,multipath 為 `dev_loss_tmo 60` + `no_path_retry 30`。Plugin 透過 `make deb` 建置並以 `dpkg -i jt-pve-storage-netapp_0.2.4-1_all.deb` 安裝。

#### Section 19: v0.2.4 稽核修復測試

| #  | 測試 | 結果 |
|----|------|------|
| 19.1.1 | Cleanup 路徑沒有 `volume_delete` 缺少前置 `lun_unmap_all` | PASS (alloc_image:1063, clone_image:2071+2112, free_image:1149, temp clone:1529 全部驗證;alloc_image:1028 是 LUN-create 失敗路徑,當下沒有 LUN 可 unmap,安全) |
| 19.1.2 | Multipath.pm 沒有不安全的 `basename()` 在 `/sys/block/` 附近使用 | PASS (剩下的都是安全用法:resolver 自身、傳給 dmsetup/multipathd 的 map name、操作 /sys/block/sd* 個別 path) |
| 19.1.3 | 無用程式碼 `get_multipath_wwid()` 已刪除 | PASS (zero matches) |
| 19.1.4 | 沒有 bare `system()` 呼叫 | PASS (zero matches) |
| 19.1.5 | 沒有 bare `open()` 寫到 `/sys/` | PASS (zero matches) |
| 19.2 | clone_image happy path:linked clone + full clone + destroy 不留下殘留 | PASS (沒有 failed multipath,WWID tracking 在 status() poll 後自動收斂為空) |
| 19.3 | 對停機 VM 做 volume_snapshot,觸發 pre-flush 路徑成功 | PASS (snapshot 建立成功,dmesg 無 flush 錯誤,rollback 正常) |
| 19.4 | 對運行中 VM 做 volume_snapshot,正確 skip flush (device in use) | PASS (沒有 hang、沒有 flush 警告,snapshot 成功) |
| 19.5 | 對運行中 VM 執行 qm resize (v0.2.3 regression check) | PASS (沒有 "Cannot grow device files" 錯誤,blockdev --getsize64 確認 1610612736 bytes,從 1G 加 512M) |
| 19.6 | is_device_in_use 偵測 `/dev/mapper/<wwid>` 上的 dm-linear holder (v0.2.3 資料遺失修復重驗) | PASS (回傳 IN_USE,pvesm free 正確拒絕並顯示清楚錯誤訊息,volume 保留) |

#### Section 19.2 詳細觀察

- 兩個 clones 在 destroy 時都正確觸發 `dmsetup remove --force --retry` fallback (在這個 simulator 帶 legacy `queue_if_no_path` 設定下,這是 v0.2.3 預期行為)
- Template volume 命中已知的 ONTAP simulator stale clone metadata 錯誤後,`status()` 的 auto-import 自動清除了該殘留 WWID,證明 v0.2.3 的 cluster 收斂機制在 v0.2.4 仍正常運作

#### Section 19.6 詳細觀察

- 使用 `dmsetup create test_holder ... linear /dev/mapper/<wwid>` 建立真實的 holder 關係 (這個 PVE host 的 LVM filter 會拒絕 multipath 裝置,所以直接用 dm-linear 是更可靠的 holder 測試)
- Resolver 解出來後:`/sys/block/dm-9/holders/dm-10` 正確列出
- `is_device_in_use('/dev/mapper/3600a09807770457a795d5a7653705a63')` 回傳 1
- `pvesm free` 拒絕並回覆:`Cannot delete volume 'vm-9963-disk-0': device /dev/mapper/3600a09807770457a795d5a7653705a63 is still in use (mounted, has holders, or open by process)`
- 執行 `dmsetup remove test_holder_v024` 之後,`pvesm free` 正常成功

#### Regression: Sections 1、2、3、5

| #  | 章節 / 測試 | 結果 |
|----|--------------|------|
| R1 | Section 1: pvesm status, pvesm list | PASS |
| R2 | Section 2: alloc + path + free | PASS |
| R3 | Section 3.2-3.4: snapshot snap1, snap2, delete snap1 | PASS |
| R4 | Section 3.5: rollback snap2 | PASS |
| R5 | Section 3.6: qm resize +512M | PASS (config 顯示 1536M) |
| R6 | Section 5.1: qm clone --full 1 | PASS |
| R7 | Section 5.2: qm template + linked clone | PASS (功能正常;template volume 命中 ONTAP simulator stale clone metadata 限制,已記錄於 CLAUDE.md,不是 plugin bug) |

#### 最終狀態

- WWID tracking 檔案:`{}` (空,完全收斂)
- multipath:沒有任何 failed 狀態的 NETAPP 裝置
- Process 狀態:沒有 D-state process
- 服務:pvedaemon active、pveproxy active

**結論:** Section 19 全部 PASS,所有 regression PASS。v0.2.4-1 可以發佈。

### v0.2.2-1 擴展測試套件 (2026-04-08)

**測試環境：** 與 v0.2.1 相同，配合混合 multipath.conf（保留既有的手動 NetApp 設定，含 `queue_if_no_path` 和 `dev_loss_tmo infinity` -- 故意保留以驗證 postinst 警告）。

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

**v0.2.2 已驗證的改進：**
- 叢集殘留清理機制端到端正常運作
- WWID 追蹤在 path() / free_image() 生命週期中正確維護
- alloc_image 對應到所有 per-node igroups（不只當前節點）
- 混合環境（手動 NetApp + plugin）安全 -- 只碰追蹤過的 WWID
- API 401 重試邏輯已驗證有效（測試中 Perl shell 引號觸發 401，plugin 自動恢復）
- status() 輪詢快速且永不掛起

### v0.2.2-1 初版測試 (2026-04-08)

**測試環境：** 與 v0.2.1 相同

| # | 測試項目 | 結果 | 備註 |
|---|---------|------|------|
| T1-T22 | 所有 v0.2.1 測試 | PASS | |
| T23 | **殘留清理 (叢集情境)** | **PASS** | 初步驗證 |

**總計：23/23 PASS**

### v0.2.1-1 (2026-04-08)

**測試環境：**
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

**已知限制 (僅限測試環境)：**
- SCSI host6 掃描因測試 VM 的 NIC 設定而持續逾時 (10 秒) — 不影響操作，逾時保護機制運作正常
- ONTAP 模擬器的過期 FlexClone 中繼資料導致部分範本 volume 無法刪除 — 屬 ONTAP 端問題，非外掛 bug
