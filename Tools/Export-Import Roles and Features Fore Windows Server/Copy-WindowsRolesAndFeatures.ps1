<#
.SYNOPSIS
    Copy installed Windows roles and features from a source server to one or more destination servers.
.DESCRIPTION
    Copy-WindowsRolesAndFeatures exports installed roles/features from a source
    server to a JSON data file, then installs missing roles/features on one or
    more destination servers. The export and install operations can run locally
    or through PowerShell remoting, and support -Verbose and -WhatIf.
.PARAMETER SourceServer
    Source server to export roles/features from. If omitted, the local server is
    used.
.PARAMETER DestinationServer
    One or more destination servers to install roles/features on.
.PARAMETER JSONConfigFile
    Path to the intermediary JSON data file (local path or UNC). If omitted, a
    timestamped JSON file in $env:TEMP is used.
.PARAMETER SourceCredential
    Credential used for remoting to the source server.
.PARAMETER DestinationCredential
    Credential used for remoting to destination servers.
.PARAMETER IncludeManagementTools
    Whether management tools should be included during feature installation.
.PARAMETER Restart
    Allows restart when required by role/feature installation.
.PARAMETER Source
    Alternate source path for role/feature binaries (for example SxS media).
.PARAMETER RelaxedMode
    Enables compatibility mapping for known feature-name differences between
    Windows versions. When enabled, unavailable feature names can be mapped to
    alternative names if present in the mapping table.
.PARAMETER FeatureNameMap
    Optional custom hashtable used when -RelaxedMode is enabled.
    Key = source feature name; Value = target feature name to install.
    If omitted, the script uses the built-in default mapping table.
.PARAMETER KeepJSONConfigFile
    Keeps the intermediary JSON data file after copy is complete.
.PARAMETER PassThru
    Returns per-destination result objects.
.EXAMPLE
    .\Copy-WindowsRolesAndFeatures.ps1 -SourceServer SRV01 -DestinationServer SRV02
.EXAMPLE
    .\Copy-WindowsRolesAndFeatures.ps1 -SourceServer SRV01 -DestinationServer SRV02,SRV03 -RelaxedMode -Verbose
.EXAMPLE
    .\Copy-WindowsRolesAndFeatures.ps1 -SourceServer SRV01 -DestinationServer SRV02 -JSONConfigFile \\fileserver\share\roles.json -KeepJSONConfigFile
.EXAMPLE
    .\Copy-WindowsRolesAndFeatures.ps1 -SourceServer SRV01 -DestinationServer SRV02,SRV03 -RelaxedMode -Source \\fileserver\sources\sxs -FeatureNameMap @{ 'InkAndHandwritingServices'='Server-Media-Foundation' } -Verbose
.NOTES
    FileName:    Copy-WindowsRolesAndFeatures.ps1
    Author:      Mikael Nystrom
    Contact:     deploymentbunny@outlook.com
    Created:     2026-04-24
    Updated:     2026-04-27
    Web:         https://www.deploymentbunny.com
    Twitter:     @mikael_nystrom

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author.
.FUNCTIONALITY
    Exports installed roles/features and OS metadata from the source server,
    writes JSON to local/UNC storage, then processes each destination server.
    For each destination, compares OS version against source, applies relaxed
    mapping logic when enabled, skips unavailable/already-installed features,
    and installs only required items. Writes status to screen and log file.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SourceServer,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$DestinationServer,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$JSONConfigFile,

    [Parameter()]
    [System.Management.Automation.PSCredential]$SourceCredential,

    [Parameter()]
    [System.Management.Automation.PSCredential]$DestinationCredential,

    [Parameter()]
    [bool]$IncludeManagementTools = $true,

    [Parameter()]
    [switch]$Restart,

    [Parameter()]
    [string]$Source,

    [Parameter()]
    [switch]$RelaxedMode,

    [Parameter()]
    [hashtable]$FeatureNameMap,

    [Parameter()]
    [switch]$KeepJSONConfigFile,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:LogFile = Join-Path $env:TEMP ("Copy-WindowsRolesAndFeatures_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$Script:RunUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

function Write-TSxLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $Script:LogFile -Value ("[{0}] [User: {1}] {2}" -f $timestamp, $Script:RunUser, $Message)
}

function Write-TSxStatus {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-TSxLog -Message $Message
    Write-Verbose ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message)
    if ($VerbosePreference -ne 'Continue') {
        Write-Output ("STATUS: [{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message)
    }
}

Write-TSxStatus -Message "Copy-WindowsRolesAndFeatures started"

$defaultFeatureNameMap = @{
    'Windows-Defender-Features' = 'Windows-Defender'
    'InkAndHandwritingServices' = 'Server-Media-Foundation'
}
$featureMapForInstall = if ($FeatureNameMap) { $FeatureNameMap } else { $defaultFeatureNameMap }

$autoGeneratedFile = [string]::IsNullOrWhiteSpace($JSONConfigFile)
if ($autoGeneratedFile) {
    $JSONConfigFile = Join-Path $env:TEMP ("RolesAndFeatures_{0}.json" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
    Write-TSxStatus -Message "No -JSONConfigFile specified. Using auto-generated path: $JSONConfigFile"
}

if (Test-Path -LiteralPath $JSONConfigFile -PathType Container) {
    throw "-JSONConfigFile must be a file path, not a folder."
}

$sourceDisplay = if ([string]::IsNullOrWhiteSpace($SourceServer)) { $env:COMPUTERNAME } else { $SourceServer }

$collectFeaturesScriptBlock = {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    Import-Module ServerManager -ErrorAction Stop

    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $osInfo = [PSCustomObject]@{
        Caption                 = $os.Caption
        Version                 = $os.Version
        BuildNumber             = $os.BuildNumber
        OSArchitecture          = $os.OSArchitecture
        OperatingSystemSKU      = [int]$os.OperatingSystemSKU
        SKUName                 = switch ([int]$os.OperatingSystemSKU) {
            7   { 'Server Standard' }
            8   { 'Server Datacenter' }
            10  { 'Enterprise' }
            12  { 'Server Datacenter Core' }
            13  { 'Server Standard Core' }
            17  { 'Server Web' }
            28  { 'Server HPC' }
            42  { 'Server Solution Embedded' }
            48  { 'Professional' }
            50  { 'Server Hyper-V' }
            79  { 'Server Datacenter Evaluation' }
            80  { 'Server Standard Evaluation' }
            84  { 'Server Standard Evaluation Core' }
            default { "Unknown SKU ($([int]$os.OperatingSystemSKU))" }
        }
        ServicePackMajorVersion = $os.ServicePackMajorVersion
        InstallDate             = $os.InstallDate.ToString('o')
    }

    $installedFeatures = Get-WindowsFeature |
        Where-Object { $_.InstallState -eq 'Installed' } |
        Sort-Object -Property Name |
        ForEach-Object {
            [PSCustomObject]@{
                Name         = $_.Name
                DisplayName  = $_.DisplayName
                InstallState = [string]$_.InstallState
                FeatureType  = [string]$_.FeatureType
                Path         = $_.Path
                Depth        = $_.Depth
            }
        }

    [PSCustomObject]@{
        SchemaVersion   = 1
        ComputerName    = $env:COMPUTERNAME
        ExportedAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
        OperatingSystem = $osInfo
        FeatureCount    = $installedFeatures.Count
        Features        = $installedFeatures
    }
}

$installScriptBlock = {
    param(
        [string[]]$Names,
        [bool]$IncludeMgmtTools,
        [bool]$DoRestart,
        [string]$SourcePath,
        [bool]$UseRelaxedMode,
        [hashtable]$NameMap
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    Import-Module ServerManager -ErrorAction Stop

    $featureNamesToProcess = @($Names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $knownFeatures = @(Get-WindowsFeature | ForEach-Object { $_.Name })

    if ($UseRelaxedMode) {
        $mappedFeatureNames = foreach ($name in $featureNamesToProcess) {
            if ($knownFeatures -contains $name) {
                $name
                continue
            }

            if ($NameMap.ContainsKey($name)) {
                $mappedName = [string]$NameMap[$name]
                if (-not [string]::IsNullOrWhiteSpace($mappedName) -and $knownFeatures -contains $mappedName) {
                    Write-Warning "Role/feature '$name' is not available on this system. Relaxed mode will use '$mappedName' instead."
                    $mappedName
                    continue
                }
            }

            $name
        }

        $featureNamesToProcess = @($mappedFeatureNames | Sort-Object -Unique)
    }

    $unavailable = @($featureNamesToProcess | Where-Object { $_ -notin $knownFeatures })
    $available = @($featureNamesToProcess | Where-Object { $_ -in $knownFeatures })

    foreach ($name in $unavailable) {
        Write-Warning "Role/feature '$name' is not available on this system and will be skipped."
    }

    if ($available.Count -eq 0) {
        Write-Warning "None of the requested roles/features are available on this system. Nothing to install."
        return
    }

    $alreadyInstalled = @(Get-WindowsFeature -Name $available |
        Where-Object { $_.InstallState -eq 'Installed' } |
        ForEach-Object { $_.Name })

    foreach ($name in $alreadyInstalled) {
        Write-Verbose "Skipping '$name' - already installed."
    }

    $toInstall = @($available | Where-Object { $_ -notin $alreadyInstalled })
    if ($toInstall.Count -eq 0) {
        Write-Verbose "All available roles/features are already installed. Nothing to do."
        return
    }

    $installParams = @{
        Name                   = $toInstall
        IncludeManagementTools = $IncludeMgmtTools
        Restart                = $DoRestart
        ErrorAction            = 'Stop'
    }

    if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
        $installParams.Source = $SourcePath
    }

    Install-WindowsFeature @installParams
}

try {
    if (-not $PSCmdlet.ShouldProcess($sourceDisplay, "Export installed roles/features to '$JSONConfigFile'")) {
        return
    }

    Write-TSxStatus -Message "Exporting roles/features from '$sourceDisplay'."

    $exportObject = if ([string]::IsNullOrWhiteSpace($SourceServer)) {
        & $collectFeaturesScriptBlock
    }
    else {
        $invokeParams = @{
            ComputerName = $SourceServer
            ScriptBlock  = $collectFeaturesScriptBlock
            ErrorAction  = 'Stop'
        }
        if ($SourceCredential) { $invokeParams.Credential = $SourceCredential }
        
        Invoke-Command @invokeParams
    }

    $parentPath = Split-Path -Path $JSONConfigFile -Parent
    if (-not [string]::IsNullOrWhiteSpace($parentPath) -and -not (Test-Path -LiteralPath $parentPath)) {
        New-Item -ItemType Directory -Path $parentPath -Force | Out-Null
        Write-TSxStatus -Message "Created output directory '$parentPath'."
    }

    $json = $exportObject | ConvertTo-Json -Depth 8
    Set-Content -Path $JSONConfigFile -Value $json -Encoding UTF8
    Write-TSxStatus -Message "Exported $($exportObject.FeatureCount) features from '$sourceDisplay' to '$JSONConfigFile'."

    $featureNames = @(
        $exportObject.Features |
            ForEach-Object { $_.Name } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )

    $results = foreach ($destination in $DestinationServer) {
        Write-TSxStatus -Message "Processing destination '$destination'."

        if ($exportObject.OperatingSystem -and $exportObject.OperatingSystem.Version) {
            $sourceVersion = [string]$exportObject.OperatingSystem.Version
            try {
                $destInvokeParams = @{ ComputerName = $destination; ErrorAction = 'Stop' }
                if ($DestinationCredential) { $destInvokeParams.Credential = $DestinationCredential }
                elseif ($SourceCredential) { $destInvokeParams.Credential = $SourceCredential }

                $destVersion = [string](Invoke-Command @destInvokeParams -ScriptBlock {
                    (Get-CimInstance -ClassName Win32_OperatingSystem).Version
                })

                if ($sourceVersion -ne $destVersion) {
                    Write-Warning "Importing on different version on '$destination', some Roles or Features might not be available"
                    Write-TSxStatus -Message "OS version mismatch on '$destination' - source: $sourceVersion, destination: $destVersion"
                }
                else {
                    Write-TSxStatus -Message "OS version match on '$destination': $destVersion"
                }
            }
            catch {
                Write-TSxStatus -Message "Could not retrieve OS version from '$destination'. Skipping version check. Error: $($_.Exception.Message)"
            }
        }

        if (-not $PSCmdlet.ShouldProcess($destination, "Install $($featureNames.Count) roles/features")) {
            continue
        }

        $destParams = @{
            ComputerName = $destination
            ScriptBlock  = $installScriptBlock
            ArgumentList = @($featureNames, $IncludeManagementTools, $Restart.IsPresent, $Source, $RelaxedMode.IsPresent, $featureMapForInstall)
            ErrorAction  = 'Stop'
        }
        if ($DestinationCredential) { $destParams.Credential = $DestinationCredential }
        elseif ($SourceCredential) { $destParams.Credential = $SourceCredential }

        try {
            $installResult = Invoke-Command @destParams
            Write-TSxStatus -Message "Completed installation on '$destination'."

            if ($PassThru) {
                [PSCustomObject]@{
                    DestinationServer = $destination
                    Result = $installResult
                }
            }
        }
        catch {
            Write-TSxStatus -Message ("Installation failed on '$destination'. Error: {0}" -f $_.Exception.Message)
            Write-Warning "Failed to install roles/features on '$destination': $_"
        }
    }

    if (-not $KeepJSONConfigFile) {
        if (Test-Path -LiteralPath $JSONConfigFile) {
            Remove-Item -LiteralPath $JSONConfigFile -Force
            Write-TSxStatus -Message "Removed intermediary file '$JSONConfigFile'."
        }
    }
    else {
        Write-TSxStatus -Message "Kept intermediary file '$JSONConfigFile'."
    }

    Write-TSxStatus -Message "Copy-WindowsRolesAndFeatures completed. Log: $Script:LogFile"

    if ($PassThru) { $results }
}
catch {
    $errorMessage = "Copy-WindowsRolesAndFeatures failed. Error: {0}" -f $_.Exception.Message
    Write-TSxStatus -Message $errorMessage
    throw
}
