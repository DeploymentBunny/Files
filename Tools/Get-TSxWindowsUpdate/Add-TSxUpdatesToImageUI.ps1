<#
.SYNOPSIS
    Windows Forms UI for injecting MSU updates into offline WIM and VHDX images.

.DESCRIPTION
    Provides a Windows Forms front end for Add-TSxUpdatesToImage.ps1.
    The UI supports selecting image path, update source path, WIM index, optional scratch directory,
    and WhatIf execution, and persists last used values between launches.

.PARAMETER Force
    When set, clears the current UI log file at startup.

.EXAMPLE
    .\Add-TSxUpdatesToImageUI.ps1 -Verbose

.NOTES
    FileName:    Add-TSxUpdatesToImageUI.ps1
    Version:     1.0.3
    Author:      Mikael Nystrom
    Contact:     @mikael_nystrom
    Created:     2026-05-26
    Updated:     2026-05-26
    Twitter:     @mikael_nystrom

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author.

.LINK
    https://www.deploymentbunny.com

.FUNCTIONALITY
    Starts a Windows Forms UI for offline image patching with MSU packages.
    Loads and saves last-used UI settings in %TEMP%\Get-TSxLatestWindowsUpdate\Settings.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [switch]$Force
)

Import-Module -Name (Join-Path $PSScriptRoot 'Modules\TSxWindowsUpdateUtility\TSxWindowsUpdateUtility.psd1') -Force -ErrorAction Stop

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

$scriptRoot = Split-Path -Path $PSCommandPath -Parent
$patchScriptPath = Join-Path -Path $scriptRoot -ChildPath 'Add-TSxUpdatesToImage.ps1'

if (-not (Test-Path -Path $patchScriptPath)) {
    throw ('Patching script not found: {0}' -f $patchScriptPath)
}

$scriptName = Split-Path -Path $PSCommandPath -Leaf
Start-TSxLog -FilePath $script:LogFilePath -Force:$Force
Write-TSxLog -Message ('{0} started' -f $scriptName)
Write-TSxLog -Message ('Force: {0}' -f $Force.IsPresent)
Write-TSxLog -Message ('Log root path: {0}' -f $script:LogRootPath)
Write-TSxLog -Message ('Log path: {0}' -f $script:LogFilePath)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Add-TSxUpdatesToImage'
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

$labelImage = New-Object System.Windows.Forms.Label
$labelImage.Location = New-Object System.Drawing.Point(12, 16)
$labelImage.Size = New-Object System.Drawing.Size(150, 20)
$labelImage.Text = 'Image Path'
$labelImage.Font = $fontMain
$labelImage.BackColor = [System.Drawing.Color]::White

$textImage = New-Object System.Windows.Forms.TextBox
$textImage.Location = New-Object System.Drawing.Point(166, 12)
$textImage.Size = New-Object System.Drawing.Size(620, 23)
$textImage.Font = $fontMain

$buttonBrowseImage = New-Object System.Windows.Forms.Button
$buttonBrowseImage.Location = New-Object System.Drawing.Point(796, 10)
$buttonBrowseImage.Size = New-Object System.Drawing.Size(90, 27)
$buttonBrowseImage.Text = 'Image...'
$buttonBrowseImage.Font = $fontMain
$buttonBrowseImage.BackColor = $colorSecondaryButton
$buttonBrowseImage.ForeColor = $colorButtonText

$labelUpdatePath = New-Object System.Windows.Forms.Label
$labelUpdatePath.Location = New-Object System.Drawing.Point(12, 48)
$labelUpdatePath.Size = New-Object System.Drawing.Size(150, 20)
$labelUpdatePath.Text = 'Update Path'
$labelUpdatePath.Font = $fontMain
$labelUpdatePath.BackColor = [System.Drawing.Color]::White

$textUpdatePath = New-Object System.Windows.Forms.TextBox
$textUpdatePath.Location = New-Object System.Drawing.Point(166, 44)
$textUpdatePath.Size = New-Object System.Drawing.Size(620, 23)
$textUpdatePath.Font = $fontMain

$buttonBrowseUpdates = New-Object System.Windows.Forms.Button
$buttonBrowseUpdates.Location = New-Object System.Drawing.Point(796, 42)
$buttonBrowseUpdates.Size = New-Object System.Drawing.Size(90, 27)
$buttonBrowseUpdates.Text = 'Updates...'
$buttonBrowseUpdates.Font = $fontMain
$buttonBrowseUpdates.BackColor = $colorSecondaryButton
$buttonBrowseUpdates.ForeColor = $colorButtonText

$buttonInject = New-Object System.Windows.Forms.Button
$buttonInject.Location = New-Object System.Drawing.Point(890, 42)
$buttonInject.Size = New-Object System.Drawing.Size(90, 27)
$buttonInject.Text = 'Inject'
$buttonInject.Font = $fontMain
$buttonInject.BackColor = $colorPrimaryButton
$buttonInject.ForeColor = $colorButtonText

$labelScratch = New-Object System.Windows.Forms.Label
$labelScratch.Location = New-Object System.Drawing.Point(12, 80)
$labelScratch.Size = New-Object System.Drawing.Size(150, 20)
$labelScratch.Text = 'Scratch Directory'
$labelScratch.Font = $fontMain
$labelScratch.BackColor = [System.Drawing.Color]::White

$textScratch = New-Object System.Windows.Forms.TextBox
$textScratch.Location = New-Object System.Drawing.Point(166, 76)
$textScratch.Size = New-Object System.Drawing.Size(620, 23)
$textScratch.Font = $fontMain

$buttonBrowseScratch = New-Object System.Windows.Forms.Button
$buttonBrowseScratch.Location = New-Object System.Drawing.Point(796, 74)
$buttonBrowseScratch.Size = New-Object System.Drawing.Size(90, 27)
$buttonBrowseScratch.Text = 'Scratch...'
$buttonBrowseScratch.Font = $fontMain
$buttonBrowseScratch.BackColor = $colorSecondaryButton
$buttonBrowseScratch.ForeColor = $colorButtonText

$labelIndex = New-Object System.Windows.Forms.Label
$labelIndex.Location = New-Object System.Drawing.Point(12, 112)
$labelIndex.Size = New-Object System.Drawing.Size(100, 20)
$labelIndex.Text = 'WIM Index'
$labelIndex.Font = $fontMain
$labelIndex.BackColor = [System.Drawing.Color]::White

$numericIndex = New-Object System.Windows.Forms.NumericUpDown
$numericIndex.Location = New-Object System.Drawing.Point(118, 108)
$numericIndex.Size = New-Object System.Drawing.Size(70, 23)
$numericIndex.Minimum = 1
$numericIndex.Maximum = 999
$numericIndex.Value = 1
$numericIndex.Font = $fontMain

$checkWhatIf = New-Object System.Windows.Forms.CheckBox
$checkWhatIf.Location = New-Object System.Drawing.Point(208, 110)
$checkWhatIf.Size = New-Object System.Drawing.Size(120, 20)
$checkWhatIf.Text = 'Use WhatIf'
$checkWhatIf.Checked = $false
$checkWhatIf.Font = $fontMain
$checkWhatIf.BackColor = [System.Drawing.Color]::White

$progressOperation = New-Object System.Windows.Forms.ProgressBar
$progressOperation.Location = New-Object System.Drawing.Point(12, 142)
$progressOperation.Size = New-Object System.Drawing.Size(1138, 18)
$progressOperation.Anchor = 'Top,Left,Right'
$progressOperation.Style = 'Continuous'
$progressOperation.Minimum = 0
$progressOperation.Maximum = 100
$progressOperation.Value = 0

$textOutput = New-Object System.Windows.Forms.RichTextBox
$textOutput.Location = New-Object System.Drawing.Point(12, 166)
$textOutput.Size = New-Object System.Drawing.Size(1138, 472)
$textOutput.Anchor = 'Top,Bottom,Left,Right'
$textOutput.ReadOnly = $true
$textOutput.WordWrap = $false
$textOutput.BackColor = [System.Drawing.Color]::White
$textOutput.Font = $fontData
$script:OutputTextBox = $textOutput
$PSDefaultParameterValues['Add-TSxUiOutput:OutputTextBox'] = $script:OutputTextBox

$statusBar = New-Object System.Windows.Forms.StatusStrip
$statusBar.Dock = 'Bottom'
$statusBar.BackColor = [System.Drawing.Color]::White
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = 'Ready'
$statusLabel.Font = $fontHeading
[void]$statusBar.Items.Add($statusLabel)

[void]$form.Controls.Add($labelImage)
[void]$form.Controls.Add($textImage)
[void]$form.Controls.Add($buttonBrowseImage)
[void]$form.Controls.Add($labelUpdatePath)
[void]$form.Controls.Add($textUpdatePath)
[void]$form.Controls.Add($buttonBrowseUpdates)
[void]$form.Controls.Add($buttonInject)
[void]$form.Controls.Add($labelScratch)
[void]$form.Controls.Add($textScratch)
[void]$form.Controls.Add($buttonBrowseScratch)
[void]$form.Controls.Add($labelIndex)
[void]$form.Controls.Add($numericIndex)
[void]$form.Controls.Add($checkWhatIf)
[void]$form.Controls.Add($progressOperation)
[void]$form.Controls.Add($textOutput)
[void]$form.Controls.Add($statusBar)

$buttonBrowseImage.Add_Click({
    $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $fileDialog.Title = 'Select image file'
    $fileDialog.Filter = 'Image files (*.wim;*.vhdx)|*.wim;*.vhdx|All files (*.*)|*.*'
    if (-not [string]::IsNullOrWhiteSpace($textImage.Text) -and (Test-Path -LiteralPath $textImage.Text -PathType Leaf)) {
        $fileDialog.FileName = $textImage.Text
    }

    if ($fileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $textImage.Text = $fileDialog.FileName
    }
})

$buttonBrowseUpdates.Add_Click({
    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderDialog.Description = 'Select update source folder'
    if (-not [string]::IsNullOrWhiteSpace($textUpdatePath.Text) -and (Test-Path -LiteralPath $textUpdatePath.Text -PathType Container)) {
        $folderDialog.SelectedPath = $textUpdatePath.Text
    }

    if ($folderDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $textUpdatePath.Text = $folderDialog.SelectedPath
    }
})

$buttonBrowseScratch.Add_Click({
    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderDialog.Description = 'Select optional scratch directory'
    if (-not [string]::IsNullOrWhiteSpace($textScratch.Text) -and (Test-Path -LiteralPath $textScratch.Text -PathType Container)) {
        $folderDialog.SelectedPath = $textScratch.Text
    }

    if ($folderDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $textScratch.Text = $folderDialog.SelectedPath
    }
})

$buttonInject.Add_Click({
    try {
        $imagePath = $textImage.Text.Trim()
        $updatePath = $textUpdatePath.Text.Trim()
        $scratchPath = $textScratch.Text.Trim()
        $indexValue = [int]$numericIndex.Value

        if ([string]::IsNullOrWhiteSpace($imagePath)) {
            [System.Windows.Forms.MessageBox]::Show('Image path is required.', 'Validation', 'OK', 'Warning') | Out-Null
            return
        }

        if (-not (Test-Path -LiteralPath $imagePath -PathType Leaf)) {
            [System.Windows.Forms.MessageBox]::Show('Image path does not exist.', 'Validation', 'OK', 'Warning') | Out-Null
            return
        }

        $imageExtension = ([System.IO.Path]::GetExtension($imagePath)).ToLowerInvariant()
        if ($imageExtension -notin @('.wim', '.vhdx')) {
            [System.Windows.Forms.MessageBox]::Show('Image must be .wim or .vhdx.', 'Validation', 'OK', 'Warning') | Out-Null
            return
        }

        if ([string]::IsNullOrWhiteSpace($updatePath)) {
            [System.Windows.Forms.MessageBox]::Show('Update path is required.', 'Validation', 'OK', 'Warning') | Out-Null
            return
        }

        if (-not (Test-Path -LiteralPath $updatePath)) {
            [System.Windows.Forms.MessageBox]::Show('Update path does not exist.', 'Validation', 'OK', 'Warning') | Out-Null
            return
        }

        if (-not [string]::IsNullOrWhiteSpace($scratchPath) -and -not (Test-Path -LiteralPath $scratchPath -PathType Container)) {
            [System.Windows.Forms.MessageBox]::Show('Scratch directory does not exist.', 'Validation', 'OK', 'Warning') | Out-Null
            return
        }

        $operationText = 'Inject updates into image'
        if ($PSCmdlet.ShouldProcess($imagePath, $operationText)) {
            $statusLabel.Text = 'Injecting updates...'
            $progressOperation.Style = 'Marquee'
            $progressOperation.MarqueeAnimationSpeed = 25
            $buttonInject.Enabled = $false
            [System.Windows.Forms.Application]::DoEvents()

            Add-TSxUiOutput -Message ('Starting patch operation: Image={0}, Updates={1}, Index={2}, WhatIf={3}' -f $imagePath, $updatePath, $indexValue, $checkWhatIf.Checked)
            Write-TSxLog -Message ('Starting patch operation: Image={0}, Updates={1}, Index={2}, WhatIf={3}' -f $imagePath, $updatePath, $indexValue, $checkWhatIf.Checked)

            $invokeParams = @{
                Image      = $imagePath
                UpdatePath = $updatePath
                Index      = $indexValue
                WhatIf     = $checkWhatIf.Checked
                Verbose    = $true
            }

            if (-not [string]::IsNullOrWhiteSpace($scratchPath)) {
                $invokeParams['ScratchDirectory'] = $scratchPath
            }

            $scriptOutput = @(& $patchScriptPath @invokeParams 4>&1)
            $resultObject = $null
            foreach ($outputItem in $scriptOutput) {
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
                    $resultObject = $outputItem
                }
            }

            if ($resultObject -and $resultObject.PSObject.Properties['Image']) {
                $summary = 'Completed: Image={0}; Type={1}; PackagesApplied={2}' -f [string]$resultObject.Image, [string]$resultObject.Type, [string]$resultObject.PackagesApplied
                Add-TSxUiOutput -Message $summary
                Write-TSxLog -Message $summary
            }

            $statusLabel.Text = 'Completed'
            [System.Windows.Forms.MessageBox]::Show('Image patch operation completed.', 'Completed', 'OK', 'Information') | Out-Null
        }
    }
    catch {
        Write-TSxLog -Level 'ERROR' -Message $_.Exception.Message
        Add-TSxUiOutput -Level 'ERROR' -Message $_.Exception.Message
        $statusLabel.Text = 'Failed'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Operation Failed', 'OK', 'Error') | Out-Null
    }
    finally {
        $progressOperation.Style = 'Continuous'
        $progressOperation.MarqueeAnimationSpeed = 0
        $progressOperation.Value = 0
        $buttonInject.Enabled = $true
    }
})

$loadedSettings = Import-TSxUiSettings -SettingsFile $script:SettingsFile
if ($loadedSettings) {
    if (-not [string]::IsNullOrWhiteSpace([string]$loadedSettings.ImagePath)) {
        $textImage.Text = [string]$loadedSettings.ImagePath
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$loadedSettings.UpdatePath)) {
        $textUpdatePath.Text = [string]$loadedSettings.UpdatePath
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$loadedSettings.ScratchDirectory)) {
        $textScratch.Text = [string]$loadedSettings.ScratchDirectory
    }

    if ($null -ne $loadedSettings.Index) {
        $loadedIndex = [int]$loadedSettings.Index
        if ($loadedIndex -lt $numericIndex.Minimum) {
            $loadedIndex = [int]$numericIndex.Minimum
        }
        if ($loadedIndex -gt $numericIndex.Maximum) {
            $loadedIndex = [int]$numericIndex.Maximum
        }
        $numericIndex.Value = $loadedIndex
    }

    if ($null -ne $loadedSettings.UseWhatIf) {
        $checkWhatIf.Checked = [bool]$loadedSettings.UseWhatIf
    }
}

$form.Add_FormClosing({
    try {
        $settings = [pscustomobject]@{
            ImagePath        = $textImage.Text.Trim()
            UpdatePath       = $textUpdatePath.Text.Trim()
            ScratchDirectory = $textScratch.Text.Trim()
            Index            = [int]$numericIndex.Value
            UseWhatIf        = $checkWhatIf.Checked
        }
        Save-TSxUiSettings -SettingsDirectory $script:SettingsDirectory -SettingsFile $script:SettingsFile -Settings $settings
    }
    catch {
        Write-TSxLog -Level 'WARN' -Message ('Failed to persist UI settings during close. Error: {0}' -f $_.Exception.Message)
    }
})

Add-TSxUiOutput -Message ('{0} started' -f $scriptName)
Add-TSxUiOutput -Message ('Log path: {0}' -f $script:LogFilePath)
[void]$form.ShowDialog()
