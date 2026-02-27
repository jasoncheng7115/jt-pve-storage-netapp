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

2. **Add NetApp configuration:**
   ```bash
   cat >> /etc/multipath.conf << 'EOF'
   devices {
       device {
           vendor "NETAPP"
           product "LUN"
           path_grouping_policy group_by_prio
           path_selector "queue-length 0"
           path_checker tur
           features "3 queue_if_no_path pg_init_retries 50"
           hardware_handler "1 alua"
           prio alua
           failback immediate
           rr_weight uniform
           rr_min_io_rq 1
           dev_loss_tmo infinity
       }
   }
   EOF

   systemctl restart multipathd
   ```

3. **Reconfigure multipath:**
   ```bash
   multipathd reconfigure
   multipath -v2
   ```

### Stale Multipath Devices

**Symptoms:**
- Old devices remain after LUN deletion
- Device shows "failed" paths

**Solutions:**

```bash
# Flush specific device
multipath -f <device-name>

# Flush all unused maps
multipath -F

# Remove stale device
dmsetup remove <device-name>
```

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
