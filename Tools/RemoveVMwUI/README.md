# RemoveVMwUI Documentation

## Overview

`RemoveVMwUI.ps1` is an interactive PowerShell script for Hyper-V cleanup.

It displays a Windows Forms dialog, lets you select one or more local Hyper-V virtual machines, and then permanently removes each selected VM together with related resources.

## What The Script Does

For each selected VM, the script:

1. Ensures the script is running elevated (Administrator). If not, it self-elevates.
2. Loads all local VMs using `Get-VM`.
3. Shows a selection dialog where multiple VMs can be selected.
4. Shows a confirmation dialog with the selected VM names.
5. Stops the VM if it is running (`Stop-VM -Force -TurnOff`).
6. Removes snapshots/checkpoints if present.
7. Deletes attached virtual disk files (`Get-VMHardDiskDrive` + `Remove-Item`).
8. Removes the VM object from Hyper-V (`Remove-VM -Force`).
9. Deletes the VM configuration folder.
10. Shows a final dialog listing all removed VM names (or a message that no VMs were removed).

## Logging

The script writes a log file in the current user's temp folder.

- Path format: `%TEMP%\\RemoveVMwUI_yyyyMMdd_HHmmss.log`
- One line per event with timestamp and user identity

Logged information includes:

1. Script start and completion
2. User running the script
3. Selected VM names
4. For each removed VM:
	- VM name
	- Configuration folder path
	- Attached disk file paths
5. No-selection / no-removal outcomes

## Requirements

- Windows with Hyper-V PowerShell module available.
- Local administrator rights.
- PowerShell with access to Windows Forms (`System.Windows.Forms`).
- Permission to stop and delete VMs and VM files.

## Usage

Run from an elevated PowerShell session (or allow UAC prompt when script self-elevates):

```powershell
.\RemoveVMwUI.ps1
```

Then:

1. Select one or more VMs in the first dialog.
2. Click `OK`.
3. Review the second dialog and click `OK` to continue.
4. At the end, review the final dialog that shows all removed VMs.

## Important Safety Notes

- Deletion is destructive and permanent.
- VM disks and configuration folders are removed from disk.
- Running VMs are force-stopped.
- There is no built-in rollback.

Recommended before use:

- Export or back up any VM you may need.
- Verify selected VM names carefully.
- Run during a maintenance window when possible.

## Scope And Limitations

- Works against local Hyper-V host only.
- Uses GUI interaction (not designed for unattended automation).
- Deletes resources discovered from VM configuration and disk attachments.

## Troubleshooting

- If no VMs appear: verify Hyper-V role/module and that VMs exist on the local host.
- If UAC prompt does not appear: run PowerShell as Administrator manually.
- If file deletion fails: check file locks, permissions, and path accessibility.

## Script Location

- `Tools/RemoveVMwUI/RemoveVMwUI.ps1`
