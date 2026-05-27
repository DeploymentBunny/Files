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
    Version:     1.2.45
    Author:      Mikael Nystrom
    Contact:     @mikael_nystrom
    Created:     2026-05-22
    Updated:     2026-05-27
    Twitter:     @mikael_nystrom

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author.

.LINK
    https://www.deploymentbunny.com

.FUNCTIONALITY
    Starts a Windows Forms UI for querying Microsoft Update Catalog and downloading selected updates.
    Loads and saves last-used UI settings in %TEMP%\Get-TSxWindowsUpdate\Settings.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [switch]$Force
)

Import-Module -Name (Join-Path $PSScriptRoot 'Modules\TSxWindowsUpdateUtility\TSxWindowsUpdateUtility.psd1') -Force -ErrorAction Stop

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogRootPath = Join-Path -Path $env:TEMP -ChildPath 'Get-TSxWindowsUpdate'
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
$script:IsApplyingGridRowStyles = $false
$script:ActiveDownloadJob = $null
$script:CancelDownloadRequested = $false

$scriptRoot = Split-Path -Path $PSCommandPath -Parent
$listScriptPath = Join-Path -Path $scriptRoot -ChildPath 'Get-TSxWindowsUpdateList.ps1'
$downloadScriptPath = Join-Path -Path $scriptRoot -ChildPath 'Save-TSxWindowsUpdate.ps1'

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

$logoImage = Get-TSxDeploymentBunnyLogoImage -UiScriptRoot $PSScriptRoot
if ($logoImage) {
    $pictureBox = New-Object System.Windows.Forms.PictureBox
    $pictureBox.Location = New-Object System.Drawing.Point(980, 2)
    $pictureBox.Size = New-Object System.Drawing.Size(188, 112)
    $pictureBox.Image = $logoImage
    $pictureBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $pictureBox.BackColor = [System.Drawing.Color]::White
    $pictureBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    [void]$form.Controls.Add($pictureBox)
}

$labelOS = New-Object System.Windows.Forms.Label
$labelOS.Location = New-Object System.Drawing.Point(12, 16)
$labelOS.Size = New-Object System.Drawing.Size(150, 20)
$labelOS.Text = 'Operating System'
$labelOS.Font = $fontMain
$labelOS.BackColor = [System.Drawing.Color]::White

$textOS = New-Object System.Windows.Forms.TextBox
$textOS.Location = New-Object System.Drawing.Point(166, 12)
$textOS.Size = New-Object System.Drawing.Size(320, 23)
$textOS.Text = 'Windows 11 24H2'
$textOS.Font = $fontMain

$labelArchitecture = New-Object System.Windows.Forms.Label
$labelArchitecture.Location = New-Object System.Drawing.Point(494, 16)
$labelArchitecture.Size = New-Object System.Drawing.Size(80, 20)
$labelArchitecture.Text = 'Architecture'
$labelArchitecture.Font = $fontMain
$labelArchitecture.BackColor = [System.Drawing.Color]::White

$comboArchitecture = New-Object System.Windows.Forms.ComboBox
$comboArchitecture.Location = New-Object System.Drawing.Point(580, 12)
$comboArchitecture.Size = New-Object System.Drawing.Size(110, 23)
$comboArchitecture.DropDownStyle = 'DropDownList'
$comboArchitecture.Font = $fontMain
[void]$comboArchitecture.Items.AddRange(@('x64', 'arm64', 'x86'))
$comboArchitecture.SelectedItem = Get-TSxDefaultArchitecture

$buttonSearch = New-Object System.Windows.Forms.Button
$buttonSearch.Location = New-Object System.Drawing.Point(702, 10)
$buttonSearch.Size = New-Object System.Drawing.Size(90, 27)
$buttonSearch.Text = 'Search'
$buttonSearch.Font = $fontMain
$buttonSearch.BackColor = $colorPrimaryButton
$buttonSearch.ForeColor = $colorButtonText

$buttonSelectAll = New-Object System.Windows.Forms.Button
$buttonSelectAll.Location = New-Object System.Drawing.Point(796, 10)
$buttonSelectAll.Size = New-Object System.Drawing.Size(90, 27)
$buttonSelectAll.Text = 'Select All'
$buttonSelectAll.Font = $fontMain
$buttonSelectAll.BackColor = $colorSecondaryButton
$buttonSelectAll.ForeColor = $colorButtonText

$buttonClearSelection = New-Object System.Windows.Forms.Button
$buttonClearSelection.Location = New-Object System.Drawing.Point(890, 10)
$buttonClearSelection.Size = New-Object System.Drawing.Size(90, 27)
$buttonClearSelection.Text = 'Clear'
$buttonClearSelection.Font = $fontMain
$buttonClearSelection.BackColor = $colorSecondaryButton
$buttonClearSelection.ForeColor = $colorButtonText

$checkForce = New-Object System.Windows.Forms.CheckBox
$checkForce.Location = New-Object System.Drawing.Point(492, 92)
$checkForce.Size = New-Object System.Drawing.Size(150, 20)
$checkForce.Text = 'Force overwrite'
$checkForce.Checked = $Force.IsPresent
$checkForce.Font = $fontMain
$checkForce.BackColor = [System.Drawing.Color]::White

$checkVerbose = New-Object System.Windows.Forms.CheckBox
$checkVerbose.Location = New-Object System.Drawing.Point(492, 70)
$checkVerbose.Size = New-Object System.Drawing.Size(130, 20)
$checkVerbose.Text = 'Verbose output'
$checkVerbose.Checked = $false
$checkVerbose.Font = $fontMain
$checkVerbose.BackColor = [System.Drawing.Color]::White

$checkLatestOnly = New-Object System.Windows.Forms.CheckBox
$checkLatestOnly.Location = New-Object System.Drawing.Point(642, 70)
$checkLatestOnly.Size = New-Object System.Drawing.Size(120, 20)
$checkLatestOnly.Text = 'Latest only'
$checkLatestOnly.Checked = $false
$checkLatestOnly.Font = $fontMain
$checkLatestOnly.BackColor = [System.Drawing.Color]::White

$checkUseLegacyTranser = New-Object System.Windows.Forms.CheckBox
$checkUseLegacyTranser.Location = New-Object System.Drawing.Point(642, 92)
$checkUseLegacyTranser.Size = New-Object System.Drawing.Size(180, 20)
$checkUseLegacyTranser.Text = 'Use legacy transfer'
$checkUseLegacyTranser.Checked = $false
$checkUseLegacyTranser.Font = $fontMain
$checkUseLegacyTranser.BackColor = [System.Drawing.Color]::White

$checkIncludeCumulative = New-Object System.Windows.Forms.CheckBox
$checkIncludeCumulative.Location = New-Object System.Drawing.Point(12, 70)
$checkIncludeCumulative.Size = New-Object System.Drawing.Size(150, 20)
$checkIncludeCumulative.Text = 'Include LCU'
$checkIncludeCumulative.Checked = $true
$checkIncludeCumulative.Font = $fontMain
$checkIncludeCumulative.BackColor = [System.Drawing.Color]::White

$checkIncludeDotNet = New-Object System.Windows.Forms.CheckBox
$checkIncludeDotNet.Location = New-Object System.Drawing.Point(172, 70)
$checkIncludeDotNet.Size = New-Object System.Drawing.Size(150, 20)
$checkIncludeDotNet.Text = 'Include .NET CU'
$checkIncludeDotNet.Checked = $true
$checkIncludeDotNet.Font = $fontMain
$checkIncludeDotNet.BackColor = [System.Drawing.Color]::White

$checkIncludeSSU = New-Object System.Windows.Forms.CheckBox
$checkIncludeSSU.Location = New-Object System.Drawing.Point(332, 70)
$checkIncludeSSU.Size = New-Object System.Drawing.Size(150, 20)
$checkIncludeSSU.Text = 'Include SSU'
$checkIncludeSSU.Checked = $true
$checkIncludeSSU.Font = $fontMain
$checkIncludeSSU.BackColor = [System.Drawing.Color]::White

$checkIncludeDefender = New-Object System.Windows.Forms.CheckBox
$checkIncludeDefender.Location = New-Object System.Drawing.Point(332, 92)
$checkIncludeDefender.Size = New-Object System.Drawing.Size(150, 20)
$checkIncludeDefender.Text = 'Include Defender'
$checkIncludeDefender.Checked = $false
$checkIncludeDefender.Font = $fontMain
$checkIncludeDefender.BackColor = [System.Drawing.Color]::White

$checkIncludeEdge = New-Object System.Windows.Forms.CheckBox
$checkIncludeEdge.Location = New-Object System.Drawing.Point(12, 92)
$checkIncludeEdge.Size = New-Object System.Drawing.Size(150, 20)
$checkIncludeEdge.Text = 'Include Edge'
$checkIncludeEdge.Checked = $false
$checkIncludeEdge.Font = $fontMain
$checkIncludeEdge.BackColor = [System.Drawing.Color]::White

$checkIncludePreview = New-Object System.Windows.Forms.CheckBox
$checkIncludePreview.Location = New-Object System.Drawing.Point(172, 92)
$checkIncludePreview.Size = New-Object System.Drawing.Size(150, 20)
$checkIncludePreview.Text = 'Include Preview'
$checkIncludePreview.Checked = $false
$checkIncludePreview.Font = $fontMain
$checkIncludePreview.BackColor = [System.Drawing.Color]::White

$labelPath = New-Object System.Windows.Forms.Label
$labelPath.Location = New-Object System.Drawing.Point(12, 48)
$labelPath.Size = New-Object System.Drawing.Size(150, 20)
$labelPath.Text = 'Download Path'
$labelPath.Font = $fontMain
$labelPath.BackColor = [System.Drawing.Color]::White

$textPath = New-Object System.Windows.Forms.TextBox
$textPath.Location = New-Object System.Drawing.Point(166, 44)
$textPath.Size = New-Object System.Drawing.Size(524, 23)
$textPath.Text = (Join-Path -Path $env:TEMP -ChildPath 'TSxCatalogDownloads')
$textPath.Font = $fontMain

$buttonBrowse = New-Object System.Windows.Forms.Button
$buttonBrowse.Location = New-Object System.Drawing.Point(796, 42)
$buttonBrowse.Size = New-Object System.Drawing.Size(90, 27)
$buttonBrowse.Text = 'Browse...'
$buttonBrowse.Font = $fontMain
$buttonBrowse.BackColor = $colorSecondaryButton
$buttonBrowse.ForeColor = $colorButtonText

$buttonDownload = New-Object System.Windows.Forms.Button
$buttonDownload.Location = New-Object System.Drawing.Point(890, 42)
$buttonDownload.Size = New-Object System.Drawing.Size(90, 27)
$buttonDownload.Text = 'Download'
$buttonDownload.Font = $fontMain
$buttonDownload.BackColor = $colorPrimaryButton
$buttonDownload.ForeColor = $colorButtonText

$buttonAbort = New-Object System.Windows.Forms.Button
$buttonAbort.Location = New-Object System.Drawing.Point(984, 42)
$buttonAbort.Size = New-Object System.Drawing.Size(90, 27)
$buttonAbort.Text = 'Abort'
$buttonAbort.Font = $fontMain
$buttonAbort.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#D64541')
$buttonAbort.ForeColor = [System.Drawing.Color]::White
$buttonAbort.Enabled = $false

$buttonClose = New-Object System.Windows.Forms.Button
$buttonClose.Location = New-Object System.Drawing.Point(1060, 646)
$buttonClose.Size = New-Object System.Drawing.Size(90, 27)
$buttonClose.Text = 'Close'
$buttonClose.Font = $fontMain
$buttonClose.BackColor = $colorSecondaryButton
$buttonClose.ForeColor = $colorButtonText
$buttonClose.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right

$progressDownloads = New-Object System.Windows.Forms.ProgressBar
$progressDownloads.Location = New-Object System.Drawing.Point(12, 118)
$progressDownloads.Size = New-Object System.Drawing.Size(1138, 18)
$progressDownloads.Anchor = 'Top,Left,Right'
$progressDownloads.Style = 'Continuous'
$progressDownloads.Minimum = 0
$progressDownloads.Maximum = 100
$progressDownloads.Value = 0
$progressDownloads.Visible = $false

$splitMain = New-Object System.Windows.Forms.SplitContainer
$splitMain.Location = New-Object System.Drawing.Point(12, 142)
$splitMain.Size = New-Object System.Drawing.Size(1138, 496)
$splitMain.Anchor = 'Top,Bottom,Left,Right'
$splitMain.Orientation = 'Horizontal'
$splitMain.SplitterDistance = 374

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
$colTitle.Width = 450

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
[void]$gridUpdates.Columns.Add($colArchitecture)

$textOutput = New-Object System.Windows.Forms.RichTextBox
$textOutput.Dock = 'Fill'
$textOutput.ReadOnly = $true
$textOutput.WordWrap = $false
$textOutput.BackColor = [System.Drawing.Color]::White
$textOutput.Font = $fontData
$script:OutputTextBox = $textOutput
$PSDefaultParameterValues['Add-TSxUiOutput:OutputTextBox'] = $script:OutputTextBox

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
[void]$form.Controls.Add($checkVerbose)
[void]$form.Controls.Add($checkLatestOnly)
[void]$form.Controls.Add($checkUseLegacyTranser)
[void]$form.Controls.Add($labelPath)
[void]$form.Controls.Add($textPath)
[void]$form.Controls.Add($buttonBrowse)
[void]$form.Controls.Add($buttonDownload)
[void]$form.Controls.Add($buttonAbort)
[void]$form.Controls.Add($buttonClose)
[void]$form.Controls.Add($checkIncludeCumulative)
[void]$form.Controls.Add($checkIncludeDotNet)
[void]$form.Controls.Add($checkIncludeSSU)
[void]$form.Controls.Add($checkIncludeDefender)
[void]$form.Controls.Add($checkIncludeEdge)
[void]$form.Controls.Add($checkIncludePreview)
[void]$form.Controls.Add($progressDownloads)
[void]$form.Controls.Add($splitMain)
[void]$form.Controls.Add($statusBar)

$bindingTable = New-Object System.Data.DataTable
[void]$bindingTable.Columns.Add('Select', [bool])
[void]$bindingTable.Columns.Add('IsGroup', [bool])
[void]$bindingTable.Columns.Add('LastUpdated', [string])
[void]$bindingTable.Columns.Add('KB', [string])
[void]$bindingTable.Columns.Add('Title', [string])
[void]$bindingTable.Columns.Add('Size', [string])
[void]$bindingTable.Columns.Add('Classification', [string])
[void]$bindingTable.Columns.Add('UpdateType', [string])
[void]$bindingTable.Columns.Add('UpdateId', [string])
[void]$bindingTable.Columns.Add('Architecture', [string])

$gridUpdates.DataSource = $bindingTable

$gridUpdates.Add_DataBindingComplete({
        if ($script:IsApplyingGridRowStyles) {
            return
        }

        $script:IsApplyingGridRowStyles = $true
        try {
        foreach ($gridRow in $gridUpdates.Rows) {
            $rowView = $gridRow.DataBoundItem -as [System.Data.DataRowView]
            if ($null -eq $rowView) {
                continue
            }

            if ([bool]$rowView.Row['IsGroup']) {
                $gridRow.ReadOnly = $true
                $gridRow.DefaultCellStyle.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#ECEFF1')
                $gridRow.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Black
                $gridRow.DefaultCellStyle.Font = $fontMain
                $gridRow.DefaultCellStyle.SelectionBackColor = [System.Drawing.ColorTranslator]::FromHtml('#ECEFF1')
                $gridRow.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::Black
            }
            else {
                $gridRow.ReadOnly = $false
            }
        }
        }
        finally {
            $script:IsApplyingGridRowStyles = $false
        }
    })

$buttonBrowse.Add_Click({
        $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderDialog.Description = 'Select download destination folder'
        $folderDialog.SelectedPath = $textPath.Text
        if ($folderDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $textPath.Text = $folderDialog.SelectedPath
        }
    })

$buttonClose.Add_Click({
        $form.Close()
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

            if (-not ($checkIncludeCumulative.Checked -or $checkIncludeDotNet.Checked -or $checkIncludeSSU.Checked -or $checkIncludeDefender.Checked -or $checkIncludeEdge.Checked -or $checkIncludePreview.Checked)) {
                [System.Windows.Forms.MessageBox]::Show('Select at least one update category.', 'Validation', 'OK', 'Warning') | Out-Null
                return
            }

            $statusLabel.Text = 'Searching updates...'
            [System.Windows.Forms.Application]::DoEvents()
            Write-TSxLog -Message ('Searching updates for {0} ({1})' -f $osText, $architecture)
            Add-TSxUiOutput -Message ('Searching updates for {0} ({1})' -f $osText, $architecture)

            $statusLabel.Text = 'Searching updates (collecting catalog progress in UI)...'
            Add-TSxUiOutput -Message 'Running catalog query with progress captured in UI (host progress hidden).'
            [System.Windows.Forms.Application]::DoEvents()

            $previousProgressPreference = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            $updates = @()
            $searchJob = $null
            try {
                $searchJob = Start-Job -ScriptBlock {
                    param(
                        [string]$ListScriptPath,
                        [string]$OperatingSystem,
                        [string]$Architecture,
                        [bool]$LatestOnly,
                        [bool]$Force,
                        [bool]$IncludeCumulative,
                        [bool]$IncludeDotNet,
                        [bool]$IncludeSSU,
                        [bool]$IncludeDefender,
                        [bool]$IncludeEdge,
                        [bool]$IncludePreview,
                        [bool]$UseVerbose
                    )

                    $env:TSX_EXECUTION_CONTEXT = 'Wrapper'
                    $ProgressPreference = 'SilentlyContinue'
                    & $ListScriptPath -OperatingSystem $OperatingSystem -Architecture $Architecture -LatestOnly:$LatestOnly -Force:$Force -IncludeCumulative:$IncludeCumulative -IncludeDotNet:$IncludeDotNet -IncludeSSU:$IncludeSSU -IncludeDefender:$IncludeDefender -IncludeEdge:$IncludeEdge -IncludePreview:$IncludePreview -NoProgress:$true -UiProgress:$true -InformationAction Continue -Verbose:$UseVerbose 4>&1 6>&1
                } -ArgumentList $listScriptPath, $osText, $architecture, $checkLatestOnly.Checked, $checkForce.Checked, $checkIncludeCumulative.Checked, $checkIncludeDotNet.Checked, $checkIncludeSSU.Checked, $checkIncludeDefender.Checked, $checkIncludeEdge.Checked, $checkIncludePreview.Checked, $checkVerbose.Checked

                $searchStartedAt = Get-Date
                $lastSearchHeartbeat = $searchStartedAt

                while ($searchJob.State -eq 'Running' -or $searchJob.State -eq 'NotStarted') {
                    $streamItems = @(Receive-Job -Job $searchJob -ErrorAction Stop)
                    foreach ($outputItem in $streamItems) {
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
                        elseif ($outputItem -is [psobject] -and $outputItem.PSObject.Properties['UpdateId']) {
                            $updates += $outputItem
                        }
                    }

                    if (((Get-Date) - $lastSearchHeartbeat).TotalSeconds -ge 2) {
                        $elapsedSearch = [int]((Get-Date) - $searchStartedAt).TotalSeconds
                        Add-TSxUiOutput -Message ('Search is running... {0}s elapsed' -f $elapsedSearch)
                        $lastSearchHeartbeat = Get-Date
                    }

                    [System.Windows.Forms.Application]::DoEvents()
                    [System.Threading.Thread]::Sleep(120)
                }

                $streamItems = @(Receive-Job -Job $searchJob -ErrorAction Stop)
                foreach ($outputItem in $streamItems) {
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
                    elseif ($outputItem -is [psobject] -and $outputItem.PSObject.Properties['UpdateId']) {
                        $updates += $outputItem
                    }
                }

                if ($searchJob.State -ne 'Completed') {
                    $reason = $searchJob.ChildJobs[0].JobStateInfo.Reason
                    if ($reason) { throw $reason }
                    throw ('Search job finished with unexpected state: {0}' -f $searchJob.State)
                }
            }
            finally {
                $ProgressPreference = $previousProgressPreference
                if ($searchJob) {
                    Remove-Job -Job $searchJob -Force -ErrorAction SilentlyContinue
                }
            }

            $bindingTable.Rows.Clear()
            $groupedUpdates = $updates |
            Group-Object -Property {
                if ($_.PSObject.Properties['UpdateType'] -and -not [string]::IsNullOrWhiteSpace([string]$_.UpdateType)) {
                    [string]$_.UpdateType
                }
                else {
                    'Other'
                }
            } |
            Sort-Object -Property Name

            foreach ($group in $groupedUpdates) {
                $groupRow = $bindingTable.NewRow()
                $groupRow['Select'] = $false
                $groupRow['IsGroup'] = $true
                $groupRow['LastUpdated'] = ''
                $groupRow['KB'] = ''
                $groupRow['Title'] = ('[{0}]' -f [string]$group.Name)
                $groupRow['Size'] = ''
                $groupRow['Classification'] = ''
                $groupRow['UpdateType'] = [string]$group.Name
                $groupRow['UpdateId'] = ''
                $groupRow['Architecture'] = ''
                [void]$bindingTable.Rows.Add($groupRow)

                foreach ($update in ($group.Group | Sort-Object -Property @{ Expression = { $_.LastUpdated }; Descending = $true }, @{ Expression = { $_.Title }; Descending = $false })) {
                    $row = $bindingTable.NewRow()
                    $row['Select'] = $false
                    $row['IsGroup'] = $false
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
            if (-not [bool]$row['IsGroup']) {
                $row['Select'] = $true
            }
        }
        $statusLabel.Text = 'All updates selected'
    })

$buttonClearSelection.Add_Click({
        foreach ($row in $bindingTable.Rows) {
            if (-not [bool]$row['IsGroup']) {
                $row['Select'] = $false
            }
        }
        $statusLabel.Text = 'Selection cleared'
    })

$buttonAbort.Add_Click({
        $script:CancelDownloadRequested = $true
        $statusLabel.Text = 'Cancelling active download...'
        Add-TSxUiOutput -Level 'WARN' -Message 'Abort requested by user.'

        if (Test-TSxJobRunning -JobCandidate $script:ActiveDownloadJob) {
            Stop-Job -Job $script:ActiveDownloadJob -ErrorAction SilentlyContinue
        }
    })

$buttonDownload.Add_Click({
        try {
            if (Test-TSxJobRunning -JobCandidate $script:ActiveDownloadJob) {
                [System.Windows.Forms.MessageBox]::Show('A download is already running.', 'Download In Progress', 'OK', 'Information') | Out-Null
                return
            }

            $downloadPath = $textPath.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($downloadPath)) {
                [System.Windows.Forms.MessageBox]::Show('Download path is required.', 'Validation', 'OK', 'Warning') | Out-Null
                return
            }

            $selectedRows = @($bindingTable.Rows | Where-Object { $_['Select'] -eq $true -and -not [bool]$_['IsGroup'] })
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
            Add-TSxUiOutput -Message ('Transfer mode: {0}' -f $(if ($checkUseLegacyTranser.Checked) { 'Legacy HTTP' } else { 'BITS with fallback' }))
            $statusLabel.Text = ('Downloading {0} updates...' -f $selectedUpdateCount)
            $script:CancelDownloadRequested = $false
            $buttonAbort.Enabled = $true
            $buttonDownload.Enabled = $false
            $buttonSearch.Enabled = $false
            [System.Windows.Forms.Application]::DoEvents()

            if ($PSCmdlet.ShouldProcess($downloadPath, ('Download {0} selected update(s)' -f $selectedUpdateCount))) {
                $downloadResults = @()
                $currentIndex = 0
                $wasAborted = $false
                foreach ($selectedUpdate in $selectedUpdates) {
                    if ($script:CancelDownloadRequested) {
                        $wasAborted = $true
                        break
                    }

                    $currentIndex++
                    $statusLabel.Text = ('Downloading update {0} of {1}...' -f $currentIndex, $selectedUpdateCount)
                    [System.Windows.Forms.Application]::DoEvents()

                    $updateDisplayLabel = if (-not [string]::IsNullOrWhiteSpace([string]$selectedUpdate.KB)) {
                        [string]$selectedUpdate.KB
                    }
                    elseif (-not [string]::IsNullOrWhiteSpace([string]$selectedUpdate.Title)) {
                        [string]$selectedUpdate.Title
                    }
                    else {
                        [string]$selectedUpdate.UpdateId
                    }

                    Add-TSxUiOutput -Message ('Downloading {0}/{1}: {2}' -f $currentIndex, $selectedUpdateCount, $updateDisplayLabel)
                    $previousProgressPreference = $ProgressPreference
                    $ProgressPreference = 'SilentlyContinue'
                    try {
                        $script:ActiveDownloadJob = Start-Job -ScriptBlock {
                            param(
                                [string]$DownloadScriptPath,
                                [psobject]$SelectedUpdate,
                                [string]$DownloadPath,
                                [bool]$UseForce,
                                [bool]$UseVerbose,
                                [bool]$UseLegacyTranser
                            )

                            $env:TSX_EXECUTION_CONTEXT = 'Wrapper'
                            $ProgressPreference = 'SilentlyContinue'
                            $SelectedUpdate | & $DownloadScriptPath -Path $DownloadPath -WhatIf:$false -Force:$UseForce -Verbose:$UseVerbose -UiProgress:$true -NoProgress:$true -UseLegacyTranser:$UseLegacyTranser -InformationAction Continue 4>&1 6>&1
                        } -ArgumentList $downloadScriptPath, $selectedUpdate, $downloadPath, $checkForce.Checked, $checkVerbose.Checked, $checkUseLegacyTranser.Checked

                        $downloadStartedAt = Get-Date
                        $lastDownloadHeartbeat = $downloadStartedAt

                        while (Test-TSxJobRunning -JobCandidate $script:ActiveDownloadJob) {
                            $activeJobSnapshot = $script:ActiveDownloadJob
                            if (-not ($activeJobSnapshot -is [System.Management.Automation.Job])) {
                                break
                            }

                            $streamItems = @(Receive-Job -Job $activeJobSnapshot -ErrorAction SilentlyContinue)
                            foreach ($outputItem in $streamItems) {
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
                                elseif ($outputItem -is [pscustomobject] -and $outputItem.PSObject.Properties['FileName']) {
                                    $downloadResults += $outputItem
                                    Add-TSxUiOutput -Message ('Result: {0} (Skipped={1}, Downloaded={2})' -f [string]$outputItem.FileName, [bool]$outputItem.WasSkipped, [bool]$outputItem.WasDownloaded)
                                }
                            }

                            if ($script:CancelDownloadRequested) {
                                $cancelJobSnapshot = $script:ActiveDownloadJob
                                if ($cancelJobSnapshot -is [System.Management.Automation.Job]) {
                                    Stop-Job -Job $cancelJobSnapshot -ErrorAction SilentlyContinue
                                }
                            }

                            if (((Get-Date) - $lastDownloadHeartbeat).TotalSeconds -ge 2) {
                                $elapsedDownload = [int]((Get-Date) - $downloadStartedAt).TotalSeconds
                                Add-TSxUiOutput -Message ('Download still running [{0}]... {1}s elapsed' -f $updateDisplayLabel, $elapsedDownload)
                                $lastDownloadHeartbeat = Get-Date
                            }

                            [System.Windows.Forms.Application]::DoEvents()
                            [System.Threading.Thread]::Sleep(120)
                        }

                        $finalJobSnapshot = $script:ActiveDownloadJob
                        $streamItems = @()
                        if ($finalJobSnapshot -is [System.Management.Automation.Job]) {
                            $streamItems = @(Receive-Job -Job $finalJobSnapshot -ErrorAction SilentlyContinue)
                        }
                        foreach ($outputItem in $streamItems) {
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
                            elseif ($outputItem -is [pscustomobject] -and $outputItem.PSObject.Properties['FileName']) {
                                $downloadResults += $outputItem
                                Add-TSxUiOutput -Message ('Result: {0} (Skipped={1}, Downloaded={2})' -f [string]$outputItem.FileName, [bool]$outputItem.WasSkipped, [bool]$outputItem.WasDownloaded)
                            }
                        }

                        if ($script:CancelDownloadRequested) {
                            $wasAborted = $true
                            Add-TSxUiOutput -Level 'WARN' -Message ('Download aborted while processing {0}.' -f $updateDisplayLabel)
                            break
                        }

                        if (($script:ActiveDownloadJob -is [System.Management.Automation.Job]) -and ([string]$script:ActiveDownloadJob.State -ne 'Completed')) {
                            $reason = $null
                            if ($script:ActiveDownloadJob.ChildJobs.Count -gt 0) {
                                $reason = $script:ActiveDownloadJob.ChildJobs[0].JobStateInfo.Reason
                            }
                            if ($reason) { throw $reason }
                            throw ('Download job finished with unexpected state: {0}' -f $script:ActiveDownloadJob.State)
                        }
                    }
                    finally {
                        $script:ActiveDownloadJob = Stop-TSxActiveDownloadJob -JobCandidate $script:ActiveDownloadJob
                        $ProgressPreference = $previousProgressPreference
                    }
                    [System.Windows.Forms.Application]::DoEvents()
                }

                $processedCount = @($downloadResults).Count
                $downloadedCount = @($downloadResults | Where-Object { $_.PSObject.Properties['WasDownloaded'] -and [bool]$_.WasDownloaded }).Count
                $skippedCount = @($downloadResults | Where-Object { $_.PSObject.Properties['WasSkipped'] -and [bool]$_.WasSkipped }).Count
                $missingResultCount = [Math]::Max(0, ($selectedUpdateCount - $processedCount))

                Write-TSxLog -Message ('Download summary: Selected={0}, ResultObjects={1}, Downloaded={2}, Skipped={3}, MissingResult={4}' -f $selectedUpdateCount, $processedCount, $downloadedCount, $skippedCount, $missingResultCount)
                Add-TSxUiOutput -Message ('Download summary: Selected={0}, Downloaded={1}, Skipped={2}, MissingResult={3}' -f $selectedUpdateCount, $downloadedCount, $skippedCount, $missingResultCount)
                if ($wasAborted) {
                    $statusLabel.Text = ('Aborted. Selected {0}, Downloaded {1}, Skipped {2}.' -f $selectedUpdateCount, $downloadedCount, $skippedCount)
                }
                else {
                    $statusLabel.Text = ('Done. Selected {0}, Downloaded {1}, Skipped {2}.' -f $selectedUpdateCount, $downloadedCount, $skippedCount)
                }
                $summaryMessage = [string]::Join([Environment]::NewLine, @(
                        ('Selected {0}' -f $selectedUpdateCount),
                        ('Downloaded {0}' -f $downloadedCount),
                        ('Skipped {0}' -f $skippedCount),
                        ('Missing result {0}' -f $missingResultCount),
                        ('Aborted {0}' -f $wasAborted)
                    ))
                [System.Windows.Forms.MessageBox]::Show($summaryMessage, 'Completed', 'OK', 'Information') | Out-Null
            }
        }
        catch {
            Write-TSxLog -Level 'ERROR' -Message $_.Exception.Message
            Add-TSxUiOutput -Level 'ERROR' -Message $_.Exception.Message
            $statusLabel.Text = 'Download failed'
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Download Failed', 'OK', 'Error') | Out-Null
        }
        finally {
            $script:ActiveDownloadJob = Stop-TSxActiveDownloadJob -JobCandidate $script:ActiveDownloadJob
            $buttonAbort.Enabled = $false
            $buttonDownload.Enabled = $true
            $buttonSearch.Enabled = $true
            $statusLabel.Text = $statusLabel.Text
        }
    })

$loadedSettings = Import-TSxUiSettings -SettingsFile $script:SettingsFile
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
    if ($loadedSettings.PSObject.Properties.Name -contains 'LatestOnly' -and $null -ne $loadedSettings.LatestOnly) {
        $checkLatestOnly.Checked = [bool]$loadedSettings.LatestOnly
    }
    if ($loadedSettings.PSObject.Properties.Name -contains 'Verbose' -and $null -ne $loadedSettings.Verbose) {
        $checkVerbose.Checked = [bool]$loadedSettings.Verbose
    }
    if ($loadedSettings.PSObject.Properties.Name -contains 'UseLegacyTranser' -and $null -ne $loadedSettings.UseLegacyTranser) {
        $checkUseLegacyTranser.Checked = [bool]$loadedSettings.UseLegacyTranser
    }
}

$form.Add_FormClosing({
    $script:ActiveDownloadJob = Stop-TSxActiveDownloadJob -JobCandidate $script:ActiveDownloadJob

    Save-TSxUiSettings -SettingsDirectory $script:SettingsDirectory -SettingsFile $script:SettingsFile -Settings ([pscustomobject]@{
            OperatingSystem   = $textOS.Text.Trim()
            Architecture      = [string]$comboArchitecture.SelectedItem
            DownloadPath      = $textPath.Text.Trim()
            Force             = $checkForce.Checked
            IncludeCumulative = $checkIncludeCumulative.Checked
            IncludeDotNet     = $checkIncludeDotNet.Checked
            IncludeSSU        = $checkIncludeSSU.Checked
            IncludeDefender   = $checkIncludeDefender.Checked
            IncludeEdge       = $checkIncludeEdge.Checked
            IncludePreview    = $checkIncludePreview.Checked
            LatestOnly        = $checkLatestOnly.Checked
            Verbose           = $checkVerbose.Checked
            UseLegacyTranser  = $checkUseLegacyTranser.Checked
        })
    })

[void]$form.ShowDialog()