# Check Secure Boot

This folder contains a PowerShell diagnostic script for checking Secure Boot update state on a Windows device.

The script collects signals from:
- Windows event logs
- Secure Boot servicing registry values
- The `Secure-Boot-Update` scheduled task

It then classifies the system into one of these states:
- `OK`
- `PENDING`
- `BLOCKED`
- `FAILED`
- `UNKNOWN`

It also provides recommended next actions and writes diagnostic output to a log file and a JSON file.

## Script

- `Check-SecureBoot.ps1`

## For End Users

### What this tool does

This tool checks whether Secure Boot servicing looks healthy and whether Windows has successfully applied Secure Boot update activity.

It does not change settings by itself. It is a diagnostic tool.

### What you need

- Run PowerShell as Administrator
- Use a device that supports UEFI and Secure Boot

### Quick start

Run this from an elevated PowerShell window:

```powershell
.\Check-SecureBoot.ps1
```

If you do not want anything printed in the console:

```powershell
.\Check-SecureBoot.ps1 -Silent
```

### What you will get

The script creates output files in:

```powershell
$env:TEMP\SecureBoot-Diagnostics
```

Files created:
- `SecureBoot-<timestamp>.log`
- `SecureBoot-<timestamp>.json`

### How to read the result

- `OK`: Secure Boot servicing looks healthy
- `PENDING`: a restart or follow-up action is likely needed
- `BLOCKED`: something is preventing the update from progressing
- `FAILED`: Secure Boot servicing encountered a failure
- `UNKNOWN`: not enough evidence was found to classify the device cleanly

### What to send to support

If support asks for diagnostics, send:
- the `.log` file
- the `.json` file
- a note saying whether you ran the script before or after a reboot

## For IT Pros

### Purpose

`Check-SecureBoot.ps1` is a lightweight Secure Boot servicing triage script intended for support escalation, OEM troubleshooting, and enterprise validation workflows.

It correlates:
- system event IDs related to Secure Boot servicing
- values under `HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing`
- scheduled task presence and state for `\Microsoft\Windows\PI\Secure-Boot-Update`

### Parameters

- `-SinceDays <int>`
  - Number of days of System log history to inspect
  - Default: `90`
- `-OutputPath <string>`
  - Folder used for generated `.log` and `.json` files
  - Default: `$env:TEMP\SecureBoot-Diagnostics`
  - Trailing `\` is trimmed automatically
- `-Silent`
  - Suppresses console output
  - Logging and JSON output still occur

### Examples

```powershell
.\Check-SecureBoot.ps1
```

```powershell
.\Check-SecureBoot.ps1 -SinceDays 45
```

```powershell
.\Check-SecureBoot.ps1 -OutputPath C:\Temp\SecureBoot
```

```powershell
.\Check-SecureBoot.ps1 -Silent
```

### Classification logic

The script currently classifies state using event and registry signals:

- `OK`
  - Event `1808` seen, or registry reports `UEFICA2023Status = Updated`
- `BLOCKED`
  - Event `1802` or `1803` seen
- `FAILED`
  - Event `1795` or `1796` seen
- `PENDING`
  - Event `1801` seen
- `UNKNOWN`
  - None of the above signals were found

### Event IDs used

The script queries these System log event IDs:

- `1032`
- `1034`
- `1036`
- `1043`
- `1044`
- `1045`
- `1795`
- `1796`
- `1799`
- `1801`
- `1802`
- `1803`
- `1808`

### Output structure

The JSON output includes:
- `ComputerName`
- `Timestamp`
- `SystemState`
- `RecommendedActions`
- `Registry`
- `TaskHealth`
- `Events`

### Operational notes

- The script is read-only and does not modify Secure Boot state
- It is best run elevated
- On non-UEFI or unsupported devices, results may not be meaningful
- `-Silent` is useful for automation, remote execution, or scheduled collection

### Typical next steps by state

- `OK`
  - No immediate action
  - Keep Windows and firmware current
- `PENDING`
  - Restart the device
  - Re-run the script after restart
- `BLOCKED`
  - Review policy and firmware conditions
  - Inspect related events and registry error fields
- `FAILED`
  - Review failure events
  - Run OS health checks and patching
  - Re-test after remediation
- `UNKNOWN`
  - Collect the generated files and escalate for deeper review

## Requirements

- Windows with PowerShell 5.1 or later
- Administrative rights recommended
- UEFI-based system expected for meaningful Secure Boot servicing analysis

## Notes

- Author: Mikael Nystrom
- Blog: https://www.deploymentbunny.com
- The script is provided "AS IS" with no warranties and is not supported by the author.
