# Get-TSxDisconnectedVHDs Toolkit

This folder contains two scripts:

- `Get-TSxDisconnectedVHDs.ps1` (CLI script)
- `Get-TSxDisconnectedVHDsUI.ps1` (Windows Forms UI)

Both scripts help you find VHD/VHDX files that are not attached to any local Hyper-V virtual machine.

## What The Scripts Do

`Get-TSxDisconnectedVHDs.ps1`:

- Elevates to Administrator if needed.
- Scans a target folder recursively for `*.vhd*` files.
- Collects currently attached VHD/VHDX paths from local Hyper-V VMs.
- Compares files on disk with files in use.
- Returns only disconnected files as PowerShell file objects.
- Writes detailed logs to `%TEMP%`.
- Supports detailed `-Verbose` output with VM mapping for in-use files.

`Get-TSxDisconnectedVHDsUI.ps1`:

- Elevates to Administrator if needed.
- Provides a folder picker and a Search workflow.
- Displays disconnected files in a multi-select list.
- Can open selected files in Explorer (`Open Path`).
- Can remove selected files after confirmation (`Warning, are you sure?`).
- Shows run output/verbose messages in a UI output pane.
- Saves last used settings in `%LOCALAPPDATA%\DeploymentBunny`.
- Writes per-run logs to `%TEMP%`.

## Requirements

- Windows with Hyper-V PowerShell cmdlets available.
- Permissions to query Hyper-V and access scanned folders.
- Administrator rights (scripts self-elevate automatically).
- PowerShell 5.1 or later recommended.

## Script: Get-TSxDisconnectedVHDs.ps1

### Syntax

```powershell
.\Get-TSxDisconnectedVHDs.ps1 -Folder <Path>
```

### Parameters

- `-Folder` (mandatory): Root folder to scan recursively for VHD/VHDX files.

### Output

- Returns `[System.IO.FileInfo]` objects for disconnected VHD/VHDX files.
- If no VHD/VHDX files exist in the folder, emits a warning and returns no objects.

### Detailed Examples

1. Basic scan:

```powershell
.\Get-TSxDisconnectedVHDs.ps1 -Folder "C:\VirtualDisks"
```

2. Show verbose progress and in-use VM mapping:

```powershell
.\Get-TSxDisconnectedVHDs.ps1 -Folder "D:\VMStorage" -Verbose
```

3. Capture output objects for later processing:

```powershell
$disconnected = .\Get-TSxDisconnectedVHDs.ps1 -Folder "C:\PAWDeploy"
$disconnected.Count
$disconnected | Select-Object FullName, Length, LastWriteTime
```

4. Export disconnected files to CSV:

```powershell
$disconnected = .\Get-TSxDisconnectedVHDs.ps1 -Folder "C:\PAWDeploy"
$disconnected |
    Select-Object FullName, Length, LastWriteTime |
    Export-Csv -Path "C:\Temp\DisconnectedVHDs.csv" -NoTypeInformation -Encoding UTF8
```

5. Remove disconnected files (review first):

```powershell
$disconnected = .\Get-TSxDisconnectedVHDs.ps1 -Folder "C:\PAWDeploy"
$disconnected | Select-Object FullName

# Remove only after validation
$disconnected | Remove-Item -Force -WhatIf
# If output looks correct, rerun without -WhatIf
```

6. Find very large disconnected files:

```powershell
.\Get-TSxDisconnectedVHDs.ps1 -Folder "D:\VMStorage" |
    Where-Object { $_.Length -gt 20GB } |
    Select-Object FullName, @{Name='SizeGB';Expression={[math]::Round($_.Length / 1GB, 2)}}
```

## Script: Get-TSxDisconnectedVHDsUI.ps1

### Launch

```powershell
.\Get-TSxDisconnectedVHDsUI.ps1
```

### UI Workflow

1. Set `Folder to scan`.
2. Keep `Show verbose details` enabled if you want detailed run output.
3. Click `Search`.
4. Review disconnected files in the results list.
5. Optional actions:
   - `Open Path`: Opens Explorer and selects the chosen file(s).
   - `Remove Selected`: Deletes chosen file(s) after confirmation prompt.
6. Use `Reset` to restore defaults and clear saved settings.

### Detailed UI Scenarios

1. Investigate disconnected files and open their locations:

- Run `Get-TSxDisconnectedVHDsUI.ps1`.
- Search in `C:\PAWDeploy`.
- Select multiple rows in the result list.
- Click `Open Path` to inspect files before any deletion.

2. Cleanup workflow with confirmation:

- Search in a target storage folder.
- Multi-select files to remove.
- Click `Remove Selected`.
- Confirm `Yes` in the warning dialog.
- Review status line and output panel for success/failure counts.

3. Deep troubleshooting run:

- Enable `Show verbose details`.
- Run `Search` on a large VM library folder.
- Observe verbose lines for:
  - VM discovery
  - In-use VHD mapping
  - Total discovered VHD files
  - Disconnected results

## Logging And Settings

Logs:

- CLI script log: `%TEMP%\Get-TSxDisconnectedVHDs_yyyyMMdd_HHmmss.log`
- UI script log: `%TEMP%\Get-TSxDisconnectedVHDsUI_yyyyMMdd_HHmmss.log`

UI settings:

- `%LOCALAPPDATA%\DeploymentBunny\Get-TSxDisconnectedVHDsUI.settings.json`

## Notes

- Matching is path-based (`FullName` vs mounted disk paths).
- Script checks local Hyper-V only.
- Always verify disconnected files before permanent deletion.
