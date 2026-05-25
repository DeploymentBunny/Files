<#
.SYNOPSIS
    Windows Forms UI for searching and downloading Windows updates for offline image servicing.

.DESCRIPTION
    Provides a Windows Forms front end for Microsoft Update Catalog searches and download execution.
    The UI supports category selection, architecture selection, and Force behavior,
    and persists the last used values so the next launch restores the prior session.

.PARAMETER Force
    When set, clears the current log file and forces overwrite behavior in downstream download calls.

.EXAMPLE
    .\Get-TSxWindowsUpdateUI.ps1 -Verbose

.NOTES
    FileName:    Get-TSxWindowsUpdateUI.ps1
    Version:     1.2.8
    Author:      Mikael Nystrom
    Contact:     @mikael_nystrom
    Created:     2026-05-22
    Updated:     2026-05-25
    Twitter:     @mikael_nystrom

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author.

.LINK
    https://www.deploymentbunny.com

.FUNCTIONALITY
    Starts a Windows Forms UI for querying Microsoft Update Catalog and downloading selected updates.
    Loads and saves last-used UI settings in %TEMP%\Get-TSxLatestWindowsUpdate\Settings.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [switch]$Force
)

Import-Module -Name (Join-Path $PSScriptRoot 'Modules\TSxLatestWindowsUpdateUtility\TSxLatestWindowsUpdateUtility.psd1') -Force -ErrorAction Stop

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogRootPath = Join-Path -Path $env:TEMP -ChildPath 'Get-TSxLatestWindowsUpdate'
$script:LogFilePath = Join-Path -Path $script:LogRootPath -ChildPath ('{0}.log' -f [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath))
$script:SettingsDirectory = Join-Path -Path $script:LogRootPath -ChildPath 'Settings'
$script:SettingsFile = Join-Path -Path $script:SettingsDirectory -ChildPath ('{0}.settings.json' -f [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath))

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$fontMain = [System.Drawing.Font]::new('Arial', 10, [System.Drawing.FontStyle]::Bold)
$fontHeading = [System.Drawing.Font]::new('Arial', 11, [System.Drawing.FontStyle]::Bold)
$fontData = [System.Drawing.Font]::new('Courier New', 10)
$colorPrimaryButton = [System.Drawing.ColorTranslator]::FromHtml('#F35800')
$colorSecondaryButton = [System.Drawing.ColorTranslator]::FromHtml('#F5B041')
$colorButtonText = [System.Drawing.ColorTranslator]::FromHtml('#1c1d1d')

$script:OutputTextBox = $null

function Add-TSxUiOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('INFO', 'WARN', 'ERROR', 'VERBOSE')]
        [string]$Level = 'INFO'
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return
    }

    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    if ($script:OutputTextBox -and -not $script:OutputTextBox.IsDisposed) {
        $script:OutputTextBox.AppendText($line + [Environment]::NewLine)
        $script:OutputTextBox.SelectionStart = $script:OutputTextBox.TextLength
        $script:OutputTextBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Save-UISettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OperatingSystem,

        [Parameter(Mandatory = $true)]
        [string]$Architecture,

        [Parameter(Mandatory = $true)]
        [string]$DownloadPath,

        [Parameter(Mandatory = $true)]
        [bool]$Force,

        [Parameter(Mandatory = $true)]
        [bool]$IncludeCumulative,

        [Parameter(Mandatory = $true)]
        [bool]$IncludeDotNet,

        [Parameter(Mandatory = $true)]
        [bool]$IncludeSSU,

        [Parameter(Mandatory = $true)]
        [bool]$IncludeDefender,

        [Parameter(Mandatory = $true)]
        [bool]$IncludeEdge,

        [Parameter(Mandatory = $true)]
        [bool]$IncludePreview,

        [Parameter(Mandatory = $true)]
        [bool]$IncludeInsider
    )

    try {
        if (-not (Test-Path -LiteralPath $Script:SettingsDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $Script:SettingsDirectory -Force | Out-Null
        }

        $settings = [pscustomobject]@{
            OperatingSystem = $OperatingSystem
            Architecture    = $Architecture
            DownloadPath    = $DownloadPath
            Force           = $Force
            IncludeCumulative = $IncludeCumulative
            IncludeDotNet   = $IncludeDotNet
            IncludeSSU      = $IncludeSSU
            IncludeDefender = $IncludeDefender
            IncludeEdge     = $IncludeEdge
            IncludePreview  = $IncludePreview
            IncludeInsider  = $IncludeInsider
        }

        $settings | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $Script:SettingsFile -Encoding UTF8
        Write-TSxLog -Message ('Settings saved: {0}' -f $Script:SettingsFile)
    }
    catch {
        Write-TSxLog -Level 'WARN' -Message ('Failed to save settings. Error: {0}' -f $_.Exception.Message)
    }
}

function Import-UISettings {
    if (-not (Test-Path -LiteralPath $Script:SettingsFile -PathType Leaf)) {
        return $null
    }

    try {
        $settings = Get-Content -LiteralPath $Script:SettingsFile -Raw | ConvertFrom-Json
        Write-TSxLog -Message ('Settings loaded: {0}' -f $Script:SettingsFile)
        return $settings
    }
    catch {
        Write-TSxLog -Level 'WARN' -Message ('Failed to load settings. Error: {0}' -f $_.Exception.Message)
        return $null
    }
}

function Get-TSxDeploymentBunnyLogoImage {
    $dedupUiPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Start-VIADeDupJob\Invoke-TSxDeDupJobUI.ps1'
    if (-not (Test-Path -LiteralPath $dedupUiPath -PathType Leaf)) {
        return $null
    }

    try {
        $dedupUiContent = Get-Content -LiteralPath $dedupUiPath -Raw
        $pictureStringMatch = [regex]::Match($dedupUiContent, '\$PictureString\s*=\s*"(?<data>[^"]+)"')
        if (-not $pictureStringMatch.Success) {
            return $null
        }

        $logoBytes = [Convert]::FromBase64String($pictureStringMatch.Groups['data'].Value)
        $logoStream = New-Object System.IO.MemoryStream(,$logoBytes)
        return [System.Drawing.Image]::FromStream($logoStream)
    }
    catch {
        return $null
    }
}

$scriptRoot = Split-Path -Path $PSCommandPath -Parent
$listScriptPath = Join-Path -Path $scriptRoot -ChildPath 'Get-TSxWindowsUpdateList.ps1'
$downloadScriptPath = Join-Path -Path $scriptRoot -ChildPath 'Save-TSxWindowsUpdateFromCatalog.ps1'

if (-not (Test-Path -Path $listScriptPath)) {
    throw ('List script not found: {0}' -f $listScriptPath)
}

if (-not (Test-Path -Path $downloadScriptPath)) {
    throw ('Download script not found: {0}' -f $downloadScriptPath)
}

$scriptName = Split-Path -Path $PSCommandPath -Leaf
Start-TSxLog -FilePath $script:LogFilePath -Force:$Force
Write-TSxLog -Message ('{0} started' -f $scriptName)
Write-TSxLog -Message ('Force: {0}' -f $Force.IsPresent)
Write-TSxLog -Message ('Log root path: {0}' -f $script:LogRootPath)
Write-TSxLog -Message ('Log path: {0}' -f $script:LogFilePath)
Add-TSxUiOutput -Message ('{0} started' -f $scriptName)
Add-TSxUiOutput -Message ('Log path: {0}' -f $script:LogFilePath)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Get-TSxWindowsUpdate'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1180, 760)
$form.MinimumSize = New-Object System.Drawing.Size(1000, 680)
$form.BackColor = [System.Drawing.Color]::White

$logoImage = Get-TSxDeploymentBunnyLogoImage
if ($logoImage) {
    $pictureBox = New-Object System.Windows.Forms.PictureBox
    $pictureBox.Location = New-Object System.Drawing.Point(1018, 4)
    $pictureBox.Size = New-Object System.Drawing.Size(150, 70)
    $pictureBox.Image = $logoImage
    $pictureBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $pictureBox.BackColor = [System.Drawing.Color]::White
    $pictureBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    [void]$form.Controls.Add($pictureBox)
}

$labelOS = New-Object System.Windows.Forms.Label
$labelOS.Location = New-Object System.Drawing.Point(12, 16)
$labelOS.Size = New-Object System.Drawing.Size(120, 20)
$labelOS.Text = 'Operating System'
$labelOS.Font = $fontMain
$labelOS.BackColor = [System.Drawing.Color]::White

$textOS = New-Object System.Windows.Forms.TextBox
$textOS.Location = New-Object System.Drawing.Point(138, 12)
$textOS.Size = New-Object System.Drawing.Size(300, 23)
$textOS.Text = 'Windows 11 24H2'
$textOS.Font = $fontMain

$labelArchitecture = New-Object System.Windows.Forms.Label
$labelArchitecture.Location = New-Object System.Drawing.Point(446, 16)
$labelArchitecture.Size = New-Object System.Drawing.Size(80, 20)
$labelArchitecture.Text = 'Architecture'
$labelArchitecture.Font = $fontMain
$labelArchitecture.BackColor = [System.Drawing.Color]::White

$comboArchitecture = New-Object System.Windows.Forms.ComboBox
$comboArchitecture.Location = New-Object System.Drawing.Point(532, 12)
$comboArchitecture.Size = New-Object System.Drawing.Size(110, 23)
$comboArchitecture.DropDownStyle = 'DropDownList'
$comboArchitecture.Font = $fontMain
[void]$comboArchitecture.Items.AddRange(@('x64', 'arm64', 'x86'))
$comboArchitecture.SelectedItem = Get-TSxDefaultArchitecture

$buttonSearch = New-Object System.Windows.Forms.Button
$buttonSearch.Location = New-Object System.Drawing.Point(654, 10)
$buttonSearch.Size = New-Object System.Drawing.Size(90, 27)
$buttonSearch.Text = 'Search'
$buttonSearch.Font = $fontMain
$buttonSearch.BackColor = $colorPrimaryButton
$buttonSearch.ForeColor = $colorButtonText

$buttonSelectAll = New-Object System.Windows.Forms.Button
$buttonSelectAll.Location = New-Object System.Drawing.Point(748, 10)
$buttonSelectAll.Size = New-Object System.Drawing.Size(90, 27)
$buttonSelectAll.Text = 'Select All'
$buttonSelectAll.Font = $fontMain
$buttonSelectAll.BackColor = $colorSecondaryButton
$buttonSelectAll.ForeColor = $colorButtonText

$buttonClearSelection = New-Object System.Windows.Forms.Button
$buttonClearSelection.Location = New-Object System.Drawing.Point(842, 10)
$buttonClearSelection.Size = New-Object System.Drawing.Size(90, 27)
$buttonClearSelection.Text = 'Clear'
$buttonClearSelection.Font = $fontMain
$buttonClearSelection.BackColor = $colorSecondaryButton
$buttonClearSelection.ForeColor = $colorButtonText

$checkForce = New-Object System.Windows.Forms.CheckBox
$checkForce.Location = New-Object System.Drawing.Point(886, 70)
$checkForce.Size = New-Object System.Drawing.Size(250, 20)
$checkForce.Text = 'Force overwrite existing'
$checkForce.Checked = $Force.IsPresent
$checkForce.Font = $fontMain
$checkForce.BackColor = [System.Drawing.Color]::White

$checkIncludeCumulative = New-Object System.Windows.Forms.CheckBox
$checkIncludeCumulative.Location = New-Object System.Drawing.Point(12, 70)
$checkIncludeCumulative.Size = New-Object System.Drawing.Size(112, 20)
$checkIncludeCumulative.Text = 'Include LCU'
$checkIncludeCumulative.Checked = $true
$checkIncludeCumulative.Font = $fontMain
$checkIncludeCumulative.BackColor = [System.Drawing.Color]::White

$checkIncludeDotNet = New-Object System.Windows.Forms.CheckBox
$checkIncludeDotNet.Location = New-Object System.Drawing.Point(126, 70)
$checkIncludeDotNet.Size = New-Object System.Drawing.Size(136, 20)
$checkIncludeDotNet.Text = 'Include .NET CU'
$checkIncludeDotNet.Checked = $true
$checkIncludeDotNet.Font = $fontMain
$checkIncludeDotNet.BackColor = [System.Drawing.Color]::White

$checkIncludeSSU = New-Object System.Windows.Forms.CheckBox
$checkIncludeSSU.Location = New-Object System.Drawing.Point(264, 70)
$checkIncludeSSU.Size = New-Object System.Drawing.Size(112, 20)
$checkIncludeSSU.Text = 'Include SSU'
$checkIncludeSSU.Checked = $true
$checkIncludeSSU.Font = $fontMain
$checkIncludeSSU.BackColor = [System.Drawing.Color]::White

$checkIncludeDefender = New-Object System.Windows.Forms.CheckBox
$checkIncludeDefender.Location = New-Object System.Drawing.Point(378, 70)
$checkIncludeDefender.Size = New-Object System.Drawing.Size(142, 20)
$checkIncludeDefender.Text = 'Include Defender'
$checkIncludeDefender.Checked = $false
$checkIncludeDefender.Font = $fontMain
$checkIncludeDefender.BackColor = [System.Drawing.Color]::White

$checkIncludeEdge = New-Object System.Windows.Forms.CheckBox
$checkIncludeEdge.Location = New-Object System.Drawing.Point(522, 70)
$checkIncludeEdge.Size = New-Object System.Drawing.Size(110, 20)
$checkIncludeEdge.Text = 'Include Edge'
$checkIncludeEdge.Checked = $false
$checkIncludeEdge.Font = $fontMain
$checkIncludeEdge.BackColor = [System.Drawing.Color]::White

$checkIncludePreview = New-Object System.Windows.Forms.CheckBox
$checkIncludePreview.Location = New-Object System.Drawing.Point(634, 70)
$checkIncludePreview.Size = New-Object System.Drawing.Size(130, 20)
$checkIncludePreview.Text = 'Include Preview'
$checkIncludePreview.Checked = $false
$checkIncludePreview.Font = $fontMain
$checkIncludePreview.BackColor = [System.Drawing.Color]::White

$checkIncludeInsider = New-Object System.Windows.Forms.CheckBox
$checkIncludeInsider.Location = New-Object System.Drawing.Point(766, 70)
$checkIncludeInsider.Size = New-Object System.Drawing.Size(118, 20)
$checkIncludeInsider.Text = 'Include Insider'
$checkIncludeInsider.Checked = $false
$checkIncludeInsider.Font = $fontMain
$checkIncludeInsider.BackColor = [System.Drawing.Color]::White

$labelPath = New-Object System.Windows.Forms.Label
$labelPath.Location = New-Object System.Drawing.Point(12, 48)
$labelPath.Size = New-Object System.Drawing.Size(120, 20)
$labelPath.Text = 'Download Path'
$labelPath.Font = $fontMain
$labelPath.BackColor = [System.Drawing.Color]::White

$textPath = New-Object System.Windows.Forms.TextBox
$textPath.Location = New-Object System.Drawing.Point(138, 44)
$textPath.Size = New-Object System.Drawing.Size(610, 23)
$textPath.Text = (Join-Path -Path $env:TEMP -ChildPath 'TSxCatalogDownloads')
$textPath.Font = $fontMain

$buttonBrowse = New-Object System.Windows.Forms.Button
$buttonBrowse.Location = New-Object System.Drawing.Point(754, 42)
$buttonBrowse.Size = New-Object System.Drawing.Size(90, 27)
$buttonBrowse.Text = 'Browse...'
$buttonBrowse.Font = $fontMain
$buttonBrowse.BackColor = $colorSecondaryButton
$buttonBrowse.ForeColor = $colorButtonText

$buttonDownload = New-Object System.Windows.Forms.Button
$buttonDownload.Location = New-Object System.Drawing.Point(848, 42)
$buttonDownload.Size = New-Object System.Drawing.Size(160, 27)
$buttonDownload.Text = 'Download Selected'
$buttonDownload.Font = $fontMain
$buttonDownload.BackColor = $colorPrimaryButton
$buttonDownload.ForeColor = $colorButtonText

$progressDownloads = New-Object System.Windows.Forms.ProgressBar
$progressDownloads.Location = New-Object System.Drawing.Point(12, 96)
$progressDownloads.Size = New-Object System.Drawing.Size(1138, 18)
$progressDownloads.Anchor = 'Top,Left,Right'
$progressDownloads.Style = 'Continuous'
$progressDownloads.Minimum = 0
$progressDownloads.Maximum = 100
$progressDownloads.Value = 0

$splitMain = New-Object System.Windows.Forms.SplitContainer
$splitMain.Location = New-Object System.Drawing.Point(12, 120)
$splitMain.Size = New-Object System.Drawing.Size(1138, 518)
$splitMain.Anchor = 'Top,Bottom,Left,Right'
$splitMain.Orientation = 'Horizontal'
$splitMain.SplitterDistance = 390

$gridUpdates = New-Object System.Windows.Forms.DataGridView
$gridUpdates.Dock = 'Fill'
$gridUpdates.AllowUserToAddRows = $false
$gridUpdates.AllowUserToDeleteRows = $false
$gridUpdates.ReadOnly = $false
$gridUpdates.SelectionMode = 'FullRowSelect'
$gridUpdates.MultiSelect = $true
$gridUpdates.AutoGenerateColumns = $false
$gridUpdates.BackgroundColor = [System.Drawing.Color]::White
$gridUpdates.ColumnHeadersDefaultCellStyle.Font = $fontMain

$colSelect = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colSelect.Name = 'Select'
$colSelect.HeaderText = 'Select'
$colSelect.DataPropertyName = 'Select'
$colSelect.Width = 60

$colLastUpdated = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colLastUpdated.Name = 'LastUpdated'
$colLastUpdated.HeaderText = 'Last Updated'
$colLastUpdated.DataPropertyName = 'LastUpdated'
$colLastUpdated.Width = 100

$colKB = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colKB.Name = 'KB'
$colKB.HeaderText = 'KB'
$colKB.DataPropertyName = 'KB'
$colKB.Width = 100

$colTitle = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colTitle.Name = 'Title'
$colTitle.HeaderText = 'Title'
$colTitle.DataPropertyName = 'Title'
$colTitle.Width = 500

$colSize = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colSize.Name = 'Size'
$colSize.HeaderText = 'Size'
$colSize.DataPropertyName = 'Size'
$colSize.Width = 90

$colClassification = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colClassification.Name = 'Classification'
$colClassification.HeaderText = 'Classification'
$colClassification.DataPropertyName = 'Classification'
$colClassification.Width = 110

$colUpdateType = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colUpdateType.Name = 'UpdateType'
$colUpdateType.HeaderText = 'Type'
$colUpdateType.DataPropertyName = 'UpdateType'
$colUpdateType.Width = 95

$colUpdateId = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colUpdateId.Name = 'UpdateId'
$colUpdateId.HeaderText = 'UpdateId'
$colUpdateId.DataPropertyName = 'UpdateId'
$colUpdateId.Width = 170

$colArchitecture = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colArchitecture.Name = 'Architecture'
$colArchitecture.HeaderText = 'Arch'
$colArchitecture.DataPropertyName = 'Architecture'
$colArchitecture.Width = 60

[void]$gridUpdates.Columns.Add($colSelect)
[void]$gridUpdates.Columns.Add($colLastUpdated)
[void]$gridUpdates.Columns.Add($colKB)
[void]$gridUpdates.Columns.Add($colTitle)
[void]$gridUpdates.Columns.Add($colSize)
[void]$gridUpdates.Columns.Add($colClassification)
[void]$gridUpdates.Columns.Add($colUpdateType)
[void]$gridUpdates.Columns.Add($colUpdateId)
[void]$gridUpdates.Columns.Add($colArchitecture)

$textOutput = New-Object System.Windows.Forms.RichTextBox
$textOutput.Dock = 'Fill'
$textOutput.ReadOnly = $true
$textOutput.WordWrap = $false
$textOutput.BackColor = [System.Drawing.Color]::White
$textOutput.Font = $fontData
$script:OutputTextBox = $textOutput

[void]$splitMain.Panel1.Controls.Add($gridUpdates)
[void]$splitMain.Panel2.Controls.Add($textOutput)

$statusBar = New-Object System.Windows.Forms.StatusStrip
$statusBar.Dock = 'Bottom'
$statusBar.BackColor = [System.Drawing.Color]::White
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = 'Ready'
$statusLabel.Font = $fontHeading
[void]$statusBar.Items.Add($statusLabel)

[void]$form.Controls.Add($labelOS)
[void]$form.Controls.Add($textOS)
[void]$form.Controls.Add($labelArchitecture)
[void]$form.Controls.Add($comboArchitecture)
[void]$form.Controls.Add($buttonSearch)
[void]$form.Controls.Add($buttonSelectAll)
[void]$form.Controls.Add($buttonClearSelection)
[void]$form.Controls.Add($checkForce)
[void]$form.Controls.Add($labelPath)
[void]$form.Controls.Add($textPath)
[void]$form.Controls.Add($buttonBrowse)
[void]$form.Controls.Add($buttonDownload)
[void]$form.Controls.Add($checkIncludeCumulative)
[void]$form.Controls.Add($checkIncludeDotNet)
[void]$form.Controls.Add($checkIncludeSSU)
[void]$form.Controls.Add($checkIncludeDefender)
[void]$form.Controls.Add($checkIncludeEdge)
[void]$form.Controls.Add($checkIncludePreview)
[void]$form.Controls.Add($checkIncludeInsider)
[void]$form.Controls.Add($progressDownloads)
[void]$form.Controls.Add($splitMain)
[void]$form.Controls.Add($statusBar)

$bindingTable = New-Object System.Data.DataTable
[void]$bindingTable.Columns.Add('Select', [bool])
[void]$bindingTable.Columns.Add('LastUpdated', [string])
[void]$bindingTable.Columns.Add('KB', [string])
[void]$bindingTable.Columns.Add('Title', [string])
[void]$bindingTable.Columns.Add('Size', [string])
[void]$bindingTable.Columns.Add('Classification', [string])
[void]$bindingTable.Columns.Add('UpdateType', [string])
[void]$bindingTable.Columns.Add('UpdateId', [string])
[void]$bindingTable.Columns.Add('Architecture', [string])

$gridUpdates.DataSource = $bindingTable

$buttonBrowse.Add_Click({
        $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderDialog.Description = 'Select download destination folder'
        $folderDialog.SelectedPath = $textPath.Text
        if ($folderDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $textPath.Text = $folderDialog.SelectedPath
        }
    })

$buttonSearch.Add_Click({
        try {
            $osText = $textOS.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($osText)) {
                [System.Windows.Forms.MessageBox]::Show('Operating System is required.', 'Validation', 'OK', 'Warning') | Out-Null
                return
            }

            $architecture = [string]$comboArchitecture.SelectedItem
            if ([string]::IsNullOrWhiteSpace($architecture)) {
                [System.Windows.Forms.MessageBox]::Show('Architecture is required.', 'Validation', 'OK', 'Warning') | Out-Null
                return
            }

            if (-not ($checkIncludeCumulative.Checked -or $checkIncludeDotNet.Checked -or $checkIncludeSSU.Checked -or $checkIncludeDefender.Checked -or $checkIncludeEdge.Checked)) {
                [System.Windows.Forms.MessageBox]::Show('Select at least one update category.', 'Validation', 'OK', 'Warning') | Out-Null
                return
            }

            $statusLabel.Text = 'Searching updates...'
            [System.Windows.Forms.Application]::DoEvents()
            Write-TSxLog -Message ('Searching updates for {0} ({1})' -f $osText, $architecture)
            Add-TSxUiOutput -Message ('Searching updates for {0} ({1})' -f $osText, $architecture)

            $searchOutput = @(& $listScriptPath -OperatingSystem $osText -Architecture $architecture -Force:$checkForce.Checked -IncludeCumulative:$checkIncludeCumulative.Checked -IncludeDotNet:$checkIncludeDotNet.Checked -IncludeSSU:$checkIncludeSSU.Checked -IncludeDefender:$checkIncludeDefender.Checked -IncludeEdge:$checkIncludeEdge.Checked -IncludePreview:$checkIncludePreview.Checked -IncludeInsider:$checkIncludeInsider.Checked -Verbose 4>&1)
            $updates = @()
            foreach ($outputItem in $searchOutput) {
                if ($outputItem -is [System.Management.Automation.VerboseRecord]) {
                    Write-TSxLog -Message $outputItem.Message
                    Add-TSxUiOutput -Level 'VERBOSE' -Message $outputItem.Message
                }
                elseif ($outputItem -is [System.Management.Automation.WarningRecord]) {
                    Write-TSxLog -Level 'WARN' -Message $outputItem.Message
                    Add-TSxUiOutput -Level 'WARN' -Message $outputItem.Message
                }
                elseif ($outputItem -is [System.Management.Automation.ErrorRecord]) {
                    throw $outputItem.Exception
                }
                elseif ($outputItem -is [System.Management.Automation.InformationRecord]) {
                    Add-TSxUiOutput -Message ([string]$outputItem.MessageData)
                }
                else {
                    $updates += $outputItem
                }
            }

            $bindingTable.Rows.Clear()
            foreach ($update in $updates) {
                $row = $bindingTable.NewRow()
                $row['Select'] = $false
                $row['LastUpdated'] = if ($update.LastUpdated) { ([datetime]$update.LastUpdated).ToString('yyyy-MM-dd') } else { '' }
                $row['KB'] = [string]$update.KB
                $row['Title'] = [string]$update.Title
                $row['Size'] = [string]$update.Size
                $row['Classification'] = [string]$update.Classification
                $row['UpdateType'] = if ($update.PSObject.Properties['UpdateType']) { [string]$update.UpdateType } else { '' }
                $row['UpdateId'] = [string]$update.UpdateId
                $row['Architecture'] = [string]$update.Architecture
                [void]$bindingTable.Rows.Add($row)
            }

            Write-TSxLog -Message ('Search returned {0} update(s)' -f $updates.Count)
            Add-TSxUiOutput -Message ('Search returned {0} update(s)' -f $updates.Count)
            $statusLabel.Text = ('Found {0} updates' -f $updates.Count)
        }
        catch {
            Write-TSxLog -Level 'ERROR' -Message $_.Exception.Message
            $statusLabel.Text = 'Search failed'
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Search Failed', 'OK', 'Error') | Out-Null
        }
    })

$buttonSelectAll.Add_Click({
        foreach ($row in $bindingTable.Rows) {
            $row['Select'] = $true
        }
        $statusLabel.Text = 'All updates selected'
    })

$buttonClearSelection.Add_Click({
        foreach ($row in $bindingTable.Rows) {
            $row['Select'] = $false
        }
        $statusLabel.Text = 'Selection cleared'
    })

$buttonDownload.Add_Click({
        try {
            $downloadPath = $textPath.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($downloadPath)) {
                [System.Windows.Forms.MessageBox]::Show('Download path is required.', 'Validation', 'OK', 'Warning') | Out-Null
                return
            }

            $selectedRows = @($bindingTable.Rows | Where-Object { $_['Select'] -eq $true })
            if ($selectedRows.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show('Select at least one update to download.', 'Validation', 'OK', 'Warning') | Out-Null
                return
            }

            $selectedUpdates = @(
                foreach ($row in $selectedRows) {
                    if ([string]::IsNullOrWhiteSpace([string]$row['UpdateId'])) {
                        continue
                    }

                    [pscustomobject]@{
                        UpdateId     = [string]$row['UpdateId']
                        KB           = [string]$row['KB']
                        Architecture = [string]$row['Architecture']
                        Title        = [string]$row['Title']
                    }
                }
            )

            $selectedUpdateCount = @($selectedUpdates).Count
            if ($selectedUpdateCount -eq 0) {
                [System.Windows.Forms.MessageBox]::Show('No valid selected updates found (missing UpdateId).', 'Validation', 'OK', 'Warning') | Out-Null
                return
            }

            Write-TSxLog -Message ('Starting download for {0} selected update(s)' -f $selectedUpdateCount)
            Add-TSxUiOutput -Message ('Starting download for {0} selected update(s)' -f $selectedUpdateCount)
            $statusLabel.Text = ('Downloading {0} updates...' -f $selectedUpdateCount)
            $progressDownloads.Value = 0
            $progressDownloads.Maximum = $selectedUpdateCount
            [System.Windows.Forms.Application]::DoEvents()

            if ($PSCmdlet.ShouldProcess($downloadPath, ('Download {0} selected update(s)' -f $selectedUpdateCount))) {
                $downloadResults = @()
                $currentIndex = 0
                foreach ($selectedUpdate in $selectedUpdates) {
                    $currentIndex++
                    $statusLabel.Text = ('Downloading update {0} of {1}...' -f $currentIndex, $selectedUpdateCount)
                    $progressDownloads.Style = 'Marquee'
                    $progressDownloads.MarqueeAnimationSpeed = 25
                    [System.Windows.Forms.Application]::DoEvents()

                    $singleDownloadOutput = @(Invoke-TSxDownloadJob -DownloadScriptPath $downloadScriptPath -SelectedUpdate $selectedUpdate -DownloadPath $downloadPath -UseWhatIf:$false -UseForce $checkForce.Checked)
                    foreach ($outputItem in $singleDownloadOutput) {
                        if ($outputItem -is [System.Management.Automation.VerboseRecord]) {
                            Write-TSxLog -Message $outputItem.Message
                            Add-TSxUiOutput -Level 'VERBOSE' -Message $outputItem.Message
                        }
                        elseif ($outputItem -is [System.Management.Automation.WarningRecord]) {
                            Write-TSxLog -Level 'WARN' -Message $outputItem.Message
                            Add-TSxUiOutput -Level 'WARN' -Message $outputItem.Message
                        }
                        elseif ($outputItem -is [System.Management.Automation.ErrorRecord]) {
                            throw $outputItem.Exception
                        }
                        elseif ($outputItem -is [System.Management.Automation.InformationRecord]) {
                            Add-TSxUiOutput -Message ([string]$outputItem.MessageData)
                        }
                        else {
                            $downloadResults += $outputItem
                            if ($outputItem -is [pscustomobject] -and $outputItem.PSObject.Properties['FileName']) {
                                Add-TSxUiOutput -Message ('Result: {0} (Skipped={1}, Downloaded={2})' -f [string]$outputItem.FileName, [bool]$outputItem.WasSkipped, [bool]$outputItem.WasDownloaded)
                            }
                        }
                    }

                    $progressDownloads.Style = 'Continuous'
                    $progressDownloads.MarqueeAnimationSpeed = 0
                    $progressDownloads.Value = $currentIndex
                    [System.Windows.Forms.Application]::DoEvents()
                }

                Write-TSxLog -Message ('Download process returned {0} result(s)' -f $downloadResults.Count)
                Add-TSxUiOutput -Message ('Download process returned {0} result(s)' -f $downloadResults.Count)
                $statusLabel.Text = ('Done. Processed {0} updates.' -f $downloadResults.Count)
                [System.Windows.Forms.MessageBox]::Show(('Processed {0} update(s).' -f $downloadResults.Count), 'Completed', 'OK', 'Information') | Out-Null
            }
        }
        catch {
            Write-TSxLog -Level 'ERROR' -Message $_.Exception.Message
            Add-TSxUiOutput -Level 'ERROR' -Message $_.Exception.Message
            $statusLabel.Text = 'Download failed'
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Download Failed', 'OK', 'Error') | Out-Null
        }
        finally {
            $progressDownloads.Style = 'Continuous'
            $progressDownloads.MarqueeAnimationSpeed = 0
            if ($progressDownloads.Maximum -gt 0 -and $progressDownloads.Value -ge $progressDownloads.Maximum) {
                $statusLabel.Text = $statusLabel.Text
            }
        }
    })

$loadedSettings = Import-UISettings
if ($loadedSettings) {
    if (-not [string]::IsNullOrWhiteSpace([string]$loadedSettings.OperatingSystem)) {
        $textOS.Text = [string]$loadedSettings.OperatingSystem
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$loadedSettings.Architecture) -and $comboArchitecture.Items.Contains([string]$loadedSettings.Architecture)) {
        $comboArchitecture.SelectedItem = [string]$loadedSettings.Architecture
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$loadedSettings.DownloadPath)) {
        $textPath.Text = [string]$loadedSettings.DownloadPath
    }

    if ($null -ne $loadedSettings.Force) { $checkForce.Checked = [bool]$loadedSettings.Force }
    if ($null -ne $loadedSettings.IncludeCumulative) { $checkIncludeCumulative.Checked = [bool]$loadedSettings.IncludeCumulative }
    if ($null -ne $loadedSettings.IncludeDotNet) { $checkIncludeDotNet.Checked = [bool]$loadedSettings.IncludeDotNet }
    if ($null -ne $loadedSettings.IncludeSSU) { $checkIncludeSSU.Checked = [bool]$loadedSettings.IncludeSSU }
    if ($null -ne $loadedSettings.IncludeDefender) { $checkIncludeDefender.Checked = [bool]$loadedSettings.IncludeDefender }
    if ($null -ne $loadedSettings.IncludeEdge) { $checkIncludeEdge.Checked = [bool]$loadedSettings.IncludeEdge }
    if ($null -ne $loadedSettings.IncludePreview) { $checkIncludePreview.Checked = [bool]$loadedSettings.IncludePreview }
    if ($null -ne $loadedSettings.IncludeInsider) { $checkIncludeInsider.Checked = [bool]$loadedSettings.IncludeInsider }
}

$form.Add_FormClosing({
    Save-UISettings -OperatingSystem $textOS.Text.Trim() -Architecture ([string]$comboArchitecture.SelectedItem) -DownloadPath $textPath.Text.Trim() -Force $checkForce.Checked -IncludeCumulative $checkIncludeCumulative.Checked -IncludeDotNet $checkIncludeDotNet.Checked -IncludeSSU $checkIncludeSSU.Checked -IncludeDefender $checkIncludeDefender.Checked -IncludeEdge $checkIncludeEdge.Checked -IncludePreview $checkIncludePreview.Checked -IncludeInsider $checkIncludeInsider.Checked
    })

[void]$form.ShowDialog()