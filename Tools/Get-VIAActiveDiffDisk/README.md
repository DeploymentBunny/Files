# Get-VIAActiveDiffDisk Solution

This folder contains a small Hyper-V operations solution for identifying active differencing disks and (optionally) converting selected differencing disks to standalone dynamic VHDX files.

## Contents

- `Get-TSxActiveDiffDisk.ps1`: Core discovery script (object output, optional path output).
- `Convert-TSxDiffToDyn.ps1`: Conversion script for one VM at a time.
- `Get-TSxActiveDiffDiskUI.ps1`: Windows Forms UI wrapper for discovery and conversion.

## Audience

This documentation is split for two audiences:

- IT Pros / Operators: How to run safely in production-like environments.
- Community / Contributors: How the scripts are structured and how to contribute changes.

## What Problem This Solves

In Hyper-V environments using differencing disks, it can be difficult to quickly identify:

- Which VMs currently use differencing chains.
- Which parent disks are actively referenced.
- Which VM-specific differencing disks should be consolidated.

This toolset provides:

- Fast discovery of active differencing disk mappings.
- Optional path-only output for scripting.
- Interactive UI to inspect mappings.
- Controlled conversion workflow for selected VMs (VM must be off).

## High-Level Workflow

1. Discover active differencing disk mappings.
2. Review VM state and disk/parent paths.
3. Select target VMs carefully.
4. Convert differencing disks to dynamic VHDX files (per VM).
5. Validate VM startup and workload health.
6. Remove or archive old files after acceptance.

## Requirements

### Platform

- Windows host with Hyper-V management cmdlets available.
- Local execution on a host with access to VM storage paths.

### PowerShell

- Windows PowerShell 5.1 or newer compatible host.

### Permissions

- Local Administrator is required.
- The discovery and UI scripts self-elevate when launched non-elevated.
- The conversion script does not self-elevate; run elevated.

### VM State Requirements

- Conversion requires target VM state = `Off`.
- Do not convert running or saved-state VM differencing disks.

## Safety and Operational Guidance (IT Pros)

### Critical Warnings

- Conversion modifies disk files on storage.
- Run in a maintenance window.
- Ensure tested backups/checkpoints exist according to your policy.
- Validate free space before conversion.
- Validate replica/backup tooling expectations if used.

### Recommended Pre-Change Checklist

- Confirm change ticket and maintenance window.
- Confirm VM backup success in last backup cycle.
- Confirm no concurrent storage migration jobs.
- Confirm selected VMs are powered off.
- Confirm enough free space for temporary and rollback artifacts.

### Post-Change Checklist

- Start each converted VM.
- Validate guest OS boot and service health.
- Validate application-level checks.
- Validate backup jobs for converted VMs.
- Archive or remove old disk files only after validation period.

## Script Details

## 1) Get-TSxActiveDiffDisk.ps1

Discovers active differencing disks attached to local Hyper-V VMs.

### Parameters

- `-AsPath`: Return only unique parent paths (string output).
- `-AsList`: Display output with `Format-List`.

### Default Output (object mode)

Emits objects with:

- `VMName`
- `DiskPath`
- `ParentPath`

### Logging

- Per-run log in `%TEMP%`:
  - `Get-TSxActiveDiffDisk_yyyyMMdd_HHmmss.log`
- Log entries include timestamp and executing user.

### Examples

```powershell
# Detailed object output
.\Get-TSxActiveDiffDisk.ps1

# Unique parent paths only
.\Get-TSxActiveDiffDisk.ps1 -AsPath

# Verbose + list formatting
.\Get-TSxActiveDiffDisk.ps1 -Verbose -AsList
```

## 2) Convert-TSxDiffToDyn.ps1

Converts active differencing disks for one VM to dynamic VHDX files.

### Parameter

- `-VMName <string>` (mandatory)

### Conversion Sequence (per disk)

1. Read ACL from source differencing disk.
2. Convert source to temporary dynamic VHDX (`temp.vhdx`).
3. Rename original differencing disk to `old.vhdx`.
4. Rename `temp.vhdx` to original disk filename.
5. Restore ACL to new disk.

### Logging

- Per-run log in `%TEMP%`:
  - `Convert-TSxDiffToDyn_yyyyMMdd_HHmmss.log`

### Important Notes

- VM must be `Off` or script throws.
- Any conversion failure throws and stops processing.
- Existing `temp.vhdx` or `old.vhdx` in target folder may cause conflicts.

### Example

```powershell
.\Convert-TSxDiffToDyn.ps1 -VMName "LAB-VM01" -Verbose
```

## 3) Get-TSxActiveDiffDiskUI.ps1

Windows Forms interface that:

- Runs discovery script and displays mappings.
- Shows VM state in result grid.
- Opens selected disk/parent file in Explorer.
- Converts selected VMs after confirmation.
- Persists UI setting for verbose mode.

### UI Features

- Search: Runs discovery.
- Open Disk Path: Opens selected DiskPath item(s) in Explorer.
- Open Parent Path: Opens selected ParentPath item(s) in Explorer.
- Convert Selected: Runs conversion for selected VM(s).
- Reset: Clears UI state and deletes saved settings file.

### Settings and Logs

- Settings file:
  - `%LOCALAPPDATA%\DeploymentBunny\Get-TSxActiveDiffDiskUI.settings.json`
- Per-run UI log:
  - `%TEMP%\Get-TSxActiveDiffDiskUI_yyyyMMdd_HHmmss.log`

### Example

```powershell
.\Get-TSxActiveDiffDiskUI.ps1
```

## IT Pro Runbook

### Discovery-Only Mode (No Changes)

```powershell
# Run elevated
.\Get-TSxActiveDiffDisk.ps1 -Verbose |
  Sort-Object VMName, DiskPath |
  Format-Table -AutoSize
```

### Export Mapping for CAB/Change Record

```powershell
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
.\Get-TSxActiveDiffDisk.ps1 |
  Export-Csv -NoTypeInformation -Encoding UTF8 ".\ActiveDiffMappings_$timestamp.csv"
```

### Controlled Conversion

```powershell
# Example: convert one approved VM
Stop-VM -Name "LAB-VM01" -Force
.\Convert-TSxDiffToDyn.ps1 -VMName "LAB-VM01" -Verbose
Start-VM -Name "LAB-VM01"
```

### Validation Steps

- Verify VM boots and integration services are healthy.
- Verify critical app/service endpoints.
- Review host and guest event logs for disk-related errors.
- Confirm backup and monitoring jobs remain healthy.

## Troubleshooting

### Script says VM is not off

- Confirm current VM state with:

```powershell
Get-VM -Name "<VMName>" | Select-Object Name, State
```

### Access denied / elevation issues

- Start elevated PowerShell first.
- Ensure your account has local admin rights on host.

### Hyper-V cmdlets not found

- Install/enable Hyper-V management tools.
- Verify module availability:

```powershell
Get-Command Get-VM, Get-VHD, Convert-VHD
```

### Conversion name collisions (`temp.vhdx` / `old.vhdx`)

- Inspect disk folder for pre-existing temporary/old files.
- Move or rename stale artifacts before rerun.

### Script runs but returns no results

- Environment may not have active differencing disks.
- Verify VM disk types manually:

```powershell
Get-VM | Get-VMHardDiskDrive | Get-VHD |
  Select-Object Path, VhdType, ParentPath
```

## Recovery and Rollback Guidance

The conversion flow preserves the previous file as `old.vhdx` in the same folder.

If needed, you can roll back manually (with VM off):

1. Remove or move failed replacement disk.
2. Rename `old.vhdx` back to original disk name.
3. Confirm ACL and file path correctness.
4. Start VM and validate.

Always follow your organization's restore and incident procedures first.

## Security and Compliance Notes

- Logs include executing username.
- Logs may include VM names and storage paths.
- Treat logs as operational metadata and protect accordingly.
- Review/change retention policy for `%TEMP%` logs where required.

## Community Contributor Guide

### Design Principles

- Keep output object-based by default for automation.
- Keep user-facing errors clear and actionable.
- Maintain conservative behavior for destructive operations.
- Preserve existing script naming and command behavior.

### Coding Guidelines

- Prefer `CmdletBinding()` and explicit parameters.
- Use `-ErrorAction Stop` in critical paths and catch exceptions.
- Keep logging timestamped and per-run.
- Avoid breaking parameter names or output schema unless versioned.

### Backward Compatibility

Changes should avoid breaking:

- `Get-TSxActiveDiffDisk.ps1` default properties (`VMName`, `DiskPath`, `ParentPath`).
- Existing command lines used by operators.
- UI control behavior and labels unless documented.

### Suggested Enhancements

- Add optional `-VMName` filter to discovery script.
- Add conflict-safe temporary filename generation in conversion script.
- Add `-WhatIf` support pattern for conversion preflight mode.
- Add CSV export button in UI.
- Add Pester tests for parsing and error paths.

### Testing Recommendations

Minimum test matrix:

- Host with no VMs.
- Host with VMs but no differencing disks.
- Host with multiple differencing chains.
- Conversion success path (single and multiple disks).
- Conversion failure path (permission denied, file collision).
- UI behavior with verbose on/off and multi-select actions.

## Known Limitations

- Conversion script processes all active differencing disks for a VM, not a per-disk subset.
- Temporary and backup filenames are fixed (`temp.vhdx`, `old.vhdx`).
- UI is designed for local host operations, not remote host management.

## Versioning and Change Log Guidance

When updating this solution, include in commit/PR notes:

- Script version changes (if any).
- Behavior changes affecting operators.
- New parameters and defaults.
- Migration or rollback notes.

## License and Disclaimer

- `Convert-TSxDiffToDyn.ps1` includes MIT License header.
- Other scripts include author disclaimer (provided AS IS, no warranties).

Follow the repository's licensing and contribution conventions for any additions.

## Quick Start

```powershell
# 1) Discover active differencing mappings
.\Get-TSxActiveDiffDisk.ps1 -Verbose

# 2) Optional: Launch UI
.\Get-TSxActiveDiffDiskUI.ps1

# 3) Convert one VM (must be Off)
.\Convert-TSxDiffToDyn.ps1 -VMName "LAB-VM01" -Verbose
```

If you are unsure, start with discovery-only mode and validate results before any conversion action.
