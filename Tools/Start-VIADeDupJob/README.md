# TSx DeDup Job Toolkit

## Version
- Toolkit Version: 1.1.0
- Last Updated: 2026-05-06
- Script: Invoke-TSxDeDupJob.ps1 (1.1.0)
- Script: Invoke-TSxDeDupJobUI.ps1 (1.1.0)

## Latest Changes
- Refreshed script header descriptions for both scripts.
- Added explicit version metadata to script headers.
- Synchronized documentation wording with current behavior.

## Scripts
- `Invoke-TSxDeDupJob.ps1` — runs dedup jobs from the command line.
- `Invoke-TSxDeDupJobUI.ps1` — Windows Forms launcher for the dedup script.

## Purpose
Runs Windows Data Deduplication maintenance jobs on all dedup-enabled volumes after validating prerequisites.

Also supports reporting only actively running dedup jobs without starting new jobs.

For each volume the following jobs are executed in order:
1. Optimization
2. Garbage Collection (Full)
3. Scrubbing (Full)

Active job progress (type, state, progress %) is reported on every 30-second poll.
Final dedup status is collected via `Get-DedupStatus`.

## Prerequisites
- Windows Server with the Data Deduplication feature installed.
- For local execution: PowerShell running as local Administrator.
- For remote execution from the UI: PowerShell remoting (WinRM) enabled on the target server and network access to that server.
- Execution policy that allows script execution.

## How To Run

### Command line
```powershell
.\Invoke-TSxDeDupJob.ps1
```

```powershell
.\Invoke-TSxDeDupJob.ps1 -Report
```

If launched non-elevated the script self-elevates automatically.

### GUI
```powershell
.\Invoke-TSxDeDupJobUI.ps1
```

The UI launcher:
- Starts directly without an elevation prompt.
- Shows an **Elevate (Admin)** button when running as a standard user.
  - Clicking it relaunches the UI as Administrator via UAC.
- Supports running against the local server or a remote server selected in the **Server** field.
- Supports selecting alternate credentials for remote execution via the **Credential** button.
- Requires elevation only when running against the local server.
- Provides two operations:
  - **Run DeDup Jobs** — runs optimization/garbage collection/scrubbing workflow.
  - **Show Running Jobs** — runs report mode and displays only active dedup jobs.
- Runs `Invoke-TSxDeDupJob.ps1` asynchronously in a background runspace.
- Displays output, warnings, errors, and live job progress in a text pane.
- Supports a **Show Verbose** toggle.
- Persists settings to `%LOCALAPPDATA%\DeploymentBunny\Invoke-TSxDeDupJobUI.settings.json`.
- Both the UI and the main script each write their own log to `%TEMP%`:
  - `Invoke-TSxDeDupJobUI_<timestamp>.log` — UI events and run status.
  - `Invoke-TSxDeDupJob_<timestamp>.log` — dedup job execution detail.
- Can be closed while the script continues running in the background.

## Logging

Both scripts write their own log file to `%TEMP%`:

| Script | Log file |
|---|---|
| `Invoke-TSxDeDupJob.ps1` | `%TEMP%\Invoke-TSxDeDupJob_<yyyyMMdd_HHmmss>.log` |
| `Invoke-TSxDeDupJobUI.ps1` | `%TEMP%\Invoke-TSxDeDupJobUI_<yyyyMMdd_HHmmss>.log` |

### Log format
Each line is written as:
```text
[yyyy-MM-dd HH:mm:ss] [User: DOMAIN\user] <message>
```

### Example log entries
```text
[2026-04-23 21:34:01] [User: CONTOSO\admin] Invoke-TSxDeDupJob started (running as Administrator)
[2026-04-23 21:34:02] [User: CONTOSO\admin] Validation passed: Found 1 dedup-enabled volume(s)
[2026-04-23 21:34:02] [User: CONTOSO\admin] Starting Optimization for volume: E:
[2026-04-23 21:37:21] [User: CONTOSO\admin] Invoke-TSxDeDupJob completed successfully
```

## Troubleshooting
- Dedup cmdlets not found:
  - Install or enable Data Deduplication feature on the server.
- Access denied or elevation issues:
  - For local runs, click **Elevate (Admin)** in the UI and retry.
- Remote connection errors (WinRM/Invoke-Command):
  - Verify PowerShell remoting is enabled on the target server.
  - Verify firewall/network access and that the target server name is reachable.
  - If needed, use the **Credential** button and provide an account with rights on the remote server.
- Long wait times:
  - Existing dedup jobs are allowed to finish before new jobs start.
- Failure entries in log:
  - Review the `Details` field for the exception message and failing volume.

## Notes
- The script is designed to serialize dedup jobs and avoid overlap.
- Runtime depends on volume size, data churn, and current dedup load.
