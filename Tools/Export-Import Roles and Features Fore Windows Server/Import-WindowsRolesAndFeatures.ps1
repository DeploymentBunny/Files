<#
.SYNOPSIS
    Import and install Windows roles and features from a JSON export file.
.DESCRIPTION
    Import-WindowsRolesAndFeatures reads a JSON file produced by
    Export-WindowsRolesAndFeatures.ps1 and installs any roles and features that
    are not yet present on the local or a remote computer. Features that are
    already installed are silently skipped. Features that do not exist on the
    target OS version emit a warning and are skipped. If the OS version of the
    target differs from the exported source, a warning is displayed.
.PARAMETER JSONConfigFile
    Path to the JSON file created by Export-WindowsRolesAndFeatures.ps1. Must be
    accessible from the machine running this script (local path or UNC share).
.PARAMETER ComputerName
    Name of the remote computer to install roles and features on. When omitted
    the local computer is used. Installation is performed via Invoke-Command.
.PARAMETER Credential
    Credentials to use when connecting to a remote computer.
.PARAMETER IncludeManagementTools
    Whether to include management tools when installing features. Defaults to
    true.
.PARAMETER Restart
    Automatically restart the computer if required after installation.
.PARAMETER Source
    Alternate source path passed to Install-WindowsFeature (e.g. WIM or SxS).
.PARAMETER RelaxedMode
    Enables compatibility mapping for known feature-name differences between
    Windows versions. When enabled, unavailable feature names can be mapped to
    alternative names if present in the mapping table.
.PARAMETER FeatureNameMap
    Optional custom hashtable used when -RelaxedMode is enabled.
    Key = source feature name from JSON; Value = target feature name to install.
    If omitted, the script uses the built-in default mapping table.
.PARAMETER PassThru
    When specified, returns the Install-WindowsFeature result object.
.EXAMPLE
    .\Import-WindowsRolesAndFeatures.ps1 -JSONConfigFile C:\Temp\roles.json
.EXAMPLE
    .\Import-WindowsRolesAndFeatures.ps1 -JSONConfigFile \\fileserver\share\SRV01.json -ComputerName SRV02 -Verbose
.EXAMPLE
    .\Import-WindowsRolesAndFeatures.ps1 -JSONConfigFile C:\Temp\roles.json -RelaxedMode -Source E:\sources\sxs -FeatureNameMap @{ 'Windows-Defender-Features'='Windows-Defender' } -Verbose
.NOTES
    FileName:    Import-WindowsRolesAndFeatures.ps1
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
    Reads and validates the JSON export file. Compares the exported OS version
    against the target system and warns on a mismatch. On the target machine,
    checks which requested features are unavailable on this OS (warns and skips),
    which are already installed (verbose skip), and installs only the remainder.
    In install phase, outputs visible per-item progress lines for each role or
    feature being installed. Supports -Verbose and -WhatIf.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
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
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:LogFile = Join-Path $env:TEMP ("Import-WindowsRolesAndFeatures_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
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

function Get-TSxPendingRestartStateLocal {
    $reasons = New-Object System.Collections.Generic.List[string]

    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $reasons.Add('ComponentBasedServicing')
    }

    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $reasons.Add('WindowsUpdate')
    }

    try {
        $sessionManager = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
        if ($sessionManager.PendingFileRenameOperations) {
            $reasons.Add('PendingFileRenameOperations')
        }
    }
    catch {
    }

    try {
        $computerNameKey = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -ErrorAction Stop
        $pendingNameKey = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction Stop
        if ($computerNameKey.ComputerName -ne $pendingNameKey.ComputerName) {
            $reasons.Add('PendingComputerRename')
        }
    }
    catch {
    }

    [PSCustomObject]@{
        ComputerName = $env:COMPUTERNAME
        IsPending    = $reasons.Count -gt 0
        Reasons      = @($reasons)
    }
}

function Get-TSxPendingRestartState {
    param(
        [string]$TargetComputerName,
        [System.Management.Automation.PSCredential]$TargetCredential
    )

    if ([string]::IsNullOrWhiteSpace($TargetComputerName)) {
        return Get-TSxPendingRestartStateLocal
    }

    $invokeParams = @{
        ComputerName = $TargetComputerName
        ScriptBlock  = ${function:Get-TSxPendingRestartStateLocal}
        ErrorAction  = 'Stop'
    }

    if ($TargetCredential) {
        $invokeParams.Credential = $TargetCredential
    }

    Invoke-Command @invokeParams
}

function Write-TSxPendingRestartStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetComputerName,

        [Parameter(Mandatory = $true)]
        [psobject]$PendingState,

        [Parameter(Mandatory = $true)]
        [string]$Phase
    )

    if ($PendingState.IsPending) {
        $reasonText = if ($PendingState.Reasons.Count -gt 0) { $PendingState.Reasons -join ', ' } else { 'Unknown' }
        Write-Warning ("[{0}] Pending restart detected during {1}: {2}" -f $TargetComputerName, $Phase, $reasonText)
        Write-TSxStatus -Message ("[{0}] Pending restart detected during {1}: {2}" -f $TargetComputerName, $Phase, $reasonText)
    }
    else {
        Write-TSxStatus -Message ("[{0}] No pending restart detected during {1}." -f $TargetComputerName, $Phase)
    }
}

function Restart-TSxComputerAndWait {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetComputerName,

        [System.Management.Automation.PSCredential]$TargetCredential,

        [int]$TimeoutSeconds = 600
    )

    Write-TSxStatus -Message ("[{0}] Restarting computer and waiting for it to come back online..." -f $TargetComputerName)

    if ($TargetComputerName -eq $env:COMPUTERNAME) {
        Restart-Computer -Force -Wait -For PowerShell -Timeout $TimeoutSeconds -Delay 5
        Write-TSxStatus -Message ("[{0}] Restart completed and PowerShell is available again." -f $TargetComputerName)
        return
    }

    $restartParams = @{
        ComputerName = $TargetComputerName
        Force        = $true
        Wait         = $true
        For          = 'PowerShell'
        Timeout      = $TimeoutSeconds
        Delay        = 5
        ErrorAction  = 'Stop'
    }

    if ($TargetCredential) {
        $restartParams.Credential = $TargetCredential
    }

    Restart-Computer @restartParams
    Write-TSxStatus -Message ("[{0}] Restart completed and PowerShell is available again." -f $TargetComputerName)
}

Write-TSxStatus -Message "Import-WindowsRolesAndFeatures started"

if (-not (Test-Path -LiteralPath $JSONConfigFile)) {
    throw "Input file was not found: $JSONConfigFile"
}

if (Test-Path -LiteralPath $JSONConfigFile -PathType Container) {
    throw "-JSONConfigFile must be a file, not a folder"
}

Write-TSxStatus -Message "Reading roles/features export file '$JSONConfigFile'."
$importObject = Get-Content -LiteralPath $JSONConfigFile -Raw | ConvertFrom-Json

if (-not $importObject.Features) {
    throw "Input file '$JSONConfigFile' does not contain a 'Features' collection."
}

$featureNames = @(
    $importObject.Features |
        ForEach-Object { $_.Name } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
)

if ($featureNames.Count -eq 0) {
    throw "No feature names were found in '$JSONConfigFile'."
}

$targetComputer = if ([string]::IsNullOrWhiteSpace($ComputerName)) { $env:COMPUTERNAME } else { $ComputerName }

if ($importObject.OperatingSystem -and $importObject.OperatingSystem.Version) {
    $exportedVersion = [string]$importObject.OperatingSystem.Version
    $targetVersion = if ([string]::IsNullOrWhiteSpace($ComputerName)) {
        (Get-CimInstance -ClassName Win32_OperatingSystem).Version
    }
    else {
        $versionInvokeParams = @{
            ComputerName = $ComputerName
            ScriptBlock  = { (Get-CimInstance -ClassName Win32_OperatingSystem).Version }
            ErrorAction  = 'Stop'
        }

        if ($Credential) {
            $versionInvokeParams.Credential = $Credential
        }

        Invoke-Command @versionInvokeParams
    }

    if ($exportedVersion -ne [string]$targetVersion) {
        Write-Warning "Importing on different version, some Roles or Features might not be available"
        Write-TSxStatus -Message "OS version mismatch - exported: $exportedVersion, current: $targetVersion"
    }
    else {
        Write-TSxStatus -Message "OS version match: $targetVersion"
    }
}

if (-not $PSCmdlet.ShouldProcess($targetComputer, "Install $($featureNames.Count) roles/features from '$JSONConfigFile'")) {
    return
}

$defaultFeatureNameMap = @{
    'Windows-Defender-Features' = 'Windows-Defender'
    'InkAndHandwritingServices' = 'Server-Media-Foundation'
}

$featureMapForInstall = if ($FeatureNameMap) { $FeatureNameMap } else { $defaultFeatureNameMap }
$doRestartForInstall = $Restart.IsPresent
$includeMgmtToolsForInstall = $IncludeManagementTools
$sourceForInstall = $Source
$relaxedModeForInstall = $RelaxedMode.IsPresent

$installFeaturesLocal = {
    $ErrorActionPreference = 'Stop'
    Import-Module ServerManager -ErrorAction Stop

    $featureNamesToProcess = @($featureNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($featureNamesToProcess.Count -eq 0) {
        Write-Warning "No role/feature names were supplied. Nothing to install."
        return
    }

    $knownFeatures = @(Get-WindowsFeature | ForEach-Object { $_.Name })

    if ($relaxedModeForInstall) {
        $mappedFeatureNames = foreach ($name in $featureNamesToProcess) {
            if ($knownFeatures -contains $name) {
                $name
                continue
            }

            if ($featureMapForInstall.ContainsKey($name)) {
                $mappedName = [string]$featureMapForInstall[$name]
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

    $unavailable   = @($featureNamesToProcess | Where-Object { $_ -notin $knownFeatures })
    $available     = @($featureNamesToProcess | Where-Object { $_ -in $knownFeatures })

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
        IncludeManagementTools = $includeMgmtToolsForInstall
        Restart                = $doRestartForInstall
        ErrorAction            = 'Stop'
    }

    if (-not [string]::IsNullOrWhiteSpace($sourceForInstall)) {
        $installParams.Source = $sourceForInstall
    }

    $installResults = foreach ($item in $toInstall) {
        Write-Output ("INSTALL: Starting role/feature '{0}'" -f $item)
        $singleParams = @{} + $installParams
        $singleParams.Name = $item

        $singleResult = Install-WindowsFeature @singleParams

        if ($singleResult.Success) {
            Write-Output ("INSTALL: Completed role/feature '{0}'" -f $item)
        }
        else {
            Write-Warning ("INSTALL: Role/feature '{0}' did not report success." -f $item)
        }

        $singleResult
    }

    $installResults
}

$installFeaturesRemote = {
    $ErrorActionPreference = 'Stop'
    Import-Module ServerManager -ErrorAction Stop
    $featureMap = $using:featureMapForInstall

    $featureNamesToProcess = @($using:featureNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($featureNamesToProcess.Count -eq 0) {
        Write-Warning "No role/feature names were supplied. Nothing to install."
        return
    }

    $knownFeatures = @(Get-WindowsFeature | ForEach-Object { $_.Name })

    if ($using:relaxedModeForInstall) {
        $mappedFeatureNames = foreach ($name in $featureNamesToProcess) {
            if ($knownFeatures -contains $name) {
                $name
                continue
            }

            if ($featureMap.ContainsKey($name)) {
                $mappedName = [string]$featureMap[$name]
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

    $unavailable   = @($featureNamesToProcess | Where-Object { $_ -notin $knownFeatures })
    $available     = @($featureNamesToProcess | Where-Object { $_ -in $knownFeatures })

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
        IncludeManagementTools = $using:includeMgmtToolsForInstall
        Restart                = $using:doRestartForInstall
        ErrorAction            = 'Stop'
    }

    if (-not [string]::IsNullOrWhiteSpace($using:sourceForInstall)) {
        $installParams.Source = $using:sourceForInstall
    }

    $installResults = foreach ($item in $toInstall) {
        Write-Output ("INSTALL: Starting role/feature '{0}'" -f $item)
        $singleParams = @{} + $installParams
        $singleParams.Name = $item

        $singleResult = Install-WindowsFeature @singleParams

        if ($singleResult.Success) {
            Write-Output ("INSTALL: Completed role/feature '{0}'" -f $item)
        }
        else {
            Write-Warning ("INSTALL: Role/feature '{0}' did not report success." -f $item)
        }

        $singleResult
    }

    $installResults
}

try {
    $pendingBeforeInstall = Get-TSxPendingRestartState -TargetComputerName $ComputerName -TargetCredential $Credential
    Write-TSxPendingRestartStatus -TargetComputerName $targetComputer -PendingState $pendingBeforeInstall -Phase 'before install'

    if ($pendingBeforeInstall.IsPending -and $Restart.IsPresent) {
        Restart-TSxComputerAndWait -TargetComputerName $targetComputer -TargetCredential $Credential
        $pendingAfterPreInstallRestart = Get-TSxPendingRestartState -TargetComputerName $ComputerName -TargetCredential $Credential
        Write-TSxPendingRestartStatus -TargetComputerName $targetComputer -PendingState $pendingAfterPreInstallRestart -Phase 'after pre-install restart'
    }

    Write-TSxStatus -Message "Installing roles/features on '$targetComputer'."

    $result = if ([string]::IsNullOrWhiteSpace($ComputerName)) {
        & $installFeaturesLocal
    }
    else {
        $invokeParams = @{
            ComputerName = $ComputerName
            ScriptBlock  = $installFeaturesRemote
            ErrorAction  = 'Stop'
        }

        if ($Credential) {
            $invokeParams.Credential = $Credential
        }

        Invoke-Command @invokeParams
    }

    $restartNeededFromInstall = @($result | Where-Object { $null -ne $_ -and $_.PSObject.Properties['RestartNeeded'] -and $_.RestartNeeded -ne 'No' }).Count -gt 0
    if ($restartNeededFromInstall) {
        Write-TSxStatus -Message ("[{0}] Installation reported that a restart is required." -f $targetComputer)
    }

    $pendingAfterInstall = Get-TSxPendingRestartState -TargetComputerName $ComputerName -TargetCredential $Credential
    Write-TSxPendingRestartStatus -TargetComputerName $targetComputer -PendingState $pendingAfterInstall -Phase 'after install'

    if ($pendingAfterInstall.IsPending -and $Restart.IsPresent) {
        Restart-TSxComputerAndWait -TargetComputerName $targetComputer -TargetCredential $Credential
        $pendingAfterFinalRestart = Get-TSxPendingRestartState -TargetComputerName $ComputerName -TargetCredential $Credential
        Write-TSxPendingRestartStatus -TargetComputerName $targetComputer -PendingState $pendingAfterFinalRestart -Phase 'after final restart'
    }

    Write-TSxStatus -Message "Import-WindowsRolesAndFeatures completed successfully. Log: $Script:LogFile"

    if ($PassThru) {
        $result
    }
}
catch {
    $errorMessage = "Import-WindowsRolesAndFeatures failed. Error: {0}" -f $_.Exception.Message
    Write-TSxStatus -Message $errorMessage
    Write-Warning $errorMessage
}
