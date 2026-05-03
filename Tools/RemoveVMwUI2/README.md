# Remove-VMUI2

GUI tool to connect to a Hyper-V host and permanently remove selected virtual machines.

`Remove-VMUI2.ps1` is a Windows Forms script that:
- Self-elevates to Administrator if needed.
- Connects to a local or remote Hyper-V host.
- Lists available VMs in a multi-select grid.
- Supports alternate credentials for remote host operations.
- Deletes selected VMs and associated resources.
- Writes a timestamped log file to `%TEMP%\Remove-VMUI2\`.
- Persists last-used settings (hostname, Verbose state) between sessions.

## Table of contents
- [What this script does](#what-this-script-does)
- [How removal works](#how-removal-works)
- [Requirements](#requirements)
- [Permissions and remoting](#permissions-and-remoting)
- [Files and functions](#files-and-functions)
- [Parameters](#parameters)
- [How to use](#how-to-use)
- [Logging](#logging)
- [Settings persistence](#settings-persistence)
- [Behavior notes](#behavior-notes)
- [Error handling](#error-handling)
- [Safety recommendations](#safety-recommendations)
- [Known limitations](#known-limitations)
- [Troubleshooting](#troubleshooting)
- [Version notes](#version-notes)

## What this script does
The tool is intended for cleanup workflows where you must remove one or more Hyper-V VMs from a host.

For each selected VM, the script attempts to:
1. Stop the VM if it is running.
2. Remove all checkpoints/snapshots.
3. Remove attached virtual disk files (paths returned by `Get-VMHardDiskDrive`).
4. Remove the VM from Hyper-V.
5. Remove the VM configuration folder (`ConfigurationLocation`).

After completion, the UI shows a summary in the output pane and refreshes the VM list.

## How removal works
The removal logic is implemented by `Remove-TSxVM` and executed through PowerShell remoting:
- A script block is sent to the selected host via `Invoke-Command -ComputerName <host>`.
- The VM is looked up by name using `Get-VM -Name`.
- If running, `Stop-VM -Force -TurnOff` is used.
- If checkpoints exist:
  - The root checkpoint is restored.
  - All checkpoints are removed.
  - The script waits until no checkpoints remain.
- Each attached disk path is removed with `Remove-Item -Force`.
- The VM is removed using `Remove-VM -Force`.
- The configuration folder is removed recursively.

The function returns structured result objects to the caller, and the UI layer logs and summarizes those results.

## Requirements
- Windows with PowerShell 5.1+
- Hyper-V module available (`Get-VM`, `Stop-VM`, `Remove-VM`, etc.)
- Windows Forms available (for the GUI)
- Network connectivity from the execution machine to target Hyper-V host
- PowerShell remoting support for remote host operations

## Permissions and remoting
- The script self-elevates and must run as Administrator.
- The executing account must have sufficient rights on the target Hyper-V host.
- If remote host operations fail, verify WinRM/remoting configuration and firewall rules.
- Use the **Credential** button to supply alternate credentials for remote operations.

## Files and functions
- Script: `Remove-VMUI2.ps1`
- Main functions:
  - `Connect-TSxUI`: Loads VM names from selected host into the grid.
  - `Remove-TSxUI`: Processes selected VMs from the UI and shows completion summary.
  - `Remove-TSxVM`: Performs remote VM removal workflow.
  - `Close-TSxUI`: Closes the form.
  - `Add-OutputLine`: Appends a line to the UI output pane.
  - `Add-LogLine`: Appends a timestamped entry to the log file.
  - `Add-VerboseLine`: Writes to the output pane (when Verbose is enabled) and to the log file.
  - `Save-UISettings`: Saves current settings to JSON file on form close.
  - `Import-UISettings`: Loads settings from JSON file on form load.

## Parameters
### Script parameters
This script has no top-level command-line parameters. It is designed for interactive GUI use.

### Function parameters
`Remove-TSxVM` supports:
- `-Computername` (mandatory): Hyper-V host name.
- `-VMName` (mandatory): Target VM name.

## How to use
1. Open a PowerShell session (elevated, or click Elevate button in the UI).
2. Navigate to the script directory.
3. Run:

```powershell
.\Remove-VMUI2.ps1
```

4. In the GUI:
- Confirm or change the Hyper-V host in the host textbox.
- Optionally click **Credential** to set alternate credentials.
- Click **Connect** to load VMs.
- Select one or more VMs in the list.
- Click **Delete Selected VMs**.
- Review the final confirmation dialog.

## Logging
A timestamped log file is created each time the script runs:

- **Location:** `%TEMP%\Remove-VMUI2\`
- **Filename format:** `Remove-VMUI2_yyyy-MM-dd_HH-mm-ss.log`
- **Each entry:** `[yyyy-MM-dd HH:mm:ss.fff] Message`

Enable the **Verbose** checkbox to see verbose messages in the output pane in addition to the log file. When Verbose is checked, the log file path is displayed as the first line in the output pane.

Typical logged events:
- Host connection and VM count loaded
- Delete confirmation and initiated events
- Per-VM deletion details (running state, snapshot state, disk list, configuration folder)
- Not found or failure messages
- Settings save and load events

## Settings persistence
The script automatically saves and restores last-used settings:

- **Settings file:** `%LOCALAPPDATA%\DeploymentBunny\Remove-VMUI2.settings.json`
- **Persisted values:**
  - Hyper-V hostname (`HostName`)
  - Verbose checkbox state (`VerboseChecked`)

Settings are loaded when the form opens and saved when the form closes.

## Behavior notes
- VM selection supports multi-select.
- If no VM is selected and Delete is clicked, a warning dialog is shown.
- If a VM is not found on the host, the script logs it and continues.
- The PowerShell console window is minimized when the GUI starts.

## Error handling
- `Remove-TSxUI` wraps each VM removal in `try/catch`.
- On error, the failure is logged and the error is rethrown.
- Disk and folder deletion use forceful file operations; some file deletion operations use `-ErrorAction Continue` and may proceed even if specific files fail.

## Safety recommendations
Because this tool permanently removes VM resources, use it carefully.

Recommended safeguards:
- Validate host name before clicking **Delete Selected VMs**.
- Verify VM selection carefully (especially in multi-select).
- Confirm backups or exports exist if rollback is required.
- Test in non-production first.
- Prefer running during maintenance windows.

## Known limitations
- No built-in dry-run mode.
- No secondary typed confirmation (for example, entering VM name to confirm).
- Uses VM name matching; duplicate naming patterns can increase operator risk.
- The checkpoint workflow restores root snapshot before removal, which may be unnecessary in some environments.
- If remoting is blocked, operations will fail.

## Troubleshooting
### No VMs appear after Connect
- Verify host name is correct and reachable.
- Verify Hyper-V service and module availability on target host.
- Verify account permissions.

### Access denied or remoting errors
- Run elevated.
- Confirm WinRM is enabled and trusted-host/auth settings are correct for your environment.
- Confirm firewall allows remoting.
- Try clicking **Credential** to supply explicit credentials.

### VM removed but some files remain
- Check log for disk paths and errors.
- Ensure files were not locked by another process.
- Manually remove residual files if required.

### GUI does not start
- Ensure script is run with Windows PowerShell where WinForms is available.
- Check execution policy and script blocking rules.

## Version notes
Current script title string in the UI:
- `Completely remove virtual machines, for real`
