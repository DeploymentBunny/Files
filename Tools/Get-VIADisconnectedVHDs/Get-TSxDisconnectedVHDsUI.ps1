<#
.SYNOPSIS
    GUI launcher for Get-TSxDisconnectedVHDs.ps1.

.DESCRIPTION
    Get-TSxDisconnectedVHDsUI provides a Windows Forms interface that:
    - Self-elevates to local Administrator.
    - Lets you browse and select the root folder to scan.
    - Searches for disconnected VHD/VHDX files by running Get-TSxDisconnectedVHDs.ps1.
    - Shows disconnected VHD/VHDX files in a multi-select result list.
    - Opens selected file locations in Explorer (Open Path).
    - Removes selected files with a confirmation warning.
    - Optionally shows verbose progress messages in an output box.
    - Persists last-used settings in %LOCALAPPDATA%\DeploymentBunny.
    - Writes a per-run log file in %TEMP%.

.NOTES
    Version:     0.0.0.1

    Author - Mikael Nystrom
    Twitter: @mikael_nystrom

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author.
.LINK
    https://www.deploymentbunny.com
.EXAMPLE
    .\Get-TSxDisconnectedVHDsUI.ps1
#>

# Get the ID and security principal of the current user account
$myWindowsID = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal($myWindowsID)

# Get the security principal for the Administrator role
$adminRole = [System.Security.Principal.WindowsBuiltInRole]::Administrator

# Check to see if we are currently running as Administrator
if ($myWindowsPrincipal.IsInRole($adminRole)) {
    $Host.UI.RawUI.WindowTitle = $myInvocation.MyCommand.Definition + " (Elevated)"
}
else {
    $newProcess = New-Object System.Diagnostics.ProcessStartInfo "PowerShell"
    $newProcess.Arguments = "-NoProfile -File `"$($myInvocation.MyCommand.Definition)`""
    $newProcess.Verb = "runas"

    [System.Diagnostics.Process]::Start($newProcess) | Out-Null
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Script:ToolName = "Get-TSxDisconnectedVHDsUI"
$Script:TargetScriptPath = Join-Path $PSScriptRoot "Get-TSxDisconnectedVHDs.ps1"
$Script:LogFile = Join-Path $env:TEMP ("{0}_{1}.log" -f $Script:ToolName, (Get-Date -Format "yyyyMMdd_HHmmss"))
$Script:RunUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$Script:SettingsDirectory = Join-Path $env:LOCALAPPDATA "DeploymentBunny"
$Script:SettingsFile = Join-Path $Script:SettingsDirectory "Get-TSxDisconnectedVHDsUI.settings.json"
$Script:LogoPath = Join-Path $env:TEMP "deploymentbunnylogo.png"

function Write-TSxLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $Script:LogFile -Value ("[{0}] [User: {1}] {2}" -f $timestamp, $Script:RunUser, $Message)
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

$removeVmUi2Path = Join-Path (Split-Path -Parent $PSScriptRoot) "RemoveVMwUI2\RemoveVMwUI2.ps1"
if (Test-Path -Path $removeVmUi2Path) {
    try {
        $removeVmUi2Content = Get-Content -Path $removeVmUi2Path -Raw -ErrorAction Stop
        if ($removeVmUi2Content -match '\$PictureString\s*=\s*"(?<base64>[A-Za-z0-9\+/=]+)"') {
            $imageBytes = [Convert]::FromBase64String($matches['base64'])
            [System.IO.File]::WriteAllBytes($Script:LogoPath, $imageBytes)
            Write-TSxLog -Message ("Logo generated from RemoveVMwUI2 payload: {0}" -f $Script:LogoPath)
        }
        else {
            Write-TSxLog -Message "Logo payload not found in RemoveVMwUI2.ps1"
        }
    }
    catch {
        Write-TSxLog -Message ("Failed to generate logo from RemoveVMwUI2 payload. Error: {0}" -f $_.Exception.Message)
    }
}
else {
    Write-TSxLog -Message ("RemoveVMwUI2 script not found at expected path: {0}" -f $removeVmUi2Path)
}

function Save-UISettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderPath,

        [Parameter(Mandatory = $true)]
        [bool]$ShowVerbose
    )

    try {
        if (-not (Test-Path -LiteralPath $Script:SettingsDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $Script:SettingsDirectory -Force | Out-Null
        }

        $settings = [PSCustomObject]@{
            FolderPath  = $FolderPath
            ShowVerbose = $ShowVerbose
        }

        $settings | ConvertTo-Json -Depth 3 | Out-File -LiteralPath $Script:SettingsFile -Encoding UTF8
        Write-TSxLog -Message ("Settings saved: {0}" -f $Script:SettingsFile)
    }
    catch {
        Write-TSxLog -Message ("Failed to save settings. Error: {0}" -f $_.Exception.Message)
    }
}

function Import-UISettings {
    if (-not (Test-Path -LiteralPath $Script:SettingsFile -PathType Leaf)) {
        return $null
    }

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

function Add-OutputLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $TextOutput.AppendText($Text + [Environment]::NewLine)
}

function Invoke-DisconnectedVhdScan {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Form]$Owner,

        [Parameter(Mandatory = $true)]
        [string]$FolderPath,

        [Parameter(Mandatory = $true)]
        [bool]$ShowVerbose
    )

    if (-not (Test-Path -LiteralPath $Script:TargetScriptPath -PathType Leaf)) {
        Show-TSxDialog -Message ("Could not find Get-TSxDisconnectedVHDs.ps1 at: {0}" -f $Script:TargetScriptPath) -Title $Script:ToolName -Icon Error -Owner $Owner
        return
    }

    if ([string]::IsNullOrWhiteSpace($FolderPath)) {
        Show-TSxDialog -Message "Folder is required." -Title $Script:ToolName -Icon Warning -Owner $Owner
        return
    }

    if (-not (Test-Path -LiteralPath $FolderPath -PathType Container)) {
        Show-TSxDialog -Message ("Folder not found: {0}" -f $FolderPath) -Title $Script:ToolName -Icon Warning -Owner $Owner
        return
    }

    $ButtonSearch.Enabled = $false
    $Owner.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $ListResults.Items.Clear()
    $TextOutput.Clear()

    $LabelStatus.Text = "Running scan..."
    Add-OutputLine -Text ("[{0}] Starting scan in: {1}" -f (Get-Date -Format "HH:mm:ss"), $FolderPath)
    Write-TSxLog -Message ("Starting scan. FolderPath={0}; ShowVerbose={1}" -f $FolderPath, $ShowVerbose)

    $disconnected = New-Object System.Collections.Generic.List[System.IO.FileInfo]

    try {
        $stream = & $Script:TargetScriptPath -Folder $FolderPath -Verbose:$ShowVerbose 3>&1 4>&1 6>&1

        foreach ($item in $stream) {
            if ($item -is [System.IO.FileInfo]) {
                [void]$disconnected.Add($item)
                continue
            }

            if ($item -is [System.Management.Automation.VerboseRecord]) {
                if ($ShowVerbose) {
                    Add-OutputLine -Text ("VERBOSE: {0}" -f $item.Message)
                }
                continue
            }

            if ($item -is [System.Management.Automation.WarningRecord]) {
                Add-OutputLine -Text ("WARNING: {0}" -f $item.Message)
                continue
            }

            if ($item -is [System.Management.Automation.InformationRecord]) {
                Add-OutputLine -Text ("INFO: {0}" -f $item.MessageData)
                continue
            }

            if ($null -ne $item) {
                Add-OutputLine -Text ([string]$item)
            }
        }

        foreach ($file in $disconnected) {
            $sizeMB = [math]::Round(($file.Length / 1MB), 2)
            $row = New-Object System.Windows.Forms.ListViewItem($file.FullName)
            [void]$row.SubItems.Add([string]$sizeMB)
            [void]$row.SubItems.Add($file.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"))
            [void]$ListResults.Items.Add($row)
        }

        $LabelStatus.Text = ("Completed. Disconnected file(s): {0}" -f $disconnected.Count)
        Add-OutputLine -Text ("[{0}] Completed. Found {1} disconnected file(s)." -f (Get-Date -Format "HH:mm:ss"), $disconnected.Count)

        if ($disconnected.Count -gt 0) {
            Write-TSxLog -Message ("Disconnected VHDs: {0}" -f ($disconnected.FullName -join ", "))
        }
        else {
            Write-TSxLog -Message "No disconnected VHD files found"
        }
    }
    catch {
        $LabelStatus.Text = "Run failed"
        Add-OutputLine -Text ("ERROR: {0}" -f $_.Exception.Message)
        Write-TSxLog -Message ("Run failed with exception: {0}" -f $_.Exception.Message)
        Show-TSxDialog -Message ("Failed to run Get-TSxDisconnectedVHDs.ps1. {0}`r`n`r`nLog: {1}" -f $_.Exception.Message, $Script:LogFile) -Title $Script:ToolName -Icon Error -Owner $Owner
    }
    finally {
        $Owner.Cursor = [System.Windows.Forms.Cursors]::Default
        $ButtonSearch.Enabled = $true
    }
}

$Form = New-Object System.Windows.Forms.Form
$Form.Size = New-Object System.Drawing.Size(1024, 700)
$Form.MinimumSize = New-Object System.Drawing.Size(900, 580)
$Form.Text = "Get TSxDisconnectedVHDs UI"
$Form.StartPosition = "CenterScreen"
$Form.TopMost = $false

$LabelTitle = New-Object System.Windows.Forms.Label
$LabelTitle.AutoSize = $true
$LabelTitle.Location = New-Object System.Drawing.Point(20, 30)
$LabelTitle.Font = New-Object System.Drawing.Font("Consolas", 11, [System.Drawing.FontStyle]::Bold)
$LabelTitle.Text = "Launch Get-TSxDisconnectedVHDs.ps1"

$PictureBoxLogo = New-Object System.Windows.Forms.PictureBox
$PictureBoxLogo.Location = New-Object System.Drawing.Point(685, 6)
$PictureBoxLogo.Size = New-Object System.Drawing.Size(270, 78)
$PictureBoxLogo.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
if (Test-Path -Path $Script:LogoPath) {
    $PictureBoxLogo.ImageLocation = $Script:LogoPath
}

$LabelFolder = New-Object System.Windows.Forms.Label
$LabelFolder.AutoSize = $true
$LabelFolder.Location = New-Object System.Drawing.Point(20, 102)
$LabelFolder.Font = New-Object System.Drawing.Font("Consolas", 10)
$LabelFolder.Text = "Folder to scan:"

$TextFolder = New-Object System.Windows.Forms.TextBox
$TextFolder.Location = New-Object System.Drawing.Point(170, 98)
$TextFolder.Size = New-Object System.Drawing.Size(680, 26)
$TextFolder.Font = New-Object System.Drawing.Font("Consolas", 10)
$TextFolder.Text = "C:\"

$ButtonBrowseFolder = New-Object System.Windows.Forms.Button
$ButtonBrowseFolder.Location = New-Object System.Drawing.Point(860, 96)
$ButtonBrowseFolder.Size = New-Object System.Drawing.Size(170, 32)
$ButtonBrowseFolder.Text = "Browse"
$ButtonBrowseFolder.Font = New-Object System.Drawing.Font("Consolas", 10)

$CheckVerbose = New-Object System.Windows.Forms.CheckBox
$CheckVerbose.AutoSize = $true
$CheckVerbose.Location = New-Object System.Drawing.Point(23, 140)
$CheckVerbose.Font = New-Object System.Drawing.Font("Consolas", 10)
$CheckVerbose.Text = "Show verbose details"
$CheckVerbose.Checked = $true

$ButtonSearch = New-Object System.Windows.Forms.Button
$ButtonSearch.Location = New-Object System.Drawing.Point(490, 135)
$ButtonSearch.Size = New-Object System.Drawing.Size(170, 32)
$ButtonSearch.Text = "Search"
$ButtonSearch.Font = New-Object System.Drawing.Font("Consolas", 10)

$ButtonOpenPath = New-Object System.Windows.Forms.Button
$ButtonOpenPath.Location = New-Object System.Drawing.Point(645, 135)
$ButtonOpenPath.Size = New-Object System.Drawing.Size(170, 32)
$ButtonOpenPath.Text = "Open Path"
$ButtonOpenPath.Font = New-Object System.Drawing.Font("Consolas", 10)

$ButtonRemoveSelected = New-Object System.Windows.Forms.Button
$ButtonRemoveSelected.Location = New-Object System.Drawing.Point(800, 135)
$ButtonRemoveSelected.Size = New-Object System.Drawing.Size(170, 32)
$ButtonRemoveSelected.Text = "Remove Selected"
$ButtonRemoveSelected.Font = New-Object System.Drawing.Font("Consolas", 10)

$ButtonResetDefaults = New-Object System.Windows.Forms.Button
$ButtonResetDefaults.Location = New-Object System.Drawing.Point(645, 175)
$ButtonResetDefaults.Size = New-Object System.Drawing.Size(170, 32)
$ButtonResetDefaults.Text = "Reset"
$ButtonResetDefaults.Font = New-Object System.Drawing.Font("Consolas", 10)

$ButtonExit = New-Object System.Windows.Forms.Button
$ButtonExit.Location = New-Object System.Drawing.Point(800, 175)
$ButtonExit.Size = New-Object System.Drawing.Size(170, 32)
$ButtonExit.Text = "Exit"
$ButtonExit.Font = New-Object System.Drawing.Font("Consolas", 10)

$LabelResults = New-Object System.Windows.Forms.Label
$LabelResults.AutoSize = $true
$LabelResults.Location = New-Object System.Drawing.Point(20, 230)
$LabelResults.Font = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
$LabelResults.Text = "Disconnected VHD/VHDX files"

$ListResults = New-Object System.Windows.Forms.ListView
$ListResults.Location = New-Object System.Drawing.Point(23, 253)
$ListResults.Size = New-Object System.Drawing.Size(932, 250)
$ListResults.View = [System.Windows.Forms.View]::Details
$ListResults.FullRowSelect = $true
$ListResults.GridLines = $true
$ListResults.MultiSelect = $true
[void]$ListResults.Columns.Add("FullName", 690)
[void]$ListResults.Columns.Add("Size (MB)", 100)
[void]$ListResults.Columns.Add("LastWriteTime", 130)

$LabelOutputHeader = New-Object System.Windows.Forms.Label
$LabelOutputHeader.AutoSize = $true
$LabelOutputHeader.Location = New-Object System.Drawing.Point(20, 515)
$LabelOutputHeader.Font = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
$LabelOutputHeader.Text = "Run output"

$TextOutput = New-Object System.Windows.Forms.TextBox
$TextOutput.Location = New-Object System.Drawing.Point(23, 538)
$TextOutput.Size = New-Object System.Drawing.Size(932, 120)
$TextOutput.Multiline = $true
$TextOutput.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$TextOutput.ReadOnly = $true
$TextOutput.Font = New-Object System.Drawing.Font("Consolas", 9)

$LabelStatus = New-Object System.Windows.Forms.Label
$LabelStatus.AutoSize = $false
$LabelStatus.Location = New-Object System.Drawing.Point(23, 675)
$LabelStatus.Size = New-Object System.Drawing.Size(932, 35)
$LabelStatus.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$LabelStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$LabelStatus.Font = New-Object System.Drawing.Font("Consolas", 10)
$LabelStatus.Text = "Ready"

$Form.Controls.AddRange(@(
    $LabelTitle,
    $PictureBoxLogo,
    $LabelFolder,
    $TextFolder,
    $ButtonBrowseFolder,
    $CheckVerbose,
    $ButtonSearch,
    $ButtonOpenPath,
    $ButtonRemoveSelected,
    $ButtonResetDefaults,
    $ButtonExit,
    $LabelResults,
    $ListResults,
    $LabelOutputHeader,
    $TextOutput,
    $LabelStatus
))

$loadedSettings = Import-UISettings
if ($loadedSettings) {
    if (-not [string]::IsNullOrWhiteSpace($loadedSettings.FolderPath)) {
        $TextFolder.Text = [string]$loadedSettings.FolderPath
    }
    if ($null -ne $loadedSettings.ShowVerbose) {
        $CheckVerbose.Checked = [bool]$loadedSettings.ShowVerbose
    }
}

$ButtonBrowseFolder.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Select folder to scan recursively"
    $dialog.ShowNewFolderButton = $true
    if (-not [string]::IsNullOrWhiteSpace($TextFolder.Text) -and (Test-Path -LiteralPath $TextFolder.Text -PathType Container)) {
        $dialog.SelectedPath = $TextFolder.Text
    }

    if ($dialog.ShowDialog($Form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $TextFolder.Text = $dialog.SelectedPath
    }
})

$ButtonSearch.Add_Click({
    $folderPath = $TextFolder.Text.Trim()

    Save-UISettings -FolderPath $folderPath -ShowVerbose $CheckVerbose.Checked

    Invoke-DisconnectedVhdScan -Owner $Form -FolderPath $folderPath -ShowVerbose $CheckVerbose.Checked
})

$ButtonOpenPath.Add_Click({
    if ($ListResults.SelectedItems.Count -eq 0) {
        Show-TSxDialog -Message "Select one or more files to open in Explorer." -Title $Script:ToolName -Icon Warning -Owner $Form
        return
    }

    $selectedPaths = @()
    foreach ($selectedItem in $ListResults.SelectedItems) {
        $selectedPaths += $selectedItem.Text
    }

    foreach ($selectedPath in $selectedPaths | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $selectedPath -PathType Leaf)) {
            Add-OutputLine -Text ("File not found: {0}" -f $selectedPath)
            Write-TSxLog -Message ("Open Path skipped because file was not found: {0}" -f $selectedPath)
            continue
        }

        Start-Process -FilePath "explorer.exe" -ArgumentList "/select,`"$selectedPath`""
        Add-OutputLine -Text ("Opened in Explorer: {0}" -f $selectedPath)
        Write-TSxLog -Message ("Opened in Explorer: {0}" -f $selectedPath)
    }
})

$ButtonRemoveSelected.Add_Click({
    if ($ListResults.SelectedItems.Count -eq 0) {
        Show-TSxDialog -Message "Select one or more files to remove." -Title $Script:ToolName -Icon Warning -Owner $Form
        return
    }

    $selectedPaths = @()
    foreach ($selectedItem in $ListResults.SelectedItems) {
        $selectedPaths += $selectedItem.Text
    }

    $confirmMessage = @(
        "Warning, are you sure?",
        "",
        "You are about to permanently delete {0} selected file(s)." -f $selectedPaths.Count,
        "This action cannot be undone."
    ) -join [Environment]::NewLine

    $confirmResult = [System.Windows.Forms.MessageBox]::Show(
        $Form,
        $confirmMessage,
        $Script:ToolName,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($confirmResult -ne [System.Windows.Forms.DialogResult]::Yes) {
        Add-OutputLine -Text "Delete operation cancelled by user."
        return
    }

    $removedCount = 0
    $failedCount = 0

    foreach ($selectedPath in $selectedPaths) {
        try {
            if (Test-Path -LiteralPath $selectedPath -PathType Leaf) {
                Remove-Item -LiteralPath $selectedPath -Force -ErrorAction Stop
                Add-OutputLine -Text ("Removed: {0}" -f $selectedPath)
                Write-TSxLog -Message ("Removed file: {0}" -f $selectedPath)
                $removedCount++
            }
            else {
                Add-OutputLine -Text ("File not found (already removed?): {0}" -f $selectedPath)
                Write-TSxLog -Message ("File not found during remove: {0}" -f $selectedPath)
                $failedCount++
            }
        }
        catch {
            Add-OutputLine -Text ("Failed to remove: {0}. Error: {1}" -f $selectedPath, $_.Exception.Message)
            Write-TSxLog -Message ("Failed to remove file: {0}. Error: {1}" -f $selectedPath, $_.Exception.Message)
            $failedCount++
        }
    }

    for ($i = $ListResults.Items.Count - 1; $i -ge 0; $i--) {
        if ($selectedPaths -contains $ListResults.Items[$i].Text) {
            $ListResults.Items.RemoveAt($i)
        }
    }

    $LabelStatus.Text = ("Remove completed. Removed: {0}. Failed: {1}." -f $removedCount, $failedCount)
})

$ButtonResetDefaults.Add_Click({
    $TextFolder.Text = "C:\"
    $CheckVerbose.Checked = $true
    $ListResults.Items.Clear()
    $TextOutput.Clear()
    $LabelStatus.Text = "Defaults restored"

    try {
        if (Test-Path -LiteralPath $Script:SettingsFile -PathType Leaf) {
            Remove-Item -LiteralPath $Script:SettingsFile -Force
            Write-TSxLog -Message ("Deleted saved settings file: {0}" -f $Script:SettingsFile)
        }
    }
    catch {
        Write-TSxLog -Message ("Failed to delete settings file. Error: {0}" -f $_.Exception.Message)
    }
})

$Form.Add_FormClosing({
    Save-UISettings -FolderPath $TextFolder.Text.Trim() -ShowVerbose $CheckVerbose.Checked
})

$ButtonExit.Add_Click({
    $Form.Close()
})

Write-TSxLog -Message "Get-TSxDisconnectedVHDsUI started"
[void]$Form.ShowDialog()
