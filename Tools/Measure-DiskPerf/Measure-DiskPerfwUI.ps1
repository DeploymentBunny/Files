<#
.SYNOPSIS
    GUI launcher for Measure-DiskPerf.ps1.

.DESCRIPTION
    Measure-DiskPerfwUI provides a Windows Forms interface that:
    - Uses the same UI baseline and interaction model as Remove-VMUI2.
    - Connects to a target host context (for operator consistency).
    - Lets you browse for a local target folder or type a UNC path manually.
    - Lets you browse and select diskspd.exe.
    - Lets you configure duration, block size, threads, and output path.
    - Runs Measure-DiskPerf.ps1 with selected values.
    - Optionally opens the latest generated HTML report.
    - Persists last-used settings in %LOCALAPPDATA%\DeploymentBunny.
    - Writes a timestamped log file in %TEMP%\Measure-DiskPerfwUI\.

.NOTES
    FileName:    Measure-DiskPerfwUI.ps1
    Author:      Mikael Nystrom
    Contact:     deploymentbunny@outlook.com
    Created:     2026-04-28
    Updated:     2026-04-28
    Twitter:     @mikael_nystrom

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author.
.LINK
    https://www.deploymentbunny.com
.EXAMPLE
    .\Measure-DiskPerfwUI.ps1
#>

$Host.UI.RawUI.WindowTitle = $myInvocation.MyCommand.Definition

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Font1        = [System.Drawing.Font]::new("Arial", 10, [System.Drawing.FontStyle]::Bold)
$FontHeading1 = [System.Drawing.Font]::new("Arial", 11, [System.Drawing.FontStyle]::Bold)
$FontHeading2 = [System.Drawing.Font]::new("Arial", 14, [System.Drawing.FontStyle]::Bold)
$FontData     = [System.Drawing.Font]::new("Courier New", 10)

$DLL = '[DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);'
Add-Type -MemberDefinition $DLL -name NativeMethods -namespace Win32

$Script:ToolName = "Measure-DiskPerfwUI"
$Script:IsAdmin = [bool](([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
$Script:ScriptPath = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$Script:TargetComputer = $env:COMPUTERNAME
$Script:MeasureScriptPath = Join-Path $PSScriptRoot "Measure-DiskPerf.ps1"

# Logging Setup
$Script:ScriptName = (Get-Item -Path $Script:ScriptPath).BaseName
$Script:LogDirectory = Join-Path -Path $env:TEMP -ChildPath $Script:ScriptName
$Script:LogFile = Join-Path -Path $Script:LogDirectory -ChildPath "$($Script:ScriptName)_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"
if (-not (Test-Path -Path $Script:LogDirectory -PathType Container)) {
    [void](New-Item -Path $Script:LogDirectory -ItemType Directory -Force -ErrorAction SilentlyContinue)
}

# Settings File Setup
$Script:SettingsDirectory = Join-Path -Path $env:LOCALAPPDATA -ChildPath "DeploymentBunny"
$Script:SettingsFile = Join-Path -Path $Script:SettingsDirectory -ChildPath "$($Script:ScriptName).settings.json"

# Generate logo from Remove-VMUI2.ps1 payload
$Script:LogoImage = $null
$removeVmUi2Path = Join-Path (Split-Path -Parent $PSScriptRoot) "RemoveVMwUI2\Remove-VMUI2.ps1"
if (Test-Path -LiteralPath $removeVmUi2Path -PathType Leaf) {
    try {
        $removeVmUi2Content = Get-Content -LiteralPath $removeVmUi2Path -Raw -ErrorAction Stop
        if ($removeVmUi2Content -match '\$PictureString\s*=\s*"(?<base64>[A-Za-z0-9\+/=]+)"') {
            $imageBytes = [Convert]::FromBase64String($matches['base64'])
            $imageStream = New-Object System.IO.MemoryStream(,$imageBytes)
            $Script:LogoImage = [System.Drawing.Image]::FromStream($imageStream)
        }
    }
    catch {
    }
}

$consoleHandle = (Get-Process -Id $PID).MainWindowHandle
if ($consoleHandle -ne [IntPtr]::Zero) {
    [void][Win32.NativeMethods]::ShowWindowAsync($consoleHandle, 2)
}

function Write-TSxLog {
    param([Parameter(Mandatory = $true)][string]$Message)

    $timestamp = "{0:yyyy-MM-dd HH:mm:ss.fff}" -f (Get-Date)
    $logLine = "[{0}] {1}" -f $timestamp, $Message
    try { Add-Content -Path $Script:LogFile -Value $logLine -ErrorAction SilentlyContinue } catch {}
}

function Add-TSxOutputLine {
    param([Parameter(Mandatory = $true)][string]$Line)

    $TextOutput.AppendText(("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Line) + [Environment]::NewLine)
    $TextOutput.SelectionStart = $TextOutput.TextLength
    $TextOutput.ScrollToCaret()
}

function Write-TSxVerbose {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-TSxLog -Message ("VERBOSE: {0}" -f $Message)
    if ($CheckboxVerbose.Checked) {
        Add-TSxOutputLine -Line $Message
    }
}

function Show-TSxDialog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$Title,
        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information,
        [System.Windows.Forms.Form]$Owner = $null
    )

    [void][System.Windows.Forms.MessageBox]::Show(
        $Owner,
        $Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $Icon
    )
}

function Save-UISettings {
    try {
        if (-not (Test-Path -LiteralPath $Script:SettingsDirectory -PathType Container)) {
            [void](New-Item -Path $Script:SettingsDirectory -ItemType Directory -Force -ErrorAction SilentlyContinue)
        }

        $settings = [PSCustomObject]@{
            HostName          = $TextServer.Text.Trim()
            VerboseChecked    = $CheckboxVerbose.Checked
            TargetPath        = $TextTargetPath.Text.Trim()
            DiskSpdPath       = $TextDiskSpdPath.Text.Trim()
            OutputPath        = $TextOutputPath.Text.Trim()
            Duration          = [int]$NumericDuration.Value
            BlockSizeKB       = [int]$NumericBlock.Value
            Threads           = [int]$NumericThreads.Value
            OpenReportAfterRun = $CheckOpenReport.Checked
        }

        $settings | ConvertTo-Json -Depth 3 | Out-File -LiteralPath $Script:SettingsFile -Encoding UTF8
        Write-TSxLog -Message "Settings saved: $($Script:SettingsFile)"
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
        Write-TSxLog -Message "Settings loaded: $($Script:SettingsFile)"
        return $settings
    }
    catch {
        Write-TSxLog -Message ("Failed to load settings. Error: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Get-LatestReportPath {
    param([Parameter(Mandatory = $true)][string]$OutputPath)

    if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
        return $null
    }

    $report = Get-ChildItem -LiteralPath $OutputPath -Filter "DiskSpd_Report_*.html" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime |
        Select-Object -Last 1

    if ($report) { return $report.FullName }
    return $null
}

function Connect-TSxUI {
    $hostName = $TextServer.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        $hostName = $env:COMPUTERNAME
        $TextServer.Text = $hostName
    }

    $LabelStatus.Text = "Connecting to $hostName..."
    $Form.Refresh()
    Write-TSxLog -Message "UI: Connect sequence started for host '$hostName'"

    try {
        if ($hostName -ieq $env:COMPUTERNAME -or $hostName -ieq 'localhost' -or $hostName -eq '.') {
            $Script:TargetComputer = $hostName
            Add-TSxOutputLine -Line "Connected to local host context: $hostName"
            $LabelStatus.Text = "Connected"
            Write-TSxLog -Message "UI: Connected to local host context '$hostName'"
            return
        }

        Test-WSMan -ComputerName $hostName -ErrorAction Stop | Out-Null
        $Script:TargetComputer = $hostName
        Add-TSxOutputLine -Line "Connected to remote host context: $hostName"
        $LabelStatus.Text = "Connected"
        Write-TSxLog -Message "UI: Connected to remote host context '$hostName'"
    }
    catch {
        $LabelStatus.Text = "Connection failed"
        Add-TSxOutputLine -Line ("ERROR: Failed to connect to {0}: {1}" -f $hostName, $_.Exception.Message)
        Write-TSxLog -Message ("UI: Connect sequence FAILED for '{0}' - {1}" -f $hostName, $_.Exception.Message)
    }
}

function Invoke-MeasureDiskPerf {
    if (-not (Test-Path -LiteralPath $Script:MeasureScriptPath -PathType Leaf)) {
        Show-TSxDialog -Message ("Could not find Measure-DiskPerf.ps1 at: {0}" -f $Script:MeasureScriptPath) -Title $Script:ToolName -Icon Error -Owner $Form
        return
    }

    $targetPath = $TextTargetPath.Text.Trim()
    $diskSpdPath = $TextDiskSpdPath.Text.Trim()
    $outputPath = $TextOutputPath.Text.Trim()
    $duration = [int]$NumericDuration.Value
    $blockSizeKb = [int]$NumericBlock.Value
    $threads = [int]$NumericThreads.Value
    $openReport = $CheckOpenReport.Checked

    if ([string]::IsNullOrWhiteSpace($targetPath)) {
        Show-TSxDialog -Message "Target path is required." -Title $Script:ToolName -Icon Warning -Owner $Form
        return
    }

    if ([string]::IsNullOrWhiteSpace($diskSpdPath) -or -not (Test-Path -LiteralPath $diskSpdPath -PathType Leaf)) {
        Show-TSxDialog -Message ("diskspd.exe was not found at: {0}" -f $diskSpdPath) -Title $Script:ToolName -Icon Warning -Owner $Form
        return
    }

    if ([string]::IsNullOrWhiteSpace($outputPath)) {
        Show-TSxDialog -Message "Output path is required." -Title $Script:ToolName -Icon Warning -Owner $Form
        return
    }

    try {
        if (-not (Test-Path -LiteralPath $outputPath -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $outputPath -Force)
        }
    }
    catch {
        Show-TSxDialog -Message ("Failed to create output path. {0}" -f $_.Exception.Message) -Title $Script:ToolName -Icon Error -Owner $Form
        return
    }

    $LabelStatus.Text = "Running benchmark..."
    $Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $ButtonRun.Enabled = $false

    Write-TSxLog -Message ("Starting run. Host={0}; TargetPath={1}; DiskSpdPath={2}; OutputPath={3}; Duration={4}; BlockSizeKB={5}; Threads={6}; OpenReportAfterRun={7}" -f $Script:TargetComputer, $targetPath, $diskSpdPath, $outputPath, $duration, $blockSizeKb, $threads, $openReport)
    Write-TSxVerbose -Message ("Run details -> Host={0}; TargetPath={1}; OutputPath={2}" -f $Script:TargetComputer, $targetPath, $outputPath)

    try {
        & $Script:MeasureScriptPath `
            -TargetPath $targetPath `
            -Duration $duration `
            -BlockSizeKB $blockSizeKb `
            -Threads $threads `
            -OutputPath $outputPath `
            -DiskSpdPath $diskSpdPath

        $latestReport = Get-LatestReportPath -OutputPath $outputPath
        if ($openReport -and $latestReport) {
            Start-Process -FilePath $latestReport | Out-Null
            Write-TSxLog -Message ("Opened report: {0}" -f $latestReport)
        }

        $LabelStatus.Text = "Completed"
        Add-TSxOutputLine -Line "Measure-DiskPerf completed successfully."
        if ($latestReport) {
            Add-TSxOutputLine -Line ("Latest report: {0}" -f $latestReport)
        }
        Add-TSxOutputLine -Line ("Log: {0}" -f $Script:LogFile)

        if (-not $openReport) {
            Show-TSxDialog -Message "Measure-DiskPerf completed successfully." -Title $Script:ToolName -Icon Information -Owner $Form
        }
    }
    catch {
        $LabelStatus.Text = "Run failed"
        Add-TSxOutputLine -Line ("ERROR: {0}" -f $_.Exception.Message)
        Write-TSxLog -Message ("Run failed with exception: {0}" -f $_.Exception.Message)
        Show-TSxDialog -Message ("Failed to run Measure-DiskPerf.ps1. {0}`r`n`r`nLog: {1}" -f $_.Exception.Message, $Script:LogFile) -Title $Script:ToolName -Icon Error -Owner $Form
    }
    finally {
        $Form.Cursor = [System.Windows.Forms.Cursors]::Default
        $ButtonRun.Enabled = $true
    }
}

# --- Form ---
$Form = New-Object System.Windows.Forms.Form
$Form.Text          = $Script:ToolName
$Form.StartPosition = "CenterScreen"
$Form.Size          = New-Object System.Drawing.Size(1024, 700)
$Form.MinimumSize   = New-Object System.Drawing.Size(900, 580)
$Form.BackColor     = [System.Drawing.Color]::White

$LabelTitle = New-Object System.Windows.Forms.Label
$LabelTitle.Location = New-Object System.Drawing.Point(16, 12)
$LabelTitle.Size = New-Object System.Drawing.Size(750, 24)
$LabelTitle.Text = "Measure disk performance with DiskSpd"
$LabelTitle.Font = $FontHeading2
$LabelTitle.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($LabelTitle)

$PictureBox = New-Object System.Windows.Forms.PictureBox
$PictureBox.Location = New-Object System.Drawing.Point(842, 4)
$PictureBox.Size = New-Object System.Drawing.Size(150, 70)
$PictureBox.Image = $Script:LogoImage
$PictureBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
$PictureBox.BackColor = [System.Drawing.Color]::White
$PictureBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$Form.Controls.Add($PictureBox)

$ButtonConnect = New-Object System.Windows.Forms.Button
$ButtonConnect.Location = New-Object System.Drawing.Point(16, 46)
$ButtonConnect.Size = New-Object System.Drawing.Size(170, 32)
$ButtonConnect.Text = "Connect"
$ButtonConnect.Font = $Font1
$ButtonConnect.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#F35800")
$ButtonConnect.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#1c1d1d")
$Form.Controls.Add($ButtonConnect)

$CheckboxVerbose = New-Object System.Windows.Forms.CheckBox
$CheckboxVerbose.Location = New-Object System.Drawing.Point(16, 92)
$CheckboxVerbose.Size = New-Object System.Drawing.Size(120, 24)
$CheckboxVerbose.Text = "Verbose"
$CheckboxVerbose.Font = $Font1
$CheckboxVerbose.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($CheckboxVerbose)

$LabelStatus = New-Object System.Windows.Forms.Label
$LabelStatus.AutoSize = $false
$LabelStatus.Location = New-Object System.Drawing.Point(150, 92)
$LabelStatus.Size = New-Object System.Drawing.Size(846, 24)
$LabelStatus.Text = "Ready"
$LabelStatus.Font = $FontHeading1
$LabelStatus.BackColor = [System.Drawing.Color]::White
$LabelStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$LabelStatus.AutoEllipsis = $true
$Form.Controls.Add($LabelStatus)

$LabelServer = New-Object System.Windows.Forms.Label
$LabelServer.Location = New-Object System.Drawing.Point(202, 52)
$LabelServer.Size = New-Object System.Drawing.Size(130, 20)
$LabelServer.Text = "Computer Name:"
$LabelServer.Font = $Font1
$LabelServer.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($LabelServer)

$TextServer = New-Object System.Windows.Forms.TextBox
$TextServer.Location = New-Object System.Drawing.Point(338, 48)
$TextServer.Size = New-Object System.Drawing.Size(654, 24)
$TextServer.Text = $env:COMPUTERNAME
$TextServer.Font = $Font1
$Form.Controls.Add($TextServer)

$LabelTarget = New-Object System.Windows.Forms.Label
$LabelTarget.Location = New-Object System.Drawing.Point(16, 126)
$LabelTarget.Size = New-Object System.Drawing.Size(170, 24)
$LabelTarget.Text = "Target path:"
$LabelTarget.Font = $Font1
$LabelTarget.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($LabelTarget)

$TextTargetPath = New-Object System.Windows.Forms.TextBox
$TextTargetPath.Location = New-Object System.Drawing.Point(196, 126)
$TextTargetPath.Size = New-Object System.Drawing.Size(626, 24)
$TextTargetPath.Text = "$env:TEMP"
$TextTargetPath.Font = $Font1
$Form.Controls.Add($TextTargetPath)

$ButtonBrowseTarget = New-Object System.Windows.Forms.Button
$ButtonBrowseTarget.Location = New-Object System.Drawing.Point(822, 126)
$ButtonBrowseTarget.Size = New-Object System.Drawing.Size(170, 32)
$ButtonBrowseTarget.Text = "Browse"
$ButtonBrowseTarget.Font = $Font1
$Form.Controls.Add($ButtonBrowseTarget)

$LabelDiskSpd = New-Object System.Windows.Forms.Label
$LabelDiskSpd.Location = New-Object System.Drawing.Point(16, 166)
$LabelDiskSpd.Size = New-Object System.Drawing.Size(170, 24)
$LabelDiskSpd.Text = "diskspd.exe path:"
$LabelDiskSpd.Font = $Font1
$LabelDiskSpd.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($LabelDiskSpd)

$TextDiskSpdPath = New-Object System.Windows.Forms.TextBox
$TextDiskSpdPath.Location = New-Object System.Drawing.Point(196, 166)
$TextDiskSpdPath.Size = New-Object System.Drawing.Size(626, 24)
$TextDiskSpdPath.Text = "diskspd.exe"
$TextDiskSpdPath.Font = $Font1
$Form.Controls.Add($TextDiskSpdPath)

$ButtonBrowseDiskSpd = New-Object System.Windows.Forms.Button
$ButtonBrowseDiskSpd.Location = New-Object System.Drawing.Point(822, 166)
$ButtonBrowseDiskSpd.Size = New-Object System.Drawing.Size(170, 32)
$ButtonBrowseDiskSpd.Text = "Browse"
$ButtonBrowseDiskSpd.Font = $Font1
$Form.Controls.Add($ButtonBrowseDiskSpd)

$LabelOutputPath = New-Object System.Windows.Forms.Label
$LabelOutputPath.Location = New-Object System.Drawing.Point(16, 206)
$LabelOutputPath.Size = New-Object System.Drawing.Size(170, 24)
$LabelOutputPath.Text = "Output path:"
$LabelOutputPath.Font = $Font1
$LabelOutputPath.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($LabelOutputPath)

$TextOutputPath = New-Object System.Windows.Forms.TextBox
$TextOutputPath.Location = New-Object System.Drawing.Point(196, 206)
$TextOutputPath.Size = New-Object System.Drawing.Size(626, 24)
$TextOutputPath.Text = (Join-Path $env:TEMP "DiskSpdResults")
$TextOutputPath.Font = $Font1
$Form.Controls.Add($TextOutputPath)

$ButtonBrowseOutput = New-Object System.Windows.Forms.Button
$ButtonBrowseOutput.Location = New-Object System.Drawing.Point(822, 206)
$ButtonBrowseOutput.Size = New-Object System.Drawing.Size(170, 32)
$ButtonBrowseOutput.Text = "Browse"
$ButtonBrowseOutput.Font = $Font1
$Form.Controls.Add($ButtonBrowseOutput)

$LabelDuration = New-Object System.Windows.Forms.Label
$LabelDuration.Location = New-Object System.Drawing.Point(16, 246)
$LabelDuration.Size = New-Object System.Drawing.Size(170, 24)
$LabelDuration.Text = "Duration (sec):"
$LabelDuration.Font = $Font1
$LabelDuration.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($LabelDuration)

$NumericDuration = New-Object System.Windows.Forms.NumericUpDown
$NumericDuration.Location = New-Object System.Drawing.Point(196, 246)
$NumericDuration.Size = New-Object System.Drawing.Size(120, 24)
$NumericDuration.Font = $Font1
$NumericDuration.Minimum = 1
$NumericDuration.Maximum = 86400
$NumericDuration.Value = 120
$Form.Controls.Add($NumericDuration)

$LabelBlock = New-Object System.Windows.Forms.Label
$LabelBlock.Location = New-Object System.Drawing.Point(336, 246)
$LabelBlock.Size = New-Object System.Drawing.Size(150, 24)
$LabelBlock.Text = "Block size (KB):"
$LabelBlock.Font = $Font1
$LabelBlock.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($LabelBlock)

$NumericBlock = New-Object System.Windows.Forms.NumericUpDown
$NumericBlock.Location = New-Object System.Drawing.Point(486, 246)
$NumericBlock.Size = New-Object System.Drawing.Size(120, 24)
$NumericBlock.Font = $Font1
$NumericBlock.Minimum = 1
$NumericBlock.Maximum = 1024
$NumericBlock.Value = 4
$Form.Controls.Add($NumericBlock)

$LabelThreads = New-Object System.Windows.Forms.Label
$LabelThreads.Location = New-Object System.Drawing.Point(626, 246)
$LabelThreads.Size = New-Object System.Drawing.Size(90, 24)
$LabelThreads.Text = "Threads:"
$LabelThreads.Font = $Font1
$LabelThreads.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($LabelThreads)

$NumericThreads = New-Object System.Windows.Forms.NumericUpDown
$NumericThreads.Location = New-Object System.Drawing.Point(702, 246)
$NumericThreads.Size = New-Object System.Drawing.Size(120, 24)
$NumericThreads.Font = $Font1
$NumericThreads.Minimum = 1
$NumericThreads.Maximum = 256
$NumericThreads.Value = 2
$Form.Controls.Add($NumericThreads)

$CheckOpenReport = New-Object System.Windows.Forms.CheckBox
$CheckOpenReport.Location = New-Object System.Drawing.Point(16, 286)
$CheckOpenReport.Size = New-Object System.Drawing.Size(420, 24)
$CheckOpenReport.Text = "Open report in default browser when done"
$CheckOpenReport.Checked = $true
$CheckOpenReport.Font = $Font1
$CheckOpenReport.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($CheckOpenReport)

$ButtonReset = New-Object System.Windows.Forms.Button
$ButtonReset.Location = New-Object System.Drawing.Point(446, 286)
$ButtonReset.Size = New-Object System.Drawing.Size(170, 32)
$ButtonReset.Text = "Reset"
$ButtonReset.Font = $Font1
$Form.Controls.Add($ButtonReset)

$ButtonRun = New-Object System.Windows.Forms.Button
$ButtonRun.Location = New-Object System.Drawing.Point(636, 286)
$ButtonRun.Size = New-Object System.Drawing.Size(170, 32)
$ButtonRun.Text = "Run"
$ButtonRun.Font = $Font1
$Form.Controls.Add($ButtonRun)

$TextOutput = New-Object System.Windows.Forms.TextBox
$TextOutput.Location = New-Object System.Drawing.Point(16, 332)
$TextOutput.Size = New-Object System.Drawing.Size(976, 276)
$TextOutput.Multiline = $true
$TextOutput.ScrollBars = "Both"
$TextOutput.ReadOnly = $true
$TextOutput.WordWrap = $false
$TextOutput.Font = $FontData
$TextOutput.BackColor = [System.Drawing.Color]::White
$TextOutput.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$Form.Controls.Add($TextOutput)

$ButtonElevate = New-Object System.Windows.Forms.Button
$ButtonElevate.Location = New-Object System.Drawing.Point(16, 616)
$ButtonElevate.Size = New-Object System.Drawing.Size(170, 32)
$ButtonElevate.Text = "Elevate (Admin)"
$ButtonElevate.Font = $Font1
$ButtonElevate.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#FFC107")
$ButtonElevate.ForeColor = [System.Drawing.Color]::Black
$ButtonElevate.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$ButtonElevate.Visible = (-not $Script:IsAdmin)
$Form.Controls.Add($ButtonElevate)

$ButtonClose = New-Object System.Windows.Forms.Button
$ButtonClose.Location = New-Object System.Drawing.Point(822, 616)
$ButtonClose.Size = New-Object System.Drawing.Size(170, 32)
$ButtonClose.Text = "Close"
$ButtonClose.Font = $Font1
$ButtonClose.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
$Form.Controls.Add($ButtonClose)

# --- Events ---
$Form.Add_Load({
    $loadedSettings = Import-UISettings
    if ($loadedSettings) {
        if (-not [string]::IsNullOrWhiteSpace($loadedSettings.HostName)) { $TextServer.Text = [string]$loadedSettings.HostName }
        if (-not [string]::IsNullOrWhiteSpace($loadedSettings.TargetPath)) { $TextTargetPath.Text = [string]$loadedSettings.TargetPath }
        if (-not [string]::IsNullOrWhiteSpace($loadedSettings.DiskSpdPath)) { $TextDiskSpdPath.Text = [string]$loadedSettings.DiskSpdPath }
        if (-not [string]::IsNullOrWhiteSpace($loadedSettings.OutputPath)) { $TextOutputPath.Text = [string]$loadedSettings.OutputPath }
        if ($null -ne $loadedSettings.VerboseChecked) { $CheckboxVerbose.Checked = [bool]$loadedSettings.VerboseChecked }
        if ($null -ne $loadedSettings.OpenReportAfterRun) { $CheckOpenReport.Checked = [bool]$loadedSettings.OpenReportAfterRun }

        if ($null -ne $loadedSettings.Duration) {
            $durationValue = [int]$loadedSettings.Duration
            if ($durationValue -lt [int]$NumericDuration.Minimum) { $durationValue = [int]$NumericDuration.Minimum }
            if ($durationValue -gt [int]$NumericDuration.Maximum) { $durationValue = [int]$NumericDuration.Maximum }
            $NumericDuration.Value = $durationValue
        }

        if ($null -ne $loadedSettings.BlockSizeKB) {
            $blockValue = [int]$loadedSettings.BlockSizeKB
            if ($blockValue -lt [int]$NumericBlock.Minimum) { $blockValue = [int]$NumericBlock.Minimum }
            if ($blockValue -gt [int]$NumericBlock.Maximum) { $blockValue = [int]$NumericBlock.Maximum }
            $NumericBlock.Value = $blockValue
        }

        if ($null -ne $loadedSettings.Threads) {
            $threadsValue = [int]$loadedSettings.Threads
            if ($threadsValue -lt [int]$NumericThreads.Minimum) { $threadsValue = [int]$NumericThreads.Minimum }
            if ($threadsValue -gt [int]$NumericThreads.Maximum) { $threadsValue = [int]$NumericThreads.Maximum }
            $NumericThreads.Value = $threadsValue
        }
    }
})

$Form.Add_FormClosing({
    Save-UISettings
})

$ButtonConnect.Add_Click({ Connect-TSxUI })
$ButtonRun.Add_Click({
    Save-UISettings
    Invoke-MeasureDiskPerf
})
$ButtonClose.Add_Click({ $Form.Close() })
$ButtonReset.Add_Click({
    $TextTargetPath.Text = "$env:TEMP"
    $TextDiskSpdPath.Text = "diskspd.exe"
    $TextOutputPath.Text = (Join-Path $env:TEMP "DiskSpdResults")
    $NumericDuration.Value = 120
    $NumericBlock.Value = 4
    $NumericThreads.Value = 2
    $CheckOpenReport.Checked = $true
    $LabelStatus.Text = "Defaults restored"
    Add-TSxOutputLine -Line "Defaults restored"
})
$CheckboxVerbose.Add_CheckedChanged({
    Write-TSxLog -Message ("UI: Verbose mode set to {0}" -f $CheckboxVerbose.Checked)
    if ($CheckboxVerbose.Checked) {
        Add-TSxOutputLine -Line ("Log file: {0}" -f $Script:LogFile)
    }
})

$ButtonBrowseTarget.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Select local target folder"
    $dialog.ShowNewFolderButton = $true
    if (Test-Path -LiteralPath $TextTargetPath.Text -PathType Container) { $dialog.SelectedPath = $TextTargetPath.Text }
    if ($dialog.ShowDialog($Form) -eq [System.Windows.Forms.DialogResult]::OK) { $TextTargetPath.Text = $dialog.SelectedPath }
})

$ButtonBrowseDiskSpd.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Select diskspd.exe"
    $dialog.Filter = "Executables (*.exe)|*.exe|All files (*.*)|*.*"
    $dialog.FileName = "diskspd.exe"
    $dialog.CheckFileExists = $true
    $dialog.Multiselect = $false
    if ($dialog.ShowDialog($Form) -eq [System.Windows.Forms.DialogResult]::OK) { $TextDiskSpdPath.Text = $dialog.FileName }
})

$ButtonBrowseOutput.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Select output folder"
    $dialog.ShowNewFolderButton = $true
    if (Test-Path -LiteralPath $TextOutputPath.Text -PathType Container) { $dialog.SelectedPath = $TextOutputPath.Text }
    if ($dialog.ShowDialog($Form) -eq [System.Windows.Forms.DialogResult]::OK) { $TextOutputPath.Text = $dialog.SelectedPath }
})

$ButtonElevate.Add_Click({
    try {
        if ([string]::IsNullOrWhiteSpace($Script:ScriptPath) -or -not (Test-Path -LiteralPath $Script:ScriptPath -PathType Leaf)) {
            throw "Unable to determine script path for elevation."
        }

        Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$Script:ScriptPath`"" -Verb RunAs -ErrorAction Stop
        $Form.Close()
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show(
            $Form,
            ("Failed to relaunch elevated.`r`n{0}" -f $_.Exception.Message),
            $Script:ToolName,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
})

Write-TSxLog -Message "Measure-DiskPerfwUI started"
$LabelStatus.Text = "Ready"
[void]$Form.ShowDialog()
