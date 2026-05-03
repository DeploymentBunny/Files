<#
.SYNOPSIS
    GUI launcher for saving and resuming Hyper-V VMs on local or remote hosts.

.DESCRIPTION
    Invoke-TSxVMSaveResumeUI provides a Windows Forms interface that:
    - Starts without elevation.
    - Shows an "Elevate (Admin)" button when running as a standard user.
      Clicking the button relaunches the UI as Administrator via UAC.
    - Runs Save-TSxAllRunningVMs.ps1 or Resume-TSxAllRunningVMs.ps1 asynchronously
      and streams their output into a live output pane.
    - Supports local and remote execution via PowerShell remoting.
    - Supports selecting alternate credentials for remote execution.
    - Shows a clear warning when a target host cannot be reached instead of
      reporting false "no VMs found" results.
    - Provides a "Show Running VMs" button to query live VM state on the target.
    - Provides a "Show VMs in List" button to display the contents of the
      saved-VM list file for the current target without running a full operation.
    - Maintains a dropdown of known saved-host list files with a Refresh button.
    - Stores host-specific SavedVMs_<host>.txt list files in %TEMP%.
    - Supports a Verbose toggle to show or hide verbose messages.
    - Persists settings to %LOCALAPPDATA%\DeploymentBunny.
    - Writes a per-run log file in %TEMP%.

.EXAMPLE
    .\Invoke-TSxVMSaveResumeUI.ps1

.NOTES
    FileName:    Invoke-TSxVMSaveResumeUI.ps1
    Author:      Mikael Nystrom
    Contact:     deploymentbunny@outlook.com
    Created:     2026-04-23
    Updated:     2026-04-28
    Web:         https://www.deploymentbunny.com
    Twitter:     @mikael_nystrom

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author.
.LINK
    https://www.deploymentbunny.com
.FUNCTIONALITY
    Windows Forms UI wrapper that launches Save-TSxAllRunningVMs.ps1 or
    Resume-TSxAllRunningVMs.ps1 via a background PowerShell runspace and polls
    output every 400 ms via a WinForms Timer. Starts directly in the UI without
    prompting at startup. If running as a standard user an "Elevate (Admin)"
    button is shown and relaunches the script elevated via Start-Process -Verb
    RunAs. Local or remote operations can be attempted without elevation first
    and may require elevation depending on Hyper-V permissions. Supports target
    server selection from a text box or a saved-hosts dropdown, optional
    alternate credentials, verbose output toggle, persisted settings, and
    graceful cleanup on close. Host-specific list files are stored in %TEMP%.
#>

try { $Host.UI.RawUI.WindowTitle = $myInvocation.MyCommand.Definition } catch { }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Font1        = [System.Drawing.Font]::new("Arial", 10, [System.Drawing.FontStyle]::Bold)
$FontHeading1 = [System.Drawing.Font]::new("Arial", 11, [System.Drawing.FontStyle]::Bold)
$FontHeading2 = [System.Drawing.Font]::new("Arial", 14, [System.Drawing.FontStyle]::Bold)
$FontData     = [System.Drawing.Font]::new("Courier New", 10)

$DLL = '[DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);'
Add-Type -MemberDefinition $DLL -name NativeMethods -namespace Win32

$Script:ToolName          = "Invoke-TSxVMSaveResumeUI"
$Script:SaveScriptPath    = Join-Path $PSScriptRoot "Save-TSxAllRunningVMs.ps1"
$Script:ResumeScriptPath  = Join-Path $PSScriptRoot "Resume-TSxAllRunningVMs.ps1"
$Script:ListFolder        = $env:TEMP
$Script:LogFile           = Join-Path $env:TEMP ("{0}_{1}.log" -f $Script:ToolName, (Get-Date -Format "yyyyMMdd_HHmmss"))
$Script:RunUser           = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$Script:SettingsDirectory = Join-Path $env:LOCALAPPDATA "DeploymentBunny"
$Script:SettingsFile      = Join-Path $Script:SettingsDirectory "Invoke-TSxVMSaveResumeUI.settings.json"
$Script:Runner            = $null
$Script:RunnerHandle      = $null
$Script:RunnerOutput      = $null
$Script:OutputIndex       = 0
$Script:IsRunning         = $false
$Script:IsAdmin           = [bool](([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
$Script:SelectedCredential = $null

function Write-TSxLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $Script:LogFile -Value ("[{0}] [User: {1}] {2}" -f $timestamp, $Script:RunUser, $Message)
}

function Add-OutputLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )
    $TextOutput.AppendText($Text + [Environment]::NewLine)
}

function Convert-OutputItemToText {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject
    )
    if ($null -eq $InputObject) { return $null }
    $text = ($InputObject | Out-String -Width 240).TrimEnd()
    if ([string]::IsNullOrWhiteSpace($text)) { return ([string]$InputObject) }
    return $text
}

function Invoke-OutputItem {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Item
    )
    if ($Item -is [System.Management.Automation.WarningRecord]) {
        Add-OutputLine -Text ("WARNING: {0}" -f $Item.Message)
        return
    }
    if ($Item -is [System.Management.Automation.ErrorRecord]) {
        Add-OutputLine -Text ("ERROR: {0}" -f $Item.Exception.Message)
        return
    }
    if ($Item -is [System.Management.Automation.VerboseRecord]) {
        Add-OutputLine -Text ("VERBOSE: {0}" -f $Item.Message)
        return
    }
    if ($null -ne $Item) {
        $outputText = Convert-OutputItemToText -InputObject $Item
        if (-not [string]::IsNullOrWhiteSpace($outputText)) {
            Add-OutputLine -Text $outputText
        }
    }
}

function Show-TSxDialog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information,
        [System.Windows.Forms.Form]$Owner = $null
    )
    [void][System.Windows.Forms.MessageBox]::Show($Owner, $Message, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, $Icon)
}

function Save-UISettings {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$ShowVerbose
    )
    try {
        if (-not (Test-Path -LiteralPath $Script:SettingsDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $Script:SettingsDirectory -Force | Out-Null
        }
        $settings = [PSCustomObject]@{ ShowVerbose = $ShowVerbose }
        $settings | ConvertTo-Json -Depth 3 | Out-File -LiteralPath $Script:SettingsFile -Encoding UTF8
        Write-TSxLog -Message ("Settings saved: {0}" -f $Script:SettingsFile)
    }
    catch {
        Write-TSxLog -Message ("Failed to save settings. Error: {0}" -f $_.Exception.Message)
    }
}

function Import-UISettings {
    if (-not (Test-Path -LiteralPath $Script:SettingsFile -PathType Leaf)) { return $null }
    try {
        $settings = Get-Content -LiteralPath $Script:SettingsFile -Raw | ConvertFrom-Json
        Write-TSxLog -Message ("Settings loaded: {0}" -f $Script:SettingsFile)
        return $settings
    }
    catch {
        Write-TSxLog -Message ("Failed to load settings. Error: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Start-ScriptAsync {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        [Parameter(Mandatory = $true)]
        [string]$OperationName,
        [Parameter(Mandatory = $true)]
        [bool]$ShowVerbose,
        [Parameter(Mandatory = $true)]
        [string]$TargetServer,
        [System.Management.Automation.PSCredential]$CredentialObject = $null
    )

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        Show-TSxDialog -Message ("Could not find script at: {0}" -f $ScriptPath) -Title $Script:ToolName -Icon Error -Owner $Form
        Write-TSxLog -Message ("Script not found: {0}" -f $ScriptPath)
        return
    }

    if ([string]::IsNullOrWhiteSpace($TargetServer)) {
        Show-TSxDialog -Message "Please enter a target server name." -Title $Script:ToolName -Icon Warning -Owner $Form
        return
    }

    $ButtonSave.Enabled   = $false
    $ButtonResume.Enabled = $false
    $ButtonCredential.Enabled = $false
    $ComboSavedHosts.Enabled = $false
    $ButtonRefreshHosts.Enabled = $false
    $TextServer.ReadOnly = $true
    $Form.Cursor          = [System.Windows.Forms.Cursors]::WaitCursor
    $LabelStatus.Text     = ("{0} on {1}..." -f $OperationName, $TargetServer)
    $TextOutput.Clear()

    $credentialUser = if ($CredentialObject) { $CredentialObject.UserName } else { "Current user" }

    Add-OutputLine -Text ("[{0}] Starting {1} on {2} (ShowVerbose={3}, Credential={4})" -f (Get-Date -Format "HH:mm:ss"), $OperationName, $TargetServer, $ShowVerbose, $credentialUser)
    Write-TSxLog -Message ("Run started: {0}. Target={1}; ShowVerbose={2}; Credential={3}" -f $OperationName, $TargetServer, $ShowVerbose, $credentialUser)
    Save-UISettings -ShowVerbose $ShowVerbose

    try {
        $Script:Runner       = [System.Management.Automation.PowerShell]::Create()
        $inputBuffer         = New-Object System.Management.Automation.PSDataCollection[psobject]
        $Script:RunnerOutput = New-Object System.Management.Automation.PSDataCollection[psobject]
        $Script:OutputIndex  = 0

        [void]$Script:Runner.AddScript({
            param($targetPath, $runVerbose, $targetServerName, $listFolderPath, [System.Management.Automation.PSCredential]$credentialObject)

            $invokeParams = @{
                ComputerName = $targetServerName
                ListFolder   = $listFolderPath
            }
            if ($credentialObject) {
                $invokeParams.Credential = $credentialObject
            }

            if ($runVerbose) { & $targetPath @invokeParams -Verbose *>&1 }
            else             { & $targetPath @invokeParams *>&1 }
        })
        [void]$Script:Runner.AddArgument($ScriptPath)
        [void]$Script:Runner.AddArgument($ShowVerbose)
        [void]$Script:Runner.AddArgument($TargetServer)
        [void]$Script:Runner.AddArgument($Script:ListFolder)
        [void]$Script:Runner.AddArgument($CredentialObject)

        $Script:RunnerHandle = $Script:Runner.BeginInvoke($inputBuffer, $Script:RunnerOutput)
        $Script:IsRunning    = $true
        $OutputTimer.Start()
        Add-OutputLine -Text ("[{0}] Running asynchronously. You can close the UI window at any time." -f (Get-Date -Format "HH:mm:ss"))
    }
    catch {
        $LabelStatus.Text = "Failed"
        Add-OutputLine -Text ("ERROR: {0}" -f $_.Exception.Message)
        Write-TSxLog -Message ("Run startup failed: {0}" -f $_.Exception.Message)
        Show-TSxDialog -Message ("Failed to start {0}. {1}`r`n`r`nLog: {2}" -f $OperationName, $_.Exception.Message, $Script:LogFile) -Title $Script:ToolName -Icon Error -Owner $Form
        $Form.Cursor          = [System.Windows.Forms.Cursors]::Default
        $ButtonSave.Enabled   = $true
        $ButtonResume.Enabled = $true
        $ButtonCredential.Enabled = $true
        $ComboSavedHosts.Enabled = $true
        $ButtonRefreshHosts.Enabled = $true
        $TextServer.ReadOnly = $false
        $Script:IsRunning     = $false
    }
}

function Set-TSxCredential {
    try {
        $selected = Get-Credential -Message "Select credentials for remote PowerShell (Cancel to keep current user)"
        if ($null -ne $selected) {
            $Script:SelectedCredential = $selected
            $LabelCredential.Text = ("Credential: {0}" -f $selected.UserName)
            Write-TSxLog -Message ("Credential selected: {0}" -f $selected.UserName)
        }
    }
    catch {
        Write-TSxLog -Message ("Credential selection failed: {0}" -f $_.Exception.Message)
        Show-TSxDialog -Message ("Failed to select credential.`r`n{0}" -f $_.Exception.Message) -Title $Script:ToolName -Icon Error -Owner $Form
    }
}

function Get-TSxHostsFromListFiles {
    $hosts = New-Object System.Collections.Generic.List[string]
    try {
        $files = Get-ChildItem -LiteralPath $Script:ListFolder -Filter 'SavedVMs_*.txt' -File -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            $hostName = $null
            try {
                $firstLine = Get-Content -LiteralPath $file.FullName -TotalCount 1 -ErrorAction SilentlyContinue
                if ($firstLine -match '^#\s*TargetComputer=(.+)$') {
                    $hostName = $matches[1].Trim()
                }
            }
            catch { }

            if ([string]::IsNullOrWhiteSpace($hostName)) {
                $hostName = ($file.BaseName -replace '^SavedVMs_', '').Trim()
            }

            if (-not [string]::IsNullOrWhiteSpace($hostName) -and -not $hosts.Contains($hostName)) {
                [void]$hosts.Add($hostName)
            }
        }
    }
    catch {
        Write-TSxLog -Message ("Failed to enumerate host list files: {0}" -f $_.Exception.Message)
    }
    return ($hosts | Sort-Object)
}

function Update-HostDropdown {
    if ($null -eq $ComboSavedHosts) { return }

    $currentTarget = $TextServer.Text.Trim()
    $hosts = Get-TSxHostsFromListFiles

    $ComboSavedHosts.BeginUpdate()
    try {
        $ComboSavedHosts.Items.Clear()
        foreach ($hostName in $hosts) {
            [void]$ComboSavedHosts.Items.Add($hostName)
        }
    }
    finally {
        $ComboSavedHosts.EndUpdate()
    }

    if (-not [string]::IsNullOrWhiteSpace($currentTarget)) {
        $index = $ComboSavedHosts.FindStringExact($currentTarget)
        if ($index -ge 0) {
            $ComboSavedHosts.SelectedIndex = $index
        }
    }
}

function Invoke-TSxUIElevate {
    Write-TSxLog -Message 'Elevate requested. Relaunching as administrator.'
    try {
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath) `
            -Verb RunAs
        $Form.Close()
    }
    catch {
        Write-TSxLog -Message ("Elevation failed: {0}" -f $_.Exception.Message)
        Show-TSxDialog -Message ("Failed to relaunch as administrator.`r`n{0}" -f $_.Exception.Message) -Title $Script:ToolName -Icon Error -Owner $Form
    }
}

Write-TSxLog -Message "UI started"

# Minimize the hosting PowerShell console
$consoleHandle = (Get-Process -Id $PID).MainWindowHandle
if ($consoleHandle -ne [IntPtr]::Zero) {
    [Win32.NativeMethods]::ShowWindowAsync($consoleHandle, 2)
}

# Generate logo
$PictureString = "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6H7o/ujz8cGn1E+f/gUDmPP8usTo0wAAAAlwSFlzAAAuIgAALiIBquLdkgAAR99pVFh0WE1MOmNvbS5hZG9iZS54bXAAAAAAADw/eHBhY2tldCBiZWdpbj0i77u/IiBpZD0iVzVNME1wQ2VoaUh6cmVTek5UY3prYzlkIj8+Cjx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IkFkb2JlIFhNUCBDb3JlIDUuNi1jMTM4IDc5LjE1OTgyNCwgMjAxNi8wOS8xNC0wMTowOTowMSAgICAgICAgIj4KICAgPHJkZjpSREYgeG1sbnM6cmRmPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5LzAyLzIyLXJkZi1zeW50YXgtbnMjIj4KICAgICAgPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIKICAgICAgICAgICAgeG1sbnM6eG1wPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvIgogICAgICAgICAgICB4bWxuczp4bXBUUGc9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC90L3BnLyIKICAgICAgICAgICAgeG1sbnM6c3REaW09Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9zVHlwZS9EaW1lbnNpb25zIyIKICAgICAgICAgICAgeG1sbnM6eG1wRz0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL2cvIgogICAgICAgICAgICB4bWxuczppbGx1c3RyYXRvcj0iaHR0cDovL25zLmFkb2JlLmNvbS9pbGx1c3RyYXRvci8xLjAvIgogICAgICAgICAgICB4bWxuczpkYz0iaHR0cDovL3B1cmwub3JnL2RjL2VsZW1lbnRzLzEuMS8iCiAgICAgICAgICAgIHhtbG5zOnhtcE1NPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvbW0vIgogICAgICAgICAgICB4bWxuczpzdEV2dD0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL3NUeXBlL1Jlc291cmNlRXZlbnQjIgogICAgICAgICAgICB4bWxuczpzdFJlZj0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL3NUeXBlL1Jlc291cmNlUmVmIyIKICAgICAgICAgICAgeG1sbnM6cGRmeD0iaHR0cDovL25zLmFkb2JlLmNvbS9wZGZ4LzEuMy8iCiAgICAgICAgICAgIHhtbG5zOnBkZj0iaHR0cDovL25zLmFkb2JlLmNvbS9wZGYvMS4zLyIKICAgICAgICAgICAgeG1sbnM6cGhvdG9zaG9wPSJodHRwOi8vbnMuYWRvYmUuY29tL3Bob3Rvc2hvcC8xLjAvIgogICAgICAgICAgICB4bWxuczp0aWZmPSJodHRwOi8vbnMuYWRvYmUuY29tL3RpZmYvMS4wLyIKICAgICAgICAgICAgeG1sbnM6ZXhpZj0iaHR0cDovL25zLmFkb2JlLmNvbS9leGlmLzEuMC8iPgogICAgICAgICA8eG1wOkNyZWF0b3JUb29sPkFkb2JlIFBob3Rvc2hvcCBDQyAyMDE3IChXaW5kb3dzKTwveG1wOkNyZWF0b3JUb29sPgogICAgICAgICA8eG1wOkNyZWF0ZURhdGU+MjAxNy0wMS0yNVQxMjo1ODoyMi0wNTowMDwveG1wOkNyZWF0ZURhdGU+CiAgICAgICAgIDx4bXA6TW9kaWZ5RGF0ZT4yMDE3LTAxLTI2VDIyOjAzOjE4KzAxOjAwPC94bXA6TW9kaWZ5RGF0ZT4KICAgICAgICAgPHhtcDpNZXRhZGF0YURhdGU+MjAxNy0wMS0yNlQyMjowMzoxOCswMTowMDwveG1wOk1ldGFkYXRhRGF0ZT4KICAgICAgICAgPHhtcFRQZzpOUGFnZXM+MTwveG1wVFBnOk5QYWdlcz4KICAgICAgICAgPHhtcFRQZzpIYXNWaXNpYmxlVHJhbnNwYXJlbmN5PkZhbHNlPC94bXBUUGc6SGFzVmlzaWJsZVRyYW5zcGFyZW5jeT4KICAgICAgICAgPHhtcFRQZzpIYXNWaXNpYmxlT3ZlcnByaW50PkZhbHNlPC94bXBUUGc6SGFzVmlzaWJsZU92ZXJwcmludD4KICAgICAgICAgPHhtcFRQZzpNYXhQYWdlU2l6ZSByZGY6cGFyc2VUeXBlPSJSZXNvdXJjZSI+CiAgICAgICAgICAgIDxzdERpbTp3PjE1MDAuMDAwMDAwPC9zdERpbTp3PgogICAgICAgICAgICA8c3REaW06aD4xMDAwLjAwMDAwMDwvc3REaW06aD4KICAgICAgICAgICAgPHN0RGltOnVuaXQ+UG9pbnRzPC9zdERpbTp1bml0PgogICAgICAgICA8L3htcFRQZzpNYXhQYWdlU2l6ZT4KICAgICAgICAgPHhtcFRQZzpQbGF0ZU5hbWVzPgogICAgICAgICAgICA8cmRmOlNlcT4KICAgICAgICAgICAgICAgPHJkZjpsaT5DeWFuPC9yZGY6bGk+CiAgICAgICAgICAgICAgIDxyZGY6bGk+TWFnZW50YTwvcmRmOmxpPgogICAgICAgICAgICAgICA8cmRmOmxpPlllbGxvdzwvcmRmOmxpPgogICAgICAgICAgICAgICA8cmRmOmxpPkJsYWNrPC9yZGY6bGk+CiAgICAgICAgICAgIDwvcmRmOlNlcT4KICAgICAgICAgPC94bXBUUGc6UGxhdGVOYW1lcz4KICAgICAgICAgPHhtcFRQZzpTd2F0Y2hHcm91cHM+CiAgICAgICAgICAgIDxyZGY6U2VxPgogICAgICAgICAgICAgICA8cmRmOmxpIHJkZjpwYXJzZVR5cGU9IlJlc291cmNlIj4KICAgICAgICAgICAgICAgICAgPHhtcEc6Z3JvdXBOYW1lPkRlZmF1bHQgU3dhdGNoIEdyb3VwPC94bXBHOmdyb3VwTmFtZT4KICAgICAgICAgICAgICAgICAgPHhtcEc6Z3JvdXBUeXBlPjA8L3htcEc6Z3JvdXBUeXBlPgogICAgICAgICAgICAgICA8L3JkZjpsaT4KICAgICAgICAgICAgPC9yZGY6U2VxPgogICAgICAgICA8L3htcFRQZzpTd2F0Y2hHcm91cHM+CiAgICAgICAgIDxpbGx1c3RyYXRvcjpUeXBlPkRvY3VtZW50PC9pbGx1c3RyYXRvcjpUeXBlPgogICAgICAgICA8ZGM6Zm9ybWF0PmltYWdlL3BuZzwvZGM6Zm9ybWF0PgogICAgICAgICA8ZGM6dGl0bGU+CiAgICAgICAgICAgIDxyZGY6QWx0PgogICAgICAgICAgICAgICA8cmRmOmxpIHhtbDpsYW5nPSJ4LWRlZmF1bHQiPjExMXNodXR0ZXJzdG9ja18xODM0Mzg2MzggW0NvbnZlcnRlZF08L3JkZjpsaT4KICAgICAgICAgICAgPC9yZGY6QWx0PgogICAgICAgICA8L2RjOnRpdGxlPgogICAgICAgICA8eG1wTU06UmVuZGl0aW9uQ2xhc3M+cHJvb2Y6cGRmPC94bXBNTTpSZW5kaXRpb25DbGFzcz4KICAgICAgICAgPHhtcE1NOkRvY3VtZW50SUQ+YWRvYmU6ZG9jaWQ6cGhvdG9zaG9wOmQzMWQyZDc4LWU0MGEtMTFlNi04MzZkLWQwOTVmOWIwYjZjNzwveG1wTU06RG9jdW1lbnRJRD4KICAgICAgICAgPHhtcE1NOkluc3RhbmNlSUQ+eG1wLmlpZDplM2FjNTkyZi03MGExLWM3NGMtOWZkYy0zN2I2YzdmMDAwZTI8L3htcE1NOkluc3RhbmNlSUQ+CiAgICAgICAgIDx4bXBNTTpIaXN0b3J5PgogICAgICAgICAgICA8cmRmOlNlcT4KICAgICAgICAgICAgICAgPHJkZjpsaSByZGY6cGFyc2VUeXBlPSJSZXNvdXJjZSI+CiAgICAgICAgICAgICAgICAgIDxzdEV2dDphY3Rpb24+Y29udmVydGVkPC9zdEV2dDphY3Rpb24+CiAgICAgICAgICAgICAgICAgIDxzdEV2dDpwYXJhbWV0ZXJzPmZyb20gYXBwbGljYXRpb24vcGRmIHRvIGFwcGxpY2F0aW9uL3ZuZC5hZG9iZS5waG90b3Nob3A8L3N0RXZ0OnBhcmFtZXRlcnM+CiAgICAgICAgICAgICAgIDwvcmRmOmxpPgogICAgICAgICAgICAgICA8cmRmOmxpIHJkZjpwYXJzZVR5cGU9IlJlc291cmNlIj4KICAgICAgICAgICAgICAgICAgPHN0RXZ0OmFjdGlvbj5zYXZlZDwvc3RFdnQ6YWN0aW9uPgogICAgICAgICAgICAgICAgICA8c3RFdnQ6aW5zdGFuY2VJRD54bXAuaWlkOjgwMGJhMjUyLWNhNWQtNjA0NC1hMDE0LWJmYWE2MjdiNzQyODwvc3RFdnQ6aW5zdGFuY2VJRD4KICAgICAgICAgICAgICAgICAgPHN0RXZ0OndoZW4+MjAxNy0wMS0yNVQxNTowNzoyNi0wNjowMDwvc3RFdnQ6d2hlbj4KICAgICAgICAgICAgICAgICAgPHN0RXZ0OnNvZnR3YXJlQWdlbnQ+QWRvYmUgUGhvdG9zaG9wIENDIDIwMTcgKFdpbmRvd3MpPC9zdEV2dDpzb2Z0d2FyZUFnZW50PgogICAgICAgICAgICAgICAgICA8c3RFdnQ6Y2hhbmdlZD4vPC9zdEV2dDpjaGFuZ2VkPgogICAgICAgICAgICAgICA8L3JkZjpsaT4KICAgICAgICAgICAgICAgPHJkZjpsaSByZGY6cGFyc2VUeXBlPSJSZXNvdXJjZSI+CiAgICAgICAgICAgICAgICAgIDxzdEV2dDphY3Rpb24+c2F2ZWQ8L3N0RXZ0OmFjdGlvbj4KICAgICAgICAgICAgICAgICAgPHN0RXZ0Omluc3RhbmNlSUQ+eG1wLmlpZDoxZjBhZTFlNS0xY2JhLTkyNDctODE4Yi04ZTI2YzJjMDc1MmY8L3N0RXZ0Omluc3RhbmNlSUQ+CiAgICAgICAgICAgICAgICAgIDxzdEV2dDp3aGVuPjIwMTctMDEtMjZUMjI6MDM6MTgrMDE6MDA8L3N0RXZ0OndoZW4+CiAgICAgICAgICAgICAgICAgIDxzdEV2dDpzb2Z0d2FyZUFnZW50PkFkb2JlIFBob3Rvc2hvcCBDQyAyMDE3IChXaW5kb3dzKTwvc3RFdnQ6c29mdHdhcmVBZ2VudD4KICAgICAgICAgICAgICAgICAgPHN0RXZ0OmNoYW5nZWQ+Lzwvc3RFdnQ6Y2hhbmdlZD4KICAgICAgICAgICAgICAgPC9yZGY6bGk+CiAgICAgICAgICAgICAgIDxyZGY6bGkgcmRmOnBhcnNlVHlwZT0iUmVzb3VyY2UiPgogICAgICAgICAgICAgICAgICA8c3RFdnQ6YWN0aW9uPmNvbnZlcnRlZDwvc3RFdnQ6YWN0aW9uPgogICAgICAgICAgICAgICAgICA8c3RFdnQ6cGFyYW1ldGVycz5mcm9tIGFwcGxpY2F0aW9uL3ZuZC5hZG9iZS5waG90b3Nob3AgdG8gaW1hZ2UvcG5nPC9zdEV2dDpwYXJhbWV0ZXJzPgogICAgICAgICAgICAgICA8L3JkZjpsaT4KICAgICAgICAgICAgICAgPHJkZjpsaSByZGY6cGFyc2VUeXBlPSJSZXNvdXJjZSI+CiAgICAgICAgICAgICAgICAgIDxzdEV2dDphY3Rpb24+ZGVyaXZlZDwvc3RFdnQ6YWN0aW9uPgogICAgICAgICAgICAgICAgICA8c3RFdnQ6cGFyYW1ldGVycz5jb252ZXJ0ZWQgZnJvbSBhcHBsaWNhdGlvbi92bmQuYWRvYmUucGhvdG9zaG9wIHRvIGltYWdlL3BuZzwvc3RFdnQ6cGFyYW1ldGVycz4KICAgICAgICAgICAgICAgPC9yZGY6bGk+CiAgICAgICAgICAgICAgIDxyZGY6bGkgcmRmOnBhcnNlVHlwZT0iUmVzb3VyY2UiPgogICAgICAgICAgICAgICAgICA8c3RFdnQ6YWN0aW9uPnNhdmVkPC9zdEV2dDphY3Rpb24+CiAgICAgICAgICAgICAgICAgIDxzdEV2dDppbnN0YW5jZUlEPnhtcC5paWQ6ZTNhYzU5MmYtNzBhMS1jNzRjLTlmZGMtMzdiNmM3ZjAwMGUyPC9zdEV2dDppbnN0YW5jZUlEPgogICAgICAgICAgICAgICAgICA8c3RFdnQ6d2hlbj4yMDE3LTAxLTI2VDIyOjAzOjE4KzAxOjAwPC9zdEV2dDp3aGVuPgogICAgICAgICAgICAgICAgICA8c3RFdnQ6c29mdHdhcmVBZ2VudD5BZG9iZSBQaG90b3Nob3AgQ0MgMjAxNyAoV2luZG93cyk8L3N0RXZ0OnNvZnR3YXJlQWdlbnQ+CiAgICAgICAgICAgICAgICAgIDxzdEV2dDpjaGFuZ2VkPi88L3N0RXZ0OmNoYW5nZWQ+CiAgICAgICAgICAgICAgIDwvcmRmOmxpPgogICAgICAgICAgICA8L3JkZjpTZXE+CiAgICAgICAgIDwveG1wTU06SGlzdG9yeT4KICAgICAgICAgPHhtcE1NOk9yaWdpbmFsRG9jdW1lbnRJRD51dWlkOmRlYTRiN2ZiLTIwMmEtNDk2MS04ZTE3LWYzMDlhNzJlZThiMjwveG1wTU06T3JpZ2luYWxEb2N1bWVudElEPgogICAgICAgICA8eG1wTU06RGVyaXZlZEZyb20gcmRmOnBhcnNlVHlwZT0iUmVzb3VyY2UiPgogICAgICAgICAgICA8c3RSZWY6aW5zdGFuY2VJRD54bXAuaWlkOjFmMGFlMWU1LTFjYmEtOTI0Ny04MThiLThlMjZjMmMwNzUyZjwvc3RSZWY6aW5zdGFuY2VJRD4KICAgICAgICAgICAgPHN0UmVmOmRvY3VtZW50SUQ+YWRvYmU6ZG9jaWQ6cGhvdG9zaG9wOjQwYWFlMTY1LWU0MDgtMTFlNi1hYTY3LTg3YTU5Njc3OTFjYTwvc3RSZWY6ZG9jdW1lbnRJRD4KICAgICAgICAgICAgPHN0UmVmOm9yaWdpbmFsRG9jdW1lbnRJRD51dWlkOmRlYTRiN2ZiLTIwMmEtNDk2MS04ZTE3LWYzMDlhNzJlZThiMjwvc3RSZWY6b3JpZ2luYWxEb2N1bWVudElEPgogICAgICAgICAgICA8c3RSZWY6cmVuZGl0aW9uQ2xhc3M+cHJvb2Y6cGRmPC9zdFJlZjpyZW5kaXRpb25DbGFzcz4KICAgICAgICAgPC94bXBNTTpEZXJpdmVkRnJvbT4KICAgICAgICAgPHBkZng6Q3JlYXRvclZlcnNpb24+MjEuMC4xPC9wZGZ4OkNyZWF0b3JWZXJzaW9uPgogICAgICAgICA8cGRmOlByb2R1Y2VyPkFkb2JlIFBERiBsaWJyYXJ5IDE1LjAwPC9wZGY6UHJvZHVjZXI+CiAgICAgICAgIDxwaG90b3Nob3A6Q29sb3JNb2RlPjM8L3Bob3Rvc2hvcDpDb2xvck1vZGU+CiAgICAgICAgIDxwaG90b3Nob3A6SUNDUHJvZmlsZT5zUkdCIElFQzYxOTY2LTIuMTwvcGhvdG9zaG9wOklDQ1Byb2ZpbGU+CiAgICAgICAgIDx0aWZmOk9yaWVudGF0aW9uPjE8L3RpZmY6T3JpZW50YXRpb24+CiAgICAgICAgIDx0aWZmOlhSZXNvbHV0aW9uPjMwMDAwMDAvMTAwMDA8L3RpZmY6WFJlc29sdXRpb24+CiAgICAgICAgIDx0aWZmOllSZXNvbHV0aW9uPjMwMDAwMDAvMTAwMDA8L3RpZmY6WVJlc29sdXRpb24+CiAgICAgICAgIDx0aWZmOlJlc29sdXRpb25Vbml0PjI8L3RpZmY6UmVzb2x1dGlvblVuaXQ+CiAgICAgICAgIDxleGlmOkNvbG9yU3BhY2U+MTwvZXhpZjpDb2xvclNwYWNlPgogICAgICAgICA8ZXhpZjpQaXhlbFhEaW1lbnNpb24+MTc1PC9leGlmOlBpeGVsWERpbWVuc2lvbj4KICAgICAgICAgPGV4aWY6UGl4ZWxZRGltZW5zaW9uPjEzMDwvZXhpZjpQaXhlbFlEaW1lbnNpb24+CiAgICAgIDwvcmRmOkRlc2NyaXB0aW9uPgogICA8L3JkZjpSREY+CjwveDp4bXBtZXRhPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgIAo8P3hwYWNrZXQgZW5kPSJ3Ij8+6deWSwAAOLBJREFUeF7dvQecFTX3Pv5sr2yh92ql9yJSBCkiRbEjTSk2iq8o0hQQpKmI8lpogoAdURRBBRHpSFMsCEjvZXvvv/NkNmx2du7duwt+ff//Zz+zSU7OZDLJyck5mcxcL19f3xy4gZeXV27MPdzxucpzol9LWmFpwlMa4YquUVj+tUJOjusuc5XnRPeEptPXRFDc8RSl0a8lrbA04QkPUVS6CU94XMFVp5twx+OJIBB2mlParaBci4Zwynd1jp3u6bmFnXetytVwRSfc5V0LOHU04YpOOOU5CYMJe/ofFRRPGprxlJSU3JQFb29vBAYG5qby4FSenXa1acKJRhSF1w5P+QhXnc4ysrKyEBMTk0uxULJkSZWnz3M63xOau7RLQfHkxtzxuMqz01NTU1GmTFk88shAJRwbN27Epk2bVB7TPj4+qsJO5dlp1zqt4UR3xUu4yysuOHguXryo4g0bNkS3bt0QEhKCL774Ert370J4eDj8/PyQnZ2teIjiCAdh0nT8/1RQ7DQKSb369fHLvl+kIfLyDh48hEGDBmHr1i0qHRoaWuCG7GVd6zThCQ/him6HJ3z2+6SAZGRk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"
$imageBytes  = [Convert]::FromBase64String($PictureString)
$imageStream = New-Object System.IO.MemoryStream(,$imageBytes)
$LogoImage   = [System.Drawing.Image]::FromStream($imageStream)

# --- Form ---
$Form = New-Object System.Windows.Forms.Form
$Form.Text          = "Invoke-TSxVMSaveResumeUI"
$Form.StartPosition = "CenterScreen"
$Form.Size          = New-Object System.Drawing.Size(1024, 700)
$Form.MinimumSize   = New-Object System.Drawing.Size(900, 580)
$Form.BackColor     = [System.Drawing.Color]::White

$LabelTitle          = New-Object System.Windows.Forms.Label
$LabelTitle.Location = New-Object System.Drawing.Point(16, 12)
$LabelTitle.Size     = New-Object System.Drawing.Size(750, 24)
$LabelTitle.Text     = "Save and Resume Hyper-V Virtual Machines"
$LabelTitle.Font     = $FontHeading2
$LabelTitle.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($LabelTitle)

$PictureBox          = New-Object System.Windows.Forms.PictureBox
$PictureBox.Location = New-Object System.Drawing.Point(842, 4)
$PictureBox.Size     = New-Object System.Drawing.Size(150, 70)
$PictureBox.Image    = $LogoImage
$PictureBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
$PictureBox.BackColor = [System.Drawing.Color]::White
$PictureBox.Anchor   = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$Form.Controls.Add($PictureBox)

$ButtonSave          = New-Object System.Windows.Forms.Button
$ButtonSave.Location = New-Object System.Drawing.Point(16, 72)
$ButtonSave.Size     = New-Object System.Drawing.Size(170, 32)
$ButtonSave.Text     = "Save Running VMs"
$ButtonSave.Font     = $Font1
$ButtonSave.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#F35800")
$ButtonSave.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#1c1d1d")
$Form.Controls.Add($ButtonSave)

$ButtonResume          = New-Object System.Windows.Forms.Button
$ButtonResume.Location = New-Object System.Drawing.Point(196, 72)
$ButtonResume.Size     = New-Object System.Drawing.Size(170, 32)
$ButtonResume.Text     = "Resume VMs"
$ButtonResume.Font     = $Font1
$ButtonResume.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#F35800")
$ButtonResume.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#1c1d1d")
$Form.Controls.Add($ButtonResume)

$ButtonShowVMs          = New-Object System.Windows.Forms.Button
$ButtonShowVMs.Location = New-Object System.Drawing.Point(16, 112)
$ButtonShowVMs.Size     = New-Object System.Drawing.Size(170, 32)
$ButtonShowVMs.Text     = "Show Running VMs"
$ButtonShowVMs.Font     = $Font1
$ButtonShowVMs.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#F5B041")
$ButtonShowVMs.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#1c1d1d")
$Form.Controls.Add($ButtonShowVMs)

$ButtonShowList          = New-Object System.Windows.Forms.Button
$ButtonShowList.Location = New-Object System.Drawing.Point(196, 112)
$ButtonShowList.Size     = New-Object System.Drawing.Size(170, 32)
$ButtonShowList.Text     = "Show VMs in List"
$ButtonShowList.Font     = $Font1
$ButtonShowList.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#F5B041")
$ButtonShowList.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#1c1d1d")
$Form.Controls.Add($ButtonShowList)

$ButtonClose          = New-Object System.Windows.Forms.Button
$ButtonClose.Location = New-Object System.Drawing.Point(822, 616)
$ButtonClose.Size     = New-Object System.Drawing.Size(170, 32)
$ButtonClose.Text     = "Close"
$ButtonClose.Font     = $Font1
$ButtonClose.Anchor   = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$Form.Controls.Add($ButtonClose)

$ButtonElevate          = New-Object System.Windows.Forms.Button
$ButtonElevate.Location = New-Object System.Drawing.Point(16, 616)
$ButtonElevate.Size     = New-Object System.Drawing.Size(170, 32)
$ButtonElevate.Text     = "Elevate (Admin)"
$ButtonElevate.Font     = $Font1
$ButtonElevate.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#FFC107")
$ButtonElevate.ForeColor = [System.Drawing.Color]::Black
$ButtonElevate.Anchor    = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$ButtonElevate.Visible   = (-not $Script:IsAdmin)
$Form.Controls.Add($ButtonElevate)

$LabelServer          = New-Object System.Windows.Forms.Label
$LabelServer.Location = New-Object System.Drawing.Point(16, 155)
$LabelServer.Size     = New-Object System.Drawing.Size(100, 24)
$LabelServer.Text     = "Target server"
$LabelServer.Font     = $Font1
$LabelServer.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($LabelServer)

$TextServer          = New-Object System.Windows.Forms.TextBox
$TextServer.Location = New-Object System.Drawing.Point(120, 152)
$TextServer.Size     = New-Object System.Drawing.Size(220, 24)
$TextServer.Text     = $env:COMPUTERNAME
$TextServer.Font     = $Font1
$Form.Controls.Add($TextServer)

$LabelSavedHosts          = New-Object System.Windows.Forms.Label
$LabelSavedHosts.Location = New-Object System.Drawing.Point(16, 185)
$LabelSavedHosts.Size     = New-Object System.Drawing.Size(100, 24)
$LabelSavedHosts.Text     = "Saved hosts"
$LabelSavedHosts.Font     = $Font1
$LabelSavedHosts.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($LabelSavedHosts)

$ComboSavedHosts          = New-Object System.Windows.Forms.ComboBox
$ComboSavedHosts.Location = New-Object System.Drawing.Point(120, 182)
$ComboSavedHosts.Size     = New-Object System.Drawing.Size(220, 24)
$ComboSavedHosts.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$ComboSavedHosts.Font     = $Font1
$Form.Controls.Add($ComboSavedHosts)

$ButtonRefreshHosts          = New-Object System.Windows.Forms.Button
$ButtonRefreshHosts.Location = New-Object System.Drawing.Point(348, 180)
$ButtonRefreshHosts.Size     = New-Object System.Drawing.Size(170, 32)
$ButtonRefreshHosts.Text     = "Refresh Hosts"
$ButtonRefreshHosts.Font     = $Font1
$Form.Controls.Add($ButtonRefreshHosts)

$ButtonCredential          = New-Object System.Windows.Forms.Button
$ButtonCredential.Location = New-Object System.Drawing.Point(348, 150)
$ButtonCredential.Size     = New-Object System.Drawing.Size(170, 32)
$ButtonCredential.Text     = "Credential"
$ButtonCredential.Font     = $Font1
$Form.Controls.Add($ButtonCredential)

$LabelCredential          = New-Object System.Windows.Forms.Label
$LabelCredential.Location = New-Object System.Drawing.Point(530, 155)
$LabelCredential.Size     = New-Object System.Drawing.Size(450, 22)
$LabelCredential.Text     = "Credential: Current user"
$LabelCredential.Font     = $Font1
$LabelCredential.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($LabelCredential)

$CheckboxVerbose          = New-Object System.Windows.Forms.CheckBox
$CheckboxVerbose.Location = New-Object System.Drawing.Point(370, 75)
$CheckboxVerbose.Size     = New-Object System.Drawing.Size(140, 24)
$CheckboxVerbose.Text     = "Show Verbose"
$CheckboxVerbose.Checked  = $false
$CheckboxVerbose.Font     = $Font1
$CheckboxVerbose.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($CheckboxVerbose)

$LabelStatus          = New-Object System.Windows.Forms.Label
$LabelStatus.Location = New-Object System.Drawing.Point(530, 79)
$LabelStatus.Size     = New-Object System.Drawing.Size(185, 20)
$LabelStatus.Text     = "Ready"
$LabelStatus.Font     = $FontHeading1
$LabelStatus.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($LabelStatus)

$TextOutput          = New-Object System.Windows.Forms.TextBox
$TextOutput.Location = New-Object System.Drawing.Point(16, 218)
$TextOutput.Size     = New-Object System.Drawing.Size(912, 380)
$TextOutput.Multiline   = $true
$TextOutput.ScrollBars  = "Both"
$TextOutput.ReadOnly    = $true
$TextOutput.WordWrap    = $false
$TextOutput.Font        = $FontData
$TextOutput.BackColor   = [System.Drawing.Color]::White
$Form.Controls.Add($TextOutput)

# --- Timer ---
$OutputTimer          = New-Object System.Windows.Forms.Timer
$OutputTimer.Interval = 400
$OutputTimer.Add_Tick({
    if (-not $Script:IsRunning) {
        $OutputTimer.Stop()
        return
    }

    while ($Script:OutputIndex -lt $Script:RunnerOutput.Count) {
        Invoke-OutputItem -Item $Script:RunnerOutput[$Script:OutputIndex]
        $Script:OutputIndex++
    }

    if ($Script:RunnerHandle.IsCompleted) {
        try {
            $null = $Script:Runner.EndInvoke($Script:RunnerHandle)
            $LabelStatus.Text = "Completed"
            Add-OutputLine -Text ("[{0}] Completed" -f (Get-Date -Format "HH:mm:ss"))
            Write-TSxLog -Message "Run completed"
        }
        catch {
            $LabelStatus.Text = "Failed"
            Add-OutputLine -Text ("ERROR: {0}" -f $_.Exception.Message)
            Write-TSxLog -Message ("Run failed: {0}" -f $_.Exception.Message)
            Show-TSxDialog -Message ("Operation failed. {0}`r`n`r`nLog: {1}" -f $_.Exception.Message, $Script:LogFile) -Title $Script:ToolName -Icon Error -Owner $Form
        }
        finally {
            if ($Script:Runner) { $Script:Runner.Dispose() }
            $Script:Runner       = $null
            $Script:RunnerHandle = $null
            $Script:RunnerOutput = $null
            $Script:OutputIndex  = 0
            $Script:IsRunning    = $false
            $Form.Cursor          = [System.Windows.Forms.Cursors]::Default
            $ButtonSave.Enabled   = $true
            $ButtonResume.Enabled = $true
            $ButtonCredential.Enabled = $true
            $ComboSavedHosts.Enabled = $true
            $ButtonRefreshHosts.Enabled = $true
            $TextServer.ReadOnly = $false
            Update-HostDropdown
            $OutputTimer.Stop()
        }
    }
})

# --- Settings ---
$settings = Import-UISettings
if ($null -ne $settings -and $settings.PSObject.Properties['ShowVerbose']) {
    $CheckboxVerbose.Checked = [bool]$settings.ShowVerbose
}

$CheckboxVerbose.Add_CheckedChanged({
    Save-UISettings -ShowVerbose $CheckboxVerbose.Checked
})

Update-HostDropdown
$ComboSavedHosts.Add_SelectedIndexChanged({
    if ($ComboSavedHosts.SelectedItem) {
        $TextServer.Text = $ComboSavedHosts.SelectedItem.ToString()
    }
})

# --- Button handlers ---
$ButtonClose.Add_Click({ $Form.Close() })
$ButtonElevate.Add_Click({ Invoke-TSxUIElevate })
$ButtonCredential.Add_Click({ Set-TSxCredential })
$ButtonRefreshHosts.Add_Click({ Update-HostDropdown })
$ButtonShowVMs.Add_Click({
    $target = $TextServer.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($target)) {
        Show-TSxDialog -Message "Please enter a target server name." -Title $Script:ToolName -Icon Warning -Owner $Form
        return
    }
    $TextOutput.Clear()
    $LabelStatus.Text = "Querying VMs..."
    Add-OutputLine -Text ("[{0}] Querying running VMs on {1}" -f (Get-Date -Format "HH:mm:ss"), $target)
    try {
        $getParams = @{ ComputerName = $target }
        if ($Script:SelectedCredential) { $getParams.Credential = $Script:SelectedCredential }
        $isLocal = ($target -eq $env:COMPUTERNAME -or $target -eq '.' -or $target -ieq 'localhost')
        if ($isLocal) {
            $vms = Get-VM | Where-Object { $_.State -eq 'Running' }
        } else {
            $vms = Invoke-Command @getParams -ErrorAction Stop -ScriptBlock { Get-VM | Where-Object { $_.State -eq 'Running' } }
        }
        if ($vms) {
            $vms | Sort-Object Name | ForEach-Object {
                Add-OutputLine -Text ("  {0,-40} State: {1}" -f $_.Name, $_.State)
            }
            Add-OutputLine -Text ("{0} running VM(s) found." -f @($vms).Count)
        } else {
            Add-OutputLine -Text "No running VMs found."
        }
        $LabelStatus.Text = "Done"
    }
    catch {
        $LabelStatus.Text = "Warning"
        Add-OutputLine -Text ("WARNING: Unable to connect to host '{0}'." -f $target)
        Write-TSxLog -Message ("Show Running VMs failed for '{0}': {1}" -f $target, $_.Exception.Message)
    }
})

$ButtonShowList.Add_Click({
    $target = $TextServer.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($target)) {
        Show-TSxDialog -Message "Please enter a target server name." -Title $Script:ToolName -Icon Warning -Owner $Form
        return
    }
    $listFile = Join-Path $Script:ListFolder ("SavedVMs_{0}.txt" -f $target)
    $TextOutput.Clear()
    Add-OutputLine -Text ("[{0}] Reading list file: {1}" -f (Get-Date -Format "HH:mm:ss"), $listFile)
    if (-not (Test-Path -LiteralPath $listFile -PathType Leaf)) {
        Add-OutputLine -Text "No list file found for this host. Run 'Save Running VMs' first."
        $LabelStatus.Text = "No list file"
        return
    }
    try {
        $lines = Get-Content -LiteralPath $listFile
        $vmNames = $lines | Where-Object { $_ -notmatch '^\s*#' -and -not [string]::IsNullOrWhiteSpace($_) }
        if ($vmNames) {
            foreach ($name in $vmNames) {
                Add-OutputLine -Text ("  {0}" -f $name)
            }
            Add-OutputLine -Text ("{0} VM(s) in list." -f @($vmNames).Count)
        } else {
            Add-OutputLine -Text "List file is empty."
        }
        $LabelStatus.Text = "Done"
    }
    catch {
        $LabelStatus.Text = "Failed"
        Add-OutputLine -Text ("ERROR: {0}" -f $_.Exception.Message)
        Write-TSxLog -Message ("Show VMs in List failed: {0}" -f $_.Exception.Message)
    }
})

$Form.Add_FormClosing({
    Save-UISettings -ShowVerbose $CheckboxVerbose.Checked
    if ($Script:IsRunning -and $Script:Runner) {
        try {
            $Script:Runner.Stop()
            $Script:Runner.Dispose()
        }
        catch {
            Write-TSxLog -Message ("Failed to stop running execution during form close: {0}" -f $_.Exception.Message)
        }
    }
})

$ButtonSave.Add_Click({
    Start-ScriptAsync -ScriptPath $Script:SaveScriptPath -OperationName "Save Running VMs" -ShowVerbose $CheckboxVerbose.Checked -TargetServer $TextServer.Text.Trim() -CredentialObject $Script:SelectedCredential
})

$ButtonResume.Add_Click({
    Start-ScriptAsync -ScriptPath $Script:ResumeScriptPath -OperationName "Resume VMs" -ShowVerbose $CheckboxVerbose.Checked -TargetServer $TextServer.Text.Trim() -CredentialObject $Script:SelectedCredential
})

[void]$Form.ShowDialog()
