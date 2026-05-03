# Export / Import / Copy / Deploy Windows Roles and Features

This solution provides a GUI launcher and four PowerShell scripts to export installed Windows Server roles/features, import them to another server, copy directly from one server to multiple destinations, or deploy from a JSON export to multiple servers in parallel.

## Scripts and UI

- `Invoke-WindowsRolesAndFeaturesUI.ps1` — Windows Forms GUI launcher
- `Export-WindowsRolesAndFeatures.ps1` — Export roles/features to JSON
- `Import-WindowsRolesAndFeatures.ps1` — Import and install from JSON
- `Copy-WindowsRolesAndFeatures.ps1` — Copy from source to one or more destinations
- `Deploy-WindowsRolesAndFeatures.ps1` — Parallel deployment to multiple servers

## What the solution does

- **GUI launcher**: Windows Forms UI with 4 tabs (Export, Import, Copy, Deploy) for easy operation.
- Exports installed roles/features to JSON.
- Includes source OS metadata in export (`Version`, `Build`, `SKU`, etc.).
- Imports roles/features from JSON to local or remote targets.
- Copies roles/features directly from a source server to one or more destination servers.
- Deploys roles/features from JSON to multiple servers in parallel using background jobs.
- Skips roles/features that are already installed.
- Warns and skips roles/features not available on current target OS.
- Supports relaxed mapping mode for known feature-name differences between versions.
- Supports `-WhatIf`, `-Verbose`, and `-PassThru` flags.
- Supports automatic restart if needed (Import, Copy, Deploy).
- Writes status both to screen and to log files in `%TEMP%`.
- Persists UI settings to `%LOCALAPPDATA%\DeploymentBunny`.

## Requirements

- Windows Server with `ServerManager` module available.
- PowerShell remoting enabled for remote scenarios (`WinRM`).
- Sufficient privileges to query/install roles/features.
- Network access to paths used for JSON and optional `-Source` media path.

## 0) GUI Launcher

### File

`Invoke-WindowsRolesAndFeaturesUI.ps1`

### Purpose

Provides a Windows Forms graphical user interface to run Export, Import, Copy, or Deploy operations.

### Features

- Four independent tabs: Export, Import, Copy, Deploy.
- Tab-specific controls for computer names, credentials, JSON paths, and options.
- Real-time credential state display (shows when credentials are set).
- Options group with toggles: Verbose, WhatIf, PassThru, RelaxedMode, KeepJSONConfigFile, Restart if needed.
- Live output pane showing script progress and errors.
- Settings auto-save to `%LOCALAPPDATA%\DeploymentBunny\Invoke-WindowsRolesAndFeaturesUI.settings.json`.
- Per-run log files in `%TEMP%`.

### Usage

```powershell
# Launch the UI
.\Invoke-WindowsRolesAndFeaturesUI.ps1
```

Select a tab, fill in required fields, set credentials as needed, check optional flags, and click **Run**.

---

## 1) Export script

### File

`Export-WindowsRolesAndFeatures.ps1`

### Purpose

Collect installed roles/features from local or remote server and save to JSON.

### Parameters

- `-JSONConfigFile <string>` (required): Output JSON file path (local or UNC).
- `-ComputerName <string>`: Remote source server name.
- `-Credential <PSCredential>`: Credential for remote source.
- `-JsonDepth <int>`: JSON depth (default `8`).
- `-PassThru`: Return summary object.

### Examples

```powershell
# Export local server
.\Export-WindowsRolesAndFeatures.ps1 -JSONConfigFile C:\Temp\roles.json -Verbose

# Export remote server to local file
.\Export-WindowsRolesAndFeatures.ps1 -ComputerName SRV01 -JSONConfigFile C:\Temp\SRV01-roles.json -Verbose

# Export remote server to UNC
.\Export-WindowsRolesAndFeatures.ps1 -ComputerName SRV01 -JSONConfigFile \\fileserver\share\SRV01-roles.json -Verbose

# Dry run
.\Export-WindowsRolesAndFeatures.ps1 -JSONConfigFile C:\Temp\roles.json -WhatIf -Verbose
```

## 2) Import script

### File

`Import-WindowsRolesAndFeatures.ps1`

### Purpose

Install roles/features from exported JSON on local or remote target.

### Parameters

- `-JSONConfigFile <string>` (required): Input JSON path.
- `-ComputerName <string>`: Remote destination server.
- `-Credential <PSCredential>`: Credential for remote destination.
- `-IncludeManagementTools <bool>`: Include management tools (default `True`).
- `-Restart`: Allow restart if needed.
- `-Source <string>`: Alternate role binaries source path.
- `-RelaxedMode`: Enable feature-name compatibility mapping.
- `-FeatureNameMap <hashtable>`: Custom feature-name map used with relaxed mode.
- `-PassThru`: Return `Install-WindowsFeature` results.

### Behavior notes

- Compares exported OS version to target OS version and warns on mismatch.
- Installs per feature (one-by-one) and writes visible lines:
  - `INSTALL: Starting role/feature 'X'`
  - `INSTALL: Completed role/feature 'X'`
- Already installed features are skipped.
- Unavailable features are warned and skipped.

### Default relaxed-mode mappings

- `Windows-Defender-Features` -> `Windows-Defender`
- `InkAndHandwritingServices` -> `Server-Media-Foundation`

### Examples

```powershell
# Import local
.\Import-WindowsRolesAndFeatures.ps1 -JSONConfigFile C:\Temp\roles.json -Verbose

# Import to remote target
.\Import-WindowsRolesAndFeatures.ps1 -JSONConfigFile \\fileserver\share\SRV01-roles.json -ComputerName SRV02 -Verbose

# Relaxed mode with source media and custom map
.\Import-WindowsRolesAndFeatures.ps1 -JSONConfigFile C:\Temp\roles.json -RelaxedMode -Source E:\sources\sxs -FeatureNameMap @{ 'Windows-Defender-Features'='Windows-Defender' } -Verbose

# Dry run
.\Import-WindowsRolesAndFeatures.ps1 -JSONConfigFile C:\Temp\roles.json -WhatIf -Verbose
```

## 3) Copy script (end-to-end)

### File

`Copy-WindowsRolesAndFeatures.ps1`

### Purpose

Export from source and install to one or more destination servers in one run.

### Key Behaviors

- Automatically generates a temporary JSON file in `%TEMP%` (unless `-JSONConfigFile` is specified).
- Temporary JSON file is automatically deleted after completion (unless `-KeepJSONConfigFile` is used).
- Supports parallel operations via remoting and background jobs.
- Reports completion status for each destination.
- Supports automatic restart if needed via `-RestartIfNeeded`.

### Parameters

- `-SourceServer <string>`: Source server (default local).
- `-DestinationServer <string[]>` (required): One or more destinations.
- `-JSONConfigFile <string>`: Intermediary JSON path (local/UNC). Auto-generated in `%TEMP%` if omitted.
- `-SourceCredential <PSCredential>`: Credential for source remoting.
- `-DestinationCredential <PSCredential>`: Credential for destination remoting.
- `-IncludeManagementTools <bool>`: Include management tools (default `True`).
- `-RestartIfNeeded`: Allow restart if needed.
- `-Source <string>`: Alternate role binaries source path.
- `-RelaxedMode`: Enable compatibility mapping.
- `-FeatureNameMap <hashtable>`: Custom compatibility mapping.
- `-KeepJSONConfigFile`: Keep intermediary JSON after completion.
- `-PassThru`: Return per-destination results.

### Examples

```powershell
# Copy from one source to one target (temp JSON auto-cleaned)
.\Copy-WindowsRolesAndFeatures.ps1 -SourceServer SRV01 -DestinationServer SRV02 -Verbose

# Copy from one source to multiple targets
.\Copy-WindowsRolesAndFeatures.ps1 -SourceServer SRV01 -DestinationServer SRV02,SRV03,SRV04 -Verbose

# Copy with restart
.\Copy-WindowsRolesAndFeatures.ps1 -SourceServer SRV01 -DestinationServer SRV02,SRV03 -RestartIfNeeded -Verbose

# Copy with relaxed mode and custom map
.\Copy-WindowsRolesAndFeatures.ps1 -SourceServer SRV01 -DestinationServer SRV02,SRV03 -RelaxedMode -Source \\fileserver\sources\sxs -FeatureNameMap @{ 'InkAndHandwritingServices'='Server-Media-Foundation' } -Verbose

# Keep intermediary JSON on a share
.\Copy-WindowsRolesAndFeatures.ps1 -SourceServer SRV01 -DestinationServer SRV02 -JSONConfigFile \\fileserver\share\SRV01-roles.json -KeepJSONConfigFile -Verbose

# Dry run
.\Copy-WindowsRolesAndFeatures.ps1 -SourceServer SRV01 -DestinationServer SRV02,SRV03 -WhatIf -Verbose

## 4) Deploy script (parallel)

### File

`Deploy-WindowsRolesAndFeatures.ps1`

### Purpose

Install roles/features from a JSON export to multiple destination servers simultaneously using parallel background jobs.

### Key Behaviors

- Each destination server gets its own background job.
- All jobs run in parallel up to the throttle limit.
- Progress is reported every 30 seconds during deployment.
- If a job exceeds the timeout (default 10 minutes), the job is stopped and the script verifies what was installed.
- Supports restart per destination if needed via `-RestartIfNeeded`.
- Returns per-destination result objects when `-PassThru` is used.

### Parameters

- `-JSONConfigFile <string>` (required): Input JSON path.
- `-DestinationServer <string[]>` (required): One or more destination servers.
- `-Credential <PSCredential>`: Credential for remote destinations.
- `-IncludeManagementTools <bool>`: Include management tools (default `True`).
- `-RestartIfNeeded`: Automatically restart if required after installation.
- `-Source <string>`: Alternate role binaries source path.
- `-RelaxedMode`: Enable compatibility mapping.
- `-FeatureNameMap <hashtable>`: Custom compatibility mapping.
- `-PassThru`: Return per-destination results.
- `-ThrottleLimit <int>`: Maximum parallel jobs (default `8`).
- `-JobTimeoutMinutes <int>`: Job timeout in minutes (default `10`).

### Examples

```powershell
# Deploy to 3 servers
.\Deploy-WindowsRolesAndFeatures.ps1 -JSONConfigFile C:\Temp\roles.json -DestinationServer SRV01,SRV02,SRV03 -Verbose

# Deploy to multiple servers with credentials
.\Deploy-WindowsRolesAndFeatures.ps1 -JSONConfigFile \\fileserver\share\roles.json -DestinationServer SRV01,SRV02,SRV03 -Credential (Get-Credential) -Verbose

# Deploy with restart
.\Deploy-WindowsRolesAndFeatures.ps1 -JSONConfigFile C:\Temp\roles.json -DestinationServer SRV01,SRV02,SRV03 -RestartIfNeeded -Verbose

# Deploy with relaxed mode and alternate throttle
.\Deploy-WindowsRolesAndFeatures.ps1 -JSONConfigFile C:\Temp\roles.json -DestinationServer SRV01,SRV02,SRV03,SRV04,SRV05 -RelaxedMode -ThrottleLimit 3 -Verbose

# Dry run
.\Deploy-WindowsRolesAndFeatures.ps1 -JSONConfigFile C:\Temp\roles.json -DestinationServer SRV01,SRV02,SRV03 -WhatIf -Verbose
```
```

## Logging

Each script writes a timestamped log file in `%TEMP%`:

- `Export-WindowsRolesAndFeatures_yyyyMMdd_HHmmss.log`
- `Import-WindowsRolesAndFeatures_yyyyMMdd_HHmmss.log`
- `Copy-WindowsRolesAndFeatures_yyyyMMdd_HHmmss.log`
- `Deploy-WindowsRolesAndFeatures_yyyyMMdd_HHmmss.log`
- `Invoke-WindowsRolesAndFeaturesUI_yyyyMMdd_HHmmss.log`

Logs include timestamp, running user, and status messages.

The UI also persists settings to: `%LOCALAPPDATA%\DeploymentBunny\Invoke-WindowsRolesAndFeaturesUI.settings.json`

## Typical workflows

### A) Using the GUI launcher (recommended)

1. Run `Invoke-WindowsRolesAndFeaturesUI.ps1`.
2. Select the desired tab (Export, Import, Copy, or Deploy).
3. Fill in required fields and set credentials as needed.
4. Check optional flags (Verbose, RelaxedMode, Restart if needed, etc.).
5. Click **Run**.
6. Monitor output in the UI pane.
7. Settings are saved automatically for next time.

### B) Export now, import later (command line)

1. Run export on source.
2. Store JSON locally or in UNC share.
3. Run import on destination(s) using JSON.

### C) One-command copy (command line)

1. Run copy script with source and destination servers.
2. Optional relaxed mode handles known name differences.
3. Optional `-KeepJSONConfigFile` preserves intermediary JSON.
4. Temporary JSON file is auto-deleted unless `-KeepJSONConfigFile` is used.

### D) Parallel deploy to multiple servers (command line)

1. Export roles/features to JSON on a source server (or use existing JSON).
2. Run deploy script specifying destination servers.
3. Jobs run in parallel (configurable throttle).
4. Optional `-RestartIfNeeded` handles reboots on each destination.
5. Check result objects for per-server status.

## Troubleshooting

- `-JSONConfigFile must be a file, not a folder`
  - Supply a file path like `C:\Temp\roles.json`, not `C:\Temp`.

- `Importing on different version...`
  - Expected when source/target OS versions differ.
  - Use `-RelaxedMode` and optional `-FeatureNameMap` for compatibility.

- Remote connection errors (`Invoke-Command`)
  - Verify WinRM and firewall.
  - Verify credentials and permissions.

- Feature unavailable warnings
  - Feature does not exist on target OS edition/version.
  - Use mapping via `-RelaxedMode` and custom map if appropriate.

## Notes

- Scripts are idempotent for installed features (already installed items are skipped).
- Use `-WhatIf` before production runs.
- Prefer UNC paths for shared JSON/source media in multi-server runs.
- GUI tabs are independent — changes to one tab do not affect others.
- Copy script uses a temporary JSON file by default (auto-deleted); use `-KeepJSONConfigFile` to preserve it.
- Restart handling is supported on Import, Copy, and Deploy operations via `-RestartIfNeeded` (UI: "Restart if needed" checkbox).
- Pending restart states are detected before and after install/update operations.
- Deploy script uses parallel background jobs (configurable `-ThrottleLimit`, default 8).
- All operation dates in headers updated: 2026-04-27
