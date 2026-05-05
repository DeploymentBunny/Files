# Windows Client Health Logs Collector

This folder contains a script that gathers health and troubleshooting logs from a Windows 10 or Windows 11 computer.

It is designed for people who are not IT experts. You run one command, wait for it to finish, and send one ZIP file to support.

## What this script does

The script:
- Collects important system logs used for troubleshooting.
- Collects Intune and ConfigMgr (SCCM) client logs if they exist.
- Exports key Windows Event Logs.
- Captures system health details such as OS info, hotfixes, services, network config, and reboot indicators.
- Creates one ZIP archive that contains everything.

## Why this helps

When a device has update, policy, app deployment, or OS health issues, support usually needs logs from many places.

This script saves time by collecting those logs in one run.

## Operating systems supported

- Windows 10
- Windows 11

## What is collected

### File-based logs

The script attempts to copy logs from these common locations when they are available:

- DISM logs
- CBS logs
- Setup and upgrade logs (Panther, MoSetup, rollback)
- Intune Management Extension logs
- Windows Provisioning logs
- ConfigMgr/CCM logs
- Task sequence logs (if present)
- Windows Update ETL logs

If a path does not exist on a specific machine, the script continues and records that as missing.

### Event logs

The script exports these event channels:

- Application
- System
- Setup
- DeviceManagement-Enterprise-Diagnostics-Provider (Admin and Operational)
- WindowsUpdateClient Operational
- BITS Operational
- AppXDeploymentServer Operational
- ModernDeployment-Diagnostics-Provider Autopilot

### Health and environment outputs

The script captures command outputs including:

- OS and hardware details
- systeminfo
- Installed hotfixes
- Signed driver list
- Microsoft Defender status
- Services list
- Network details (ipconfig, route, proxy)
- Group Policy computer result
- Windows Update policy registry values
- Pending reboot indicators
- DISM CheckHealth

Optional:
- DISM ScanHealth and SFC verify (longer runtime)
- MSINFO32 report

## Files created by the script

Inside the output collection folder, you will see:

- FileLogs folder
- EventLogs folder
- CommandOutputs folder
- Collector.log
- Summary.json
- CollectedItems.txt
- FailedItems.txt
- MissingPaths.txt

By default, these are packaged into one ZIP file.

## Before you run

1. Open PowerShell as Administrator.
2. Confirm you are on the target Windows 10/11 device.
3. Make sure enough free disk space is available (recommended at least 1 to 2 GB free).
4. Close apps you do not need to reduce noise in logs.

## How to run

### Basic run

```powershell
Set-Location C:\Repo\DeploymentBunny\Files\Tools\Get-WindowsClientHealthLogs
.\Get-WindowsClientHealthLogs.ps1
```

### Run with deeper health checks

This can take significantly longer.

```powershell
.\Get-WindowsClientHealthLogs.ps1 -RunHealthCommands
```

### Include MSINFO report

```powershell
.\Get-WindowsClientHealthLogs.ps1 -IncludeMsInfo
```

### Choose a custom output location

```powershell
.\Get-WindowsClientHealthLogs.ps1 -OutputPath C:\Temp\HealthLogs
```

### Keep folder only (no ZIP)

```powershell
.\Get-WindowsClientHealthLogs.ps1 -NoZip
```

## What to send to support

Send the generated ZIP file.

Default output location:

- C:\ProgramData\WindowsClientHealthLogs

The ZIP file name format is:

- ComputerName_YYYYMMDD_HHMMSS.zip

Example:

- LAPTOP-12345_20260505_101530.zip

## Estimated runtime

- Standard run: often 3 to 15 minutes
- With RunHealthCommands: often 15 to 60+ minutes depending on disk performance and system condition

## Troubleshooting

### Script says it cannot access some files

- Run PowerShell as Administrator.
- This is expected for some logs if that component is not installed.

### Script takes a long time

- DISM ScanHealth and SFC checks are slow by design.
- Use a standard run first if you need quick results.

### No Intune or ConfigMgr logs found

- The device may not be managed by that service.
- This is normal; check MissingPaths.txt in the output.

### ZIP was not created

- The script still keeps the full folder.
- Check Collector.log and FailedItems.txt for details.

## Privacy and sensitivity notice

Log files may contain:

- Device name
- Usernames
- Domain information
- Installed software and update details
- Network configuration details

Handle and share logs according to your company security policy.

## Script location

- Get-WindowsClientHealthLogs.ps1

## Quick summary

If you are unsure, do this:

1. Open PowerShell as Administrator.
2. Run the basic command.
3. Wait for completion.
4. Send the ZIP file from C:\ProgramData\WindowsClientHealthLogs to your support team.
