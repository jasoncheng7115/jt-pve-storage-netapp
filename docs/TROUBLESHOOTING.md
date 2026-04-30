# Troubleshooting Guide - NetApp ONTAP Storage Plugin

## Quick Diagnostic Commands

```bash
# Check storage status
pvesm status

# Check PVE daemon logs
journalctl -xeu pvedaemon --since "10 minutes ago"

# Check iSCSI sessions
iscsiadm -m session

# Check multipath devices
multipathd show maps

# Check ONTAP API connectivity
curl -k -u username:password https://ONTAP_IP/api/cluster
```

---

## Installation Issues

### Plugin Not Loading

**Symptoms:**
- `netappontap` not shown in `pvesm add --help`
- Error: "unknown storage type 'netappontap'"

**Diagnosis:**

```bash
# Check if plugin file exists
ls -la /usr/share/perl5/PVE/Storage/Custom/NetAppONTAPPlugin.pm

# Check for syntax errors
perl -I /usr/share/perl5 -c /usr/share/perl5/PVE/Storage/Custom/NetAppONTAPPlugin.pm

# Check plugin loading logs
journalctl -xeu pvedaemon | grep -i "netapp\|plugin\|error"
```

**Solutions:**

1. **Reinstall plugin:**
   ```bash
   dpkg -i jt-pve-storage-netapp_*.deb
   systemctl restart pvedaemon pveproxy
   ```

2. **Check dependencies:**
   ```bash
   apt install -f
   ```

3. **Verify Perl modules:**
   ```bash
   perl -MPVE::Storage -e 'print "OK\n"'
   ```

### API Version Warning

**Symptoms:**
- Warning: "Plugin ... is implementing an older storage API"

**Solution:**
This warning is informational. The plugin will still work. To eliminate the warning, update to the latest plugin version.

---

## Storage Configuration Issues

### Storage Not Active

**Symptoms:**
- Storage shows "inactive" in `pvesm status`
- Cannot create VMs on storage

**Diagnosis:**

```bash
# Check storage configuration
pvesm config <storage-id>

# Test ONTAP API
curl -k -u <username>:<password> https://<portal>/api/cluster

# Check detailed error
journalctl -xeu pvedaemon | grep -i "netapp\|ontap" | tail -20
```

**Common Causes and Solutions:**

1. **Invalid credentials:**
   ```bash
   # Test credentials
   curl -k -u pveadmin:password https://192.168.1.100/api/cluster

   # Update password
   pvesm set <storage-id> --ontap-password 'NewPassword'
   ```

2. **Network connectivity:**
   ```bash
   # Test connectivity
   ping <ontap-portal>
   nc -zv <ontap-portal> 443

   # Check firewall
   iptables -L -n | grep 443
   ```

3. **SSL certificate issues:**
   ```bash
   # Temporarily disable SSL verification
   pvesm set <storage-id> --ontap-ssl-verify 0
   ```

4. **SVM not accessible:**
   ```bash
   # On ONTAP, verify SVM status
   vserver show -vserver <svm-name>

   # Verify iSCSI service
   vserver iscsi show -vserver <svm-name>
   ```

### Invalid Configuration

**Symptoms:**
- Error messages about missing or invalid options

**Solution:**

Verify all required options are set:
```bash
pvesm config <storage-id>

# Required options:
# - ontap-portal
# - ontap-svm
# - ontap-aggregate
# - ontap-username
# - ontap-password
```

---

## iSCSI Issues

### No iSCSI Sessions

**Symptoms:**
- `iscsiadm -m session` shows no sessions
- Cannot access LUNs

**Diagnosis:**

```bash
# Check iSCSI daemon
systemctl status iscsid

# Check for targets
iscsiadm -m discovery -t sendtargets -p <ontap-ip>

# Check initiator name
cat /etc/iscsi/initiatorname.iscsi
```

**Solutions:**

1. **Start iSCSI daemon:**
   ```bash
   systemctl enable --now iscsid
   ```

2. **Discover and login:**
   ```bash
   # Discover targets
   iscsiadm -m discovery -t sendtargets -p <ontap-data-ip>

   # Login to all discovered targets
   iscsiadm -m node --login
   ```

3. **Check igroup on ONTAP:**
   ```bash
   # On ONTAP CLI
   igroup show -vserver <svm>

   # Verify initiator is added
   igroup show -vserver <svm> -igroup pve_*
   ```

### Cannot Find LUN After Creation

**Symptoms:**
- Disk created successfully
- Device not appearing in `/dev/`

**Diagnosis:**

```bash
# Check for new devices
lsscsi

# Check multipath
multipath -ll

# Check LUN mapping on ONTAP
# lun show -vserver <svm> -mapped
```

**Solutions:**

1. **Rescan iSCSI sessions:**
   ```bash
   iscsiadm -m session --rescan
   ```

2. **Rescan SCSI hosts:**
   ```bash
   for host in /sys/class/scsi_host/host*/scan; do
       echo "- - -" > $host
   done
   ```

3. **Reload multipath:**
   ```bash
   multipathd reconfigure
   multipath -v2
   ```

4. **Full rescan sequence:**
   ```bash
   iscsiadm -m session --rescan
   sleep 2
   for host in /sys/class/scsi_host/host*/scan; do echo "- - -" > $host; done
   sleep 2
   multipathd reconfigure
   ```

### Session Timeouts

**Symptoms:**
- iSCSI sessions disconnecting
- I/O errors during operation

**Solutions:**

1. **Increase timeouts in `/etc/iscsi/iscsid.conf`:**
   ```ini
   node.session.timeo.replacement_timeout = 120
   node.conn[0].timeo.noop_out_interval = 5
   node.conn[0].timeo.noop_out_timeout = 5
   ```

2. **Restart iSCSI:**
   ```bash
   systemctl restart iscsid
   iscsiadm -m node --logout
   iscsiadm -m node --login
   ```

---

## Multipath Issues

### Multipath Devices Not Created

**Symptoms:**
- Multiple paths visible in `lsscsi`
- No `/dev/mapper/` devices

**Diagnosis:**

```bash
# Check multipathd status
systemctl status multipathd

# Check configuration
cat /etc/multipath.conf

# Show paths
multipathd show paths

# Show maps
multipathd show maps
```

**Solutions:**

1. **Start multipathd:**
   ```bash
   systemctl enable --now multipathd
   ```

2. **Add NetApp configuration (SAFE settings):**
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

   > **WARNING:** Do NOT use `features "3 queue_if_no_path pg_init_retries 50"` or `dev_loss_tmo infinity`. These cause the entire PVE node to hang when a LUN becomes unavailable. See [CONFIGURATION.md](CONFIGURATION.md#multipath-configuration) for details.

3. **Reconfigure multipath:**
   ```bash
   multipathd reconfigure
   multipath -v2
   ```

### Stale Multipath Devices

**Symptoms:**
- Old multipath devices remain after LUN deletion or VM removal
- Device shows all paths as `failed faulty running`
- May appear on cluster nodes that didn't perform the delete operation
- `lsblk` and `multipath -ll` still show the deleted LUN

**Root cause:**
- When a LUN is deleted on one node, OTHER nodes still have local SCSI devices
- The kernel does not auto-remove SCSI devices for unmapped LUNs
- Multipath maps persist until explicitly cleaned

**v0.2.2+ Automatic Solution:**

This is now handled automatically. The plugin tracks WWIDs it has seen and runs orphan cleanup on every `status()` poll (background fork, non-blocking). If you upgraded from an older version, just wait for the next status poll and stale devices will be cleaned up.

```bash
# Verify orphan cleanup is working
journalctl -u pvedaemon --since "5 minutes ago" | grep "Orphan cleanup"
# Expected: "Orphan cleanup: processed N stale WWID(s)"
```

**Manual Cleanup (only if needed for pre-v0.2.2 leftovers):**

```bash
# 1. Identify stale WWIDs - look for "failed faulty running" in all paths
multipath -ll

# 2. Flush ONLY specific stale WWIDs (lowercase -f)
multipath -f 3600a09807770457a795d5a7653705853

# 3. Remove residual SCSI devices for that WWID
for sd in $(lsscsi | grep NETAPP | awk '{print $NF}'); do
    devname=$(basename $sd)
    wwid=$(cat /sys/block/$devname/device/wwid 2>/dev/null)
    if [[ "$wwid" == *"3600a09807770457a795d5a7653705853"* ]]; then
        echo 1 > /sys/block/$devname/device/delete
    fi
done
```

**WARNING - DO NOT USE `multipath -F`:**

> `multipath -F` (capital F) flushes ALL unused multipath maps system-wide. In a mixed environment (e.g., this plugin + manually configured iSCSI LVM), it will disconnect any storage that has no active I/O at the moment. This includes:
> - Manual iSCSI/FC LVM storage on cluster nodes that are not currently running VMs from that storage
> - Other storage plugins' devices in idle state
>
> Recovery requires `systemctl reload multipathd` or `iscsiadm -m session --rescan` on each affected node, and possibly LVM rescan.
>
> **Always use `multipath -f <wwid>` (lowercase) to flush specific devices.**

**Mixed Environment Scenario (Manual iSCSI LVM + This Plugin):**

| Symptom | Cause | Fix |
|---------|-------|-----|
| Manual LVM disappears after `multipath -F` | `-F` flushed unused map on idle node | `systemctl reload multipathd` |
| Migrating VM to "broken" node still shows storage offline | LVM plugin doesn't auto-rescan multipath | Same as above + `pvesm set <id> --disable 0` to re-activate |
| Plugin orphans appear after deletion on remote node | Other nodes don't know LUN is gone | v0.2.2 handles automatically; older versions need manual cleanup |

---

## Snapshot Issues

### Snapshot Creation Fails

**Symptoms:**
- Error when creating VM snapshot
- Snapshot not appearing in ONTAP

**Diagnosis:**

```bash
# Check ONTAP snapshots
# On ONTAP: snapshot show -vserver <svm> -volume pve_*

# Check PVE logs
journalctl -xeu pvedaemon | grep -i snapshot
```

**Solutions:**

1. **Verify volume exists:**
   ```bash
   # On ONTAP
   vol show -vserver <svm> -volume pve_<storage>_<vmid>_*
   ```

2. **Check snapshot space:**
   ```bash
   # On ONTAP
   vol show -vserver <svm> -fields percent-snapshot-space
   ```

3. **Verify API permissions:**
   ```bash
   # On ONTAP
   security login role show -vserver <svm> -role <role> -cmddirname snapshot
   ```

### Snapshot Rollback Fails

**Symptoms:**
- Rollback operation fails
- Error: "volume is busy"

**Solutions:**

1. **Ensure VM is stopped:**
   ```bash
   qm stop <vmid>
   ```

2. **Check for active sessions:**
   ```bash
   iscsiadm -m session | grep <volume-name>
   ```

3. **Disconnect volume:**
   ```bash
   # May need to manually disconnect
   iscsiadm -m node -T <target> -p <portal> --logout
   ```

---

## Permission Issues

### ONTAP API Permission Denied

**Symptoms:**
- HTTP 403 errors
- "access denied" in logs

**Diagnosis:**

```bash
# Test API access
curl -k -u <user>:<pass> https://<portal>/api/storage/volumes

# Check permissions on ONTAP
security login role show -vserver <svm> -role <role>
```

**Solutions:**

Add missing permissions:
```bash
# On ONTAP CLI
security login role create -vserver <svm> -role <role> -cmddirname "volume" -access all
security login role create -vserver <svm> -role <role> -cmddirname "lun" -access all
security login role create -vserver <svm> -role <role> -cmddirname "igroup" -access all
security login role create -vserver <svm> -role <role> -cmddirname "snapshot" -access all
```

---

## Performance Issues

### Slow I/O Performance

**Diagnosis:**

```bash
# Check multipath status
multipathd show maps format "%n %S %P"

# Check path health
multipathd show paths format "%d %T %t %s"

# Check iSCSI statistics
iscsiadm -m session -P 3
```

**Solutions:**

1. **Enable queue_if_no_path:**
   ```bash
   # In /etc/multipath.conf
   defaults {
       features "3 queue_if_no_path pg_init_retries 50"
   }
   ```

2. **Use multiple paths:**
   - Configure multiple iSCSI data LIFs
   - Ensure multipath is configured correctly

3. **Check network:**
   ```bash
   # Test throughput
   iperf3 -c <ontap-ip>
   ```

---

## Recovery Procedures

### Recover After Node Failure

1. **On new/recovered node:**
   ```bash
   # Ensure services are running
   systemctl start iscsid multipathd

   # Discover targets
   iscsiadm -m discovery -t sendtargets -p <ontap-ip>

   # Login
   iscsiadm -m node --login

   # Reconfigure multipath
   multipathd reconfigure
   ```

2. **Restart PVE services:**
   ```bash
   systemctl restart pvedaemon pveproxy
   ```

### Clean Up Orphaned Resources

On ONTAP, identify and clean orphaned volumes:

```bash
# List all plugin-managed volumes
vol show -vserver <svm> -volume pve_*

# Check if volume is mapped
lun show -vserver <svm> -path /vol/pve_*/* -mapped

# If volume is orphaned (no corresponding VM):
vol offline -vserver <svm> -volume <vol-name>
vol delete -vserver <svm> -volume <vol-name>
```

---

## Log Locations

| Component | Log Command |
|-----------|-------------|
| PVE Daemon | `journalctl -xeu pvedaemon` |
| iSCSI | `journalctl -u iscsid` |
| Multipath | `journalctl -u multipathd` |
| System | `dmesg \| grep -i scsi` |

---

## Cannot Delete Volume: LVM on Plugin-Managed LUN

**Symptom:**
```
Cannot delete volume 'vm-XXXXX-disk-0': device /dev/mapper/3600a... is still in use.
[HOLDERS] Device has N holder(s):
    /dev/dm-XX (3600a...-part3)
      sub-holder: /dev/dm-XX (pbs-data)
  Detected LVM VG(s): pbs
```

**Cause:** Someone created LVM volume groups directly on a plugin-managed multipath LUN (or its partitions) at the PVE host level. Common scenarios:
- PBS (Proxmox Backup Server) storage built on a plugin LUN partition
- Manual LVM VG created for host-level storage on a plugin LUN
- Host LVM auto-activation of VGs from inside VM disks (PVE 7->8->9 upgrade without lvm.conf global_filter)

Plugin-managed LUNs are designed to be used exclusively by PVE as VM/CT disks (whole LUN passed to QEMU). Building host-level LVM on them conflicts with the plugin's lifecycle management.

**Resolution:**

1. Confirm the LVM VG data is no longer needed (or has been migrated elsewhere).

2. Deactivate the VG:
   ```bash
   vgchange -an <vg_name>
   ```

3. If the VG name is duplicated (two VGs with the same name):
   ```bash
   # Find the correct UUID
   vgs -o vg_name,vg_uuid,pv_name
   # Deactivate by UUID
   vgchange -an --select 'vg_uuid=<UUID>'
   ```

4. Retry the delete:
   ```bash
   pvesm free <storage>:<volname>
   ```

**Prevention:**
- Do not create LVM, PBS storage, or any host-level storage on plugin-managed LUNs
- Use customer-managed storage (e.g. manual iSCSI LVM) for host-level LVM needs
- Add `global_filter` to `/etc/lvm/lvm.conf` to prevent auto-activation:
  ```
  global_filter = [ "r|/dev/mapper/360.*|", "r|/dev/dm-|", "a|.*|" ]
  ```

## Cannot Delete Volume: Bare Partition Holders (Fixed in v0.2.7)

**Symptom (v0.2.6 and earlier):**
```
Cannot delete volume: device is still in use (mounted, has holders, or open by process)
```
Every disk deletion fails, even on disks with no LVM or mount.

**Cause:** The kernel auto-creates partition dm devices on multipath LUNs when it detects a partition table inside a VM disk. Before v0.2.7, `is_device_in_use()` treated ALL holders as "in use", including these harmless partition artifacts.

**Resolution:** Upgrade to v0.2.7 or later. The plugin now correctly ignores bare kpartx partition holders (no LVM/mount/swap on top) while still blocking when partitions have real sub-holders.

---

## Recovery After Storage Disconnect

If the ONTAP system was unreachable for an extended period (network outage, ONTAP reboot, controller failover lasting more than the multipath `no_path_retry` window), follow this procedure to verify and recover.

### Step 1: Verify storage is reachable again

```bash
# API connectivity
curl -sk -u <user>:<password> https://<ontap-ip>/api/cluster/nodes \
    | grep -q '"name"' && echo "API OK" || echo "API still failing"

# iSCSI sessions
iscsiadm -m session
# Expected: all configured portals show active sessions

# Multipath paths
multipath -ll | grep -A4 NETAPP
# Expected: all paths "active ready running"
```

### Step 2: Check for hung tasks

```bash
# Look for D-state processes (uninterruptible sleep)
ps -eo pid,stat,comm | awk '$2 ~ /D/'
# Expected: empty (no D-state processes)

# If any D-state process appears: do NOT kill -9. Wait for it to finish
# (kernel will eventually time out internal operations) or reboot the node.
```

### Step 3: Verify VM I/O recovered

For each running VM that uses NetApp storage:

```bash
# Inside the VM, check filesystem state
dmesg | tail -50 | grep -iE 'I/O error|read-only|remount'

# If filesystem went read-only during the outage:
mount -o remount,rw <mount-point>
# Or reboot the VM to restore full filesystem state
```

### Step 4: Check plugin tracking state

```bash
# WWID tracking file should reflect current ONTAP LUNs
cat /var/lib/pve-storage-netapp/<storeid>-wwids.json | python3 -m json.tool

# Force a status() poll to trigger auto-import
pvesm status | grep <storeid>
# Expected: active, with non-zero capacity
```

### Step 5: Check for orphan devices

If LUNs were deleted on ONTAP during the outage by another node:

```bash
# Look for stale multipath devices
multipath -ll | grep -B1 NETAPP | grep "failed faulty"

# If any: plugin's status() background cleanup will remove them
# automatically within 1-2 polls. Force a poll if needed:
pvesm status > /dev/null
sleep 30
pvesm status > /dev/null

# Verify cleanup
multipath -ll | grep -B1 NETAPP | grep "failed faulty"
# Expected: empty
```

### Step 6: Verify alerts cleared

If you have monitoring on syslog/journal, check that the storage-recovered message appeared:

```bash
journalctl -t pve-storage-netapp --since "1 hour ago"
# Expected: "Storage 'X' reachable again after N consecutive failures"
```

---

## Recovery After Abrupt Power Loss

If a Proxmox VE node lost power without graceful shutdown.

### What happens

- VM in-memory state is lost. Data on ONTAP LUNs is crash-consistent (writes either complete or absent, no partial corruption).
- iSCSI sessions are abruptly closed. ONTAP keeps LUN reservations until they time out.
- Plugin tracking files in `/var/lib/pve-storage-netapp/` survive (persisted on local disk).
- Plugin lock files in `/var/run/pve-storage-netapp/` are wiped (tmpfs).

### Recovery procedure

```bash
# 1. After node boots, verify services
systemctl is-active iscsid multipathd pvedaemon pvestatd pveproxy
# Expected: all active

# 2. Verify iSCSI sessions reconnected
iscsiadm -m session
# Expected: sessions to all configured ONTAP LIFs

# 3. Verify multipath
multipath -ll | head -20
# Expected: NETAPP devices visible with all paths active

# 4. Verify plugin storage
pvesm status | grep netapp
# Expected: active

# 5. If VMs are in HA group, check whether they migrated to other nodes
pvecm status
ha-manager status
```

### LUN reservation timeout

Default ONTAP LUN reservation timeout is 30-60 seconds. If a VM tries to start on this node before the timeout expires, you will see SCSI reservation conflict errors. Wait 60 seconds and retry.

To shorten the timeout (recommended for HA scenarios):

```
# On ONTAP CLI
vserver iscsi reservation modify -vserver <svm> -timeout 30
```

Recommended values:
- **30 seconds** (recommended, balanced)
- 60s = ONTAP default, conservative
- < 20s not recommended (false-positive cleanup during transient network issues)

---

## Updating ONTAP Password

When the ONTAP API user password changes, every Proxmox VE node must be updated. The cluster filesystem auto-syncs `/etc/pve/storage.cfg`, but cached API client objects in pvedaemon/pvestatd must be cleared.

### Procedure

```bash
# 1. Change password on ONTAP first
ssh <ontap-cluster> "security login password -username pveadmin"
# Or via OnCommand System Manager UI

# 2. Update PVE storage configuration (run on ANY one node;
#    /etc/pve/storage.cfg auto-replicates to all nodes)
pvesm set <storage-id> --ontap-password '<new-password>'

# 3. Verify the configuration was updated
grep ontap-password /etc/pve/storage.cfg

# 4. On EACH PVE node, reload services to clear cached API client
for node in $(pvecm nodes 2>/dev/null | awk 'NR>3 {print $3}'); do
    ssh root@$node "systemctl reload pvedaemon pvestatd pveproxy"
done

# 5. Verify storage is reachable on all nodes
pvesm status | grep <storage-id>
# Expected: active
```

### What goes wrong if you skip step 4

The plugin caches `LWP::UserAgent` objects in memory for 5 minutes. Without service reload:
- pvestatd continues using the old password until cache expires (5 min).
- Operations during this window get HTTP 401, plugin retries with re-init.
- Symptoms: `pvesm status` shows `active`, but errors appear in `journalctl -u pvedaemon`.

### Special characters in password

If the password contains shell-special characters (`$`, `!`, backtick, etc.), single-quote it carefully:

```bash
# Safe: single quotes preserve all special chars
pvesm set <storage-id> --ontap-password '$omeP@ss!w0rd`'

# Unsafe: double quotes interpolate $ and backticks
pvesm set <storage-id> --ontap-password "$omeP@ss"  # WRONG
```

---

## Getting Help

1. **Collect diagnostic information:**
   ```bash
   pvesm status
   iscsiadm -m session
   multipathd show maps
   journalctl -xeu pvedaemon --since "1 hour ago" > pvedaemon.log
   ```

2. **Check documentation:**
   - [QUICKSTART.md](QUICKSTART.md)
   - [CONFIGURATION.md](CONFIGURATION.md)
   - [NAMING_CONVENTIONS.md](NAMING_CONVENTIONS.md)

3. **Report issues:**
   - GitHub Issues: https://github.com/jasoncheng7115/jt-pve-storage-netapp/issues
   - Include: PVE version, ONTAP version, error messages, logs

---

## Acknowledgments

Special thanks to **NetApp** for generously providing the development and testing environment that made this project possible.

我們特別感謝 **NetApp 原廠**協助提供開發測試環境，使本專案得以順利完成。
