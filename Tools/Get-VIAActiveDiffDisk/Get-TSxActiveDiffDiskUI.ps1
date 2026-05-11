<#
.SYNOPSIS
    GUI launcher for Get-TSxActiveDiffDisk.ps1.

.DESCRIPTION
    Get-TSxActiveDiffDiskUI provides a Windows Forms interface that:
    - Self-elevates to local Administrator.
    - Runs Get-TSxActiveDiffDisk.ps1 and captures output safely for UI display.
    - Shows active differencing disk mappings (VMName, DiskPath, ParentPath) in a multi-select list.
    - Opens selected DiskPath or ParentPath entries in Explorer.
    - Optionally shows verbose progress messages in an output box.
    - Persists last-used settings in %LOCALAPPDATA%\DeploymentBunny.
    - Writes a per-run log file in %TEMP%.

.EXAMPLE
    .\Get-TSxActiveDiffDiskUI.ps1

.NOTES
    FileName:    Get-TSxActiveDiffDiskUI.ps1
    Version:     1.0.0
    Author:      Mikael Nystrom
    Twitter:     @mikael_nystrom
    Contact:     deploymentbunny@outlook.com
    Created:     2026-05-11
    Updated:     2026-05-11

    Disclaimer:
    This script is provided "AS IS" with no warranties.
.LINK
    https://www.deploymentbunny.com
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

$Script:ToolName = "Get-TSxActiveDiffDiskUI"
$Script:TargetScriptPath = Join-Path $PSScriptRoot "Get-TSxActiveDiffDisk.ps1"
$Script:ConvertScriptPath = Join-Path $PSScriptRoot "Convert-TSxDiffToDyn.ps1"
$Script:LogFile = Join-Path $env:TEMP ("{0}_{1}.log" -f $Script:ToolName, (Get-Date -Format "yyyyMMdd_HHmmss"))
$Script:RunUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$Script:SettingsDirectory = Join-Path $env:LOCALAPPDATA "DeploymentBunny"
$Script:SettingsFile = Join-Path $Script:SettingsDirectory "Get-TSxActiveDiffDiskUI.settings.json"
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
        [bool]$ShowVerbose
    )

    try {
        if (-not (Test-Path -LiteralPath $Script:SettingsDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $Script:SettingsDirectory -Force | Out-Null
        }

        $settings = [PSCustomObject]@{
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

function Invoke-ActiveDiffDiskScan {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Form]$Owner,

        [Parameter(Mandatory = $true)]
        [bool]$ShowVerbose
    )

    if (-not (Test-Path -LiteralPath $Script:TargetScriptPath -PathType Leaf)) {
        Show-TSxDialog -Message ("Could not find Get-TSxActiveDiffDisk.ps1 at: {0}" -f $Script:TargetScriptPath) -Title $Script:ToolName -Icon Error -Owner $Owner
        return
    }

    $ButtonSearch.Enabled = $false
    $Owner.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $ListResults.Items.Clear()
    $TextOutput.Clear()

    $LabelStatus.Text = "Running scan..."
    Add-OutputLine -Text ("[{0}] Starting scan..." -f (Get-Date -Format "HH:mm:ss"))
    Write-TSxLog -Message ("Starting scan. ShowVerbose={0}" -f $ShowVerbose)

    $results = New-Object System.Collections.Generic.List[object]

    try {
        $stream = & $Script:TargetScriptPath -Verbose:$ShowVerbose 3>&1 4>&1 6>&1

        foreach ($item in $stream) {
            if ($item -is [System.Management.Automation.PSObject] -and
                $item.PSObject.Properties['VMName'] -and
                $item.PSObject.Properties['DiskPath'] -and
                $item.PSObject.Properties['ParentPath']) {
                [void]$results.Add($item)
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

        $vmStateMap = @{}
        foreach ($vmInfo in @(Get-VM -ErrorAction SilentlyContinue)) {
            $vmStateMap[$vmInfo.Name] = [string]$vmInfo.State
        }

        foreach ($entry in $results) {
            $vmState = if ($vmStateMap.ContainsKey([string]$entry.VMName)) { $vmStateMap[[string]$entry.VMName] } else { 'Unknown' }
            $row = New-Object System.Windows.Forms.ListViewItem([string]$entry.VMName)
            [void]$row.SubItems.Add([string]$vmState)
            [void]$row.SubItems.Add([string]$entry.DiskPath)
            [void]$row.SubItems.Add([string]$entry.ParentPath)
            [void]$ListResults.Items.Add($row)
        }

        $LabelStatus.Text = ("Completed. Mapping(s): {0}" -f $results.Count)
        Add-OutputLine -Text ("[{0}] Completed. Found {1} mapping(s)." -f (Get-Date -Format "HH:mm:ss"), $results.Count)

        if ($results.Count -gt 0) {
            $mappingSummary = @(
                $results | ForEach-Object { "{0}|{1}|{2}" -f $_.VMName, $_.DiskPath, $_.ParentPath }
            ) -join "; "
            Write-TSxLog -Message ("Mappings found: {0}" -f $mappingSummary)
        }
        else {
            Write-TSxLog -Message "No active differencing disk mappings found"
        }
    }
    catch {
        $LabelStatus.Text = "Run failed"
        Add-OutputLine -Text ("ERROR: {0}" -f $_.Exception.Message)
        Write-TSxLog -Message ("Run failed with exception: {0}" -f $_.Exception.Message)
        Show-TSxDialog -Message ("Failed to run Get-TSxActiveDiffDisk.ps1. {0}`r`n`r`nLog: {1}" -f $_.Exception.Message, $Script:LogFile) -Title $Script:ToolName -Icon Error -Owner $Owner
    }
    finally {
        $Owner.Cursor = [System.Windows.Forms.Cursors]::Default
        $ButtonSearch.Enabled = $true
    }
}

function Open-SelectedPath {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('DiskPath', 'ParentPath')]
        [string]$PathType
    )

    if ($ListResults.SelectedItems.Count -eq 0) {
        Show-TSxDialog -Message "Select one or more rows first." -Title $Script:ToolName -Icon Warning -Owner $Form
        return
    }

    $subItemIndex = if ($PathType -eq 'DiskPath') { 2 } else { 3 }

    $selectedPaths = @()
    foreach ($selectedItem in $ListResults.SelectedItems) {
        if ($selectedItem.SubItems.Count -gt $subItemIndex) {
            $candidatePath = [string]$selectedItem.SubItems[$subItemIndex].Text
            if (-not [string]::IsNullOrWhiteSpace($candidatePath)) {
                $selectedPaths += $candidatePath
            }
        }
    }

    foreach ($selectedPath in $selectedPaths | Sort-Object -Unique) {
        if (-not (Test-Path -LiteralPath $selectedPath -PathType Leaf)) {
            Add-OutputLine -Text ("Path not found: {0}" -f $selectedPath)
            Write-TSxLog -Message ("Open {0} skipped because file was not found: {1}" -f $PathType, $selectedPath)
            continue
        }

        Start-Process -FilePath "explorer.exe" -ArgumentList "/select,`"$selectedPath`""
        Add-OutputLine -Text ("Opened in Explorer ({0}): {1}" -f $PathType, $selectedPath)
        Write-TSxLog -Message ("Opened in Explorer ({0}): {1}" -f $PathType, $selectedPath)
    }
}

function Invoke-ConvertSelectedVMs {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Form]$Owner,

        [Parameter(Mandatory = $true)]
        [bool]$ShowVerbose
    )

    if (-not (Test-Path -LiteralPath $Script:ConvertScriptPath -PathType Leaf)) {
        Show-TSxDialog -Message ("Could not find Convert-TSxDiffToDyn.ps1 at: {0}" -f $Script:ConvertScriptPath) -Title $Script:ToolName -Icon Error -Owner $Owner
        return
    }

    if ($ListResults.SelectedItems.Count -eq 0) {
        Show-TSxDialog -Message "Select one or more VM rows to convert." -Title $Script:ToolName -Icon Warning -Owner $Owner
        return
    }

    $vmNames = @()
    foreach ($selectedItem in $ListResults.SelectedItems) {
        $vmName = [string]$selectedItem.Text
        if (-not [string]::IsNullOrWhiteSpace($vmName)) {
            $vmNames += $vmName
        }
    }
    $vmNames = @($vmNames | Sort-Object -Unique)

    if ($vmNames.Count -eq 0) {
        Show-TSxDialog -Message "No valid VM names found in selected rows." -Title $Script:ToolName -Icon Warning -Owner $Owner
        return
    }

    $confirmMessage = @(
        "Warning, are you sure?",
        "",
        "You are about to convert differencing disks for {0} VM(s)." -f $vmNames.Count,
        "This changes VHDX files on disk and should be used with caution.",
        "",
        "Selected VM(s):",
        ($vmNames -join ", ")
    ) -join [Environment]::NewLine

    $confirmResult = [System.Windows.Forms.MessageBox]::Show(
        $Owner,
        $confirmMessage,
        $Script:ToolName,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($confirmResult -ne [System.Windows.Forms.DialogResult]::Yes) {
        Add-OutputLine -Text "Convert operation cancelled by user."
        return
    }

    $ButtonSearch.Enabled = $false
    $ButtonConvertSelected.Enabled = $false
    $Owner.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $LabelStatus.Text = "Running conversion..."

    $successCount = 0
    $failedCount = 0

    try {
        foreach ($vmName in $vmNames) {
            Add-OutputLine -Text ("[{0}] Starting conversion for VM: {1}" -f (Get-Date -Format "HH:mm:ss"), $vmName)
            Write-TSxLog -Message ("Starting conversion for VM: {0}" -f $vmName)

            try {
                $stream = & $Script:ConvertScriptPath -VMName $vmName -Verbose:$ShowVerbose 3>&1 4>&1 6>&1

                foreach ($item in $stream) {
                    if ($item -is [System.Management.Automation.VerboseRecord]) {
                        if ($ShowVerbose) {
                            Add-OutputLine -Text ("VERBOSE [{0}]: {1}" -f $vmName, $item.Message)
                        }
                        continue
                    }

                    if ($item -is [System.Management.Automation.WarningRecord]) {
                        Add-OutputLine -Text ("WARNING [{0}]: {1}" -f $vmName, $item.Message)
                        continue
                    }

                    if ($item -is [System.Management.Automation.InformationRecord]) {
                        Add-OutputLine -Text ("INFO [{0}]: {1}" -f $vmName, $item.MessageData)
                        continue
                    }

                    if ($null -ne $item) {
                        Add-OutputLine -Text ([string]$item)
                    }
                }

                Add-OutputLine -Text ("[{0}] Conversion completed for VM: {1}" -f (Get-Date -Format "HH:mm:ss"), $vmName)
                Write-TSxLog -Message ("Conversion completed for VM: {0}" -f $vmName)
                $successCount++
            }
            catch {
                Add-OutputLine -Text ("ERROR [{0}]: {1}" -f $vmName, $_.Exception.Message)
                Write-TSxLog -Message ("Conversion failed for VM '{0}'. Error: {1}" -f $vmName, $_.Exception.Message)
                $failedCount++
            }
        }

        $LabelStatus.Text = ("Conversion completed. Success: {0}. Failed: {1}." -f $successCount, $failedCount)
    }
    finally {
        $Owner.Cursor = [System.Windows.Forms.Cursors]::Default
        $ButtonSearch.Enabled = $true
        $ButtonConvertSelected.Enabled = $true
    }
}

$Form = New-Object System.Windows.Forms.Form
$Form.Size = New-Object System.Drawing.Size(1024, 700)
$Form.MinimumSize = New-Object System.Drawing.Size(900, 580)
$Form.Text = "Get TSxActiveDiffDisk UI"
$Form.StartPosition = "CenterScreen"
$Form.TopMost = $false
$Form.BackColor = [System.Drawing.Color]::White

$LabelTitle = New-Object System.Windows.Forms.Label
$LabelTitle.AutoSize = $true
$LabelTitle.Location = New-Object System.Drawing.Point(20, 30)
$LabelTitle.Font = New-Object System.Drawing.Font("Consolas", 11, [System.Drawing.FontStyle]::Bold)
$LabelTitle.Text = "Get differance disks in use"

$PictureBoxLogo = New-Object System.Windows.Forms.PictureBox
$PictureBoxLogo.Location = New-Object System.Drawing.Point(740, 6)
$PictureBoxLogo.Size = New-Object System.Drawing.Size(260, 78)
$PictureBoxLogo.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
if (Test-Path -Path $Script:LogoPath) {
    $PictureBoxLogo.ImageLocation = $Script:LogoPath
}

$CheckVerbose = New-Object System.Windows.Forms.CheckBox
$CheckVerbose.AutoSize = $true
$CheckVerbose.Location = New-Object System.Drawing.Point(23, 100)
$CheckVerbose.Font = New-Object System.Drawing.Font("Consolas", 10)
$CheckVerbose.Text = "Show verbose details"
$CheckVerbose.Checked = $true

$ButtonSearch = New-Object System.Windows.Forms.Button
$ButtonSearch.Location = New-Object System.Drawing.Point(520, 95)
$ButtonSearch.Size = New-Object System.Drawing.Size(170, 32)
$ButtonSearch.Text = "Search"
$ButtonSearch.Font = New-Object System.Drawing.Font("Consolas", 10)

$ButtonOpenDiskPath = New-Object System.Windows.Forms.Button
$ButtonOpenDiskPath.Location = New-Object System.Drawing.Point(675, 95)
$ButtonOpenDiskPath.Size = New-Object System.Drawing.Size(170, 32)
$ButtonOpenDiskPath.Text = "Open Disk Path"
$ButtonOpenDiskPath.Font = New-Object System.Drawing.Font("Consolas", 10)

$ButtonOpenParentPath = New-Object System.Windows.Forms.Button
$ButtonOpenParentPath.Location = New-Object System.Drawing.Point(830, 95)
$ButtonOpenParentPath.Size = New-Object System.Drawing.Size(170, 32)
$ButtonOpenParentPath.Text = "Open Parent Path"
$ButtonOpenParentPath.Font = New-Object System.Drawing.Font("Consolas", 10)

$ButtonConvertSelected = New-Object System.Windows.Forms.Button
$ButtonConvertSelected.Location = New-Object System.Drawing.Point(520, 140)
$ButtonConvertSelected.Size = New-Object System.Drawing.Size(170, 32)
$ButtonConvertSelected.Text = "Convert Selected"
$ButtonConvertSelected.Font = New-Object System.Drawing.Font("Consolas", 10)

$ButtonResetDefaults = New-Object System.Windows.Forms.Button
$ButtonResetDefaults.Location = New-Object System.Drawing.Point(675, 140)
$ButtonResetDefaults.Size = New-Object System.Drawing.Size(170, 32)
$ButtonResetDefaults.Text = "Reset"
$ButtonResetDefaults.Font = New-Object System.Drawing.Font("Consolas", 10)

$ButtonExit = New-Object System.Windows.Forms.Button
$ButtonExit.Location = New-Object System.Drawing.Point(830, 140)
$ButtonExit.Size = New-Object System.Drawing.Size(170, 32)
$ButtonExit.Text = "Exit"
$ButtonExit.Font = New-Object System.Drawing.Font("Consolas", 10)

$LabelResults = New-Object System.Windows.Forms.Label
$LabelResults.AutoSize = $true
$LabelResults.Location = New-Object System.Drawing.Point(20, 195)
$LabelResults.Font = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
$LabelResults.Text = "Active differencing disk mappings"

$ListResults = New-Object System.Windows.Forms.ListView
$ListResults.Location = New-Object System.Drawing.Point(23, 218)
$ListResults.Size = New-Object System.Drawing.Size(977, 255)
$ListResults.View = [System.Windows.Forms.View]::Details
$ListResults.FullRowSelect = $true
$ListResults.GridLines = $true
$ListResults.MultiSelect = $true
[void]$ListResults.Columns.Add("VMName", 180)
[void]$ListResults.Columns.Add("VMState", 120)
[void]$ListResults.Columns.Add("DiskPath", 330)
[void]$ListResults.Columns.Add("ParentPath", 330)

$LabelOutputHeader = New-Object System.Windows.Forms.Label
$LabelOutputHeader.AutoSize = $true
$LabelOutputHeader.Location = New-Object System.Drawing.Point(20, 488)
$LabelOutputHeader.Font = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
$LabelOutputHeader.Text = "Run output"

$TextOutput = New-Object System.Windows.Forms.TextBox
$TextOutput.Location = New-Object System.Drawing.Point(23, 511)
$TextOutput.Size = New-Object System.Drawing.Size(977, 120)
$TextOutput.Multiline = $true
$TextOutput.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$TextOutput.ReadOnly = $true
$TextOutput.Font = New-Object System.Drawing.Font("Consolas", 9)

$LabelStatus = New-Object System.Windows.Forms.Label
$LabelStatus.AutoSize = $false
$LabelStatus.Location = New-Object System.Drawing.Point(23, 640)
$LabelStatus.Size = New-Object System.Drawing.Size(977, 35)
$LabelStatus.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$LabelStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$LabelStatus.Font = New-Object System.Drawing.Font("Consolas", 10)
$LabelStatus.Text = "Ready"

$Form.Controls.AddRange(@(
    $LabelTitle,
    $PictureBoxLogo,
    $CheckVerbose,
    $ButtonSearch,
    $ButtonOpenDiskPath,
    $ButtonOpenParentPath,
    $ButtonConvertSelected,
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
    if ($null -ne $loadedSettings.ShowVerbose) {
        $CheckVerbose.Checked = [bool]$loadedSettings.ShowVerbose
    }
}

$ButtonSearch.Add_Click({
    Save-UISettings -ShowVerbose $CheckVerbose.Checked
    Invoke-ActiveDiffDiskScan -Owner $Form -ShowVerbose $CheckVerbose.Checked
})

$ButtonOpenDiskPath.Add_Click({
    Open-SelectedPath -PathType DiskPath
})

$ButtonOpenParentPath.Add_Click({
    Open-SelectedPath -PathType ParentPath
})

$ButtonConvertSelected.Add_Click({
    Save-UISettings -ShowVerbose $CheckVerbose.Checked
    Invoke-ConvertSelectedVMs -Owner $Form -ShowVerbose $CheckVerbose.Checked
})

$ButtonResetDefaults.Add_Click({
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
    Save-UISettings -ShowVerbose $CheckVerbose.Checked
})

$ButtonExit.Add_Click({
    $Form.Close()
})

Write-TSxLog -Message "Get-TSxActiveDiffDiskUI started"
[void]$Form.ShowDialog()
