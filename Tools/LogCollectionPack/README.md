# LogCollectionPack

This folder contains diagnostic collection scripts for Windows Server and Windows clients, plus focused troubleshooting tools.
The collection scripts are read-only from a system-configuration perspective and only write collection artifacts.

| Script | Target OS | Default Output |
|---|---|---|
| `Collect-WindowsServerLogs.ps1` | Windows Server | `C:\WS-Diagnostics` |
| `Collect-WindowsClient.ps1` | Windows 7 / 10 / 11 | `C:\WC-Diagnostics` |
| [Get-TSxBoots.ps1](./Get-TSxBoots.ps1) | Windows Server / Windows client (PowerShell 5.1+) | `C:\Temp\Boot-Diagnostics` |

## Boot, Restart, Shutdown and BSOD History

Run [Get-TSxBoots.ps1](./Get-TSxBoots.ps1) from an elevated PowerShell session:

```powershell
.\Get-TSxBoots.ps1
.\Get-TSxBoots.ps1 -OutputRoot 'D:\Diagnostics' -Verbose
.\Get-TSxBoots.ps1 -DisplayCount 20
```

After collection, a compact colored quick view shows the latest 12 records
(newest first) with local time, event type, ID when space permits, and a shortened
reason/comment. It adapts to console width and height. Green indicates boot,
cyan shutdown/restart requests, yellow unexpected shutdowns/warnings, red
BSOD/dump errors, magenta user-supplied reasons, and gray informational events.
Use `-DisplayCount` to change the limit or `-DisplayCount 0` to disable the view.
The limit and shortened display text do **not** affect the exported files.

Exports **all retained matching System events**, without a date or count limit,
into a unique timestamped folder:
- `BootEvents.evtx`: native filtered event-log snapshot.
- `BootEvents.csv`: chronological records with category, UTC time, process/user,
  reason/code, shutdown type, user comment, bugcheck/dump details, message and event data JSON.
- `BootEvents.xml`: original event XML, preserving all data fields.
- `Summary.json`: event/category counts, retained time range and selection query.
- `README.txt`: interpretation notes; `CollectionIssues.txt` is created for missing messages or an empty history.

Includes Kernel-General 12/13 (boot/shutdown), Kernel-Boot 20/27 (boot status/type),
Kernel-Power 41/109 (unclean restart/shutdown transition), EventLog 6005/6006/6008/6009
(logging service start/stop, unexpected shutdown, startup OS version), User32 1074
(shutdown/restart request and supplied reason/comment), User32 1076 (user's subsequent
explanation of an unexpected shutdown), bugcheck 1001 from WER/BugCheck/Save Dump,
volmgr 46/161 (dump failures) and Eventlog 104 (log cleared).

Several records may describe the same restart; this is not a physical boot count.
Unexpected shutdown and BSOD reports may be logged at the next boot. Kernel-Power 41
alone does not establish a root cause or prove a BSOD. Reasons/comments are included
when Windows recorded them; prior cleared/overwritten history cannot be recovered.
Crash dumps are not copied. Protect account names and free-text comments before sharing.

---

# Collect-WindowsClient

## What This Is
This tool creates a full health snapshot of a Windows client machine so it can be reviewed later or sent to support.

It gathers:
- OS summary, hardware, BIOS, CPU, RAM, battery, power plan, UAC, Secure Boot, TPM
- Installed applications (classic registry + modern Appx), startup programs, environment variables
- Patch level, Windows Update history and pending updates
- Device and driver health (problem devices, third-party drivers, recently changed drivers)
- Security state (Windows Defender, firewall profiles, BitLocker, AppLocker)
- Health checks (DISM CheckHealth, optional SFC/ScanHealth)
- BSOD and crash artifacts (minidumps, WER, full dump detection, BSOD system events)
- Network diagnostics (NIC, IP, routing, ARP, DNS, proxy, Winsock, Wi-Fi, hosts file,
  connectivity tests to default gateway and internet, DNS resolution tests, SMB client config)
- Domain Controller checks: DC discovery, SMB port 445, SYSVOL UNC access, Kerberos port 88,
  TGT validity via klist, secure channel via nltest (domain-joined machines only)
- Group Policy: gpresult text/XML/HTML, applied GPO names as CSV, HKLM Policies registry dump
- Disk and storage (physical disk, SMART, partitions, volumes, shadow copies, page file, temp sizes)
- Memory (physical RAM slots, OS memory state)
- Performance counters (BLG + CSV, quick point-in-time snapshot)
- Reliability monitor data (Win32_ReliabilityRecords, stability index)
- Event logs (exported EVTX + converted to CSV for analytics)

## Who This Is For
This guide is written for non-IT staff who need to run the collection and send the results to support or an IT team.

## Is It Safe To Run?
Yes. The script is designed for collection only.
- It writes files to an output folder.
- It does not change client configuration.

## Before You Start
You need:
- A Windows 7, 10, or 11 machine (Windows 7 requires WMF 5.1)
- PowerShell 4.0 or later (Windows PowerShell 4.0/5.1 or PowerShell 7+)
- Administrator rights on that machine
- Enough free disk space for logs and optional ZIP

## File To Run
- Script: `Collect-WindowsClient.ps1`
- Location: same folder as this README

## Quick Start (Recommended)
1. Right-click PowerShell and choose **Run as administrator**.
2. Go to this folder.
3. Run:

```powershell
.\Collect-WindowsClient.ps1
```

## Simple Run Examples

### Standard run
```powershell
.\Collect-WindowsClient.ps1
```

### Skip performance counter collection (faster)
```powershell
.\Collect-WindowsClient.ps1 -SkipPerformance
```

### Save output to another drive
```powershell
.\Collect-WindowsClient.ps1 -OutputRoot "D:\Diagnostics"
```

### More detailed health checks (takes longer)
```powershell
.\Collect-WindowsClient.ps1 -DeepHealth
```

### Limit event log conversion to the last 7 days
```powershell
.\Collect-WindowsClient.ps1 -EvtxDaysBack 7
```

### Show detailed progress/decision logging
```powershell
.\Collect-WindowsClient.ps1 -Verbose
```

### Do not create ZIP
```powershell
.\Collect-WindowsClient.ps1 -NoZip
```

### Exclude native EVTX files from ZIP (converted CSV still included)
```powershell
.\Collect-WindowsClient.ps1 -ExcludeEvtxFromZip
```

### Validate script syntax without collecting any data
```powershell
.\Collect-WindowsClient.ps1 -SelfTest
```

## What You Will Get
A timestamped output folder is created under the output root (default: `C:\WC-Diagnostics`).

Inside it, you will see folders like:
- `System` — OS, hardware, apps, startup, UAC, Secure Boot, TPM
- `PatchAndUpdate` — hotfixes, WU history, pending updates
- `DevicesAndDrivers` — problem devices, driver inventory
- `Security` — Defender, firewall, BitLocker, AppLocker
- `Health` — DISM, optional SFC, CBS and DISM logs
- `Crashes_BSOD` — minidumps, WER artifacts, BSOD events
- `Network` — NIC, IP, routing, DNS, proxy, Wi-Fi, connectivity/DNS tests, DC tests
- `GroupPolicy` — gpresult outputs, applied GPO CSV, registry policies
- `Disk_Storage` — disk info, SMART, volumes, shadow copies, page file, temp sizes
- `Memory` — physical RAM inventory, OS memory state
- `Performance` — counter samples (BLG + CSV), quick snapshot
- `Reliability` — reliability records, stability index
- `EventLogs` — exported EVTX; only files containing events within the configured time window are converted
- `EventLogs\Converted` — EVTX converted to CSV
- `Analytic-Ready` — key files consolidated for upload and analysis

If ZIP is enabled (default), a ZIP file is also created in the output root.

## What To Send To Support
Preferred:
1. Send the generated ZIP file.

If ZIP is disabled:
1. Send the full timestamped output folder.

## Expected Runtime
- Typical run with `-SkipPerformance`: 5–10 minutes
- Typical run with performance sampling: 10–20 minutes
- Longer if `-DeepHealth` is used or if there are many large event logs

## Common Problems

### "Run as Administrator" warning
Cause: PowerShell was not opened with admin rights.
Fix: Close PowerShell, reopen as Administrator, run again.

### Script appears to hang on event log conversion
Cause: One or more EVTX files may have many events or be partially corrupted.
Fix: Use `-EvtxDaysBack 7` to narrow the window, or `-EvtxPerFileTimeoutSeconds 60` to enforce a shorter per-file limit.
Files that time out or fail are recorded in `EventLogs\Converted\ConversionIssues.csv`.

### ZIP was not created
Cause: File lock, path issue, or permission issue.
Fix: Use the output folder directly and send that folder.

## Parameters (Plain Language)
- `-OutputRoot`: Where to place results. Default is `C:\WC-Diagnostics`.
- `-DurationMinutes`: How long performance data is sampled. Default `5`.
- `-SampleIntervalSeconds`: How often samples are taken. Default `5`.
- `-SkipPerformance`: Skip performance counter collection entirely (faster run).
- `-DeepHealth`: Run extra health checks — DISM /ScanHealth and SFC /verifyonly (slower).
- `-IncludeFullCBS`: Collect full CBS log instead of last 5000 lines only.
- `-NoZip`: Skip ZIP creation.
- `-ValidateCounters`: Test performance counters before collection and skip unavailable ones.
- `-ExcludeEvtxFromZip`: Keep native EVTX out of ZIP while keeping converted CSV files.
- `-EvtxMaxEvents`: Maximum events per log during EVTX conversion. Default `25000`.
- `-EvtxDaysBack`: Convert only events from the last N days. Default `30`.
- `-EvtxPerFileTimeoutSeconds`: Maximum seconds per EVTX file before skipping it. Default `180`.
- `-IncludeEventMessage`: Include full event message text in CSV output (slower).
- `-SelfTest`: Validate script syntax and lint checks without collecting any data.

## Version
- Script name: `Collect-WindowsClient.ps1`
- Script version: `1.7.2`
- Last updated in script header: `2026-06-12`

---

# Collect-WindowsServerLogs

## What This Is
This tool creates a full health snapshot of a Windows Server so it can be reviewed later.

It gathers:
- Basic server details (name, version, uptime, hardware summary)
- Event logs, including the full Security log on every server
- When AD DS is detected (NTDS service exists): Directory Service, DFS Replication, File Replication Service,
  Active Directory Web Services, and all registered AD/directory services, authentication, SYSVOL replication,
  DNS Server, Group Policy and Time Service event channels (not just a fixed list of Operational channels)
  including Security-Kerberos and protected-user/authentication-policy channels
- Performance data (CPU, memory, disk, network)
- Patch and role information
- Health checks (DISM, optional deep checks)
- Crash dump and WER artifacts (when present)
- Role-specific diagnostics (if DNS, DHCP, AD, CA, Hyper-V, Cluster, S2D, SAN/RDMA exist)

## Who This Is For
This guide is written for non-IT staff who need to run the collection and send the results to support or an IT team.

## Is It Safe To Run?
Yes. The script is designed for collection only.
- It writes files to an output folder.
- It does not change server configuration.

## Before You Start
You need:
- A Windows Server machine
- PowerShell 5.1
- Administrator rights on that server
- Enough free disk space for logs and optional ZIP

## File To Run
- Script: `Collect-WindowsServerLogs.ps1`
- Location: same folder as this README

## Quick Start (Recommended)
1. Right-click PowerShell and choose **Run as administrator**.
2. Go to this folder.
3. Run:

```powershell
.\Collect-WindowsServerLogs.ps1
```

## Simple Run Examples
### Standard run
```powershell
.\Collect-WindowsServerLogs.ps1
```

### Save output to another drive
```powershell
.\Collect-WindowsServerLogs.ps1 -OutputRoot "D:\Diagnostics"
```

### Longer performance sampling (15 minutes)
```powershell
.\Collect-WindowsServerLogs.ps1 -DurationMinutes 15
```

### More detailed health checks (takes longer)
```powershell
.\Collect-WindowsServerLogs.ps1 -DeepHealth
```

### Show detailed progress/decision logging
```powershell
.\Collect-WindowsServerLogs.ps1 -Verbose
```

### Do not create ZIP
```powershell
.\Collect-WindowsServerLogs.ps1 -NoZip
```

### Exclude native EVTX files from ZIP
```powershell
.\Collect-WindowsServerLogs.ps1 -ExcludeEvtxFromZip
```

## What You Will Get
A timestamped output folder is created under the output root (default: `C:\WS-Diagnostics`).

Inside it, you will see folders like:
- `System`
- `PatchAndRoles`
- `Health`
- `RoleSpecific` (if relevant roles exist)
- `EventLogs`
- `Performance`
- `Analytic-Ready`

Notable outputs include:
- EventLogs\Converted (EVTX converted to TXT/XML/CSV)
- EventLogs\Security.evtx (Security log, collected regardless of installed roles)
- EventLogs\FoundVsSkipped.txt (exported/missing channels and export failure details)
- Health\CrashDumps\CrashDump_Presence.txt (YES/NO + count)
- Health\WER (WER files + parsed `.wer` CSV)

If ZIP is enabled (default), a ZIP file is also created in the output root.

## What To Send To Support
Preferred:
1. Send the generated ZIP file.

If ZIP is disabled:
1. Send the full timestamped output folder.

## Expected Runtime
- Typical run: around 10-20 minutes
- Longer if `-DeepHealth` is used
- Longer if server is busy or has very large logs

## Common Problems
### "Run as Administrator" warning
Cause: PowerShell was not opened with admin rights.
Fix: Close PowerShell, reopen as Administrator, run again.

### "Windows PowerShell 5.1 is required"
Cause: Script was run from a different PowerShell edition.
Fix: Run from Windows PowerShell 5.1.

### ZIP was not created
Cause: File lock, path issue, or permission issue.
Fix: Use the output folder directly and send that folder.

### Script takes a long time
Cause: Large logs and/or deep health checks.
Fix: Wait for completion, or rerun without `-DeepHealth` if not required.

### iSCSI errors when service is stopped
Cause: Microsoft iSCSI Initiator service is installed but not running.
Fix: Current script version auto-skips iSCSI collection when `MSiSCSI` is not running.

## Parameters (Plain Language)
- `-OutputRoot`: Where to place results. Default is `C:\WS-Diagnostics`.
- `-DurationMinutes`: How long performance data is sampled. Default `10`.
- `-SampleIntervalSeconds`: How often samples are taken. Default `5`.
- `-DeepHealth`: Run extra health checks (slower).
- `-IncludeFullCBS`: Collect full CBS log instead of last part only.
- `-NoZip`: Skip ZIP creation.
- `-ValidateCounters`: Test performance counters before collection.
- `-ExcludeEvtxFromZip`: Keep EVTX out of ZIP while keeping converted files.

Notes:
- AD-related diagnostic, debug and analytic channels are selected when present; the script does not enable
  channels or change auditing. Disabled or inaccessible logs that cannot be exported are reported as failures.
- Native EVTX exports contain the available log history; `-EvtxMaxEvents` caps only TXT/XML/CSV conversion
  (default `250000` events per log).
- Security and AD logs can contain sensitive account and authentication details. Protect the output folder
  and ZIP, and share them only with authorized recipients.
- Java metrics are auto-detected (collected only when java.exe processes exist).
- Missing performance counters are handled silently and skipped.
- Cluster logs are collected with full available history (no time-span limit parameter).

## Version
- Script name: `Collect-WindowsServerLogs.ps1`
- Script version: `5.9.2`
- Last updated in script header: `2026-10-08`

## Contact
- Deployment Bunny: https://www.deploymentbunny.com
- Contact in script header: deploymentbunny@outlook.com
