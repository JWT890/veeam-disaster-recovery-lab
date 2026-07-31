# 🛡️ Veeam Backup Lab — Proxmox VE

A hands-on backup and recovery lab using Veeam Agent for Linux and Veeam Backup & Replication (VBR) on a Proxmox VE host. Covers agent-based backup, point-in-time recovery, file-level restore, and ransomware simulation with recovery.

---

## Environment

| Component | Detail |
|---|---|
| Hypervisor | Proxmox VE 8.x (running inside VMware Workstation) |
| Test VM | Ubuntu 26.04 LTS — 2 vCPU, 2GB RAM, 50GB disk (VM ID 100) |
| Backup agent | Veeam Agent for Linux (installed inside test VM) |
| VBR server | Veeam Backup & Replication 13.0.2.29 (Windows) |
| Proxmox IP | 10.0.0.22 |
| Host machine | AMD Ryzen 7 8845HS — Windows 11 with VMware Workstation |

---

## Lab levels

### ✅ Level 1 — Basic backup and restore

Installed Veeam Agent for Linux inside the test VM and configured a backup job pointing to VBR as the repository. Ran first full backup (8GB, ~5 minutes). Verified job completion and restore point creation in the VBR console.

**Key commands:**
```bash
veeamconfig job start --name "TestVM-Backup"
veeamconfig session list
```

---

### ✅ Level 2 — Point-in-time recovery

Created a v1 config file, backed it up, then overwrote it with a corrupted v2 version and backed that up too. Mounted the older restore point in the Veeam TUI and recovered the clean v1 file — proving granular point-in-time restore across two backup generations.

```bash
# Create and back up v1
echo "Version 1 - original config" > ~/app-config.txt
veeamconfig job start --name "TestVM-Backup"

# Corrupt and back up v2
echo "Version 2 - CORRUPTED config" > ~/app-config.txt
veeamconfig job start --name "TestVM-Backup"

# Restore from the older restore point via TUI
sudo veeam
# Press R → select job → select older restore point → mount
cp /mnt/backup/home/jon/app-config.txt ~/app-config.txt
cat ~/app-config.txt
# Output: Version 1 - original config
```

---

### ✅ Level 3 — File-level restore from LVM backup

Navigated Veeam's LVM-backed loop device mount structure to recover individual files. The backup is not directly accessible at `/mnt/backup/home/user` — it is exposed as a raw loop device that must be manually mounted.

```bash
# Find loop devices after mounting restore point in Veeam TUI
lsblk

# Mount the main filesystem (loop0 = root LVM volume)
sudo mkdir -p /mnt/veeamrestore
sudo mount /dev/loop0 /mnt/veeamrestore
ls /mnt/veeamrestore/home/jon/

# Copy files out
cp /mnt/veeamrestore/home/jon/app-config.txt ~/app-config.txt
```

---

### ✅ Level 4 — Ransomware simulation and recovery

Created a `company-data` directory with three critical business files. Backed them up, then simulated a ransomware attack by overwriting all files with encrypted content. Recovered the entire directory from the pre-attack restore point in under 2 minutes.

```bash
# Create important files
mkdir ~/company-data
echo "Q4 financial report" > ~/company-data/financials.txt
echo "Customer database" > ~/company-data/customers.txt
echo "Employee records" > ~/company-data/employees.txt
veeamconfig job start --name "TestVM-Backup"

# Simulate ransomware
for f in ~/company-data/*; do
    echo "ENCRYPTED_$(date)" > "$f"
done
cat ~/company-data/financials.txt
# Output: ENCRYPTED_Fri Jul 24 05:22:36 PM UTC 2026

# Mount pre-attack restore point and recover
sudo mount /dev/loop0 /mnt/veeamrestore
cp -r /mnt/veeamrestore/home/jon/company-data/ ~/company-data-restored/
cat ~/company-data-restored/financials.txt
# Output: Q4 financial report
```

**Result:** All three files fully recovered. Original content intact.

---

### ⚠️ Level 5 — Hypervisor-level VM backup and restore

**Status: Architecture validated — blocked by nested virtualisation limitation.**

Installed the Veeam Plug-in for Proxmox VE on the VBR server, added Proxmox as a managed server, and configured a hypervisor-level backup job targeting test-labvm directly via the Proxmox API. The VBR worker VM (VM 102) deploys successfully and gets patched with `kvm: 0`, but the worker appliance kernel requires x86-64-v2 CPU features that depend on KVM hardware virtualisation — causing a kernel panic in the nested environment.

**Root cause:** Proxmox runs inside VMware Workstation on a Windows 11 host with Virtualization Based Security (VBS) enforced at firmware level. VBS prevents VMware from exposing VT-x to the guest, so KVM is unavailable inside Proxmox.

**To enable Level 5:**
- Run Proxmox on bare metal hardware, OR
- Use VMware ESXi/vSphere with "Expose VMX to guest OS" enabled, AND
- Ensure VBS/Credential Guard is not enforced at the BIOS/firmware level

---

## Known issues and workarounds

### Veeam mount sessions not released after file-level restore

After using `sudo veeam` to mount a restore point, always press **U** to unmount before exiting the TUI. If a session gets stuck:

```bash
# Find the stuck veeamagent process
ps aux | grep veeamagent

# Kill it
sudo kill -9 <PID>

# Restart Veeam service
sudo systemctl restart veeamservice.service

# Lazy unmount if mount point is busy
sudo umount -l /mnt/backup
```

---

### Veeam worker VM fails with KVM error on nested Proxmox
TASK ERROR: KVM virtualisation configured, but not available.
Either disable in VM configuration or enable in BIOS.
**Workaround using inotifywait** (patches config the moment Veeam creates it):

```bash
# Install inotify-tools on the Proxmox host
apt-get install -y inotify-tools

# Create watcher script
tee /tmp/kvm-fix.sh << 'SCRIPT'
#!/bin/bash
inotifywait -m /etc/pve/qemu-server/ -e moved_to -e create -e modify --format "%e %f" | while read event file; do
    VMID="${file%.conf}"
    [ "$VMID" = "$file" ] && continue
    qm set $VMID --kvm 0 --cpu x86-64-v2-AES >> /tmp/kvm-watcher.log 2>&1
    echo "Patched VM $VMID ($event)" >> /tmp/kvm-watcher.log
done
SCRIPT
chmod +x /tmp/kvm-fix.sh

# Run in background
nohup bash /tmp/kvm-fix.sh > /tmp/kvm-watcher-err.log 2>&1 &

# Monitor
tail -f /tmp/kvm-watcher.log
```

> Note: Even with kvm=0 patched, the worker kernel panics without real KVM due to x86-64-v2 requirements. This workaround is documented for completeness — the permanent fix is bare metal Proxmox.

---

### File-level restore — mount path is not /mnt/backup/home/user

Veeam exposes backups as raw loop devices, not as standard filesystem paths. Use `lsblk` after mounting to find the loop device, then mount manually:

```bash
lsblk                                        # find /dev/loop0
sudo mount /dev/loop0 /mnt/veeamrestore      # mount root filesystem
ls /mnt/veeamrestore/home/jon/               # browse files
```

---

### Proxmox VE plugin disappears from VBR after removing managed server

Reinstall all three components from the VBR ISO under `Plugins/Proxmox VE/`:

1. `VeeamPluginPVE.msi`
2. `VeeamPluginPVEUI.msi`
3. `VeeamPluginPVEAppliance.msi`

Then restart Veeam Backup Service on the Windows VBR server.

---

## Key commands reference

### Agent backup (run inside test VM)

```bash
veeamconfig job start --name "TestVM-Backup"
veeamconfig session list
veeamconfig session info --id <session-id>
sudo veeam                                   # interactive TUI
```

### Mount and unmount

```bash
lsblk                                        # identify loop devices
sudo mount /dev/loop0 /mnt/veeamrestore      # mount root fs
sudo umount /mnt/veeamrestore                # clean unmount
sudo umount -l /mnt/backup                   # lazy unmount if busy
```

### Proxmox host (run as root on PVE)

```bash
qm status 102                                # check worker VM status
qm config 102                                # show worker VM config
qm set 102 --kvm 0 --cpu x86-64-v2-AES      # patch KVM setting
qm stop 102 && qm start 102                  # restart worker VM
cat /tmp/kvm-watcher.log                     # inotify watcher output
```

### Session cleanup

```bash
ps aux | grep veeamagent
sudo kill -9 <PID>
sudo systemctl restart veeamservice.service
sudo veeamconfig session list | grep Running
```

---

## Lessons learned

- **Agent-based vs hypervisor-level backup** — Agent backup works well and is proven here across all recovery scenarios. Hypervisor-level backup via VBR is more powerful (no agent required inside the VM, instant VM recovery) but requires KVM to be available on the Proxmox host.
- **Nested virtualisation** — Running Proxmox inside VMware on a Windows 11 host with VBS enabled prevents KVM from working. This blocks the Veeam worker appliance which requires x86-64-v2 CPU support.
- **Always unmount restore sessions** — Leaving a Veeam mount session open blocks subsequent backup jobs. Use the TUI unmount option or kill the veeamagent process and restart veeamservice.
- **LVM mount path** — Veeam's file-level restore exposes the backup as a loop device, not a simple directory. Expect to use `lsblk` and `mount` manually rather than navigating to `/mnt/backup`.
- **VBR plugin reinstall** — Removing a Proxmox managed server from VBR does not unregister the plugin, but it can cause the Proxmox VE option to disappear from the Add Server wizard. Reinstalling from the ISO fixes it.

---

## Requirements for Level 5 (hypervisor-level backup)

| Requirement | Detail |
|---|---|
| Proxmox on bare metal | OR VMware ESXi with nested virt enabled |
| VBS disabled | Firmware-level Virtualization Based Security must be off |
| VBR 13.x | With Veeam Plug-in for Proxmox VE installed |
| Proxmox credentials | root@pam with full API access |
| Worker storage | At least 100GB free on local-lvm for worker VM disk |