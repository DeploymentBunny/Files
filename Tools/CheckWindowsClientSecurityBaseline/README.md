# Windows Client Security Baseline Toolkit

This folder contains a baseline assessment script and a remediation script for Windows 10/11 client security controls.

## Version

- Toolkit Version: 1.5.0
- Last Updated: 2026-05-06
- Baseline Script: 1.5.0
- Remediation Script: 1.5.0

## Versioning Policy

- Increase the script version in each file header whenever the file is changed.
- Keep README version values in sync with script headers.
- Use semantic versioning style:
  - Major: breaking behavior changes
  - Minor: new checks/remediations/features
  - Patch: fixes, documentation, wording, non-breaking refinements

## Latest Update

- Added Multicast Name Resolution (LLMNR) check to baseline assessment script.
- Added `-DisableMulticastNameResolution` remediation switch.
- `-DisableMulticastNameResolution` is now included in the `-HardenRecommended` preset.

## Contents

- `Check-WindowsClientSecurityBaseline.ps1`
- `Remediate-WindowsClientSecurityBaseline.ps1`

## What This Solution Does

- Assesses key endpoint security controls and returns results as PowerShell objects.
- Writes JSON, text, and log files for each run.
- Supports optional remediation for many findings.
- Supports targeted remediation switches, baseline-driven auto-remediation, and a safe preset (`-HardenRecommended`).

## Requirements

- Windows 10/11 client OS
- PowerShell 5.1+
- Administrative rights recommended for full coverage
- For best remediation support, run in an elevated PowerShell session

## Important Behavior

- The check script returns result rows as the default pipeline output.
- The last rows in output include paths to generated files:
  - `Json File`
  - `Text File`
  - `Log File`
- Exit codes are used for automation:
  - `0` = no `False` and no `Unknown`
  - `1` = one or more `Unknown`
  - `2` = one or more `False`
  - `99` = fatal runtime error

## Script 1: Baseline Assessment

### File

`Check-WindowsClientSecurityBaseline.ps1`

### Purpose

Evaluates core security controls and returns objects with this shape:

- `Check`
- `Status` (`True`, `False`, `Unknown`, `NA`)
- `Details`

### Parameters

- `-OutputPath <string>`
  - Default: `$env:ProgramData\WindowsClientSecurityBaseline`
- `-AsJsonOnly`
  - Present in parameter block for compatibility.

### Checks Implemented

- Administrative Privileges
- Supported OS
- UEFI
- Secure Boot
- Secure Boot Certificate
- TPM
- BitLocker (OS Drive)
- Device Guard Data
- VBS
- Credential Guard
- HVCI (Memory Integrity)
- WDAC
- LSA Protection (RunAsPPL)
- LSASS Protected Process
- WDigest Credential Caching
- Cached Logons Count
- Defender Real-Time Protection
- Defender EDR Service
- SMB1
- NTLM Hardening
- Windows Firewall Profiles (active profile(s))
- Active Inbound Firewall Rules (active profile(s))
- Multicast Name Resolution
- AppLocker
- Json File (output artifact path)
- Text File (output artifact path)
- Log File (output artifact path)

### Output Files

Each run writes:

- `SecurityBaseline_<ComputerName>_<Timestamp>.json`
- `SecurityBaseline_<ComputerName>_<Timestamp>.txt`
- `SecurityBaseline_<ComputerName>_<Timestamp>.log`

in `-OutputPath`.

### Examples

```powershell
# Basic run
.\Check-WindowsClientSecurityBaseline.ps1

# Verbose run
.\Check-WindowsClientSecurityBaseline.ps1 -Verbose

# Save output object
$r = .\Check-WindowsClientSecurityBaseline.ps1

# Show failed checks
$r | Where-Object { $_.Status -eq 'False' }

# Show generated file paths
$r | Where-Object { $_.Check -in 'Json File','Text File','Log File' }
```

## Script 2: Remediation

### File

`Remediate-WindowsClientSecurityBaseline.ps1`

### Purpose

Applies selected remediations and returns a summary object with:

- `ComputerName`
- `Timestamp`
- `ChangedCount`
- `FailedCount`
- `RestartRequired`
- `LogFile`
- `Result` (per-action outcomes)

### Parameters

Core control switches:

- `-EnableVBS`
- `-EnableCredentialGuard`
- `-EnableHVCI`
- `-EnableLsaProtection`
- `-EnableLsassProtectedProcess`
- `-DisableWDigestCredentialCaching`
- `-SetCachedLogonsCount1`
- `-EnableDefenderRealtimeProtection`
- `-EnableDefenderEdrService`
- `-DisableSMB1`
- `-HardenNTLM`
- `-EnableFirewallProfiles`
- `-SetInboundDefaultBlock`
- `-DisableAllInboundFirewallRules`
- `-DisableMulticastNameResolution`

Automation and presets:

- `-AutoFromBaseline`
- `-BaselineResult <object>`
- `-HardenRecommended`

Common:

- `-OutputPath <string>`
  - Default: `$env:ProgramData\WindowsClientSecurityBaseline`
- Supports `-WhatIf` and `-Confirm`

### HardenRecommended Preset

`-HardenRecommended` applies a curated subset:

- Enable Defender real-time protection
- Enable Defender EDR service
- Enable firewall profiles
- Set inbound default action to Block
- Enable LSA protection / LSASS protected process
- Disable WDigest credential caching
- Set cached logons count to 1
- Disable SMB1
- Harden NTLM settings
- Disable Multicast Name Resolution (LLMNR)

### Baseline-Driven Auto Remediation

`-AutoFromBaseline` parses baseline result objects and enables matching remediation switches.

Example:

```powershell
$b = .\Check-WindowsClientSecurityBaseline.ps1
.\Remediate-WindowsClientSecurityBaseline.ps1 -BaselineResult $b -AutoFromBaseline -WhatIf
```

### Remediation Exit Codes

- `0` = completed, no failures, no restart required
- `1` = completed, restart required
- `2` = completed with one or more failed actions
- `99` = fatal runtime error

## Check-to-Remediation Mapping

| Baseline Check | Remediation Switch |
|---|---|
| VBS | `-EnableVBS` |
| Credential Guard | `-EnableCredentialGuard` |
| HVCI (Memory Integrity) | `-EnableHVCI` |
| LSA Protection (RunAsPPL) | `-EnableLsaProtection` |
| LSASS Protected Process | `-EnableLsassProtectedProcess` |
| WDigest Credential Caching | `-DisableWDigestCredentialCaching` |
| Cached Logons Count | `-SetCachedLogonsCount1` |
| Defender Real-Time Protection | `-EnableDefenderRealtimeProtection` |
| Defender EDR Service | `-EnableDefenderEdrService` |
| SMB1 | `-DisableSMB1` |
| NTLM Hardening | `-HardenNTLM` |
| Windows Firewall Profiles | `-EnableFirewallProfiles` |
| Active Inbound Firewall Rules | `-SetInboundDefaultBlock` |
| Multicast Name Resolution | `-DisableMulticastNameResolution` |

## Operational Guidance

- Run baseline first, then remediate.
- Use `-WhatIf` for remediation dry-runs.
- Run remediation elevated.
- Expect reboot requirements after some registry and feature changes.
- Re-run baseline after remediation to verify outcomes.

## Known Considerations

- Some checks are permission-sensitive and may return `Unknown` without elevation.
- Security tooling state can be governed by enterprise policy (GPO/MDM), which may override local changes.
- Some settings (especially SMB1 feature and virtualization-based controls) may require reboot before status changes are visible.

## Quick Start

```powershell
# 1) Assess
$b = .\Check-WindowsClientSecurityBaseline.ps1 -Verbose

# 2) Review failed checks
$b | Where-Object { $_.Status -eq 'False' }

# 3) Simulate recommended remediation
.\Remediate-WindowsClientSecurityBaseline.ps1 -HardenRecommended -WhatIf -Verbose

# 4) Apply remediation (run elevated)
.\Remediate-WindowsClientSecurityBaseline.ps1 -HardenRecommended -Verbose

# 5) Re-assess
.\Check-WindowsClientSecurityBaseline.ps1 -Verbose
```
