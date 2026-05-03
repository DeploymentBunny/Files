<#
.SYNOPSIS
    Deploy Windows roles and features from a JSON export file to multiple servers simultaneously.
.DESCRIPTION
    Deploy-WindowsRolesAndFeatures reads a JSON file produced by
    Export-WindowsRolesAndFeatures.ps1 and installs the captured roles and
    features on one or more destination servers at the same time using parallel
    PowerShell background jobs. Each server gets its own job so deployments
    proceed concurrently rather than sequentially. Progress is reported as jobs
    complete. Features that are already installed are silently skipped. Features
    unavailable on a target OS version emit a warning and are skipped. If the OS
    version on a target differs from the exported source a warning is displayed.
.PARAMETER JSONConfigFile
    Path to the JSON file created by Export-WindowsRolesAndFeatures.ps1. Must be
    accessible from the machine running this script (local path or UNC share).
.PARAMETER DestinationServer
    One or more destination server names to deploy roles and features to.
    All servers are processed simultaneously in parallel background jobs.
.PARAMETER Credential
    Credentials used when connecting to the destination servers.
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
    When specified, returns a result object per destination server.
.PARAMETER ThrottleLimit
    Maximum number of parallel background jobs. Defaults to 8.
.EXAMPLE
    .\Deploy-WindowsRolesAndFeatures.ps1 -JSONConfigFile C:\Temp\roles.json -DestinationServer SRV01,SRV02,SRV03
.EXAMPLE
    .\Deploy-WindowsRolesAndFeatures.ps1 -JSONConfigFile \\fileserver\share\roles.json -DestinationServer SRV01,SRV02 -Credential (Get-Credential) -Verbose
.EXAMPLE
    .\Deploy-WindowsRolesAndFeatures.ps1 -JSONConfigFile C:\Temp\roles.json -DestinationServer SRV01,SRV02,SRV03 -RelaxedMode -Source E:\sources\sxs -WhatIf
.NOTES
    FileName:    Deploy-WindowsRolesAndFeatures.ps1
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
    Reads and validates the JSON export file. For each destination server a
    parallel background job is started that connects via Invoke-Command and
    applies the same install logic as Import-WindowsRolesAndFeatures.ps1:
    version mismatch warning, unavailable/already-installed skip, per-feature
    output, and optional relaxed name mapping. Jobs are throttled by
    -ThrottleLimit. Results are collected and returned when all jobs finish.
    Supports -Verbose and -WhatIf.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$JSONConfigFile,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$DestinationServer,

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
    [switch]$PassThru,

    [Parameter()]
    [ValidateRange(1, 64)]
    [int]$ThrottleLimit = 8,

    [Parameter()]
    [switch]$RestartIfNeeded,

    [Parameter()]
    [ValidateRange(1, 120)]
    [int]$JobTimeoutMinutes = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:LogFile = Join-Path $env:TEMP ("Deploy-WindowsRolesAndFeatures_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
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

Write-TSxStatus -Message "Deploy-WindowsRolesAndFeatures started"

# ── Validate input file ────────────────────────────────────────────────────────

if (-not (Test-Path -LiteralPath $JSONConfigFile)) {
    throw "Input file was not found: $JSONConfigFile"
}

if (Test-Path -LiteralPath $JSONConfigFile -PathType Container) {
    throw "-JSONConfigFile must be a file, not a folder."
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

$exportedOSVersion = if ($importObject.OperatingSystem -and $importObject.OperatingSystem.Version) {
    [string]$importObject.OperatingSystem.Version
}
else {
    $null
}

Write-TSxStatus -Message ("Found {0} features in export. Preparing to deploy to {1} server(s)." -f $featureNames.Count, $DestinationServer.Count)

# ── WhatIf guard ─────────────────────────────────────────────────────────────

$serverList = @($DestinationServer | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

foreach ($srv in $serverList) {
    if (-not $PSCmdlet.ShouldProcess($srv, "Deploy $($featureNames.Count) roles/features from '$JSONConfigFile'")) {
        return
    }
}

# ── Resolve install options ───────────────────────────────────────────────────

$defaultFeatureNameMap = @{
    'Windows-Defender-Features' = 'Windows-Defender'
    'InkAndHandwritingServices' = 'Server-Media-Foundation'
}

$resolvedFeatureMap    = if ($FeatureNameMap) { $FeatureNameMap } else { $defaultFeatureNameMap }
$doRestart             = $Restart.IsPresent
$includeMgmt           = $IncludeManagementTools
$resolvedSource        = $Source
$relaxed               = $RelaxedMode.IsPresent

# ── Remote scriptblock executed on each target ──────────────────────────────

$remoteInstallBlock = {
    param(
        [string[]]$FeatureNamesToInstall,
        [hashtable]$FeatureMap,
        [bool]$RelaxedModeEnabled,
        [bool]$IncludeManagementToolsParam,
        [bool]$DoRestart,
        [string]$SourceParam
    )

    $ErrorActionPreference = 'Stop'
    Import-Module ServerManager -ErrorAction Stop

    $featureNamesToProcess = @($FeatureNamesToInstall | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($featureNamesToProcess.Count -eq 0) {
        Write-Warning "No role/feature names were supplied. Nothing to install."
        return
    }

    $knownFeatures = @(Get-WindowsFeature | ForEach-Object { $_.Name })

    if ($RelaxedModeEnabled) {
        $mappedNames = foreach ($name in $featureNamesToProcess) {
            if ($knownFeatures -contains $name) {
                $name
                continue
            }

            if ($FeatureMap.ContainsKey($name)) {
                $mappedName = [string]$FeatureMap[$name]
                if (-not [string]::IsNullOrWhiteSpace($mappedName) -and $knownFeatures -contains $mappedName) {
                    Write-Warning "Role/feature '$name' is not available. Relaxed mode will use '$mappedName' instead."
                    $mappedName
                    continue
                }
            }

            $name
        }

        $featureNamesToProcess = @($mappedNames | Sort-Object -Unique)
    }

    $unavailable = @($featureNamesToProcess | Where-Object { $_ -notin $knownFeatures })
    $available   = @($featureNamesToProcess | Where-Object { $_ -in $knownFeatures })

    foreach ($name in $unavailable) {
        Write-Warning "Role/feature '$name' is not available on this system and will be skipped."
    }

    if ($available.Count -eq 0) {
        Write-Warning "None of the requested roles/features are available on this system. Nothing to install."
        return
    }

    $alreadyInstalled = @(
        Get-WindowsFeature -Name $available |
            Where-Object { $_.InstallState -eq 'Installed' } |
            ForEach-Object { $_.Name }
    )

    foreach ($name in $alreadyInstalled) {
        Write-Verbose "Skipping '$name' - already installed."
    }

    $toInstall = @($available | Where-Object { $_ -notin $alreadyInstalled })

    if ($toInstall.Count -eq 0) {
        Write-Verbose "All available roles/features are already installed. Nothing to do."
        return
    }

    $baseInstallParams = @{
        IncludeManagementTools = $IncludeManagementToolsParam
        Restart                = $DoRestart
        ErrorAction            = 'Stop'
    }

    if (-not [string]::IsNullOrWhiteSpace($SourceParam)) {
        $baseInstallParams.Source = $SourceParam
    }

    foreach ($item in $toInstall) {
        Write-Output ("INSTALL: Starting role/feature '{0}'" -f $item)
        $singleParams = @{} + $baseInstallParams
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
}

# ── Spawn parallel jobs ───────────────────────────────────────────────────────

$jobs = [System.Collections.Generic.List[hashtable]]::new()
$running = 0

foreach ($srv in $serverList) {
    # Throttle: wait until a slot is free
    while ($running -ge $ThrottleLimit) {
        $jobs | Where-Object { $_.Job.State -in 'Completed','Failed','Stopped' } | ForEach-Object {
            $running--
        }

        $jobs = [System.Collections.Generic.List[hashtable]]@(
            $jobs | Where-Object { $_.Job.State -notin 'Completed','Failed','Stopped' }
        )

        if ($running -ge $ThrottleLimit) {
            Start-Sleep -Milliseconds 500
        }
    }

    # Optionally check OS version before spawning
    if ($exportedOSVersion) {
        try {
            $checkParams = @{
                ComputerName = $srv
                ScriptBlock  = { (Get-CimInstance -ClassName Win32_OperatingSystem).Version }
                ErrorAction  = 'Stop'
            }

            if ($Credential) { $checkParams.Credential = $Credential }

            $targetVersion = Invoke-Command @checkParams

            if ($exportedOSVersion -ne [string]$targetVersion) {
                Write-Warning "[$srv] Importing on different version, some Roles or Features might not be available"
                Write-TSxStatus -Message "[$srv] OS version mismatch - exported: $exportedOSVersion, target: $targetVersion"
            }
            else {
                Write-TSxStatus -Message "[$srv] OS version match: $targetVersion"
            }
        }
        catch {
            Write-Warning "[$srv] Could not check OS version: $($_.Exception.Message)"
        }
    }

    Write-TSxStatus -Message "[$srv] Starting deployment job."

    $jobParams = @{
        ComputerName = $srv
        ScriptBlock  = $remoteInstallBlock
        ArgumentList = @(
            $featureNames,
            $resolvedFeatureMap,
            $relaxed,
            $includeMgmt,
            ($doRestart -and (-not $RestartIfNeeded.IsPresent)),
            $resolvedSource
        )
        ErrorAction  = 'Stop'
        AsJob        = $true
    }

    if ($Credential) { $jobParams.Credential = $Credential }

    $job = Invoke-Command @jobParams

    $jobs.Add(@{
        Server = $srv
        Job    = $job
    })

    $running++
}

# ── Collect results with timeout and restart handling ────────────────────────

Write-TSxStatus -Message ("Waiting for all deployment jobs to complete (timeout: {0} min per server)..." -f $JobTimeoutMinutes)

$allResults = foreach ($entry in $jobs) {
    $srv        = $entry.Server
    $job        = $entry.Job
    $timeoutSec = $JobTimeoutMinutes * 60

    Write-TSxStatus -Message ("[$srv] Waiting for deployment job...")

    $stopwatch     = [System.Diagnostics.Stopwatch]::StartNew()
    $lastNotifySec = 0

    while ($job.State -eq 'Running') {
        if ($stopwatch.Elapsed.TotalSeconds -ge $timeoutSec) {
            Write-Warning ("[$srv] Job timed out after {0} minutes. Stopping job." -f $JobTimeoutMinutes)
            Write-TSxStatus -Message ("[$srv] Timeout reached after {0} min - stopping job." -f $JobTimeoutMinutes)
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            break
        }

        $elapsedSec = [int]$stopwatch.Elapsed.TotalSeconds
        if (($elapsedSec - $lastNotifySec) -ge 30) {
            Write-TSxStatus -Message ("[$srv] Still deploying... ({0} min elapsed of {1} min timeout)" -f ([int]$stopwatch.Elapsed.TotalMinutes), $JobTimeoutMinutes)
            $lastNotifySec = $elapsedSec
        }

        Start-Sleep -Seconds 5
    }

    $didTimeOut = ($job.State -eq 'Stopped')

    if ($didTimeOut) {
        # ── Timeout path: verify what was actually installed ──────────────────
        Write-TSxStatus -Message ("[$srv] Job timed out. Verifying installed features on server...")

        try {
            $verifyParams = @{
                ComputerName = $srv
                ScriptBlock  = {
                    param([string[]]$Names)
                    Import-Module ServerManager -ErrorAction SilentlyContinue
                    Get-WindowsFeature -Name $Names | Select-Object Name, InstallState
                }
                ArgumentList = @(,$featureNames)
                ErrorAction  = 'Stop'
            }
            if ($Credential) { $verifyParams.Credential = $Credential }

            $verifyResult   = Invoke-Command @verifyParams
            $installedNames = @($verifyResult | Where-Object { $_.InstallState -eq 'Installed' } | ForEach-Object { $_.Name })
            $notInstalled   = @($featureNames | Where-Object { $_ -notin $installedNames })

            Write-TSxStatus -Message ("[$srv] Verification: {0}/{1} features are installed." -f $installedNames.Count, $featureNames.Count)

            if ($notInstalled.Count -gt 0) {
                Write-Warning ("[$srv] {0} feature(s) not installed after timeout: {1}" -f $notInstalled.Count, ($notInstalled -join ', '))
            }
            else {
                Write-TSxStatus -Message ("[$srv] All features verified as installed despite timeout.")
            }

            [PSCustomObject]@{
                Server   = $srv
                Success  = ($notInstalled.Count -eq 0)
                TimedOut = $true
                Result   = $verifyResult
                Error    = if ($notInstalled.Count -gt 0) { "Timed out - $($notInstalled.Count) feature(s) not installed: $($notInstalled -join ', ')" } else { "Timed out but all features verified installed" }
            }
        }
        catch {
            $connErr = $_.Exception.Message
            Write-Warning ("[$srv] Could not verify features after timeout (connection lost?): {0}" -f $connErr)
            Write-TSxStatus -Message ("[$srv] Post-timeout verification failed: {0}" -f $connErr)

            [PSCustomObject]@{
                Server   = $srv
                Success  = $false
                TimedOut = $true
                Result   = $null
                Error    = ("Job timed out after {0} min and verification failed (connection lost?): {1}" -f $JobTimeoutMinutes, $connErr)
            }
        }
        finally {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        # ── Normal completion path ────────────────────────────────────────────
        try {
            $jobResult = Receive-Job -Job $job -Wait -ErrorAction Stop
            Write-TSxStatus -Message ("[$srv] Deployment job completed.")

            # Check if any features required a restart
            $restartItems = @($jobResult | Where-Object { $null -ne $_ -and $_.PSObject.Properties['RestartNeeded'] -and $_.RestartNeeded -ne 'No' })

            if ($restartItems.Count -gt 0 -and $RestartIfNeeded.IsPresent) {
                Write-TSxStatus -Message ("[$srv] Restart required. Sending restart command...")

                try {
                    $restartInvokeParams = @{
                        ComputerName = $srv
                        ScriptBlock  = { Restart-Computer -Force }
                        ErrorAction  = 'Stop'
                    }
                    if ($Credential) { $restartInvokeParams.Credential = $Credential }

                    Invoke-Command @restartInvokeParams
                    Write-TSxStatus -Message ("[$srv] Restart command sent. Waiting for server to go offline...")

                    # Wait for server to go offline (up to 2 minutes)
                    $offlineWait = 0
                    while ($offlineWait -lt 120) {
                        Start-Sleep -Seconds 5
                        $offlineWait += 5
                        if (-not (Test-Connection -ComputerName $srv -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
                            Write-TSxStatus -Message ("[$srv] Server is offline. Waiting for it to come back online...")
                            break
                        }
                    }

                    # Wait for server to come back online (up to 10 minutes)
                    $onlineWait = 0
                    $cameBack   = $false
                    while ($onlineWait -lt 600) {
                        Start-Sleep -Seconds 10
                        $onlineWait += 10
                        if (Test-Connection -ComputerName $srv -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                            Write-TSxStatus -Message ("[$srv] Server is back online. Waiting 15 seconds for WinRM to start...")
                            Start-Sleep -Seconds 15
                            $cameBack = $true
                            break
                        }
                        if (($onlineWait % 60) -eq 0) {
                            Write-TSxStatus -Message ("[$srv] Still waiting for server to return... ({0} sec elapsed)" -f $onlineWait)
                        }
                    }

                    if (-not $cameBack) {
                        Write-Warning ("[$srv] Server did not come back online within 10 minutes after restart.")
                        [PSCustomObject]@{
                            Server   = $srv
                            Success  = $false
                            TimedOut = $false
                            Result   = $jobResult
                            Error    = "Server did not come back online within 10 minutes after restart."
                        }
                    }
                    else {
                        # Verify features after restart
                        Write-TSxStatus -Message ("[$srv] Verifying features after restart...")
                        $postRestartVerifyParams = @{
                            ComputerName = $srv
                            ScriptBlock  = {
                                param([string[]]$Names)
                                Import-Module ServerManager -ErrorAction SilentlyContinue
                                Get-WindowsFeature -Name $Names | Select-Object Name, InstallState
                            }
                            ArgumentList = @(,$featureNames)
                            ErrorAction  = 'Stop'
                        }
                        if ($Credential) { $postRestartVerifyParams.Credential = $Credential }

                        $verifyResult   = Invoke-Command @postRestartVerifyParams
                        $installedNames = @($verifyResult | Where-Object { $_.InstallState -eq 'Installed' } | ForEach-Object { $_.Name })
                        $notInstalled   = @($featureNames | Where-Object { $_ -notin $installedNames })

                        if ($notInstalled.Count -gt 0) {
                            Write-Warning ("[$srv] After restart, {0} feature(s) still not installed: {1}" -f $notInstalled.Count, ($notInstalled -join ', '))
                        }
                        else {
                            Write-TSxStatus -Message ("[$srv] All features verified as installed after restart.")
                        }

                        [PSCustomObject]@{
                            Server   = $srv
                            Success  = ($notInstalled.Count -eq 0)
                            TimedOut = $false
                            Result   = $verifyResult
                            Error    = if ($notInstalled.Count -gt 0) { "Features not installed after restart: $($notInstalled -join ', ')" } else { $null }
                        }
                    }
                }
                catch {
                    $restartErr = $_.Exception.Message
                    Write-Warning ("[$srv] Restart/verify failed: {0}" -f $restartErr)
                    Write-TSxStatus -Message ("[$srv] Restart handling error: {0}" -f $restartErr)

                    [PSCustomObject]@{
                        Server   = $srv
                        Success  = $false
                        TimedOut = $false
                        Result   = $jobResult
                        Error    = ("Restart/verify failed: {0}" -f $restartErr)
                    }
                }
            }
            elseif ($restartItems.Count -gt 0) {
                Write-Warning ("[$srv] Deployment completed but a restart is required. Enable 'Restart if needed' to automate reboot and verification.")
                Write-TSxStatus -Message ("[$srv] Deployment done, restart pending.")

                [PSCustomObject]@{
                    Server   = $srv
                    Success  = $true
                    TimedOut = $false
                    Result   = $jobResult
                    Error    = $null
                }
            }
            else {
                Write-TSxStatus -Message ("[$srv] Deployment completed. No restart required.")

                [PSCustomObject]@{
                    Server   = $srv
                    Success  = $true
                    TimedOut = $false
                    Result   = $jobResult
                    Error    = $null
                }
            }
        }
        catch {
            $errMsg = $_.Exception.Message
            Write-Warning ("[$srv] Deployment failed: {0}" -f $errMsg)
            Write-TSxStatus -Message ("[$srv] Deployment failed: {0}" -f $errMsg)

            [PSCustomObject]@{
                Server   = $srv
                Success  = $false
                TimedOut = $false
                Result   = $null
                Error    = $errMsg
            }
        }
        finally {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }
}

# ── Summary ──────────────────────────────────────────────────────────────────

$succeeded    = @($allResults | Where-Object { $_.Success })
$failed       = @($allResults | Where-Object { -not $_.Success })
$timedOutList = @($allResults | Where-Object { $_.TimedOut })

Write-TSxStatus -Message ("Deploy-WindowsRolesAndFeatures completed. Succeeded: {0}, Failed: {1}, TimedOut: {2}. Log: {3}" -f $succeeded.Count, $failed.Count, $timedOutList.Count, $Script:LogFile)

if ($timedOutList.Count -gt 0) {
    foreach ($t in $timedOutList) {
        Write-Warning ("[{0}] Job timed out after {1} minutes. {2}" -f $t.Server, $JobTimeoutMinutes, $t.Error)
    }
}

if ($failed.Count -gt 0) {
    foreach ($f in $failed) {
        Write-Warning ("Deploy failed on '{0}': {1}" -f $f.Server, $f.Error)
    }
}

if ($PassThru) {
    $allResults
}
