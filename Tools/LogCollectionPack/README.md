# Collect-WindowsServerLogs

## What This Is
This tool creates a full health snapshot of a Windows Server so it can be reviewed later.

It gathers:
- Basic server details (name, version, uptime, hardware summary)
- Event logs
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
- Java metrics are auto-detected (collected only when java.exe processes exist).
- Missing performance counters are handled silently and skipped.
- Cluster logs are collected with full available history (no time-span limit parameter).

## Version
- Script name: `Collect-WindowsServerLogs.ps1`
- Script version: `5.6.2`
- Last updated in script header: `2026-05-19`

## Contact
- Deployment Bunny: https://www.deploymentbunny.com
- Contact in script header: deploymentbunny@outlook.com
