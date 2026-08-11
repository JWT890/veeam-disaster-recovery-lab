# DR Lab Report — Veeam Backup & Replication
**Environment:** Proxmox / Linux Agent Backup  
**Date:** August 11, 2026  
**Author:** Jon  
**VBR Version:** 13.0.2.29

---

## Overview

This lab validates the backup and recovery capabilities of a Veeam Backup & Replication (VBR) deployment protecting a Linux VM (`test-labvm`, `10.0.0.244`) running on Proxmox. The lab covers end-to-end RPO validation, file-level restore verification, and RTO testing — including architectural findings discovered during recovery attempts.

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

#### 2c — Export Disks ❌ (Infrastructure Blocker)

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

**Root cause:** VBR routes Linux agent backup export jobs through the Linux agent machine as the export proxy. The only registered proxy server (`10.0.0.85`) is Windows. The Linux agent on `10.0.0.244` interprets all paths and rejects Windows-style paths. Adding a Linux machine as a registered VBR proxy would resolve this.

> **Finding:** Export Disks for Linux agent backups requires a Linux proxy server registered in VBR. A Windows-only proxy environment cannot complete disk export operations. This is a known VBR architectural constraint.

**Corrective action for production:**
```bash
# On the Linux VM, register it as a VBR Linux proxy
# Or: add a dedicated Linux proxy server to VBR infrastructure
# Backup Infrastructure → Add → Linux server
```

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

### What Doesn't Work in This Environment ⚠️
| Capability | Status | Reason |
|---|---|---|
| Instant VM Recovery | ❌ Unavailable | Requires VMware vSphere or Hyper-V |
| Entire VM Restore | ❌ Unavailable | No Proxmox restore target in VBR |
| Export Disks | ❌ Blocked | Requires Linux proxy server registered in VBR |

---

## Recommendations

1. **Register a Linux proxy server in VBR** — This unblocks Export Disks and enables a proper disk-level RTO test. The Linux agent VM itself (`10.0.0.244`) could serve this role.

2. **Document the file-level RTO as the primary recovery path** — Until a Linux proxy is registered, file-level restore is the only functional recovery method. For full machine recovery, the process is: export disks via Linux proxy → `qm importdisk` on Proxmox → attach and boot.

3. **Define a formal RTO target** — With current constraints, full machine recovery requires manual steps. Estimate and document a realistic RTO (likely 30–90 minutes depending on disk size and import speed) once Export Disks is unblocked.

4. **Enable Secure Restore for incident response** — Configure AV or YARA scanning before a real recovery event occurs.

5. **Consider increasing backup frequency** — A 24-hour worst-case RPO may be acceptable for a lab, but production workloads with critical data should evaluate more frequent backups or continuous data protection (CDP).

---

## Restore Point Reference

| Restore Point | Type | Date | Status |
|---|---|---|---|
| test-labvm-clean | Increment | 8/10/2026 8:14 PM | ✅ Verified — contains rpo-test.txt |
| test-labvm-clean | Full | 8/9/2026 3:24 PM | Original clean deployment snapshot |

---

*Lab conducted on Proxmox with Veeam Backup & Replication v13.0.2.29. All findings reflect real behavior observed during testing.*
