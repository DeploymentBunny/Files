<#
.SYNOPSIS
    GUI launcher for Export/Import/Copy Windows roles and features scripts.

.DESCRIPTION
    Invoke-WindowsRolesAndFeaturesUI provides a Windows Forms interface that:
    - Runs Export-WindowsRolesAndFeatures.ps1, Import-WindowsRolesAndFeatures.ps1,
      or Copy-WindowsRolesAndFeatures.ps1 asynchronously.
    - Displays script output, warnings, and errors in a UI output pane.
    - Supports Verbose and WhatIf toggles.
    - Supports RelaxedMode, source media path, and JSON data file paths.
    - Persists settings to %LOCALAPPDATA%\DeploymentBunny.
    - Writes a per-run log file in %TEMP%.

.EXAMPLE
    .\Invoke-WindowsRolesAndFeaturesUI.ps1

.NOTES
    FileName:    Invoke-WindowsRolesAndFeaturesUI.ps1
    Author:      Mikael Nystrom
    Contact:     deploymentbunny@outlook.com
    Created:     2026-04-24
    Updated:     2026-04-27
    Twitter:     @mikael_nystrom

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author.
.LINK
    https://www.deploymentbunny.com
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Script:ToolName = "Invoke-WindowsRolesAndFeaturesUI"
$Script:LogFile = Join-Path $env:TEMP ("{0}_{1}.log" -f $Script:ToolName, (Get-Date -Format "yyyyMMdd_HHmmss"))
$Script:RunUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$Script:SettingsDirectory = Join-Path $env:LOCALAPPDATA "DeploymentBunny"
$Script:SettingsFile = Join-Path $Script:SettingsDirectory "Invoke-WindowsRolesAndFeaturesUI.settings.json"
$Script:Runner = $null
$Script:RunnerHandle = $null
$Script:RunnerOutput = $null
$Script:OutputIndex = 0
$Script:IsRunning = $false
$Script:IsSyncingActionTab = $false
$Script:TabControlMap = @{}
$Script:SourceCredential = $null
$Script:DestinationCredential = $null
$Script:ErrorReported = $false
$Script:CopyTempJsonFile = $null

$Font1 = [System.Drawing.Font]::new("Arial", 9, [System.Drawing.FontStyle]::Regular)
$FontHeading1 = [System.Drawing.Font]::new("Arial", 10, [System.Drawing.FontStyle]::Bold)
$FontHeading2 = [System.Drawing.Font]::new("Arial", 14, [System.Drawing.FontStyle]::Bold)
$FontData = [System.Drawing.Font]::new("Courier New", 9)

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
        [AllowEmptyString()]
        [string]$Text
    )

    $TextOutput.AppendText($Text + [Environment]::NewLine)
}

function Convert-OutputItemToText {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $text = ($InputObject | Out-String -Width 240).TrimEnd()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return ([string]$InputObject)
    }

    return $text
}

function Write-OutputItem {
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

function Export-UISettings {
    try {
        if (-not (Test-Path -LiteralPath $Script:SettingsDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $Script:SettingsDirectory -Force | Out-Null
        }

        $settings = [PSCustomObject]@{
            Action             = [string]$ComboAction.SelectedItem
            Export             = [PSCustomObject]@{
                JSONConfigFile = Get-TabText -Action 'Export' -Name 'TextJsonFile'
                ComputerName   = Get-TabText -Action 'Export' -Name 'TextComputerName'
                JsonDepth      = Get-TabText -Action 'Export' -Name 'TextJsonDepth'
            }
            Import             = [PSCustomObject]@{
                JSONConfigFile     = Get-TabText -Action 'Import' -Name 'TextJsonFile'
                ComputerName       = Get-TabText -Action 'Import' -Name 'TextComputerName'
                SourcePath         = Get-TabText -Action 'Import' -Name 'TextSourcePath'
                FeatureNameMapText = Get-TabText -Action 'Import' -Name 'TextFeatureMap'
            }
            Copy               = [PSCustomObject]@{
                JSONConfigFile     = Get-TabText -Action 'Copy' -Name 'TextJsonFile'
                SourceServer       = Get-TabText -Action 'Copy' -Name 'TextSourceServer'
                DestinationServer  = Get-TabText -Action 'Copy' -Name 'TextDestinationServer'
                SourcePath         = Get-TabText -Action 'Copy' -Name 'TextSourcePath'
                FeatureNameMapText = Get-TabText -Action 'Copy' -Name 'TextFeatureMap'
            }
            Deploy             = [PSCustomObject]@{
                JSONConfigFile     = Get-TabText -Action 'Deploy' -Name 'TextJsonFile'
                DestinationServer  = Get-TabText -Action 'Deploy' -Name 'TextDestinationServer'
                SourcePath         = Get-TabText -Action 'Deploy' -Name 'TextSourcePath'
                FeatureNameMapText = Get-TabText -Action 'Deploy' -Name 'TextFeatureMap'
                ThrottleLimit      = Get-TabText -Action 'Deploy' -Name 'TextThrottleLimit'
            }
            Verbose            = $CheckVerbose.Checked
            WhatIf             = $CheckWhatIf.Checked
            PassThru           = $CheckPassThru.Checked
            RelaxedMode        = $CheckRelaxed.Checked
            KeepJSONConfigFile = $CheckKeepJson.Checked
            RestartIfNeeded    = $CheckRestartIfNeeded.Checked
        }

        $settings | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $Script:SettingsFile -Encoding UTF8
        Write-TSxLog -Message ("Settings saved: {0}" -f $Script:SettingsFile)
    }
    catch {
        Write-TSxLog -Message ("Failed to save settings. Error: {0}" -f $_.Exception.Message)
    }
}

function Get-LogoImage {
    try {
        $toolsRoot = Split-Path -Path $PSScriptRoot -Parent
        $logoSourceScript = Join-Path $toolsRoot "Start-VIADeDupJob\Invoke-TSxDeDupJobUI.ps1"

        if (-not (Test-Path -LiteralPath $logoSourceScript -PathType Leaf)) {
            return $null
        }

        $content = Get-Content -LiteralPath $logoSourceScript -Raw
        $match = [regex]::Match($content, '\$PictureString\s*=\s*"(?<b64>[^"]+)"')
        if (-not $match.Success) {
            return $null
        }

        $bytes = [Convert]::FromBase64String($match.Groups['b64'].Value)
        $stream = New-Object System.IO.MemoryStream(,$bytes)
        return [System.Drawing.Image]::FromStream($stream)
    }
    catch {
        Write-TSxLog -Message ("Failed to load logo image. Error: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Update-ActionUI {
    $action = $ComboAction.SelectedItem

    $isExport  = $action -eq "Export"
    $isImport  = $action -eq "Import"
    $isCopy    = $action -eq "Copy"
    $isDeploy  = $action -eq "Deploy"
    $CheckRelaxed.Enabled          = $isImport -or $isCopy -or $isDeploy
    $CheckKeepJson.Enabled         = $isCopy
    $CheckRestartIfNeeded.Enabled  = $isImport -or $isCopy -or $isDeploy
}

function Get-TabControl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not $Script:TabControlMap.ContainsKey($Action)) {
        return $null
    }

    $controls = $Script:TabControlMap[$Action]
    if (-not $controls.ContainsKey($Name)) {
        return $null
    }

    return $controls[$Name]
}

function Get-TabText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $control = Get-TabControl -Action $Action -Name $Name
    if ($null -eq $control) {
        return ""
    }

    return [string]$control.Text
}

function Set-TabText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$Value
    )

    $control = Get-TabControl -Action $Action -Name $Name
    if ($null -ne $control) {
        $control.Text = [string]$Value
    }
}

function Update-CredentialStateLabels {
    $sourceText = if ($Script:SourceCredential) {
        "Credential: $($Script:SourceCredential.UserName)"
    }
    else {
        "Credential: (not set)"
    }

    $destinationText = if ($Script:DestinationCredential) {
        "DestCred: $($Script:DestinationCredential.UserName)"
    }
    else {
        "DestCred: (not set)"
    }

    foreach ($action in $Script:TabControlMap.Keys) {
        $sourceLabel = Get-TabControl -Action $action -Name 'LabelSourceCredState'
        if ($null -ne $sourceLabel) {
            $sourceLabel.Text = $sourceText
        }

        $destinationLabel = Get-TabControl -Action $action -Name 'LabelDestCredState'
        if ($null -ne $destinationLabel) {
            $destinationLabel.Text = $destinationText
        }
    }
}

function Convert-FeatureMapTextToHashtable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $map = @{}

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $map
    }

    $entries = $Text -split ';'
    foreach ($entry in $entries) {
        $pair = $entry.Trim()
        if ([string]::IsNullOrWhiteSpace($pair)) {
            continue
        }

        $parts = $pair -split '=', 2
        if ($parts.Count -ne 2) {
            throw "Invalid FeatureNameMap entry '$pair'. Use format OldFeature=NewFeature;Old2=New2"
        }

        $key = $parts[0].Trim()
        $value = $parts[1].Trim()

        if ([string]::IsNullOrWhiteSpace($key) -or [string]::IsNullOrWhiteSpace($value)) {
            throw "Invalid FeatureNameMap entry '$pair'. Key and value must not be empty."
        }

        $map[$key] = $value
    }

    return $map
}

function New-InvocationContext {
    $action = [string]$ComboAction.SelectedItem

    if ($action -eq 'Copy') {
        $tempName = "RolesAndFeatures_{0}.json" -f ([System.Guid]::NewGuid().ToString('N'))
        $jsonFile = Join-Path ([System.IO.Path]::GetTempPath()) $tempName
        $Script:CopyTempJsonFile = $jsonFile
    }
    else {
        $jsonFile = (Get-TabText -Action $action -Name 'TextJsonFile').Trim()
        if ([string]::IsNullOrWhiteSpace($jsonFile)) {
            throw "JSONConfigFile is required."
        }
    }

    $scriptPath = switch ($action) {
        "Export" { Join-Path $PSScriptRoot "Export-WindowsRolesAndFeatures.ps1" }
        "Import" { Join-Path $PSScriptRoot "Import-WindowsRolesAndFeatures.ps1" }
        "Copy"   { Join-Path $PSScriptRoot "Copy-WindowsRolesAndFeatures.ps1" }
        "Deploy" { Join-Path $PSScriptRoot "Deploy-WindowsRolesAndFeatures.ps1" }
        default { throw "Unsupported action '$action'." }
    }

    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Script not found: $scriptPath"
    }

    $invokeParams = @{
        JSONConfigFile = $jsonFile
    }

    if ($CheckVerbose.Checked) { $invokeParams.Verbose = $true }
    if ($CheckWhatIf.Checked) { $invokeParams.WhatIf = $true }
    if ($CheckPassThru.Checked) { $invokeParams.PassThru = $true }

    switch ($action) {
        "Export" {
            $computerName = Get-TabText -Action 'Export' -Name 'TextComputerName'
            if (-not [string]::IsNullOrWhiteSpace($computerName)) {
                $invokeParams.ComputerName = $computerName.Trim()
            }

            if ($Script:SourceCredential) {
                $invokeParams.Credential = $Script:SourceCredential
            }

            $jsonDepth = Get-TabText -Action 'Export' -Name 'TextJsonDepth'
            if (-not [string]::IsNullOrWhiteSpace($jsonDepth)) {
                $invokeParams.JsonDepth = [int]$jsonDepth.Trim()
            }
        }
        "Import" {
            $computerName = Get-TabText -Action 'Import' -Name 'TextComputerName'
            if (-not [string]::IsNullOrWhiteSpace($computerName)) {
                $invokeParams.ComputerName = $computerName.Trim()
            }

            if ($Script:SourceCredential) {
                $invokeParams.Credential = $Script:SourceCredential
            }

            if ($CheckRelaxed.Checked) {
                $invokeParams.RelaxedMode = $true
            }

            $sourcePath = Get-TabText -Action 'Import' -Name 'TextSourcePath'
            if (-not [string]::IsNullOrWhiteSpace($sourcePath)) {
                $invokeParams.Source = $sourcePath.Trim()
            }

            $featureMap = Convert-FeatureMapTextToHashtable -Text (Get-TabText -Action 'Import' -Name 'TextFeatureMap')
            if ($featureMap.Count -gt 0) {
                $invokeParams.FeatureNameMap = $featureMap
            }

            if ($CheckRestartIfNeeded.Checked) {
                $invokeParams.Restart = $true
            }
        }
        "Copy" {
            $sourceServer = Get-TabText -Action 'Copy' -Name 'TextSourceServer'
            if (-not [string]::IsNullOrWhiteSpace($sourceServer)) {
                $invokeParams.SourceServer = $sourceServer.Trim()
            }

            $destinationServerText = Get-TabText -Action 'Copy' -Name 'TextDestinationServer'
            if ([string]::IsNullOrWhiteSpace($destinationServerText)) {
                throw "DestinationServer is required for Copy action."
            }

            $destinations = @(
                $destinationServerText.Split(',') |
                    ForEach-Object { $_.Trim() } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )

            if ($destinations.Count -eq 0) {
                throw "DestinationServer is required for Copy action."
            }

            $invokeParams.DestinationServer = $destinations

            if ($Script:SourceCredential) {
                $invokeParams.SourceCredential = $Script:SourceCredential
            }

            if ($Script:DestinationCredential) {
                $invokeParams.DestinationCredential = $Script:DestinationCredential
            }

            if ($CheckRelaxed.Checked) {
                $invokeParams.RelaxedMode = $true
            }

            $sourcePath = Get-TabText -Action 'Copy' -Name 'TextSourcePath'
            if (-not [string]::IsNullOrWhiteSpace($sourcePath)) {
                $invokeParams.Source = $sourcePath.Trim()
            }

            $featureMap = Convert-FeatureMapTextToHashtable -Text (Get-TabText -Action 'Copy' -Name 'TextFeatureMap')
            if ($featureMap.Count -gt 0) {
                $invokeParams.FeatureNameMap = $featureMap
            }

            if ($CheckKeepJson.Checked) {
                $invokeParams.KeepJSONConfigFile = $true
            }
        }
        "Deploy" {
            $destinationServerText = Get-TabText -Action 'Deploy' -Name 'TextDestinationServer'
            if ([string]::IsNullOrWhiteSpace($destinationServerText)) {
                throw "DestinationServer is required for Deploy action."
            }

            $destinations = @(
                $destinationServerText.Split(',') |
                    ForEach-Object { $_.Trim() } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )

            if ($destinations.Count -eq 0) {
                throw "DestinationServer is required for Deploy action."
            }

            $invokeParams.DestinationServer = $destinations

            if ($Script:DestinationCredential) {
                $invokeParams.Credential = $Script:DestinationCredential
            }

            if ($CheckRelaxed.Checked) {
                $invokeParams.RelaxedMode = $true
            }

            $sourcePath = Get-TabText -Action 'Deploy' -Name 'TextSourcePath'
            if (-not [string]::IsNullOrWhiteSpace($sourcePath)) {
                $invokeParams.Source = $sourcePath.Trim()
            }

            $featureMap = Convert-FeatureMapTextToHashtable -Text (Get-TabText -Action 'Deploy' -Name 'TextFeatureMap')
            if ($featureMap.Count -gt 0) {
                $invokeParams.FeatureNameMap = $featureMap
            }

            $throttleText = Get-TabText -Action 'Deploy' -Name 'TextThrottleLimit'
            if (-not [string]::IsNullOrWhiteSpace($throttleText)) {
                $throttle = 0
                if ([int]::TryParse($throttleText.Trim(), [ref]$throttle) -and $throttle -gt 0) {
                    $invokeParams.ThrottleLimit = $throttle
                }
            }

            if ($CheckRestartIfNeeded.Checked) {
                $invokeParams.RestartIfNeeded = $true
            }
        }
    }

    return [PSCustomObject]@{
        Action = $action
        ScriptPath = $scriptPath
        Params = $invokeParams
    }
}

Write-TSxLog -Message "UI started"

$Form = New-Object System.Windows.Forms.Form
$Form.Text = "Windows Roles and Features UI"
$Form.StartPosition = "CenterScreen"
$Form.Size = New-Object System.Drawing.Size(1024, 700)
$Form.MinimumSize = New-Object System.Drawing.Size(900, 580)
$Form.BackColor = [System.Drawing.Color]::White

$LabelTitle = New-Object System.Windows.Forms.Label
$LabelTitle.Location = New-Object System.Drawing.Point(16, 12)
$LabelTitle.Size = New-Object System.Drawing.Size(830, 24)
$LabelTitle.Text = "Export / Import / Copy / Deploy Windows Roles and Features"
$LabelTitle.Font = $FontHeading2
$LabelTitle.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($LabelTitle)

$LogoImage = Get-LogoImage
$PictureBox = New-Object System.Windows.Forms.PictureBox
$PictureBox.Location = New-Object System.Drawing.Point(900, 4)
$PictureBox.Size = New-Object System.Drawing.Size(150, 70)
$PictureBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
$PictureBox.BackColor = [System.Drawing.Color]::White
if ($LogoImage) {
    $PictureBox.Image = $LogoImage
}
$Form.Controls.Add($PictureBox)

$ButtonRun = New-Object System.Windows.Forms.Button
$ButtonRun.Location = New-Object System.Drawing.Point(16, 80)
$ButtonRun.Size = New-Object System.Drawing.Size(170, 32)
$ButtonRun.Text = "Run"
$ButtonRun.Font = $FontHeading1
$ButtonRun.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#F35800")
$ButtonRun.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#1c1d1d")
$Form.Controls.Add($ButtonRun)

$ButtonClose = New-Object System.Windows.Forms.Button
$ButtonClose.Location = New-Object System.Drawing.Point(186, 80)
$ButtonClose.Size = New-Object System.Drawing.Size(170, 32)
$ButtonClose.Text = "Close"
$ButtonClose.Font = $FontHeading1
$Form.Controls.Add($ButtonClose)

$ButtonReset = New-Object System.Windows.Forms.Button
$ButtonReset.Location = New-Object System.Drawing.Point(296, 80)
$ButtonReset.Size = New-Object System.Drawing.Size(170, 32)
$ButtonReset.Text = "Reset"
$ButtonReset.Font = $FontHeading1
$Form.Controls.Add($ButtonReset)

$LabelStatus = New-Object System.Windows.Forms.Label
$LabelStatus.Location = New-Object System.Drawing.Point(410, 88)
$LabelStatus.Size = New-Object System.Drawing.Size(460, 22)
$LabelStatus.Text = "Ready"
$LabelStatus.Font = $FontHeading1
$LabelStatus.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($LabelStatus)

$GroupConfig = New-Object System.Windows.Forms.GroupBox
$GroupConfig.Location = New-Object System.Drawing.Point(16, 124)
$GroupConfig.Size = New-Object System.Drawing.Size(1034, 260)
$GroupConfig.Text = "Configuration"
$GroupConfig.Font = $FontHeading1
$Form.Controls.Add($GroupConfig)

$ComboAction = New-Object System.Windows.Forms.ComboBox
$ComboAction.Location = New-Object System.Drawing.Point(12, 12)
$ComboAction.Size = New-Object System.Drawing.Size(200, 24)
$ComboAction.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$ComboAction.Items.AddRange(@("Export", "Import", "Copy", "Deploy"))
$ComboAction.SelectedIndex = 0
$GroupConfig.Controls.Add($ComboAction)

$ComboAction.Visible = $false

$TabActions = New-Object System.Windows.Forms.TabControl
$TabActions.Location = New-Object System.Drawing.Point(12, 24)
$TabActions.Size = New-Object System.Drawing.Size(1010, 228)
$TabActions.Font = $Font1
$GroupConfig.Controls.Add($TabActions)

$TabPageExport = New-Object System.Windows.Forms.TabPage
$TabPageExport.Text = "Export"
[void]$TabActions.TabPages.Add($TabPageExport)

$TabPageImport = New-Object System.Windows.Forms.TabPage
$TabPageImport.Text = "Import"
[void]$TabActions.TabPages.Add($TabPageImport)

$TabPageCopy = New-Object System.Windows.Forms.TabPage
$TabPageCopy.Text = "Copy"
[void]$TabActions.TabPages.Add($TabPageCopy)

$TabPageDeploy = New-Object System.Windows.Forms.TabPage
$TabPageDeploy.Text = "Deploy"
[void]$TabActions.TabPages.Add($TabPageDeploy)

$LabelComputerNameExport = New-Object System.Windows.Forms.Label
$LabelComputerNameExport.Location = New-Object System.Drawing.Point(8, 10)
$LabelComputerNameExport.Size = New-Object System.Drawing.Size(180, 22)
$LabelComputerNameExport.Text = "Computername"
$LabelComputerNameExport.Font = $Font1
$TabPageExport.Controls.Add($LabelComputerNameExport)

$TextComputerNameExport = New-Object System.Windows.Forms.TextBox
$TextComputerNameExport.Location = New-Object System.Drawing.Point(195, 6)
$TextComputerNameExport.Size = New-Object System.Drawing.Size(390, 23)
$TextComputerNameExport.Font = $Font1
$TabPageExport.Controls.Add($TextComputerNameExport)

$ButtonSourceCredentialExport = New-Object System.Windows.Forms.Button
$ButtonSourceCredentialExport.Location = New-Object System.Drawing.Point(605, 4)
$ButtonSourceCredentialExport.Size = New-Object System.Drawing.Size(170, 32)
$ButtonSourceCredentialExport.Text = "Set Credential"
$ButtonSourceCredentialExport.Font = $Font1
$TabPageExport.Controls.Add($ButtonSourceCredentialExport)

$LabelSourceCredStateExport = New-Object System.Windows.Forms.Label
$LabelSourceCredStateExport.Location = New-Object System.Drawing.Point(762, 10)
$LabelSourceCredStateExport.Size = New-Object System.Drawing.Size(230, 22)
$LabelSourceCredStateExport.Text = "Credential: (not set)"
$LabelSourceCredStateExport.Font = $Font1
$TabPageExport.Controls.Add($LabelSourceCredStateExport)

$LabelJsonFileExport = New-Object System.Windows.Forms.Label
$LabelJsonFileExport.Location = New-Object System.Drawing.Point(8, 48)
$LabelJsonFileExport.Size = New-Object System.Drawing.Size(180, 22)
$LabelJsonFileExport.Text = "JSON Configuration File"
$LabelJsonFileExport.Font = $Font1
$TabPageExport.Controls.Add($LabelJsonFileExport)

$TextJsonFileExport = New-Object System.Windows.Forms.TextBox
$TextJsonFileExport.Location = New-Object System.Drawing.Point(195, 44)
$TextJsonFileExport.Size = New-Object System.Drawing.Size(680, 23)
$TextJsonFileExport.Font = $Font1
$TextJsonFileExport.Text = "C:\\Temp\\RolesAndFeatures.json"
$TabPageExport.Controls.Add($TextJsonFileExport)

$ButtonBrowseJsonExport = New-Object System.Windows.Forms.Button
$ButtonBrowseJsonExport.Location = New-Object System.Drawing.Point(882, 42)
$ButtonBrowseJsonExport.Size = New-Object System.Drawing.Size(170, 32)
$ButtonBrowseJsonExport.Text = "Browse..."
$ButtonBrowseJsonExport.Font = $Font1
$ButtonBrowseJsonExport.Tag = $TextJsonFileExport
$TabPageExport.Controls.Add($ButtonBrowseJsonExport)

$LabelJsonDepthExport = New-Object System.Windows.Forms.Label
$LabelJsonDepthExport.Location = New-Object System.Drawing.Point(8, 124)
$LabelJsonDepthExport.Size = New-Object System.Drawing.Size(180, 22)
$LabelJsonDepthExport.Text = "JsonDepth"
$LabelJsonDepthExport.Font = $Font1
$LabelJsonDepthExport.Visible = $false
$TabPageExport.Controls.Add($LabelJsonDepthExport)

$TextJsonDepthExport = New-Object System.Windows.Forms.TextBox
$TextJsonDepthExport.Location = New-Object System.Drawing.Point(195, 120)
$TextJsonDepthExport.Size = New-Object System.Drawing.Size(80, 23)
$TextJsonDepthExport.Font = $Font1
$TextJsonDepthExport.Text = "10"
$TextJsonDepthExport.Visible = $false
$TabPageExport.Controls.Add($TextJsonDepthExport)

$LabelComputerNameImport = New-Object System.Windows.Forms.Label
$LabelComputerNameImport.Location = New-Object System.Drawing.Point(8, 10)
$LabelComputerNameImport.Size = New-Object System.Drawing.Size(180, 22)
$LabelComputerNameImport.Text = "Computername"
$LabelComputerNameImport.Font = $Font1
$TabPageImport.Controls.Add($LabelComputerNameImport)

$TextComputerNameImport = New-Object System.Windows.Forms.TextBox
$TextComputerNameImport.Location = New-Object System.Drawing.Point(195, 6)
$TextComputerNameImport.Size = New-Object System.Drawing.Size(390, 23)
$TextComputerNameImport.Font = $Font1
$TabPageImport.Controls.Add($TextComputerNameImport)

$ButtonSourceCredentialImport = New-Object System.Windows.Forms.Button
$ButtonSourceCredentialImport.Location = New-Object System.Drawing.Point(605, 4)
$ButtonSourceCredentialImport.Size = New-Object System.Drawing.Size(170, 32)
$ButtonSourceCredentialImport.Text = "Set Credential"
$ButtonSourceCredentialImport.Font = $Font1
$TabPageImport.Controls.Add($ButtonSourceCredentialImport)

$LabelSourceCredStateImport = New-Object System.Windows.Forms.Label
$LabelSourceCredStateImport.Location = New-Object System.Drawing.Point(802, 10)
$LabelSourceCredStateImport.Size = New-Object System.Drawing.Size(190, 22)
$LabelSourceCredStateImport.Text = "SourceCred: (not set)"
$LabelSourceCredStateImport.Font = $Font1
$TabPageImport.Controls.Add($LabelSourceCredStateImport)

$LabelJsonFileImport = New-Object System.Windows.Forms.Label
$LabelJsonFileImport.Location = New-Object System.Drawing.Point(8, 48)
$LabelJsonFileImport.Size = New-Object System.Drawing.Size(180, 22)
$LabelJsonFileImport.Text = "JSON Configuration File"
$LabelJsonFileImport.Font = $Font1
$TabPageImport.Controls.Add($LabelJsonFileImport)

$TextJsonFileImport = New-Object System.Windows.Forms.TextBox
$TextJsonFileImport.Location = New-Object System.Drawing.Point(195, 44)
$TextJsonFileImport.Size = New-Object System.Drawing.Size(680, 23)
$TextJsonFileImport.Font = $Font1
$TextJsonFileImport.Text = "C:\\Temp\\RolesAndFeatures.json"
$TabPageImport.Controls.Add($TextJsonFileImport)

$ButtonBrowseJsonImport = New-Object System.Windows.Forms.Button
$ButtonBrowseJsonImport.Location = New-Object System.Drawing.Point(882, 42)
$ButtonBrowseJsonImport.Size = New-Object System.Drawing.Size(170, 32)
$ButtonBrowseJsonImport.Text = "Browse..."
$ButtonBrowseJsonImport.Font = $Font1
$ButtonBrowseJsonImport.Tag = $TextJsonFileImport
$TabPageImport.Controls.Add($ButtonBrowseJsonImport)

$LabelSourcePathImport = New-Object System.Windows.Forms.Label
$LabelSourcePathImport.Location = New-Object System.Drawing.Point(8, 86)
$LabelSourcePathImport.Size = New-Object System.Drawing.Size(180, 22)
$LabelSourcePathImport.Text = "Source media path"
$LabelSourcePathImport.Font = $Font1
$TabPageImport.Controls.Add($LabelSourcePathImport)

$TextSourcePathImport = New-Object System.Windows.Forms.TextBox
$TextSourcePathImport.Location = New-Object System.Drawing.Point(195, 82)
$TextSourcePathImport.Size = New-Object System.Drawing.Size(797, 23)
$TextSourcePathImport.Font = $Font1
$TabPageImport.Controls.Add($TextSourcePathImport)

$LabelFeatureMapImport = New-Object System.Windows.Forms.Label
$LabelFeatureMapImport.Location = New-Object System.Drawing.Point(8, 124)
$LabelFeatureMapImport.Size = New-Object System.Drawing.Size(180, 22)
$LabelFeatureMapImport.Text = "FeatureNameMap"
$LabelFeatureMapImport.Font = $Font1
$TabPageImport.Controls.Add($LabelFeatureMapImport)

$TextFeatureMapImport = New-Object System.Windows.Forms.TextBox
$TextFeatureMapImport.Location = New-Object System.Drawing.Point(195, 120)
$TextFeatureMapImport.Size = New-Object System.Drawing.Size(797, 23)
$TextFeatureMapImport.Font = $Font1
$TextFeatureMapImport.Text = "Windows-Defender-Features=Windows-Defender;InkAndHandwritingServices=Server-Media-Foundation"
$TabPageImport.Controls.Add($TextFeatureMapImport)

$LabelSourceServerCopy = New-Object System.Windows.Forms.Label
$LabelSourceServerCopy.Location = New-Object System.Drawing.Point(8, 10)
$LabelSourceServerCopy.Size = New-Object System.Drawing.Size(155, 22)
$LabelSourceServerCopy.Text = "Source Servername"
$LabelSourceServerCopy.Font = $Font1
$TabPageCopy.Controls.Add($LabelSourceServerCopy)

$TextSourceServerCopy = New-Object System.Windows.Forms.TextBox
$TextSourceServerCopy.Location = New-Object System.Drawing.Point(195, 6)
$TextSourceServerCopy.Size = New-Object System.Drawing.Size(390, 23)
$TextSourceServerCopy.Font = $Font1
$TabPageCopy.Controls.Add($TextSourceServerCopy)

$ButtonSourceCredentialCopy = New-Object System.Windows.Forms.Button
$ButtonSourceCredentialCopy.Location = New-Object System.Drawing.Point(605, 4)
$ButtonSourceCredentialCopy.Size = New-Object System.Drawing.Size(170, 32)
$ButtonSourceCredentialCopy.Text = "Set Source Credential"
$ButtonSourceCredentialCopy.Font = $Font1
$TabPageCopy.Controls.Add($ButtonSourceCredentialCopy)

$LabelSourceCredStateCopy = New-Object System.Windows.Forms.Label
$LabelSourceCredStateCopy.Location = New-Object System.Drawing.Point(802, 10)
$LabelSourceCredStateCopy.Size = New-Object System.Drawing.Size(190, 22)
$LabelSourceCredStateCopy.Text = "SourceCred: (not set)"
$LabelSourceCredStateCopy.Font = $Font1
$TabPageCopy.Controls.Add($LabelSourceCredStateCopy)

$LabelDestinationServerCopy = New-Object System.Windows.Forms.Label
$LabelDestinationServerCopy.Location = New-Object System.Drawing.Point(8, 48)
$LabelDestinationServerCopy.Size = New-Object System.Drawing.Size(175, 22)
$LabelDestinationServerCopy.Text = "Destination Servername(s)"
$LabelDestinationServerCopy.Font = $Font1
$TabPageCopy.Controls.Add($LabelDestinationServerCopy)

$TextDestinationServerCopy = New-Object System.Windows.Forms.TextBox
$TextDestinationServerCopy.Location = New-Object System.Drawing.Point(195, 44)
$TextDestinationServerCopy.Size = New-Object System.Drawing.Size(390, 23)
$TextDestinationServerCopy.Font = $Font1
$TabPageCopy.Controls.Add($TextDestinationServerCopy)

$ButtonDestinationCredentialCopy = New-Object System.Windows.Forms.Button
$ButtonDestinationCredentialCopy.Location = New-Object System.Drawing.Point(605, 42)
$ButtonDestinationCredentialCopy.Size = New-Object System.Drawing.Size(170, 32)
$ButtonDestinationCredentialCopy.Text = "Set Destination Credential"
$ButtonDestinationCredentialCopy.Font = $Font1
$TabPageCopy.Controls.Add($ButtonDestinationCredentialCopy)

$LabelDestCredStateCopy = New-Object System.Windows.Forms.Label
$LabelDestCredStateCopy.Location = New-Object System.Drawing.Point(802, 48)
$LabelDestCredStateCopy.Size = New-Object System.Drawing.Size(190, 22)
$LabelDestCredStateCopy.Text = "DestCred: (not set)"
$LabelDestCredStateCopy.Font = $Font1
$TabPageCopy.Controls.Add($LabelDestCredStateCopy)

$LabelDestinationHintCopy = New-Object System.Windows.Forms.Label
$LabelDestinationHintCopy.Location = New-Object System.Drawing.Point(195, 70)
$LabelDestinationHintCopy.Size = New-Object System.Drawing.Size(430, 14)
$LabelDestinationHintCopy.Text = "Copy action: comma-separated list, e.g. SRV02,SRV03"
$LabelDestinationHintCopy.Font = [System.Drawing.Font]::new("Arial", 8, [System.Drawing.FontStyle]::Italic)
$LabelDestinationHintCopy.ForeColor = [System.Drawing.Color]::DimGray
$TabPageCopy.Controls.Add($LabelDestinationHintCopy)

$LabelJsonFileCopy = New-Object System.Windows.Forms.Label
$LabelJsonFileCopy.Location = New-Object System.Drawing.Point(8, 96)
$LabelJsonFileCopy.Size = New-Object System.Drawing.Size(180, 22)
$LabelJsonFileCopy.Text = "JSON Configuration File"
$LabelJsonFileCopy.Font = $Font1
$LabelJsonFileCopy.Visible = $false
$TabPageCopy.Controls.Add($LabelJsonFileCopy)

$TextJsonFileCopy = New-Object System.Windows.Forms.TextBox
$TextJsonFileCopy.Location = New-Object System.Drawing.Point(195, 92)
$TextJsonFileCopy.Size = New-Object System.Drawing.Size(680, 23)
$TextJsonFileCopy.Font = $Font1
$TextJsonFileCopy.Text = ""
$TextJsonFileCopy.Visible = $false
$TabPageCopy.Controls.Add($TextJsonFileCopy)

$ButtonBrowseJsonCopy = New-Object System.Windows.Forms.Button
$ButtonBrowseJsonCopy.Location = New-Object System.Drawing.Point(882, 90)
$ButtonBrowseJsonCopy.Size = New-Object System.Drawing.Size(170, 32)
$ButtonBrowseJsonCopy.Text = "Browse..."
$ButtonBrowseJsonCopy.Font = $Font1
$ButtonBrowseJsonCopy.Tag = $TextJsonFileCopy
$ButtonBrowseJsonCopy.Visible = $false
$TabPageCopy.Controls.Add($ButtonBrowseJsonCopy)

$LabelSourcePathCopy = New-Object System.Windows.Forms.Label
$LabelSourcePathCopy.Location = New-Object System.Drawing.Point(8, 134)
$LabelSourcePathCopy.Size = New-Object System.Drawing.Size(180, 22)
$LabelSourcePathCopy.Text = "Source media path"
$LabelSourcePathCopy.Font = $Font1
$TabPageCopy.Controls.Add($LabelSourcePathCopy)

$TextSourcePathCopy = New-Object System.Windows.Forms.TextBox
$TextSourcePathCopy.Location = New-Object System.Drawing.Point(195, 130)
$TextSourcePathCopy.Size = New-Object System.Drawing.Size(797, 23)
$TextSourcePathCopy.Font = $Font1
$TabPageCopy.Controls.Add($TextSourcePathCopy)

$LabelFeatureMapCopy = New-Object System.Windows.Forms.Label
$LabelFeatureMapCopy.Location = New-Object System.Drawing.Point(8, 172)
$LabelFeatureMapCopy.Size = New-Object System.Drawing.Size(180, 22)
$LabelFeatureMapCopy.Text = "FeatureNameMap"
$LabelFeatureMapCopy.Font = $Font1
$TabPageCopy.Controls.Add($LabelFeatureMapCopy)

$TextFeatureMapCopy = New-Object System.Windows.Forms.TextBox
$TextFeatureMapCopy.Location = New-Object System.Drawing.Point(195, 168)
$TextFeatureMapCopy.Size = New-Object System.Drawing.Size(797, 23)
$TextFeatureMapCopy.Font = $Font1
$TextFeatureMapCopy.Text = "Windows-Defender-Features=Windows-Defender;InkAndHandwritingServices=Server-Media-Foundation"
$TabPageCopy.Controls.Add($TextFeatureMapCopy)

$LabelDestinationServerDeploy = New-Object System.Windows.Forms.Label
$LabelDestinationServerDeploy.Location = New-Object System.Drawing.Point(8, 10)
$LabelDestinationServerDeploy.Size = New-Object System.Drawing.Size(175, 22)
$LabelDestinationServerDeploy.Text = "Destination Servername(s)"
$LabelDestinationServerDeploy.Font = $Font1
$TabPageDeploy.Controls.Add($LabelDestinationServerDeploy)

$TextDestinationServerDeploy = New-Object System.Windows.Forms.TextBox
$TextDestinationServerDeploy.Location = New-Object System.Drawing.Point(195, 6)
$TextDestinationServerDeploy.Size = New-Object System.Drawing.Size(390, 23)
$TextDestinationServerDeploy.Font = $Font1
$TabPageDeploy.Controls.Add($TextDestinationServerDeploy)

$ButtonDestinationCredentialDeploy = New-Object System.Windows.Forms.Button
$ButtonDestinationCredentialDeploy.Location = New-Object System.Drawing.Point(605, 4)
$ButtonDestinationCredentialDeploy.Size = New-Object System.Drawing.Size(170, 32)
$ButtonDestinationCredentialDeploy.Text = "Set Destination Credential"
$ButtonDestinationCredentialDeploy.Font = $Font1
$TabPageDeploy.Controls.Add($ButtonDestinationCredentialDeploy)

$LabelDestCredStateDeploy = New-Object System.Windows.Forms.Label
$LabelDestCredStateDeploy.Location = New-Object System.Drawing.Point(802, 10)
$LabelDestCredStateDeploy.Size = New-Object System.Drawing.Size(190, 22)
$LabelDestCredStateDeploy.Text = "DestCred: (not set)"
$LabelDestCredStateDeploy.Font = $Font1
$TabPageDeploy.Controls.Add($LabelDestCredStateDeploy)

$LabelJsonFileDeploy = New-Object System.Windows.Forms.Label
$LabelJsonFileDeploy.Location = New-Object System.Drawing.Point(8, 48)
$LabelJsonFileDeploy.Size = New-Object System.Drawing.Size(180, 22)
$LabelJsonFileDeploy.Text = "JSON Configuration File"
$LabelJsonFileDeploy.Font = $Font1
$TabPageDeploy.Controls.Add($LabelJsonFileDeploy)

$TextJsonFileDeploy = New-Object System.Windows.Forms.TextBox
$TextJsonFileDeploy.Location = New-Object System.Drawing.Point(195, 44)
$TextJsonFileDeploy.Size = New-Object System.Drawing.Size(680, 23)
$TextJsonFileDeploy.Font = $Font1
$TextJsonFileDeploy.Text = "C:\\Temp\\RolesAndFeatures.json"
$TabPageDeploy.Controls.Add($TextJsonFileDeploy)

$ButtonBrowseJsonDeploy = New-Object System.Windows.Forms.Button
$ButtonBrowseJsonDeploy.Location = New-Object System.Drawing.Point(882, 42)
$ButtonBrowseJsonDeploy.Size = New-Object System.Drawing.Size(170, 32)
$ButtonBrowseJsonDeploy.Text = "Browse..."
$ButtonBrowseJsonDeploy.Font = $Font1
$ButtonBrowseJsonDeploy.Tag = $TextJsonFileDeploy
$TabPageDeploy.Controls.Add($ButtonBrowseJsonDeploy)

$LabelSourcePathDeploy = New-Object System.Windows.Forms.Label
$LabelSourcePathDeploy.Location = New-Object System.Drawing.Point(8, 86)
$LabelSourcePathDeploy.Size = New-Object System.Drawing.Size(180, 22)
$LabelSourcePathDeploy.Text = "Source media path"
$LabelSourcePathDeploy.Font = $Font1
$TabPageDeploy.Controls.Add($LabelSourcePathDeploy)

$TextSourcePathDeploy = New-Object System.Windows.Forms.TextBox
$TextSourcePathDeploy.Location = New-Object System.Drawing.Point(195, 82)
$TextSourcePathDeploy.Size = New-Object System.Drawing.Size(797, 23)
$TextSourcePathDeploy.Font = $Font1
$TabPageDeploy.Controls.Add($TextSourcePathDeploy)

$LabelFeatureMapDeploy = New-Object System.Windows.Forms.Label
$LabelFeatureMapDeploy.Location = New-Object System.Drawing.Point(8, 124)
$LabelFeatureMapDeploy.Size = New-Object System.Drawing.Size(180, 22)
$LabelFeatureMapDeploy.Text = "FeatureNameMap"
$LabelFeatureMapDeploy.Font = $Font1
$TabPageDeploy.Controls.Add($LabelFeatureMapDeploy)

$TextFeatureMapDeploy = New-Object System.Windows.Forms.TextBox
$TextFeatureMapDeploy.Location = New-Object System.Drawing.Point(195, 120)
$TextFeatureMapDeploy.Size = New-Object System.Drawing.Size(797, 23)
$TextFeatureMapDeploy.Font = $Font1
$TextFeatureMapDeploy.Text = "Windows-Defender-Features=Windows-Defender;InkAndHandwritingServices=Server-Media-Foundation"
$TabPageDeploy.Controls.Add($TextFeatureMapDeploy)

$LabelThrottleLimitDeploy = New-Object System.Windows.Forms.Label
$LabelThrottleLimitDeploy.Location = New-Object System.Drawing.Point(8, 162)
$LabelThrottleLimitDeploy.Size = New-Object System.Drawing.Size(180, 22)
$LabelThrottleLimitDeploy.Text = "ThrottleLimit"
$LabelThrottleLimitDeploy.Font = $Font1
$TabPageDeploy.Controls.Add($LabelThrottleLimitDeploy)

$TextThrottleLimitDeploy = New-Object System.Windows.Forms.TextBox
$TextThrottleLimitDeploy.Location = New-Object System.Drawing.Point(195, 158)
$TextThrottleLimitDeploy.Size = New-Object System.Drawing.Size(80, 23)
$TextThrottleLimitDeploy.Font = $Font1
$TextThrottleLimitDeploy.Text = "8"
$TabPageDeploy.Controls.Add($TextThrottleLimitDeploy)

$Script:TabControlMap = @{
    Export = @{
        TextJsonFile         = $TextJsonFileExport
        TextComputerName     = $TextComputerNameExport
        TextJsonDepth        = $TextJsonDepthExport
        ButtonSourceCredential = $ButtonSourceCredentialExport
        LabelSourceCredState = $LabelSourceCredStateExport
        ButtonBrowseJson     = $ButtonBrowseJsonExport
    }
    Import = @{
        TextJsonFile         = $TextJsonFileImport
        TextComputerName     = $TextComputerNameImport
        TextSourcePath       = $TextSourcePathImport
        TextFeatureMap       = $TextFeatureMapImport
        ButtonSourceCredential = $ButtonSourceCredentialImport
        LabelSourceCredState = $LabelSourceCredStateImport
        ButtonBrowseJson     = $ButtonBrowseJsonImport
    }
    Copy = @{
        TextJsonFile           = $TextJsonFileCopy
        TextSourceServer       = $TextSourceServerCopy
        TextDestinationServer  = $TextDestinationServerCopy
        TextSourcePath         = $TextSourcePathCopy
        TextFeatureMap         = $TextFeatureMapCopy
        ButtonSourceCredential = $ButtonSourceCredentialCopy
        LabelSourceCredState   = $LabelSourceCredStateCopy
        ButtonDestinationCredential = $ButtonDestinationCredentialCopy
        LabelDestCredState     = $LabelDestCredStateCopy
        ButtonBrowseJson       = $ButtonBrowseJsonCopy
    }
    Deploy = @{
        TextJsonFile           = $TextJsonFileDeploy
        TextDestinationServer  = $TextDestinationServerDeploy
        TextSourcePath         = $TextSourcePathDeploy
        TextFeatureMap         = $TextFeatureMapDeploy
        TextThrottleLimit      = $TextThrottleLimitDeploy
        ButtonDestinationCredential = $ButtonDestinationCredentialDeploy
        LabelDestCredState     = $LabelDestCredStateDeploy
        ButtonBrowseJson       = $ButtonBrowseJsonDeploy
    }
}

Update-CredentialStateLabels

$GroupOptions = New-Object System.Windows.Forms.GroupBox
$GroupOptions.Location = New-Object System.Drawing.Point(16, 390)
$GroupOptions.Size = New-Object System.Drawing.Size(1034, 70)
$GroupOptions.Text = "Options"
$GroupOptions.Font = $FontHeading1
$Form.Controls.Add($GroupOptions)

$CheckVerbose = New-Object System.Windows.Forms.CheckBox
$CheckVerbose.Location = New-Object System.Drawing.Point(20, 30)
$CheckVerbose.Size = New-Object System.Drawing.Size(100, 24)
$CheckVerbose.Text = "Verbose"
$CheckVerbose.Font = $Font1
$GroupOptions.Controls.Add($CheckVerbose)

$CheckWhatIf = New-Object System.Windows.Forms.CheckBox
$CheckWhatIf.Location = New-Object System.Drawing.Point(132, 30)
$CheckWhatIf.Size = New-Object System.Drawing.Size(100, 24)
$CheckWhatIf.Text = "WhatIf"
$CheckWhatIf.Font = $Font1
$GroupOptions.Controls.Add($CheckWhatIf)

$CheckPassThru = New-Object System.Windows.Forms.CheckBox
$CheckPassThru.Location = New-Object System.Drawing.Point(244, 30)
$CheckPassThru.Size = New-Object System.Drawing.Size(110, 24)
$CheckPassThru.Text = "PassThru"
$CheckPassThru.Font = $Font1
$GroupOptions.Controls.Add($CheckPassThru)

$CheckRelaxed = New-Object System.Windows.Forms.CheckBox
$CheckRelaxed.Location = New-Object System.Drawing.Point(366, 30)
$CheckRelaxed.Size = New-Object System.Drawing.Size(130, 24)
$CheckRelaxed.Text = "RelaxedMode"
$CheckRelaxed.Font = $Font1
$GroupOptions.Controls.Add($CheckRelaxed)

$CheckKeepJson = New-Object System.Windows.Forms.CheckBox
$CheckKeepJson.Location = New-Object System.Drawing.Point(508, 30)
$CheckKeepJson.Size = New-Object System.Drawing.Size(175, 24)
$CheckKeepJson.Text = "KeepJSONConfigFile"
$CheckKeepJson.Font = $Font1
$GroupOptions.Controls.Add($CheckKeepJson)

$CheckRestartIfNeeded = New-Object System.Windows.Forms.CheckBox
$CheckRestartIfNeeded.Location = New-Object System.Drawing.Point(700, 30)
$CheckRestartIfNeeded.Size = New-Object System.Drawing.Size(160, 24)
$CheckRestartIfNeeded.Text = "Restart if needed"
$CheckRestartIfNeeded.Font = $Font1
$GroupOptions.Controls.Add($CheckRestartIfNeeded)

$TextOutput = New-Object System.Windows.Forms.TextBox
$TextOutput.Location = New-Object System.Drawing.Point(16, 468)
$TextOutput.Size = New-Object System.Drawing.Size(1034, 242)
$TextOutput.Multiline = $true
$TextOutput.ScrollBars = "Both"
$TextOutput.ReadOnly = $true
$TextOutput.WordWrap = $false
$TextOutput.Font = $FontData
$Form.Controls.Add($TextOutput)

$OutputTimer = New-Object System.Windows.Forms.Timer
$OutputTimer.Interval = 400
$OutputTimer.Add_Tick({
    if (-not $Script:IsRunning) {
        $OutputTimer.Stop()
        return
    }

    while ($Script:OutputIndex -lt $Script:RunnerOutput.Count) {
        Write-OutputItem -Item $Script:RunnerOutput[$Script:OutputIndex]
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
            # Only report error once to avoid duplicate messages
            if (-not $Script:ErrorReported) {
                $Script:ErrorReported = $true
                $LabelStatus.Text = "Failed"
                
                # Extract the meaningful error from nested exceptions
                $errorMsg = $_.Exception.Message
                
                # Try to extract the actual error from "set to Stop: ..." wrapper
                $match = [regex]::Match($errorMsg, 'set to Stop:\s*(.+?)$')
                if ($match.Success) {
                    $errorMsg = $match.Groups[1].Value.TrimEnd('.')
                }
                
                Add-OutputLine -Text ""
                Add-OutputLine -Text "==============================================="
                Add-OutputLine -Text ("ERROR - Run failed at {0}" -f (Get-Date -Format "HH:mm:ss"))
                Add-OutputLine -Text "==============================================="
                Add-OutputLine -Text $errorMsg
                Add-OutputLine -Text "==============================================="
                Add-OutputLine -Text ""
                Write-TSxLog -Message ("Run failed: {0}" -f $errorMsg)
                Show-TSxDialog -Message ("Failed to run operation.`r`n`r`nError: {0}`r`n`r`nCheck the output pane and log file for details.`r`n`r`nLog: {1}" -f $errorMsg, $Script:LogFile) -Title $Script:ToolName -Icon Error -Owner $Form
            }
        }
        finally {
            if ($Script:Runner) {
                $Script:Runner.Dispose()
            }

            if ($Script:CopyTempJsonFile -and (-not $CheckKeepJson.Checked)) {
                if (Test-Path -LiteralPath $Script:CopyTempJsonFile) {
                    Remove-Item -LiteralPath $Script:CopyTempJsonFile -Force -ErrorAction SilentlyContinue
                    Add-OutputLine -Text ("[{0}] Temporary JSON file removed: {1}" -f (Get-Date -Format "HH:mm:ss"), $Script:CopyTempJsonFile)
                }
            }
            $Script:CopyTempJsonFile = $null

            $Script:Runner = $null
            $Script:RunnerHandle = $null
            $Script:RunnerOutput = $null
            $Script:OutputIndex = 0
            $Script:IsRunning = $false
            $Script:ErrorReported = $false
            $Form.Cursor = [System.Windows.Forms.Cursors]::Default
            $ButtonRun.Enabled = $true
            $OutputTimer.Stop()
        }
    }
})

$settings = Import-UISettings
if ($settings) {
    if ($settings.Action -and $ComboAction.Items.Contains($settings.Action)) {
        $ComboAction.SelectedItem = [string]$settings.Action
    }

    if ($settings.Export) {
        Set-TabText -Action 'Export' -Name 'TextJsonFile' -Value ([string]$settings.Export.JSONConfigFile)
        Set-TabText -Action 'Export' -Name 'TextComputerName' -Value ([string]$settings.Export.ComputerName)
        Set-TabText -Action 'Export' -Name 'TextJsonDepth' -Value ([string]$settings.Export.JsonDepth)
    }
    elseif ($settings.JSONConfigFile) {
        Set-TabText -Action 'Export' -Name 'TextJsonFile' -Value ([string]$settings.JSONConfigFile)
        Set-TabText -Action 'Export' -Name 'TextComputerName' -Value ([string]$settings.ComputerName)
        Set-TabText -Action 'Export' -Name 'TextJsonDepth' -Value ([string]$settings.JsonDepth)
    }

    if ($settings.Import) {
        Set-TabText -Action 'Import' -Name 'TextJsonFile' -Value ([string]$settings.Import.JSONConfigFile)
        Set-TabText -Action 'Import' -Name 'TextComputerName' -Value ([string]$settings.Import.ComputerName)
        Set-TabText -Action 'Import' -Name 'TextSourcePath' -Value ([string]$settings.Import.SourcePath)
        Set-TabText -Action 'Import' -Name 'TextFeatureMap' -Value ([string]$settings.Import.FeatureNameMapText)
    }
    elseif ($settings.JSONConfigFile) {
        Set-TabText -Action 'Import' -Name 'TextJsonFile' -Value ([string]$settings.JSONConfigFile)
        Set-TabText -Action 'Import' -Name 'TextComputerName' -Value ([string]$settings.ComputerName)
        Set-TabText -Action 'Import' -Name 'TextSourcePath' -Value ([string]$settings.SourcePath)
        Set-TabText -Action 'Import' -Name 'TextFeatureMap' -Value ([string]$settings.FeatureNameMapText)
    }

    if ($settings.Copy) {
        Set-TabText -Action 'Copy' -Name 'TextJsonFile' -Value ([string]$settings.Copy.JSONConfigFile)
        Set-TabText -Action 'Copy' -Name 'TextSourceServer' -Value ([string]$settings.Copy.SourceServer)
        Set-TabText -Action 'Copy' -Name 'TextDestinationServer' -Value ([string]$settings.Copy.DestinationServer)
        Set-TabText -Action 'Copy' -Name 'TextSourcePath' -Value ([string]$settings.Copy.SourcePath)
        Set-TabText -Action 'Copy' -Name 'TextFeatureMap' -Value ([string]$settings.Copy.FeatureNameMapText)
    }
    elseif ($settings.JSONConfigFile) {
        Set-TabText -Action 'Copy' -Name 'TextJsonFile' -Value ([string]$settings.JSONConfigFile)
        Set-TabText -Action 'Copy' -Name 'TextSourceServer' -Value ([string]$settings.SourceServer)
        Set-TabText -Action 'Copy' -Name 'TextDestinationServer' -Value ([string]$settings.DestinationServer)
        Set-TabText -Action 'Copy' -Name 'TextSourcePath' -Value ([string]$settings.SourcePath)
        Set-TabText -Action 'Copy' -Name 'TextFeatureMap' -Value ([string]$settings.FeatureNameMapText)
    }

    if ($settings.Deploy) {
        Set-TabText -Action 'Deploy' -Name 'TextJsonFile' -Value ([string]$settings.Deploy.JSONConfigFile)
        Set-TabText -Action 'Deploy' -Name 'TextDestinationServer' -Value ([string]$settings.Deploy.DestinationServer)
        Set-TabText -Action 'Deploy' -Name 'TextSourcePath' -Value ([string]$settings.Deploy.SourcePath)
        Set-TabText -Action 'Deploy' -Name 'TextFeatureMap' -Value ([string]$settings.Deploy.FeatureNameMapText)
        if (-not [string]::IsNullOrWhiteSpace([string]$settings.Deploy.ThrottleLimit)) {
            Set-TabText -Action 'Deploy' -Name 'TextThrottleLimit' -Value ([string]$settings.Deploy.ThrottleLimit)
        }
    }
    elseif ($settings.JSONConfigFile) {
        Set-TabText -Action 'Deploy' -Name 'TextJsonFile' -Value ([string]$settings.JSONConfigFile)
        Set-TabText -Action 'Deploy' -Name 'TextDestinationServer' -Value ([string]$settings.DestinationServer)
        Set-TabText -Action 'Deploy' -Name 'TextSourcePath' -Value ([string]$settings.SourcePath)
        Set-TabText -Action 'Deploy' -Name 'TextFeatureMap' -Value ([string]$settings.FeatureNameMapText)
        if (-not [string]::IsNullOrWhiteSpace([string]$settings.ThrottleLimit)) {
            Set-TabText -Action 'Deploy' -Name 'TextThrottleLimit' -Value ([string]$settings.ThrottleLimit)
        }
    }

    $CheckVerbose.Checked = [bool]$settings.Verbose
    $CheckWhatIf.Checked = [bool]$settings.WhatIf
    $CheckPassThru.Checked = [bool]$settings.PassThru
    $CheckRelaxed.Checked = [bool]$settings.RelaxedMode
    $CheckKeepJson.Checked = [bool]$settings.KeepJSONConfigFile
    $CheckRestartIfNeeded.Checked = [bool]$settings.RestartIfNeeded
}

$ComboAction.Add_SelectedIndexChanged({
    if ($Script:IsSyncingActionTab) {
        return
    }

    $Script:IsSyncingActionTab = $true
    try {
        $targetTab = switch ([string]$ComboAction.SelectedItem) {
            "Export" { $TabPageExport }
            "Import" { $TabPageImport }
            "Copy"   { $TabPageCopy }
            "Deploy" { $TabPageDeploy }
            default   { $TabPageExport }
        }

        if ($TabActions.SelectedTab -ne $targetTab) {
            $TabActions.SelectedTab = $targetTab
        }

        Update-ActionUI
    }
    finally {
        $Script:IsSyncingActionTab = $false
    }
})

$TabActions.Add_SelectedIndexChanged({
    if ($Script:IsSyncingActionTab) {
        return
    }

    $Script:IsSyncingActionTab = $true
    try {
        $selectedAction = [string]$TabActions.SelectedTab.Text
        if ([string]$ComboAction.SelectedItem -ne $selectedAction) {
            $ComboAction.SelectedItem = $selectedAction
        }

        Update-ActionUI
    }
    finally {
        $Script:IsSyncingActionTab = $false
    }
})

$sourceCredentialHandler = {
    try {
        $cred = Get-Credential -Message "Enter source credential"
        if ($cred) {
            $Script:SourceCredential = $cred
            Update-CredentialStateLabels
            Write-TSxLog -Message "Source credential updated"
        }
    }
    catch {
        Show-TSxDialog -Message ("Failed to set source credential: {0}" -f $_.Exception.Message) -Title $Script:ToolName -Icon Error -Owner $Form
    }
}

$ButtonSourceCredentialExport.Add_Click($sourceCredentialHandler)
$ButtonSourceCredentialImport.Add_Click($sourceCredentialHandler)
$ButtonSourceCredentialCopy.Add_Click($sourceCredentialHandler)

$destinationCredentialHandler = {
    try {
        $cred = Get-Credential -Message "Enter destination credential"
        if ($cred) {
            $Script:DestinationCredential = $cred
            Update-CredentialStateLabels
            Write-TSxLog -Message "Destination credential updated"
        }
    }
    catch {
        Show-TSxDialog -Message ("Failed to set destination credential: {0}" -f $_.Exception.Message) -Title $Script:ToolName -Icon Error -Owner $Form
    }
}

$ButtonDestinationCredentialCopy.Add_Click($destinationCredentialHandler)
$ButtonDestinationCredentialDeploy.Add_Click($destinationCredentialHandler)

$ButtonClose.Add_Click({
    $Form.Close()
})

$browseJsonHandler = {
    $targetTextBox = $this.Tag
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = "Select JSON configuration file"
    $dialog.Filter = "JSON files (*.json)|*.json|All files (*.*)|*.*"
    $dialog.DefaultExt = "json"
    $dialog.FileName = if ($targetTextBox.Text.Trim() -ne "") { [System.IO.Path]::GetFileName($targetTextBox.Text.Trim()) } else { "RolesAndFeatures.json" }
    $dialog.InitialDirectory = if ($targetTextBox.Text.Trim() -ne "" -and (Test-Path -LiteralPath ([System.IO.Path]::GetDirectoryName($targetTextBox.Text.Trim())) -PathType Container)) { [System.IO.Path]::GetDirectoryName($targetTextBox.Text.Trim()) } else { "C:\\Temp" }
    if ($dialog.ShowDialog($Form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $targetTextBox.Text = $dialog.FileName
    }
}

$ButtonBrowseJsonExport.Add_Click($browseJsonHandler)
$ButtonBrowseJsonImport.Add_Click($browseJsonHandler)
$ButtonBrowseJsonCopy.Add_Click($browseJsonHandler)
$ButtonBrowseJsonDeploy.Add_Click($browseJsonHandler)

$ButtonReset.Add_Click({
    $ComboAction.SelectedItem = "Export"
    Set-TabText -Action 'Export' -Name 'TextJsonFile' -Value 'C:\Temp\RolesAndFeatures.json'
    Set-TabText -Action 'Export' -Name 'TextComputerName' -Value ''
    Set-TabText -Action 'Export' -Name 'TextJsonDepth' -Value '5'
    Set-TabText -Action 'Import' -Name 'TextJsonFile' -Value 'C:\Temp\RolesAndFeatures.json'
    Set-TabText -Action 'Import' -Name 'TextComputerName' -Value ''
    Set-TabText -Action 'Import' -Name 'TextSourcePath' -Value ''
    Set-TabText -Action 'Import' -Name 'TextFeatureMap' -Value 'Windows-Defender-Features=Windows-Defender;InkAndHandwritingServices=Server-Media-Foundation'
    Set-TabText -Action 'Copy' -Name 'TextJsonFile' -Value 'C:\Temp\RolesAndFeatures.json'
    Set-TabText -Action 'Copy' -Name 'TextSourceServer' -Value ''
    Set-TabText -Action 'Copy' -Name 'TextDestinationServer' -Value ''
    Set-TabText -Action 'Copy' -Name 'TextSourcePath' -Value ''
    Set-TabText -Action 'Copy' -Name 'TextFeatureMap' -Value 'Windows-Defender-Features=Windows-Defender;InkAndHandwritingServices=Server-Media-Foundation'
    Set-TabText -Action 'Deploy' -Name 'TextJsonFile' -Value 'C:\Temp\RolesAndFeatures.json'
    Set-TabText -Action 'Deploy' -Name 'TextDestinationServer' -Value ''
    Set-TabText -Action 'Deploy' -Name 'TextSourcePath' -Value ''
    Set-TabText -Action 'Deploy' -Name 'TextFeatureMap' -Value 'Windows-Defender-Features=Windows-Defender;InkAndHandwritingServices=Server-Media-Foundation'
    Set-TabText -Action 'Deploy' -Name 'TextThrottleLimit' -Value '8'
    $CheckVerbose.Checked = $false
    $CheckWhatIf.Checked = $false
    $CheckPassThru.Checked = $false
    $CheckRelaxed.Checked = $false
    $CheckKeepJson.Checked = $false
    $CheckRestartIfNeeded.Checked = $false
    $Script:SourceCredential = $null
    $Script:DestinationCredential = $null
    Update-CredentialStateLabels
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
    Export-UISettings

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

$ButtonRun.Add_Click({
    Export-UISettings

    try {
        $invocation = New-InvocationContext
    }
    catch {
        Show-TSxDialog -Message $_.Exception.Message -Title $Script:ToolName -Icon Warning -Owner $Form
        return
    }

    $ButtonRun.Enabled = $false
    $Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $LabelStatus.Text = "Running..."
    $TextOutput.Clear()

    Add-OutputLine -Text ("[{0}] Starting action '{1}'" -f (Get-Date -Format "HH:mm:ss"), $invocation.Action)
    Add-OutputLine -Text ("Script: {0}" -f $invocation.ScriptPath)
    Add-OutputLine -Text ("Log: {0}" -f $Script:LogFile)
    Write-TSxLog -Message ("Run started. Action={0}" -f $invocation.Action)

    try {
        $Script:Runner = [System.Management.Automation.PowerShell]::Create()
        $inputBuffer = New-Object System.Management.Automation.PSDataCollection[psobject]
        $Script:RunnerOutput = New-Object System.Management.Automation.PSDataCollection[psobject]
        $Script:OutputIndex = 0

        [void]$Script:Runner.AddScript({
            param($targetPath, $params)
            & $targetPath @params *>&1
        })
        [void]$Script:Runner.AddArgument($invocation.ScriptPath)
        [void]$Script:Runner.AddArgument($invocation.Params)

        $Script:RunnerHandle = $Script:Runner.BeginInvoke($inputBuffer, $Script:RunnerOutput)
        $Script:IsRunning = $true
        $OutputTimer.Start()
    }
    catch {
        $LabelStatus.Text = "Failed"
        Add-OutputLine -Text ("ERROR: {0}" -f $_.Exception.Message)
        Write-TSxLog -Message ("Run startup failed: {0}" -f $_.Exception.Message)
        Show-TSxDialog -Message ("Failed to start action. {0}`r`n`r`nLog: {1}" -f $_.Exception.Message, $Script:LogFile) -Title $Script:ToolName -Icon Error -Owner $Form
        $Form.Cursor = [System.Windows.Forms.Cursors]::Default
        $ButtonRun.Enabled = $true
        $Script:IsRunning = $false
    }
})

$initialTab = switch ([string]$ComboAction.SelectedItem) {
    "Export" { $TabPageExport }
    "Import" { $TabPageImport }
    "Copy"   { $TabPageCopy }
    "Deploy" { $TabPageDeploy }
    default   { $TabPageExport }
}

$TabActions.SelectedTab = $initialTab
Update-ActionUI

[void]$Form.ShowDialog()
