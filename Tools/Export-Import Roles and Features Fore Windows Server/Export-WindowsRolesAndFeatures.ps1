<#
.SYNOPSIS
    Export installed Windows roles and features to a JSON file.
.DESCRIPTION
    Export-WindowsRolesAndFeatures collects all installed roles and features from
    the local or a remote computer using Get-WindowsFeature and saves the result
    as a JSON file to a local path or a UNC share. The export includes operating
    system version and SKU information so that the import script can warn if the
    target system differs from the source.
.PARAMETER JSONConfigFile
    Path to the JSON output file. Must be a file path, not a folder. The parent
    directory is created automatically if it does not exist.
.PARAMETER ComputerName
    Name of the remote computer to export from. When omitted the local computer
    is used. The feature inventory is collected on the remote host via
    Invoke-Command; the JSON file is always written to the path specified by
    -JSONConfigFile on the machine running the script.
.PARAMETER Credential
    Credentials to use when connecting to a remote computer.
.PARAMETER JsonDepth
    Depth passed to ConvertTo-Json. Defaults to 8.
.PARAMETER PassThru
    When specified, returns a summary object with the output file path,
    computer name, feature count and export timestamp.
.EXAMPLE
    .\Export-WindowsRolesAndFeatures.ps1 -JSONConfigFile C:\Temp\roles.json
.EXAMPLE
    .\Export-WindowsRolesAndFeatures.ps1 -JSONConfigFile \\fileserver\share\SRV01.json -ComputerName SRV01 -Verbose
.NOTES
    FileName:    Export-WindowsRolesAndFeatures.ps1
    Author:      Mikael Nystrom
    Contact:     deploymentbunny@outlook.com
    Created:     2026-04-23
    Updated:     2026-04-27
    Web:         https://www.deploymentbunny.com
    Twitter:     @mikael_nystrom

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author.
.FUNCTIONALITY
    Connects to the target computer (locally or via Invoke-Command), imports the
    ServerManager module, retrieves all installed Windows features, and captures
    operating system version and SKU details. The collected data is serialised to
    JSON and written to the specified file path. Status is written both to the
    screen and to a timestamped log file in $env:TEMP. Supports -Verbose and -WhatIf.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$JSONConfigFile,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ComputerName,

    [Parameter()]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter()]
    [ValidateRange(3, 20)]
    [int]$JsonDepth = 8,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:LogFile = Join-Path $env:TEMP ("Export-WindowsRolesAndFeatures_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$Script:RunUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

function Write-TSxLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $Script:LogFile -Value ("[{0}] [User: {1}] {2}" -f $timestamp, $Script:RunUser, $Message)
}

function Write-TSxStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-TSxLog -Message $Message
    Write-Verbose ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message)
    if ($VerbosePreference -ne 'Continue') {
        Write-Output ("STATUS: [{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message)
    }
}

Write-TSxStatus -Message "Export-WindowsRolesAndFeatures started"

if (Test-Path -LiteralPath $JSONConfigFile -PathType Container) {
    Write-Warning "-JSONConfigFile must be a file, not a folder"
    return
}

$targetComputer = if ([string]::IsNullOrWhiteSpace($ComputerName)) { $env:COMPUTERNAME } else { $ComputerName }

if (-not $PSCmdlet.ShouldProcess($targetComputer, "Export installed Windows roles/features to '$JSONConfigFile'")) {
    return
}

$collectFeaturesScriptBlock = {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    Import-Module ServerManager -ErrorAction Stop

    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $osInfo = [PSCustomObject]@{
        Caption         = $os.Caption
        Version         = $os.Version
        BuildNumber     = $os.BuildNumber
        OSArchitecture  = $os.OSArchitecture
        OperatingSystemSKU = [int]$os.OperatingSystemSKU
        SKUName         = switch ([int]$os.OperatingSystemSKU) {
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
        InstallDate     = $os.InstallDate.ToString('o')
    }

    $installedFeatures = Get-WindowsFeature |
        Where-Object { $_.InstallState -eq 'Installed' } |
        Sort-Object -Property Name |
        ForEach-Object {
            $dependsOn = @(
                $_.DependsOn |
                    ForEach-Object {
                        if ($null -eq $_) {
                            return
                        }

                        if ($_ -is [string]) {
                            return $_
                        }

                        if ($_.PSObject.Properties['Name']) {
                            return $_.Name
                        }

                        return [string]$_
                    } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )

            [PSCustomObject]@{
                Name         = $_.Name
                DisplayName  = $_.DisplayName
                InstallState = [string]$_.InstallState
                FeatureType  = [string]$_.FeatureType
                Path         = $_.Path
                Depth        = $_.Depth
                DependsOn    = $dependsOn
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

Write-TSxStatus -Message "Collecting installed roles/features from '$targetComputer'."

$exportObject = if ([string]::IsNullOrWhiteSpace($ComputerName)) {
    & $collectFeaturesScriptBlock
}
else {
    $invokeParams = @{
        ComputerName = $ComputerName
        ScriptBlock  = $collectFeaturesScriptBlock
        ErrorAction  = 'Stop'
    }

    if ($Credential) {
        $invokeParams.Credential = $Credential
    }

    Invoke-Command @invokeParams
}

try {
    $parentPath = Split-Path -Path $JSONConfigFile -Parent
    if (-not [string]::IsNullOrWhiteSpace($parentPath) -and -not (Test-Path -LiteralPath $parentPath)) {
        if ($PSCmdlet.ShouldProcess($parentPath, 'Create output directory')) {
            New-Item -ItemType Directory -Path $parentPath -Force | Out-Null
            Write-TSxStatus -Message "Created output directory '$parentPath'."
        }
    }

    $json = $exportObject | ConvertTo-Json -Depth $JsonDepth

    if ($PSCmdlet.ShouldProcess($JSONConfigFile, 'Write JSON export file')) {
        Write-TSxStatus -Message "Writing JSON export to '$JSONConfigFile' ($($exportObject.FeatureCount) features)."
        Set-Content -Path $JSONConfigFile -Value $json -Encoding UTF8
        Write-TSxStatus -Message "Export-WindowsRolesAndFeatures completed successfully. Log: $Script:LogFile"
    }

    if ($PassThru) {
        [PSCustomObject]@{
            JSONConfigFile = $JSONConfigFile
            ComputerName   = $exportObject.ComputerName
            FeatureCount   = $exportObject.FeatureCount
            ExportedAtUtc  = $exportObject.ExportedAtUtc
        }
    }
}
catch {
    Write-TSxStatus -Message ("Export-WindowsRolesAndFeatures failed. Error: {0}" -f $_.Exception.Message)
    throw
}
