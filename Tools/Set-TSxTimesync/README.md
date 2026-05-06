# Set-TSxTimesync

## Version
- Script Version: 1.1.0
- Last Updated: 2026-05-07

## Purpose
Set-TSxTimesync configures Windows Time (W32Time) to use a specified external NTP source and then forces a synchronization.

## Script File
- Set-TSxTimesync.ps1

## What The Script Does
1. Validates the script is running with Administrator privileges.
2. Builds NTP source value from `TimeSource` (for example `se.pool.ntp.org,0x1`).
3. Updates required Windows Time registry settings under:
   - `HKLM:\SYSTEM\CurrentControlSet\Services\W32Time`
4. Detects whether the machine is virtual.
5. If virtual, disables `VMICTimeProvider` to avoid host/guest time sync conflicts.
6. Restarts the `W32Time` service.
7. Runs `w32tm /resync`.
8. Writes a timestamped log file to `%TEMP%` and supports `-Verbose` and `-WhatIf`.

## Parameters
### TimeSource
- Type: String
- Required: No
- Description: FQDN or host name of the NTP server to use.
- Default: `pool.ntp.org`

Example values:
- `se.pool.ntp.org`
- `time.windows.com`
- `pool.ntp.org`

## Prerequisites
- Windows system with `W32Time` service available.
- PowerShell session running as Administrator.
- Access to the configured NTP server.

## Usage
### Basic run
```powershell
.\Set-TSxTimesync.ps1 -TimeSource "se.pool.ntp.org"
```

### Verbose output
```powershell
.\Set-TSxTimesync.ps1 -TimeSource "time.windows.com" -Verbose
```

### Dry run
```powershell
.\Set-TSxTimesync.ps1 -TimeSource "pool.ntp.org" -WhatIf
```

## Expected Result
- Registry values for W32Time are updated.
- `W32Time` restarts successfully.
- `w32tm /resync` is invoked.
- A log file is written to `%TEMP%`:
  - `Set-TSxTimesync_<yyyyMMdd_HHmmss>.log`

## Verify Configuration
```powershell
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters" | Select-Object Type, NtpServer
w32tm /query /status
w32tm /query /configuration
```

## Error Behavior
- The script exits with code `1` if not started in an elevated PowerShell session.
- Terminating errors are captured, logged, and rethrown for calling tools/pipelines.

## Troubleshooting
- Access denied:
  - Run the script in an elevated PowerShell session.
- NTP server unreachable:
  - Validate DNS/network/firewall access to the specified time source.
- Resync fails:
  - Check Windows Time service health and event logs, then retry.
