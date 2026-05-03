# Save-TSxAllRunningVMs / Resume-TSxAllRunningVMs

## Purpose
This folder contains scripts for safely suspending and restoring all running Hyper-V virtual machines on local or remote hosts.

- **Save-TSxAllRunningVMs.ps1** — saves every running VM and records the VM names to a host-specific list file.
- **Resume-TSxAllRunningVMs.ps1** — reads the list file and starts each VM one by one; deletes the file when done.
- **Invoke-TSxVMSaveResumeUI.ps1** — GUI wrapper with live output, host dropdown, and VM inspection buttons.

## Script Files
- Save-TSxAllRunningVMs.ps1
- Resume-TSxAllRunningVMs.ps1
- Invoke-TSxVMSaveResumeUI.ps1

## List File
- File pattern: `SavedVMs_<target-host>.txt`
- Default location when running scripts directly: script folder (`$PSScriptRoot`)
- Location when launched from the UI: `%TEMP%` (set automatically via `-ListFolder`)
- Override location: specify `-ListFolder <existing-folder>` on the command line
- Save script aborts with a warning if the host-specific file already exists.
- Resume script reads and removes only the host-specific file for the selected target.
- The first line contains the target host metadata (`# TargetComputer=<name>`).

## What Save-TSxAllRunningVMs.ps1 Does
1. Targets local host by default, or remote host via `-ComputerName` and PowerShell remoting.
2. Finds all VMs in `Running` state with `Get-VM`.
3. Saves each VM one by one with `Save-VM`.
4. Records the name of each successfully saved VM in a host-specific list file.
5. Writes a per-run log file in `%TEMP%`.

## What Resume-TSxAllRunningVMs.ps1 Does
1. Targets local host by default, or remote host via `-ComputerName` and PowerShell remoting.
2. Reads the host-specific list file created by Save-TSxAllRunningVMs.ps1.
3. Starts each VM one by one with `Start-VM`.
4. Skips VMs that are already running or cannot be found (with a warning).
5. Always removes the host-specific list file after processing.
6. Writes a per-run log file in `%TEMP%`.

## What Invoke-TSxVMSaveResumeUI.ps1 Does
1. Starts without elevation; shows an `Elevate (Admin)` button when not running as Administrator.
2. Lets you type a target server name or pick a known host from the **Saved Hosts** dropdown (auto-populated from list files in `%TEMP%`).
3. Optionally set alternate credentials for remote hosts via the **Credentials** button.
4. **Save Running VMs** — runs Save-TSxAllRunningVMs.ps1 asynchronously with live output.
5. **Resume VMs** — runs Resume-TSxAllRunningVMs.ps1 asynchronously with live output.
6. **Show Running VMs** — queries live Hyper-V state on the target and lists all running VMs. Shows a clear warning if the host cannot be reached instead of a misleading "no VMs found" message.
7. **Show VMs in List** — displays the contents of the saved-VM list file for the current target without performing any VM operations.
8. Supports a `Show Verbose` toggle and persists UI settings to `%LOCALAPPDATA%\DeploymentBunny`.

## Prerequisites
- Hyper-V role and PowerShell Hyper-V module installed on the target host.
- Local administrative rights on the target (or alternate credentials via the UI).
- PowerShell remoting enabled on remote targets (`Enable-PSRemoting`).
- Script execution allowed by your environment policy.

## Usage

### Save all running VMs (local)
```powershell
.\Save-TSxAllRunningVMs.ps1
```

### Save all running VMs to %TEMP%
```powershell
.\Save-TSxAllRunningVMs.ps1 -ListFolder $env:TEMP
```

### Save all running VMs on a remote host
```powershell
.\Save-TSxAllRunningVMs.ps1 -ComputerName HVHOST01
```

### Save all running VMs on a remote host with alternate credentials
```powershell
$cred = Get-Credential
.\Save-TSxAllRunningVMs.ps1 -ComputerName HVHOST01 -Credential $cred
```

### Resume all saved VMs (local)
```powershell
.\Resume-TSxAllRunningVMs.ps1
```

### Resume all saved VMs from %TEMP%
```powershell
.\Resume-TSxAllRunningVMs.ps1 -ListFolder $env:TEMP
```

### Resume all saved VMs on a remote host
```powershell
.\Resume-TSxAllRunningVMs.ps1 -ComputerName HVHOST01
```

### Resume all saved VMs on a remote host with alternate credentials
```powershell
$cred = Get-Credential
.\Resume-TSxAllRunningVMs.ps1 -ComputerName HVHOST01 -Credential $cred
```

### Launch the combined UI
```powershell
.\Invoke-TSxVMSaveResumeUI.ps1
```

## Expected Outcome
- After Save: every VM that was in `Running` state is in `Saved` state and a host-specific list file exists.
- After Resume: every VM in the host-specific list file is back in `Running` state and that host-specific list file is removed.

## Verification
```powershell
Get-VM | Select-Object Name, State
```

## Notes
- Scripts can target local or remote Hyper-V hosts.
- Remote operations require PowerShell remoting access to the target host.
- VMs not in `Running` state are ignored by Save.
- Resume removes the host-specific list file even when one or more VM starts fail.
- Save and Resume write timestamped logs to `%TEMP%`.
- `-ListFolder` must point to an existing folder; the scripts do not create it.

## Troubleshooting
- Access denied: start PowerShell as Administrator.
- `Get-VM` not recognized: install/enable Hyper-V management tools and module.
- VM could not be saved or started: check VM status, host resources, and Hyper-V event logs.
