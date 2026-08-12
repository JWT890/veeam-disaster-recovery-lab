# DR Lab Report — Veeam Backup & Replication
**Environment:** Proxmox / Linux Agent Backup  
**Date:** August 11, 2026  
**Author:** Jon  
**VBR Version:** 13.0.2.29

---

## Overview

This lab validates the backup and recovery capabilities of a Veeam Backup & Replication (VBR) deployment protecting a Linux VM (`test-labvm`, `10.0.0.244`) running on Proxmox. The lab covers end-to-end RPO validation, file-level restore verification, full machine recovery via disk export and import, and a complete RTO measurement — including architectural findings discovered and resolved during testing. The lab concludes with a live booted recovered VM (`test-lab-recovered`, VM 200) with RPO verification confirmed on the running machine.

---

## Environment

| Component | Detail |
|---|---|
| Hypervisor | Proxmox |
| Protected VM | `test-labvm` — `10.0.0.244` |
| Backup server | `10.0.0.85` — Windows Server (VBR 13.0.2.29) |
| Backup job | `test-labvm-clean` |
| Backup repository | Harden repository |
| Backup schedule | Daily at 10:00 PM |
| Retention | 7 restore points |
| Backup method | Veeam Linux Agent |

---

## Part 1 — RPO Validation ✅

### Objective
Prove what data is recoverable from a restore point and document the real-world data loss window.

### Method

**Step 1 — Create a pre-backup reference file**

```bash
ssh jon@10.0.0.244
echo "RPO test file - created $(date)" > ~/rpo-test.txt
```

**Step 2 — Run a backup job**

Triggered `test-labvm-clean` manually in VBR. Backup completed at **8:14 PM Monday 8/10/2026** (Increment, 6.66 GB).

**Step 3 — Create a post-backup file to simulate data loss**

```bash
echo "This change will be LOST - created $(date)" > ~/rpo-loss-test.txt
```

Created at **03:34 UTC 8/11/2026** — after the backup completed.

**Step 4 — File-level restore verification**

Using VBR Guest File Restore (Linux):
- Navigate: `Home → Backups → Disk → test-labvm → Restore → Guest files → Linux`
- Selected restore point: **8:14 PM Monday 8/10/2026 (Increment)**
- Browsed to `/home/jon/` in the backup filesystem browser

### Results

| File | Expected | Actual | Result |
|---|---|---|---|
| `rpo-test.txt` | Present | ✅ Present (8/10/2026 7:42 PM) | Pass |
| `rpo-loss-test.txt` | Absent | ✅ Absent | Pass |

### RPO Summary

| Metric | Value |
|---|---|
| Last backup completed | 8:14 PM Monday 8/10/2026 |
| Post-backup change timestamp | 03:34 UTC 8/11/2026 |
| Measured data loss window (this test) | ~7 hours |
| Worst-case RPO (daily schedule) | ~24 hours |
| Recovery point confirmed | Increment — 6.66 GB |

> **Finding:** RPO is validated. Any data created after the last scheduled backup run is unrecoverable from that restore point. With a daily 10 PM schedule, worst-case data loss is approximately 24 hours.

---

## Part 2 — RTO Testing

### Objective
Measure how long recovery takes from backup to a usable machine, and identify which recovery methods are available in this environment.

### Method & Findings

#### 2a — Instant VM Recovery ❌

**Attempted:** `Home → Backups → Disk → test-labvm → Instant Recovery → VMware vSphere VM`

**Result:** Wizard prompts for a VMware vSphere/ESXi host. No Proxmox option exists.

> **Finding:** Instant VM Recovery is VMware and Hyper-V native. VBR does not support Instant Recovery directly to Proxmox. This feature is unavailable in this environment.

---

#### 2b — Entire VM Restore ❌

**Attempted:** Ribbon → `Entire VM` dropdown

**Result:** Options presented were Nutanix AHV, Amazon EC2, Microsoft Azure, and Google CE — no generic or Proxmox restore path.

> **Finding:** VBR's Entire VM restore is tightly coupled to specific hypervisor platforms. Linux agent backups on Proxmox have no direct full-machine restore path within VBR.

---

#### 2c — Export Disks — Initial Attempt ❌ (Infrastructure Blocker, Resolved)

**Attempted:** Export Disks to `C:\RTO-Export` on Windows server `10.0.0.85`

**Disks identified:**
| Disk | Size | Volumes |
|---|---|---|
| Disk 0 | 50 GB | sda1, sda2 |
| Disk 1 | 24 GB | ubuntu-lv |

**Export format selected:** VMDK (Proxmox-compatible via `qm importdisk`)

**Blockers encountered:**

| Attempt | Error |
|---|---|
| Path: `/RTO-Export` | Permission denied — Linux agent interpreted Windows path |
| Path: `C:\RTO-Export` | Failed to create directory `C:\` — path passed to Linux proxy |
| Path: `\\10.0.0.85\C$\RTO-Export` | Network path not found — admin share blocked |
| Path: `\\10.0.0.85\RTO-Export` | Network path not found — firewall rules updated but VBR still failed to connect |

**Root cause:** VBR routes Linux agent backup export jobs through the Linux agent machine as the export proxy. The only registered proxy server (`10.0.0.85`) is Windows. The Linux agent on `10.0.0.244` interprets all paths and rejects Windows-style paths.

> **Finding:** Export Disks for Linux agent backups requires a Linux proxy server registered in VBR. A Windows-only proxy environment cannot complete disk export operations. This is a known VBR architectural constraint.

**Resolution:** Registered `10.0.0.244` as a Linux managed server in VBR:
- `Backup Infrastructure → Add Server → Linux`
- Credentials: `jon` with automatic privilege elevation (sudoers entry added automatically)
- VBR installed: Veeam Data Mover (port 6162), HPE StoreOnce, Dell Data Domain, NetApp SnapDiff libraries
- Server registered successfully as a Linux proxy

---

#### 2e — Export Disks to Proxmox Host ✅

**Note:** Initial export targeted `10.0.0.244` (the guest VM itself — incorrect). Corrected by registering the Proxmox host (`10.0.0.22`) as a Linux managed server in VBR and re-exporting there so VMDKs land on the hypervisor filesystem, ready for `qm importdisk`.

**Re-attempted:** Export Disks using `10.0.0.22` (Proxmox host) as target server, path `/rto-export`

**Result: Success**

| Metric | Value |
|---|---|
| Start time | 2:02:29 PM 8/11/2026 |
| End time | 2:13:07 PM 8/11/2026 |
| **Measured RTO (disk export)** | **10 minutes 38 seconds** |

**Transfer details:**
| Disk | Raw Size | Transferred | Speed | Duration |
|---|---|---|---|---|
| Disk 1 | 24 GB | 6 GB | 10 MB/s | 9:59 |
| Disk 0 | 50 GB | 217 MB | 3 MB/s | 1:20 |

> **Note:** Only changed blocks were transferred — not full raw disk sizes. VBR's deduplication and changed block tracking significantly reduced actual data moved, completing a 74 GB disk set in ~10 minutes.

**Files exported to Proxmox host `/rto-export/`:**
```
10.0.0.244_Disk_0-flat.vmdk   50G   (OS disk raw data)
10.0.0.244_Disk_0.vmdk        179B  (descriptor)
10.0.0.244_Disk_1-flat.vmdk   24G   (data disk raw data)
10.0.0.244_Disk_1.vmdk        178B  (descriptor)
```

---

#### 2f — Proxmox VM Import & Boot ✅

**Objective:** Import exported VMDKs into a new Proxmox VM and verify the recovered machine boots and contains the expected data.

**VM created:**
```bash
qm create 200 --name test-lab-recovered --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
```

**Disk import via dd** (required because `qemu-img` on this Proxmox version does not support `monolithicFlat` VMDK format):
```bash
# Disk 0 — OS disk
qm set 200 --ide0 local-lvm:50
dd if=/rto-export/10.0.0.244_Disk_0-flat.vmdk of=/dev/pve/vm-200-disk-0 bs=4M status=progress
# Result: 50 GB copied in 483s at 111 MB/s

# Disk 1 — Data disk
# Required thin pool expansion first (pool was at 100% — added 60 GB via VMware hot-add)
qm set 200 --ide1 local-lvm:24
dd if=/rto-export/10.0.0.244_Disk_1-flat.vmdk of=/dev/pve/vm-200-disk-1 bs=4M status=progress
# Result: 24 GB copied in 654s at 39.3 MB/s
```

**Thin pool expansion required:**
The Proxmox LVM thin pool was at 100% capacity (42.46 GB provisioned). A 60 GB virtual disk was added to the Proxmox VM in VMware Workstation and hot-added without reboot:
```bash
for host in /sys/class/scsi_host/host*; do echo "- - -" > $host/scan; done
pvcreate /dev/sdb
vgextend pve /dev/sdb
lvextend -l +100%FREE pve/data
# Pool expanded from 42.46 GB to 114.84 GB
```

**Boot issue — SCSI controller mismatch:**
Initial boot stalled in dracut initramfs — kernel could not see any block devices. Root cause: VM created with SCSI controller but initramfs lacked SCSI drivers. Resolved by switching to IDE:
```bash
qm set 200 --ide0 local-lvm:vm-200-disk-0,size=50G
qm set 200 --ide1 local-lvm:vm-200-disk-1,size=24G
qm set 200 --delete scsi0 --delete scsi1
qm set 200 --boot order=ide0
```

**Boot result:** ✅ Ubuntu 26.04 LTS booted successfully to login prompt.

---

#### 2g — End-to-End RPO Verification on Recovered VM ✅

Logged into `test-lab-recovered` (VM 200) as `jon` and verified file state:

```
jon@test-labvm:~$ ls ~/rpo-test.txt
/home/jon/rpo-test.txt

jon@test-labvm:~$ cat ~/rpo-test.txt
RPO test file - created Tue Aug 11 02:42:04 AM UTC 2026

jon@test-labvm:~$ ls ~/rpo-loss-test.txt
ls: cannot access '/home/jon/rpo-loss-test.txt': No such file or directory
```

| File | Expected | Actual | Result |
|---|---|---|---|
| `rpo-test.txt` | Present | ✅ Present — created Tue Aug 11 02:42:04 UTC 2026 | Pass |
| `rpo-loss-test.txt` | Absent | ✅ Absent | Pass |

> **Finding:** End-to-end recovery validated. The recovered VM contains exactly the data captured in the 8:14 PM backup and nothing created after. RPO and RTO are both proven on a live booted machine.

---

#### 2d — File-Level Restore ✅ (Functional)

File-level restore via Guest Files (Linux) worked without issue and was used successfully during RPO validation. Individual files can be recovered from any restore point through the VBR file browser.

**RTO for file-level restore:** Near-instant for browsing; individual file restore estimated < 1 minute for small files.

---

## Part 3 — Secure Restore (Noted Feature)

During the Export Disks wizard, VBR presented a **Secure Restore** step offering:
- Antivirus scan of backup content prior to restore
- YARA rule-based threat scanning

> **Note for production:** Secure Restore should be enabled for any recovery following a suspected ransomware or security incident. Recovering an already-infected machine without scanning reintroduces the threat. Configure AV integration or YARA rules in VBR before a real incident occurs.

---

## Summary

### What Works ✅
| Capability | Status |
|---|---|
| Daily incremental backups | ✅ Operational |
| 7-day restore point retention | ✅ Operational |
| File-level restore (Linux guest) | ✅ Operational |
| RPO validation | ✅ Validated — 24hr worst case |
| Backup filesystem browsing | ✅ Operational |
| Export Disks (Linux proxy) | ✅ Operational — 10m 38s export time |
| Full VM recovery (dd + Proxmox import) | ✅ Completed — VM booted, RPO verified |
| End-to-end RPO verification on recovered VM | ✅ rpo-test.txt present, rpo-loss-test.txt absent |

### What Doesn't Work in This Environment ⚠️
| Capability | Status | Reason |
|---|---|---|
| Instant VM Recovery | ❌ Unavailable | Requires VMware vSphere or Hyper-V |
| Entire VM Restore | ❌ Unavailable | No Proxmox restore target in VBR |
| `qm importdisk` with monolithicFlat VMDK | ❌ Unsupported | Use `dd` directly to LVM volume instead |

### Resolved During Lab 🔧
| Issue | Resolution |
|---|---|
| Export Disks failing — no Linux proxy | Registered `10.0.0.244` and `10.0.0.22` as Linux managed servers in VBR |
| Export target incorrect (guest VM vs host) | Re-exported to Proxmox host `10.0.0.22` — VMDKs landed on hypervisor filesystem |
| Thin pool at 100% capacity | Added 60 GB virtual disk via VMware hot-add, extended LVM pool to 114.84 GB |
| VMDK import format unsupported | Used `dd` to copy flat VMDK directly to LVM volumes |
| Boot stall — SCSI controller mismatch | Switched VM disks from SCSI to IDE controller |

---

## Full Recovery Runbook

The complete tested recovery procedure for this environment:

```bash
# 1. In VBR — Export Disks
#    Source: test-labvm-clean (select restore point)
#    Target server: 10.0.0.22 (Proxmox host)
#    Path: /rto-export
#    Format: VMDK

# 2. On Proxmox host — Create recovery VM
qm create 200 --name test-lab-recovered --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
qm set 200 --ide0 local-lvm:50
qm set 200 --ide1 local-lvm:24
qm set 200 --boot order=ide0

# 3. Import disks via dd (monolithicFlat VMDK — qemu-img unsupported)
dd if=/rto-export/10.0.0.244_Disk_0-flat.vmdk of=/dev/pve/vm-200-disk-0 bs=4M status=progress
dd if=/rto-export/10.0.0.244_Disk_1-flat.vmdk of=/dev/pve/vm-200-disk-1 bs=4M status=progress

# 4. Boot and verify
qm start 200
```

## Full RTO Timeline

Timestamps sourced from VBR job logs, bash history, and `stat` on exported VMDK files. All times CDT (UTC-5).

---

### Actual Lab Timeline

```
DISASTER DECLARED
│
├─ 4:03:05 PM ── VBR Export Disks job started              [+0:00:00]
│                 Source:  test-labvm-clean
│                          8:14 PM 8/10/2026 increment
│                 Target:  10.0.0.22 (Proxmox host)
│                 Path:    /rto-export
│                 Format:  VMDK
│
├─ 4:04:25 PM ── Disk 0 (50 GB) written to export path     [+0:01:20]
│                 10.0.0.244_Disk_0-flat.vmdk
│                 10.0.0.244_Disk_0.vmdk
│
├─ 4:13:03 PM ── Disk 1 (24 GB) written to export path     [+0:09:58]
│                 10.0.0.244_Disk_1-flat.vmdk
│                 10.0.0.244_Disk_1.vmdk
│
├─ 4:13:07 PM ── VBR export completed ✅                    [+0:10:02]
│
│   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
│   LAB TROUBLESHOOTING GAP — 72 minutes
│   (thin pool expansion, VMDK format errors,
│    SCSI→IDE controller fix, VM config)
│   Would not occur in a prepared production environment
│   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
│
├─ 5:25:16 PM ── Disk 0 dd import started
│                 dd if=Disk_0-flat.vmdk
│                    of=/dev/pve/vm-200-disk-0 bs=4M
│
├─ 5:33:19 PM ── Disk 0 complete ✅                         [+8m 03s]
│                 53 GB copied at 111 MB/s
│
├─ 5:40:29 PM ── Disk 1 dd import started
│                 dd if=Disk_1-flat.vmdk
│                    of=/dev/pve/vm-200-disk-1 bs=4M
│
├─ 5:51:23 PM ── Disk 1 complete ✅                         [+10m 54s]
│                 26 GB copied at 39.3 MB/s
│
├─ 5:51:xx PM ── VM boot initiated
│                 qm set 200 --boot order=ide0
│                 qm start 200
│
├─ 5:53:xx PM ── Ubuntu 26.04 LTS login prompt ✅           [+~2m]
│                 Hostname:  test-labvm
│                 Platform:  QEMU / x86-64
│
├─ 5:54:xx PM ── RPO verification on recovered VM
│                 ✅ rpo-test.txt PRESENT
│                    "RPO test file - created
│                     Tue Aug 11 02:42:04 AM UTC 2026"
│                 ❌ rpo-loss-test.txt ABSENT
│                    created after backup — data loss window confirmed
│
└─ RECOVERY COMPLETE ✅
```

---

### Clean Production RTO

Excludes lab troubleshooting time. Assumes Linux proxy, Proxmox host, and sufficient LVM storage are pre-configured.

```
DISASTER DECLARED
│
├─ T+0:00:00 ── VBR Export Disks started
│
├─ T+0:10:02 ── VBR export complete (both disks on Proxmox host)
│
├─ T+0:11:02 ── Recovery VM created, LVM volumes allocated (~1 min)
│
├─ T+0:19:05 ── Disk 0 imported via dd  (+8m 03s at 111 MB/s)
│
├─ T+0:29:59 ── Disk 1 imported via dd  (+10m 54s at 39.3 MB/s)
│
├─ T+0:31:59 ── VM booted to login prompt  (+~2 min)
│
└─ T+0:31:59 ── RECOVERY COMPLETE ✅
```

**Clean Production RTO Summary:**

| Phase | Start | Duration | Notes |
|---|---|---|---|
| VBR disk export | T+0:00 | 10m 02s | Changed blocks only — 217 MB + 6 GB transferred |
| Recovery VM creation | T+0:10 | ~1m | `qm create` + LVM volume allocation |
| Disk 0 dd import (50 GB) | T+0:11 | 8m 03s | 111 MB/s average |
| Disk 1 dd import (24 GB) | T+0:19 | 10m 54s | 39.3 MB/s average |
| VM boot to login prompt | T+0:30 | ~2m | Ubuntu 26.04 LTS |
| **Total clean RTO** | — | **~32 minutes** | Disaster declared to verified recovery |

> **Formal RTO target: 60 minutes** — measured at ~32 minutes in the lab. 60 minutes allows headroom for real-incident variables (network load, storage contention, staff response time).

---

## Recommendations

1. ~~**Register a Linux proxy server in VBR**~~ ✅ **Completed during lab** — both `10.0.0.244` and `10.0.0.22` registered. Export Disks functional, exporting to Proxmox host directly.

2. ~~**Document the full machine recovery runbook**~~ ✅ **Completed during lab** — see Full Recovery Runbook above. End-to-end RTO measured at ~32 minutes.

3. ~~**Define a formal RTO target**~~ ✅ **Established during lab** — measured RTO is ~32 minutes for this workload. Formal target: **60 minutes** to allow buffer for unexpected issues.

4. **Enable Secure Restore for incident response** — Configure AV or YARA scanning before a real recovery event occurs.

5. **Consider increasing backup frequency** — A 24-hour worst-case RPO may be acceptable for a lab, but production workloads with critical data should evaluate more frequent backups or continuous data protection (CDP).

6. **Monitor thin pool capacity** — Pool hit 100% during this lab requiring emergency expansion. Set `activation/thin_pool_autoextend_threshold` below 100 to trigger automatic extension before the pool fills.

---

## Restore Point Reference

| Restore Point | Type | Date | Status |
|---|---|---|---|
| test-labvm-clean | Increment | 8/10/2026 8:14 PM | ✅ Verified — contains rpo-test.txt |
| test-labvm-clean | Full | 8/9/2026 3:24 PM | Original clean deployment snapshot |

---

*Lab conducted on Proxmox with Veeam Backup & Replication v13.0.2.29. All findings reflect real behavior observed during testing.*
