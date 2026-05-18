<#
.SYNOPSIS
    GUI launcher for Convert-TSxWIM2VHD.ps1.

.DESCRIPTION
    Convert-TSxWIM2VHDUI provides a Windows Forms interface that:
    - Self-elevates to local Administrator.
    - Lets you configure required and optional parameters for Convert-TSxWIM2VHD.ps1.
    - Runs conversion and streams verbose/warning/error output into the UI window.
    - Persists last-used settings in %LOCALAPPDATA%\DeploymentBunny.
    - Writes a per-run log file in %TEMP%.

.NOTES
    Version:     0.0.0.3

    Author - Mikael Nystrom
    Twitter: @mikael_nystrom

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author.
.LINK
    https://www.deploymentbunny.com
.EXAMPLE
    .\Convert-TSxWIM2VHDUI.ps1
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

$Script:ToolName = "Convert-TSxWIM2VHDUI"
$Script:TargetScriptPath = Join-Path $PSScriptRoot "Convert-TSxWIM2VHD.ps1"
$Script:IndexInfoScriptPath = Join-Path $PSScriptRoot "Get-TSxWimIndexInfo.ps1"
$Script:LogFolder = Join-Path $env:TEMP 'Convert-TSxWIMToVHD'
if (-not (Test-Path -LiteralPath $Script:LogFolder)) {
    New-Item -ItemType Directory -Path $Script:LogFolder -Force | Out-Null
}
$Script:LogFile = Join-Path $Script:LogFolder "$Script:ToolName.log"
$Script:RunUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$Script:SettingsDirectory = Join-Path $env:LOCALAPPDATA "DeploymentBunny"
$Script:SettingsFile = Join-Path $Script:SettingsDirectory "Convert-TSxWIM2VHDUI.settings.json"
$Script:LogoPath = $null
$Script:WimImages = @()

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

$localLogoCandidates = @(
    (Join-Path $PSScriptRoot 'deploymentbunnylogo.png'),
    (Join-Path $PSScriptRoot 'deploymentbunnylogo.jpg'),
    (Join-Path $PSScriptRoot 'deploymentbunnylogo.jpeg')
)

$resolvedLogo = $localLogoCandidates | Where-Object { Test-Path -Path $_ -PathType Leaf } | Select-Object -First 1
if ($null -ne $resolvedLogo) {
    $Script:LogoPath = $resolvedLogo
    Write-TSxLog -Message ("Using local logo file: {0}" -f $Script:LogoPath)
}
else {
    Write-TSxLog -Message "No local logo file found in this folder. Expected one of: deploymentbunnylogo.png, deploymentbunnylogo.jpg, deploymentbunnylogo.jpeg"
}

function Save-UISettings {
    try {
        if (-not (Test-Path -LiteralPath $Script:SettingsDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $Script:SettingsDirectory -Force | Out-Null
        }

        $settings = [PSCustomObject]@{
            Sourcefile         = $TextSourceFile.Text.Trim()
            DestinationFile    = $TextDestinationFile.Text.Trim()
            Disklayout         = [string]$ComboDisklayout.SelectedItem
            Index              = if ($null -ne $ComboImage.SelectedItem) { [int]$ComboImage.SelectedItem.ImageIndex } else { 0 }
            ImageName          = if ($null -ne $ComboImage.SelectedItem) { [string]$ComboImage.SelectedItem.ImageName } else { "" }
            SizeInMB           = [int]$NumericSize.Value
            VHDType            = [string]$ComboVHDType.SelectedItem
            PathtoSXSFolder    = $TextSXSFolder.Text.Trim()
            SXSFolderCopy      = $CheckSXSFolderCopy.Checked
            PathtoExtraFolder  = $TextExtraFolder.Text.Trim()
            PathtoPackagesFolder = $TextPackagesFolder.Text.Trim()
            Features           = $TextFeatures.Text.Trim()
            RemoveOldVHD       = $CheckRemoveOldVHD.Checked
            ShowVerbose        = $CheckVerbose.Checked
        }

        $settings | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $Script:SettingsFile -Encoding UTF8
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

function Update-SelectedImageInfo {
    $selectedImage = $ComboImage.SelectedItem
    if ($null -eq $selectedImage) {
        $LabelImageInfoValue.Text = "No image selected"
        return
    }

    $LabelImageInfoValue.Text = "Name: {0} | Size: {1} GB | Index: {2}" -f $selectedImage.ImageName, $selectedImage.ImageSizeGB, $selectedImage.ImageIndex
}

function Initialize-WimImages {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceFile,

        [int]$PreferredIndex = 0
    )

    $ComboImage.Items.Clear()
    $Script:WimImages = @()
    $LabelImageInfoValue.Text = "No image selected"

    if (-not (Test-Path -LiteralPath $Script:IndexInfoScriptPath -PathType Leaf)) {
        Write-TSxLog -Message ("Index info script not found: {0}" -f $Script:IndexInfoScriptPath)
        Show-TSxDialog -Message ("Could not find Get-TSxWimIndexInfo.ps1 at: {0}" -f $Script:IndexInfoScriptPath) -Title $Script:ToolName -Icon Error -Owner $Form
        return
    }

    if (-not (Test-Path -LiteralPath $SourceFile -PathType Leaf)) {
        return
    }

    try {
        $results = & $Script:IndexInfoScriptPath -WIMFile $SourceFile 2>&1
        $imageRows = @($results | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties.Name -contains 'ImageIndex' -and $_.PSObject.Properties.Name -contains 'ImageName' })

        if ($imageRows.Count -eq 0) {
            Show-TSxDialog -Message "No images were returned from the selected WIM file." -Title $Script:ToolName -Icon Warning -Owner $Form
            Write-TSxLog -Message ("No images returned for: {0}" -f $SourceFile)
            return
        }

        foreach ($row in $imageRows | Sort-Object ImageIndex) {
            $entry = [PSCustomObject]@{
                DisplayText = "{0}" -f $row.ImageName
                ImageName   = [string]$row.ImageName
                ImageIndex  = [int]$row.ImageIndex
                ImageSizeGB = [string]$row.ImageSizeGB
            }
            [void]$ComboImage.Items.Add($entry)
            $Script:WimImages += $entry
        }

        $ComboImage.DisplayMember = "DisplayText"

        $selected = $null
        if ($PreferredIndex -gt 0) {
            $selected = $Script:WimImages | Where-Object { $_.ImageIndex -eq $PreferredIndex } | Select-Object -First 1
        }

        if ($null -ne $selected) {
            $ComboImage.SelectedItem = $selected
        }
        elseif ($ComboImage.Items.Count -gt 0) {
            $ComboImage.SelectedIndex = 0
        }

        Update-SelectedImageInfo
        Write-TSxLog -Message ("Loaded {0} image entries from: {1}" -f $Script:WimImages.Count, $SourceFile)
    }
    catch {
        Write-TSxLog -Message ("Failed to populate image list. Error: {0}" -f $_.Exception.Message)
        Show-TSxDialog -Message ("Failed to read image information from WIM file. {0}" -f $_.Exception.Message) -Title $Script:ToolName -Icon Error -Owner $Form
    }
}

function Invoke-ConvertWimToVhd {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Form]$Owner
    )

    if (-not (Test-Path -LiteralPath $Script:TargetScriptPath -PathType Leaf)) {
        Show-TSxDialog -Message ("Could not find Convert-TSxWIM2VHD.ps1 at: {0}" -f $Script:TargetScriptPath) -Title $Script:ToolName -Icon Error -Owner $Owner
        return
    }

    $sourceFile = $TextSourceFile.Text.Trim()
    $destinationFile = $TextDestinationFile.Text.Trim()
    $disklayout = [string]$ComboDisklayout.SelectedItem
    $selectedImage = $ComboImage.SelectedItem
    $index = if ($null -ne $selectedImage) { [int]$selectedImage.ImageIndex } else { 0 }
    $sizeInMB = [int]$NumericSize.Value
    $vhdType = [string]$ComboVHDType.SelectedItem
    $pathToSXSFolder = $TextSXSFolder.Text.Trim()
    $pathToExtraFolder = $TextExtraFolder.Text.Trim()
    $pathToPackagesFolder = $TextPackagesFolder.Text.Trim()
    $featuresRaw = $TextFeatures.Text.Trim()
    $removeOldVHD = $CheckRemoveOldVHD.Checked
    $sxsFolderCopy = $CheckSXSFolderCopy.Checked
    $showVerbose = $CheckVerbose.Checked

    if ([string]::IsNullOrWhiteSpace($sourceFile)) {
        Show-TSxDialog -Message "Source WIM file is required." -Title $Script:ToolName -Icon Warning -Owner $Owner
        return
    }

    if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
        Show-TSxDialog -Message ("Source WIM file not found: {0}" -f $sourceFile) -Title $Script:ToolName -Icon Warning -Owner $Owner
        return
    }

    if ([string]::IsNullOrWhiteSpace($destinationFile)) {
        Show-TSxDialog -Message "Destination VHD/VHDX file is required." -Title $Script:ToolName -Icon Warning -Owner $Owner
        return
    }

    if ([string]::IsNullOrWhiteSpace($disklayout)) {
        Show-TSxDialog -Message "Disk layout is required." -Title $Script:ToolName -Icon Warning -Owner $Owner
        return
    }

    if ([string]::IsNullOrWhiteSpace($vhdType)) {
        Show-TSxDialog -Message "VHD type is required." -Title $Script:ToolName -Icon Warning -Owner $Owner
        return
    }

    if ($index -le 0) {
        Show-TSxDialog -Message "Please select an image from the WIM image list." -Title $Script:ToolName -Icon Warning -Owner $Owner
        return
    }

    $features = @()
    if (-not [string]::IsNullOrWhiteSpace($featuresRaw)) {
        $features = @($featuresRaw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    if ($features.Count -gt 0 -and [string]::IsNullOrWhiteSpace($pathToSXSFolder)) {
        Show-TSxDialog -Message "Features require Path to SXS folder." -Title $Script:ToolName -Icon Warning -Owner $Owner
        return
    }

    $ButtonRun.Enabled = $false
    $Owner.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $TextOutput.Clear()

    $LabelStatus.Text = "Running conversion..."
    Add-OutputLine -Text ("[{0}] Starting conversion..." -f (Get-Date -Format "HH:mm:ss"))

    $runSummary = "Sourcefile={0}; DestinationFile={1}; Disklayout={2}; Index={3}; SizeInMB={4}; VHDType={5}; RemoveOldVHD={6}; ShowVerbose={7}" -f $sourceFile, $destinationFile, $disklayout, $index, $sizeInMB, $vhdType, $removeOldVHD, $showVerbose
    Write-TSxLog -Message ("Starting run. {0}" -f $runSummary)

    try {
        $params = @{
            Sourcefile      = $sourceFile
            DestinationFile = $destinationFile
            Disklayout      = $disklayout
            Index           = $index
            SizeInMB        = $sizeInMB
            VHDType         = $vhdType
            Verbose         = $showVerbose
        }

        if ($removeOldVHD) {
            $params.RemoveOldVHD = $true
        }

        if ($sxsFolderCopy) {
            $params.SXSFolderCopy = $true
        }

        if (-not [string]::IsNullOrWhiteSpace($pathToSXSFolder)) {
            $params.PathtoSXSFolder = $pathToSXSFolder
        }

        if (-not [string]::IsNullOrWhiteSpace($pathToExtraFolder)) {
            $params.PathtoExtraFolder = $pathToExtraFolder
        }

        if (-not [string]::IsNullOrWhiteSpace($pathToPackagesFolder)) {
            $params.PathtoPackagesFolder = $pathToPackagesFolder
        }

        if ($features.Count -gt 0) {
            $params.Features = $features
        }

        $stream = & $Script:TargetScriptPath @params 3>&1 4>&1 6>&1 2>&1

        $returnedVhd = $null
        foreach ($item in $stream) {
            if ($item -is [System.Management.Automation.VerboseRecord]) {
                if ($showVerbose) {
                    Add-OutputLine -Text ("VERBOSE: {0}" -f $item.Message)
                }
                continue
            }

            if ($item -is [System.Management.Automation.WarningRecord]) {
                Add-OutputLine -Text ("WARNING: {0}" -f $item.Message)
                continue
            }

            if ($item -is [System.Management.Automation.ErrorRecord]) {
                Add-OutputLine -Text ("ERROR: {0}" -f $item.Exception.Message)
                continue
            }

            if ($item -is [System.Management.Automation.InformationRecord]) {
                Add-OutputLine -Text ("INFO: {0}" -f $item.MessageData)
                continue
            }

            if ($item -is [string]) {
                if (-not [string]::IsNullOrWhiteSpace($item)) {
                    Add-OutputLine -Text $item
                    $returnedVhd = $item
                }
                continue
            }

            if ($null -ne $item) {
                Add-OutputLine -Text ([string]$item)
            }
        }

        $LabelStatus.Text = "Completed"
        Add-OutputLine -Text ("[{0}] Conversion completed." -f (Get-Date -Format "HH:mm:ss"))

        if (-not [string]::IsNullOrWhiteSpace($returnedVhd)) {
            Add-OutputLine -Text ("Output VHD: {0}" -f $returnedVhd)
            Write-TSxLog -Message ("Run completed successfully. Output VHD: {0}" -f $returnedVhd)
        }
        else {
            Write-TSxLog -Message "Run completed successfully. No output VHD path returned."
        }
    }
    catch {
        $LabelStatus.Text = "Run failed"
        Add-OutputLine -Text ("ERROR: {0}" -f $_.Exception.Message)
        Write-TSxLog -Message ("Run failed with exception: {0}" -f $_.Exception.Message)
        Show-TSxDialog -Message ("Failed to run Convert-TSxWIM2VHD.ps1. {0}`r`n`r`nLog: {1}" -f $_.Exception.Message, $Script:LogFile) -Title $Script:ToolName -Icon Error -Owner $Owner
    }
    finally {
        $Owner.Cursor = [System.Windows.Forms.Cursors]::Default
        $ButtonRun.Enabled = $true
    }
}

$Form = New-Object System.Windows.Forms.Form
$Form.Size = New-Object System.Drawing.Size(1024, 700)
$Form.MinimumSize = New-Object System.Drawing.Size(900, 580)
$Form.Text = "Convert TSx WIM to VHD UI"
$Form.StartPosition = "CenterScreen"
$Form.TopMost = $false
$Form.BackColor = [System.Drawing.Color]::White

$LabelTitle = New-Object System.Windows.Forms.Label
$LabelTitle.AutoSize = $true
$LabelTitle.Location = New-Object System.Drawing.Point(20, 30)
$LabelTitle.Font = New-Object System.Drawing.Font("Consolas", 11, [System.Drawing.FontStyle]::Bold)
$LabelTitle.Text = "Convert WIM to bootable VHD/VHDX"

$PictureBoxLogo = New-Object System.Windows.Forms.PictureBox
$PictureBoxLogo.Location = New-Object System.Drawing.Point(850, 6)
$PictureBoxLogo.Size = New-Object System.Drawing.Size(250, 78)
$PictureBoxLogo.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
if (Test-Path -Path $Script:LogoPath) {
    $PictureBoxLogo.ImageLocation = $Script:LogoPath
}

$LabelSourceFile = New-Object System.Windows.Forms.Label
$LabelSourceFile.AutoSize = $true
$LabelSourceFile.Location = New-Object System.Drawing.Point(20, 98)
$LabelSourceFile.Font = New-Object System.Drawing.Font("Consolas", 10)
$LabelSourceFile.Text = "Source WIM file:"

$TextSourceFile = New-Object System.Windows.Forms.TextBox
$TextSourceFile.Location = New-Object System.Drawing.Point(190, 95)
$TextSourceFile.Size = New-Object System.Drawing.Size(790, 26)
$TextSourceFile.Font = New-Object System.Drawing.Font("Consolas", 10)

$ButtonBrowseSource = New-Object System.Windows.Forms.Button
$ButtonBrowseSource.Location = New-Object System.Drawing.Point(990, 93)
$ButtonBrowseSource.Size = New-Object System.Drawing.Size(170, 32)
$ButtonBrowseSource.Text = "Browse"
$ButtonBrowseSource.Font = New-Object System.Drawing.Font("Consolas", 10)

$LabelDestinationFile = New-Object System.Windows.Forms.Label
$LabelDestinationFile.AutoSize = $true
$LabelDestinationFile.Location = New-Object System.Drawing.Point(20, 133)
$LabelDestinationFile.Font = New-Object System.Drawing.Font("Consolas", 10)
$LabelDestinationFile.Text = "VHDX file:"

$TextDestinationFile = New-Object System.Windows.Forms.TextBox
$TextDestinationFile.Location = New-Object System.Drawing.Point(190, 130)
$TextDestinationFile.Size = New-Object System.Drawing.Size(790, 26)
$TextDestinationFile.Font = New-Object System.Drawing.Font("Consolas", 10)

$ButtonBrowseDestination = New-Object System.Windows.Forms.Button
$ButtonBrowseDestination.Location = New-Object System.Drawing.Point(990, 128)
$ButtonBrowseDestination.Size = New-Object System.Drawing.Size(170, 32)
$ButtonBrowseDestination.Text = "Browse"
$ButtonBrowseDestination.Font = New-Object System.Drawing.Font("Consolas", 10)

$LabelDisklayout = New-Object System.Windows.Forms.Label
$LabelDisklayout.AutoSize = $true
$LabelDisklayout.Location = New-Object System.Drawing.Point(20, 173)
$LabelDisklayout.Font = New-Object System.Drawing.Font("Consolas", 10)
$LabelDisklayout.Text = "Disklayout:"

$ComboDisklayout = New-Object System.Windows.Forms.ComboBox
$ComboDisklayout.Location = New-Object System.Drawing.Point(120, 169)
$ComboDisklayout.Size = New-Object System.Drawing.Size(130, 28)
$ComboDisklayout.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$ComboDisklayout.Font = New-Object System.Drawing.Font("Consolas", 10)
[void]$ComboDisklayout.Items.AddRange(@("BIOS", "UEFI", "COMBO"))
$ComboDisklayout.SelectedItem = "UEFI"

$LabelImage = New-Object System.Windows.Forms.Label
$LabelImage.AutoSize = $true
$LabelImage.Location = New-Object System.Drawing.Point(275, 173)
$LabelImage.Font = New-Object System.Drawing.Font("Consolas", 10)
$LabelImage.Text = "Image:"

$ComboImage = New-Object System.Windows.Forms.ComboBox
$ComboImage.Location = New-Object System.Drawing.Point(340, 169)
$ComboImage.Size = New-Object System.Drawing.Size(335, 28)
$ComboImage.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$ComboImage.Font = New-Object System.Drawing.Font("Consolas", 10)

$LabelSize = New-Object System.Windows.Forms.Label
$LabelSize.AutoSize = $true
$LabelSize.Location = New-Object System.Drawing.Point(690, 173)
$LabelSize.Font = New-Object System.Drawing.Font("Consolas", 10)
$LabelSize.Text = "SizeInMB:"

$NumericSize = New-Object System.Windows.Forms.NumericUpDown
$NumericSize.Location = New-Object System.Drawing.Point(780, 169)
$NumericSize.Size = New-Object System.Drawing.Size(140, 26)
$NumericSize.Font = New-Object System.Drawing.Font("Consolas", 10)
$NumericSize.Minimum = 1024
$NumericSize.Maximum = 4194304
$NumericSize.Value = 120000

$LabelVHDType = New-Object System.Windows.Forms.Label
$LabelVHDType.AutoSize = $true
$LabelVHDType.Location = New-Object System.Drawing.Point(935, 173)
$LabelVHDType.Font = New-Object System.Drawing.Font("Consolas", 10)
$LabelVHDType.Text = "VHDType:"

$ComboVHDType = New-Object System.Windows.Forms.ComboBox
$ComboVHDType.Location = New-Object System.Drawing.Point(1020, 169)
$ComboVHDType.Size = New-Object System.Drawing.Size(80, 28)
$ComboVHDType.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$ComboVHDType.Font = New-Object System.Drawing.Font("Consolas", 10)
[void]$ComboVHDType.Items.AddRange(@("EXPANDABLE", "FIXED"))
$ComboVHDType.SelectedItem = "EXPANDABLE"

$LabelImageInfo = New-Object System.Windows.Forms.Label
$LabelImageInfo.AutoSize = $true
$LabelImageInfo.Location = New-Object System.Drawing.Point(20, 208)
$LabelImageInfo.Font = New-Object System.Drawing.Font("Consolas", 10)
$LabelImageInfo.Text = "Selected image:"

$LabelImageInfoValue = New-Object System.Windows.Forms.Label
$LabelImageInfoValue.AutoSize = $false
$LabelImageInfoValue.Location = New-Object System.Drawing.Point(165, 208)
$LabelImageInfoValue.Size = New-Object System.Drawing.Size(935, 20)
$LabelImageInfoValue.Font = New-Object System.Drawing.Font("Consolas", 10)
$LabelImageInfoValue.Text = "No image selected"

$CheckRemoveOldVHD = New-Object System.Windows.Forms.CheckBox
$CheckRemoveOldVHD.AutoSize = $true
$CheckRemoveOldVHD.Location = New-Object System.Drawing.Point(23, 233)
$CheckRemoveOldVHD.Font = New-Object System.Drawing.Font("Consolas", 10)
$CheckRemoveOldVHD.Text = "RemoveOldVHD"
$CheckRemoveOldVHD.Checked = $false

$CheckVerbose = New-Object System.Windows.Forms.CheckBox
$CheckVerbose.AutoSize = $true
$CheckVerbose.Location = New-Object System.Drawing.Point(190, 233)
$CheckVerbose.Font = New-Object System.Drawing.Font("Consolas", 10)
$CheckVerbose.Text = "Verbose"
$CheckVerbose.Checked = $true

$LabelSXSFolder = New-Object System.Windows.Forms.Label
$LabelSXSFolder.AutoSize = $true
$LabelSXSFolder.Location = New-Object System.Drawing.Point(20, 283)
$LabelSXSFolder.Font = New-Object System.Drawing.Font("Consolas", 10)
$LabelSXSFolder.Text = "Path to SXS Folder:"

$TextSXSFolder = New-Object System.Windows.Forms.TextBox
$TextSXSFolder.Location = New-Object System.Drawing.Point(190, 280)
$TextSXSFolder.Size = New-Object System.Drawing.Size(790, 26)
$TextSXSFolder.Font = New-Object System.Drawing.Font("Consolas", 10)

$ButtonBrowseSXS = New-Object System.Windows.Forms.Button
$ButtonBrowseSXS.Location = New-Object System.Drawing.Point(990, 278)
$ButtonBrowseSXS.Size = New-Object System.Drawing.Size(170, 32)
$ButtonBrowseSXS.Text = "Browse"
$ButtonBrowseSXS.Font = New-Object System.Drawing.Font("Consolas", 10)

$CheckSXSFolderCopy = New-Object System.Windows.Forms.CheckBox
$CheckSXSFolderCopy.AutoSize = $true
$CheckSXSFolderCopy.Location = New-Object System.Drawing.Point(340, 233)
$CheckSXSFolderCopy.Font = New-Object System.Drawing.Font("Consolas", 10)
$CheckSXSFolderCopy.Text = "Copy the SxS Folder to the VHDX File"
$CheckSXSFolderCopy.Checked = $false

$LabelFeatures = New-Object System.Windows.Forms.Label
$LabelFeatures.AutoSize = $true
$LabelFeatures.Location = New-Object System.Drawing.Point(20, 423)
$LabelFeatures.Font = New-Object System.Drawing.Font("Consolas", 10)
$LabelFeatures.Text = "Features (comma separated):"

$TextFeatures = New-Object System.Windows.Forms.TextBox
$TextFeatures.Location = New-Object System.Drawing.Point(300, 420)
$TextFeatures.Size = New-Object System.Drawing.Size(800, 26)
$TextFeatures.Font = New-Object System.Drawing.Font("Consolas", 10)

$LabelExtraFolder = New-Object System.Windows.Forms.Label
$LabelExtraFolder.AutoSize = $true
$LabelExtraFolder.Location = New-Object System.Drawing.Point(20, 353)
$LabelExtraFolder.Font = New-Object System.Drawing.Font("Consolas", 10)
$LabelExtraFolder.Text = "Path to Extra Folder:"

$TextExtraFolder = New-Object System.Windows.Forms.TextBox
$TextExtraFolder.Location = New-Object System.Drawing.Point(190, 350)
$TextExtraFolder.Size = New-Object System.Drawing.Size(790, 26)
$TextExtraFolder.Font = New-Object System.Drawing.Font("Consolas", 10)

$ButtonBrowseExtra = New-Object System.Windows.Forms.Button
$ButtonBrowseExtra.Location = New-Object System.Drawing.Point(990, 348)
$ButtonBrowseExtra.Size = New-Object System.Drawing.Size(170, 32)
$ButtonBrowseExtra.Text = "Browse"
$ButtonBrowseExtra.Font = New-Object System.Drawing.Font("Consolas", 10)

$LabelPackagesFolder = New-Object System.Windows.Forms.Label
$LabelPackagesFolder.AutoSize = $true
$LabelPackagesFolder.Location = New-Object System.Drawing.Point(20, 388)
$LabelPackagesFolder.Font = New-Object System.Drawing.Font("Consolas", 10)
$LabelPackagesFolder.Text = "Path to Packages Folder:"

$TextPackagesFolder = New-Object System.Windows.Forms.TextBox
$TextPackagesFolder.Location = New-Object System.Drawing.Point(190, 385)
$TextPackagesFolder.Size = New-Object System.Drawing.Size(790, 26)
$TextPackagesFolder.Font = New-Object System.Drawing.Font("Consolas", 10)

$ButtonBrowsePackages = New-Object System.Windows.Forms.Button
$ButtonBrowsePackages.Location = New-Object System.Drawing.Point(990, 383)
$ButtonBrowsePackages.Size = New-Object System.Drawing.Size(170, 32)
$ButtonBrowsePackages.Text = "Browse"
$ButtonBrowsePackages.Font = New-Object System.Drawing.Font("Consolas", 10)

$ButtonRun = New-Object System.Windows.Forms.Button
$ButtonRun.Location = New-Object System.Drawing.Point(760, 458)
$ButtonRun.Size = New-Object System.Drawing.Size(170, 32)
$ButtonRun.Text = "Run"
$ButtonRun.Font = New-Object System.Drawing.Font("Consolas", 10)

$ButtonReset = New-Object System.Windows.Forms.Button
$ButtonReset.Location = New-Object System.Drawing.Point(875, 458)
$ButtonReset.Size = New-Object System.Drawing.Size(170, 32)
$ButtonReset.Text = "Reset"
$ButtonReset.Font = New-Object System.Drawing.Font("Consolas", 10)

$ButtonExit = New-Object System.Windows.Forms.Button
$ButtonExit.Location = New-Object System.Drawing.Point(990, 458)
$ButtonExit.Size = New-Object System.Drawing.Size(170, 32)
$ButtonExit.Text = "Exit"
$ButtonExit.Font = New-Object System.Drawing.Font("Consolas", 10)

$LabelOutputHeader = New-Object System.Windows.Forms.Label
$LabelOutputHeader.AutoSize = $true
$LabelOutputHeader.Location = New-Object System.Drawing.Point(20, 518)
$LabelOutputHeader.Font = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
$LabelOutputHeader.Text = "Run output"

$TextOutput = New-Object System.Windows.Forms.TextBox
$TextOutput.Location = New-Object System.Drawing.Point(23, 541)
$TextOutput.Size = New-Object System.Drawing.Size(1077, 170)
$TextOutput.Multiline = $true
$TextOutput.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$TextOutput.ReadOnly = $true
$TextOutput.Font = New-Object System.Drawing.Font("Consolas", 9)

$LabelStatus = New-Object System.Windows.Forms.Label
$LabelStatus.AutoSize = $false
$LabelStatus.Location = New-Object System.Drawing.Point(23, 718)
$LabelStatus.Size = New-Object System.Drawing.Size(1077, 35)
$LabelStatus.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$LabelStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$LabelStatus.Font = New-Object System.Drawing.Font("Consolas", 10)
$LabelStatus.Text = "Ready"

$Form.Controls.AddRange(@(
    $LabelTitle,
    $PictureBoxLogo,
    $LabelSourceFile,
    $TextSourceFile,
    $ButtonBrowseSource,
    $LabelDestinationFile,
    $TextDestinationFile,
    $ButtonBrowseDestination,
    $LabelDisklayout,
    $ComboDisklayout,
    $LabelImage,
    $ComboImage,
    $LabelSize,
    $NumericSize,
    $LabelVHDType,
    $ComboVHDType,
    $LabelImageInfo,
    $LabelImageInfoValue,
    $CheckRemoveOldVHD,
    $CheckVerbose,
    $LabelSXSFolder,
    $TextSXSFolder,
    $ButtonBrowseSXS,
    $CheckSXSFolderCopy,
    $LabelFeatures,
    $TextFeatures,
    $LabelExtraFolder,
    $TextExtraFolder,
    $ButtonBrowseExtra,
    $LabelPackagesFolder,
    $TextPackagesFolder,
    $ButtonBrowsePackages,
    $ButtonRun,
    $ButtonReset,
    $ButtonExit,
    $LabelOutputHeader,
    $TextOutput,
    $LabelStatus
))

$loadedSettings = Import-UISettings
if ($loadedSettings) {
    if (-not [string]::IsNullOrWhiteSpace([string]$loadedSettings.Sourcefile)) { $TextSourceFile.Text = [string]$loadedSettings.Sourcefile }
    if (-not [string]::IsNullOrWhiteSpace([string]$loadedSettings.DestinationFile)) { $TextDestinationFile.Text = [string]$loadedSettings.DestinationFile }
    if (-not [string]::IsNullOrWhiteSpace([string]$loadedSettings.Disklayout) -and $ComboDisklayout.Items.Contains([string]$loadedSettings.Disklayout)) { $ComboDisklayout.SelectedItem = [string]$loadedSettings.Disklayout }
    if ($null -ne $loadedSettings.SizeInMB) {
        $sizeValue = [int]$loadedSettings.SizeInMB
        if ($sizeValue -lt [int]$NumericSize.Minimum) { $sizeValue = [int]$NumericSize.Minimum }
        if ($sizeValue -gt [int]$NumericSize.Maximum) { $sizeValue = [int]$NumericSize.Maximum }
        $NumericSize.Value = $sizeValue
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$loadedSettings.VHDType) -and $ComboVHDType.Items.Contains([string]$loadedSettings.VHDType)) { $ComboVHDType.SelectedItem = [string]$loadedSettings.VHDType }
    if (-not [string]::IsNullOrWhiteSpace([string]$loadedSettings.PathtoSXSFolder)) { $TextSXSFolder.Text = [string]$loadedSettings.PathtoSXSFolder }
    if ($null -ne $loadedSettings.SXSFolderCopy) { $CheckSXSFolderCopy.Checked = [bool]$loadedSettings.SXSFolderCopy }
    if (-not [string]::IsNullOrWhiteSpace([string]$loadedSettings.PathtoExtraFolder)) { $TextExtraFolder.Text = [string]$loadedSettings.PathtoExtraFolder }
    if (-not [string]::IsNullOrWhiteSpace([string]$loadedSettings.PathtoPackagesFolder)) { $TextPackagesFolder.Text = [string]$loadedSettings.PathtoPackagesFolder }
    if ($null -ne $loadedSettings.Features) { $TextFeatures.Text = [string]$loadedSettings.Features }
    if ($null -ne $loadedSettings.RemoveOldVHD) { $CheckRemoveOldVHD.Checked = [bool]$loadedSettings.RemoveOldVHD }
    if ($null -ne $loadedSettings.ShowVerbose) { $CheckVerbose.Checked = [bool]$loadedSettings.ShowVerbose }

    if (-not [string]::IsNullOrWhiteSpace($TextSourceFile.Text) -and (Test-Path -LiteralPath $TextSourceFile.Text -PathType Leaf)) {
        $preferredIndex = if ($null -ne $loadedSettings.Index) { [int]$loadedSettings.Index } else { 0 }
        Initialize-WimImages -SourceFile $TextSourceFile.Text -PreferredIndex $preferredIndex
    }
}

$ButtonBrowseSource.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Select source WIM file"
    $dialog.Filter = "WIM files (*.wim)|*.wim|All files (*.*)|*.*"
    $dialog.CheckFileExists = $true
    $dialog.Multiselect = $false
    if ($dialog.ShowDialog($Form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $TextSourceFile.Text = $dialog.FileName
        Initialize-WimImages -SourceFile $dialog.FileName
    }
})

$ComboImage.Add_SelectedIndexChanged({
    Update-SelectedImageInfo
})

$ButtonBrowseDestination.Add_Click({
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = "Select destination VHD/VHDX"
    $dialog.Filter = "VHDX files (*.vhdx)|*.vhdx|VHD files (*.vhd)|*.vhd|All files (*.*)|*.*"
    $dialog.AddExtension = $true
    if ($dialog.ShowDialog($Form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $TextDestinationFile.Text = $dialog.FileName
    }
})

$ButtonBrowseSXS.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Select SXS source folder"
    $dialog.ShowNewFolderButton = $true
    if ($dialog.ShowDialog($Form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $TextSXSFolder.Text = $dialog.SelectedPath
    }
})

$ButtonBrowseExtra.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Select extra folder"
    $dialog.ShowNewFolderButton = $true
    if ($dialog.ShowDialog($Form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $TextExtraFolder.Text = $dialog.SelectedPath
    }
})

$ButtonBrowsePackages.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Select packages folder"
    $dialog.ShowNewFolderButton = $true
    if ($dialog.ShowDialog($Form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $TextPackagesFolder.Text = $dialog.SelectedPath
    }
})

$ButtonRun.Add_Click({
    Save-UISettings
    Invoke-ConvertWimToVhd -Owner $Form
})

$ButtonReset.Add_Click({
    $TextSourceFile.Text = ""
    $TextDestinationFile.Text = ""
    $ComboDisklayout.SelectedItem = "UEFI"
    $ComboImage.Items.Clear()
    $LabelImageInfoValue.Text = "No image selected"
    $NumericSize.Value = 120000
    $ComboVHDType.SelectedItem = "EXPANDABLE"
    $TextSXSFolder.Text = ""
    $CheckSXSFolderCopy.Checked = $false
    $TextExtraFolder.Text = ""
    $TextPackagesFolder.Text = ""
    $TextFeatures.Text = ""
    $CheckRemoveOldVHD.Checked = $false
    $CheckVerbose.Checked = $true
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
    Save-UISettings
})

$ButtonExit.Add_Click({
    $Form.Close()
})

Write-TSxLog -Message "Convert-TSxWIM2VHDUI started"
[void]$Form.ShowDialog()
