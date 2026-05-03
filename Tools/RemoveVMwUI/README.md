# Remove-VMUI

## Overview

`Remove-VMUI.ps1` is an interactive PowerShell script for Hyper-V cleanup.

It displays a Windows Forms dialog, lets you connect to a local or remote Hyper-V host using optional alternate credentials, select one or more virtual machines, and then permanently remove each selected VM together with related resources.

## What The Script Does

For each selected VM, the script:

1. Optionally self-elevates to Administrator via UAC if not already elevated.
2. Loads VMs from the specified host using `Get-VM`.
3. Shows a multi-select VM list in the UI.
4. Asks for confirmation before proceeding with deletion.
5. Stops the VM if it is running (`Stop-VM -Force -TurnOff`).
6. Removes snapshots/checkpoints if present.
7. Deletes attached virtual disk files (`Get-VMHardDiskDrive` + `Remove-Item`).
8. Removes the VM object from Hyper-V (`Remove-VM -Force`).
9. Deletes the VM configuration folder.
10. Shows a completion summary in the output pane.

## Logging

A timestamped log file is created each time the script runs:

- **Location:** `%TEMP%\Remove-VMUI\`
- **Filename format:** `Remove-VMUI_yyyy-MM-dd_HH-mm-ss.log`
- **Each entry:** `[yyyy-MM-dd HH:mm:ss.fff] Message`

Enable the **Verbose** checkbox to see verbose messages in the output pane in addition to the log file. When Verbose is checked, the log file path is displayed as the first line in the output pane.

Logged information includes:

1. UI connect and disconnect events
2. VM count loaded per host
3. Delete confirmation and initiated events
4. Per-VM: start, success, or failure of removal
5. Verbose detail lines when Verbose is enabled

## Settings Persistence

The script automatically saves and restores last-used settings:

- **Settings file:** `%LOCALAPPDATA%\DeploymentBunny\Remove-VMUI.settings.json`
- **Persisted values:**
  - Hyper-V hostname (`HostName`)
  - Verbose checkbox state (`VerboseChecked`)

Settings are loaded when the form opens and saved when the form closes.

## Requirements

- Windows with Hyper-V PowerShell module available.
- Local administrator rights (or UAC elevation via the Elevate button).
- PowerShell with access to Windows Forms (`System.Windows.Forms`).
- For remote hosts: PowerShell remoting (WinRM) enabled and firewall rules allowing it.

## Credentials

Click the **Credential** button to supply alternate credentials for remote host operations. If no credential is provided, the current user context is used.

## Usage

Run from a PowerShell session (the script will offer to self-elevate if needed):

```powershell
.\Remove-VMUI.ps1
```

Then:

1. Confirm or change the Hyper-V host name in the host textbox.
2. Optionally click **Credential** to set alternate credentials.
3. Click **Connect** to load the VM list.
4. Select one or more VMs.
5. Click **Delete Selected VMs**.
6. Confirm the deletion prompt.

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

- Works against local or remote Hyper-V hosts.
- Uses GUI interaction (not designed for unattended automation).
- Deletes resources discovered from VM configuration and disk attachments.

## Troubleshooting

- If no VMs appear: verify Hyper-V role/module and that VMs exist on the target host.
- If UAC prompt does not appear: run PowerShell as Administrator manually.
- If file deletion fails: check file locks, permissions, and path accessibility.
- If remoting fails: verify WinRM is enabled, firewall rules, and credentials.

## Script Location

- `Tools/RemoveVMwUI/Remove-VMUI.ps1`
