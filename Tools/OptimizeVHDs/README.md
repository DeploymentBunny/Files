# Optimize-VHDs Solution

## Files
- `Optimize-VHDs.ps1` - command-line worker script
- `Optimize-VHDsUI.ps1` - Windows Forms wrapper that invokes `Optimize-VHDs.ps1` and streams output into the UI

---

## Optimize-VHDs.ps1

### Overview
`Optimize-VHDs.ps1` optimizes VHD/VHDX files attached to Hyper-V virtual machines.

The script evaluates:
- specific VM names passed through `-VMnames`, or
- all local VMs if `-VMnames` is omitted.

A VM is eligible only when:
- VM state is `Off`
- VM has no checkpoints

For each eligible disk path the script:
1. Reads the current file size.
2. Runs `Optimize-VHD -Mode Full`.
3. Reads the new file size and reports the saving.

### Requirements
- Windows host with Hyper-V PowerShell module
- Local administrator permissions
- Access to Hyper-V VM metadata and attached VHD/VHDX paths

### Parameters

#### `-VMnames`
Type: `string[]`  
Optional. One or more VM names to evaluate. If omitted, all local VMs are evaluated.

#### `-EmitStructuredOutput`
Type: `bool`  
Internal parameter used by `Optimize-VHDsUI.ps1`. It switches output to structured `PSCustomObject` events so the UI can process progress and results in real time.

### Output (default command-line mode)
The script writes plain text to the output stream:
- progress lines per VM and per disk
- result lines in the format `VM=...; Disk=...; Status=...; SavedGB=...; Message=...`
- a `Write-Progress` bar while processing
- a final summary line

### Processing logic
1. Verify elevation (administrator is required).
2. Resolve target VM set (all VMs or named VMs).
3. For each VM:
   - Skip if not `Off`.
   - Skip if checkpoints exist.
   - Collect attached VHD/VHDX paths.
   - Skip if no paths found.
4. For each disk path:
   - Skip if path does not exist.
   - Record size before.
   - Optimize disk.
   - Record size after and compute saving.
   - Emit result.
5. Emit summary.

### Result status values
- `Success`
- `Skipped`
- `Failed`

### Examples

```powershell
# Optimize all eligible local VMs
.\Optimize-VHDs.ps1

# Optimize specific VMs
.\Optimize-VHDs.ps1 -VMnames "LAB-DC01","LAB-APP01"
```

### Troubleshooting
- **Administrator privileges required**: Run from an elevated PowerShell host.
- **No VMs processed**: Verify VM names or confirm `Get-VM` returns results.
- **VM skipped (not Off)**: Shut down the VM completely and rerun.
- **VM skipped (checkpoints)**: Remove checkpoints and rerun.
- **Disk path missing**: Verify storage path availability and permissions.

---

## Optimize-VHDsUI.ps1

### Overview
`Optimize-VHDsUI.ps1` provides a Windows Forms GUI for VHD optimization.

The UI:
- always self-elevates at startup
- supports local and remote host targeting
- allows optional credentials for remote WinRM operations
- lists eligible VMs (Off and no checkpoints)
- invokes `Optimize-VHDs.ps1` and streams structured events into the output pane
- updates status text and progress bar in real time
- shows completion summary totals

`Optimize-VHDs.ps1` must exist in the same folder.

### Requirements
- Windows host with Hyper-V PowerShell module
- Windows Forms support (.NET Framework)
- WinRM connectivity for remote mode
- Administrator permissions (handled automatically by self-elevation)

### Usage
1. Run:

```powershell
.\Optimize-VHDsUI.ps1
```

2. Accept UAC elevation.
3. Optional: Enter remote computer and credentials, then click `Connect`.
4. Click `List VMs`.
5. Select one or more VMs.
6. Click `Optimize Selected`.

### Buttons
| Button | Action |
|---|---|
| Connect | Connect to local or remote host and load VM list |
| Credentials | Capture alternate credentials for remote host access |
| List VMs | Reload eligible VMs from current target host |
| Select All VMs | Select all listed VMs |
| Optimize Selected | Run optimization for selected VMs |
| Close | Close the form |

### Logging
Location: `%TEMP%\Optimize-VHDsUI\Optimize-VHDsUI_yyyy-MM-dd_HH-mm-ss.log`  
Format: `[yyyy-MM-dd HH:mm:ss.fff] message`

Logs include startup, connection attempts, selected VMs, streamed worker output, and final summary.

### Behavior notes
- Output buffer is cleared at the start of each run.
- Progress bar resets to `0` at run start and goes to `100` on completion.
- Settings are persisted in `%LOCALAPPDATA%\DeploymentBunny\Optimize-VHDsUI.settings.json`.

