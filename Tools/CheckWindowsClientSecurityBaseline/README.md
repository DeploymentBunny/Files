# Windows Client Security Baseline Toolkit

This folder contains a baseline assessment script and a remediation script for Windows 10/11 client security controls.

## Version

- Toolkit Version: 1.7.27
- Last Updated: 2026-05-07
- Baseline Script: 1.7.27
- Remediation Script: 1.6.8

## Versioning Policy

- Increase the script version in each file header whenever the file is changed.
- Keep README version values in sync with script headers.
- Use semantic versioning style:
  - Major: breaking behavior changes
  - Minor: new checks/remediations/features
  - Patch: fixes, documentation, wording, non-breaking refinements

## Latest Update

- Removed the SmartScreen baseline check.
- Split NTLM hardening into three separate checks.
- Removed the `-FalseOnly` parameter from the baseline script.
- Added the `-IssuesOnly` switch for focused issue output.
- Extended `-IssuesOnly` to include current user local Administrators membership when status is `True`.
- Improved NTLM Restrict Sending/Receiving detail text with clear value meanings and not-configured wording.
- Renamed several baseline check labels for clearer question-style output.
- Renamed `Workgroup` check label to `Workgroup Joined?`.
- Renamed Secure Boot/Secure Boot Certificate/BitLocker check labels with question-style names.
- Removed the `Device Guard Data` informational row from returned check results.
- Added checks for Secure Boot state, Kernel DMA protection, and App Control for Business kernel/user mode policy states.
- Updated Kernel DMA protection detection to use DeviceGuardAvailableSecurityProperties from Get-ComputerInfo.
- Renamed Credential Guard and HVCI checks to running-state question labels.
- Split Windows Firewall profile status into separate Public/Domain/Internal checks and an active-profile state check.
- Renamed additional checks to question-style labels for WDAC/LSA/LSASS/WDigest/Cached Logons/Defender/Admin group checks.
- Added checks and remediations for local Administrators membership controls.
- Added informational checks for Domain Joined, Entra ID Joined, Intune Managed, and Workgroup.
- Renamed SMB1, NTLM, Multicast Name Resolution, Active Inbound Firewall Rules, and AppLocker check labels.
- Renamed WDAC and user mode policy check labels.
- Renamed application control policy/scope check labels.
- Renamed WDigest check to disabled-state wording and aligned check logic.
- Renamed cached logons check to less-or-equal wording and aligned check logic.
- Expanded `-IssuesOnly` (alias `-ShowIssues`) false-state issue checks.
- Added check `Windows patched within 45 days?` and included it in `-IssuesOnly` false-state checks.
- Expanded `-IssuesOnly`/`-ShowIssues` to include SMB1/NTLM/multicast/firewall/AppLocker checks and true-state checks for extra local admin users and active inbound firewall rules.

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
  - Default: `$env:TEMP\WindowsClientSecurityBaseline`
- `-AsJsonOnly`
  - Present in parameter block for compatibility.
- `-IssuesOnly`
  - Returns only rows where one of the configured issue checks has status `False`.
  - Alias: `-ShowIssues`
  - Current issue checks:
    - `Running with Admin Priv?` with status `False`
    - `Running supported OS?` with status `False`
    - `Windows patched within 45 days?` with status `False`
    - `UEFI Mode?` with status `False`
    - `Secure Boot?` with status `False`
    - `Secure Boot State?` with status `False`
    - `Secure Boot Certificate Updated?` with status `False`
    - `TPM exists?` with status `False`
    - `BitLocker (OS Drive)?` with status `False`
    - `VBS enabled?` with status `False`
    - `Kernel DMA Protection?` with status `False`
    - `Credential Guard running?` with status `False`
    - `HVCI (Memory Integrity) running?` with status `False`
    - `Application control policy present?` with status `False`
    - `Application control scope: apps and scripts?` with status `False`
    - `Application control policy enforced?` with status `False`
    - `LSA Protection enabled?` with status `False`
    - `LSASS Protected Process enabled?` with status `False`
    - `WDigest Credential Caching disabled?` with status `False`
    - `UAC Enabled?` with status `False`
    - `Cached Logons Count less or equal to 1?` with status `False`
    - `Defender Real-Time Protection running?` with status `False`
    - `Defender EDR Service running?` with status `False`
    - `Defender Antivirus running?` with status `False`
    - `SMB1 Disabled?` with status `False`
    - `NTLM LmCompatibilityLevel Hardened?` with status `False`
    - `NTLM Restrict Sending Traffic ok?` with status `False`
    - `NTLM Restrict Receiving Traffic ok?` with status `False`
    - `Is Multicast Name Resolution disabled` with status `False`
    - `Windows Firewall profile Public enabled?` with status `False`
    - `Windows Firewall profile Domain Enabled?` with status `False`
    - `Windows Firewall profile Internal enabled?` with status `False`
    - `Current Windows Firewall profile active?` with status `False`
    - `AppLocker being used?` with status `False`
    - `Current User member of Local Administrators group?` with status `True`
    - `Extra Local Users in Administrators group?` with status `True`
    - `Active Inbound Firewall rules in current profile?` with status `True`

### Checks Implemented

- Running with Admin Priv?
- Running supported OS?
- Windows patched within 45 days?
- UEFI Mode?
- Secure Boot?
- Secure Boot State?
- Secure Boot Certificate Updated?
- TPM exists?
- BitLocker (OS Drive)?
- VBS enabled?
- Kernel DMA Protection?
- Application control policy present?
- Application control scope: apps and scripts?
- Credential Guard running?
- HVCI (Memory Integrity) running?
- Application control policy enforced?
- LSA Protection enabled?
- LSASS Protected Process enabled?
- WDigest Credential Caching disabled?
- Cached Logons Count less or equal to 1?
- Defender Real-Time Protection running?
- Defender EDR Service running?
- Defender Antivirus running?
- SMB1 Disabled?
- NTLM LmCompatibilityLevel Hardened?
- NTLM Restrict Sending Traffic ok?
- NTLM Restrict Receiving Traffic ok?
- UAC Enabled?
- Current User member of Local Administrators group?
- Extra Local Users in Administrators group?
- Windows Firewall profile Public enabled?
- Windows Firewall profile Domain Enabled?
- Windows Firewall profile Internal enabled?
- Current Windows Firewall profile active?
- Active Inbound Firewall rules in current profile?
- Is Multicast Name Resolution disabled
- Domain Joined?
- Entra ID Joined?
- Managed by Intune?
- Workgroup Joined?
- AppLocker being used?
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
- `-EnableUAC`
- `-EnableSmartScreen`
- `-EnableDefenderAntivirus`
- `-RemoveCurrentUserFromLocalAdministrators`
- `-RemoveExtraLocalUsersFromLocalAdministrators`
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
- Enable UAC
- Enable SmartScreen
- Enable Defender Antivirus
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
| VBS enabled? | `-EnableVBS` |
| Credential Guard running? | `-EnableCredentialGuard` |
| HVCI (Memory Integrity) running? | `-EnableHVCI` |
| LSA Protection enabled? | `-EnableLsaProtection` |
| LSASS Protected Process enabled? | `-EnableLsassProtectedProcess` |
| WDigest Credential Caching disabled? | `-DisableWDigestCredentialCaching` |
| Cached Logons Count less or equal to 1? | `-SetCachedLogonsCount1` |
| Defender Real-Time Protection running? | `-EnableDefenderRealtimeProtection` |
| Defender EDR Service running? | `-EnableDefenderEdrService` |
| Defender Antivirus running? | `-EnableDefenderAntivirus` |
| SMB1 Disabled? | `-DisableSMB1` |
| NTLM LmCompatibilityLevel Hardened? | `-HardenNTLM` |
| NTLM Restrict Sending Traffic ok? | `-HardenNTLM` |
| NTLM Restrict Receiving Traffic ok? | `-HardenNTLM` |
| UAC Enabled? | `-EnableUAC` |
| Current User member of Local Administrators group? | `-RemoveCurrentUserFromLocalAdministrators` |
| Extra Local Users in Administrators group? | `-RemoveExtraLocalUsersFromLocalAdministrators` |
| Windows Firewall profile Public enabled? | `-EnableFirewallProfiles` |
| Windows Firewall profile Domain Enabled? | `-EnableFirewallProfiles` |
| Windows Firewall profile Internal enabled? | `-EnableFirewallProfiles` |
| Active Inbound Firewall rules in current profile? | `-SetInboundDefaultBlock` |
| Is Multicast Name Resolution disabled | `-DisableMulticastNameResolution` |

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
