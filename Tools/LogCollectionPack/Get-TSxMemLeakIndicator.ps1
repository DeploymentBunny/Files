<#
.SYNOPSIS
    Collects a one-time memory and process snapshot for leak investigation.

.DESCRIPTION
    Captures memory counters and a few key process/service values and appends them to
    a CSV file for tracking long-term memory growth or process leak symptoms.

.NOTES
    FileName: Get-TSxMemLeakIndicator.ps1
    Version: 1.0.1
    Author: Deployment Bunny
    Contact: info@deploymentbunny.com
    Created: 2026-09-24
    Updated: 2026-09-24
    Twitter: @DeploymentBunny
    Disclaimer: This script is provided AS IS without warranty.

.LINK
    https://www.deploymentbunny.com
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param()

$Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

Write-Verbose 'Collecting memory counters.'
$mem = Get-Counter `
    '\Memory\Committed Bytes', `
    '\Memory\Commit Limit', `
    '\Memory\Available MBytes', `
    '\Memory\Pool Nonpaged Bytes', `
    '\Memory\Pool Paged Bytes'

$committedBytes = [double](($mem.CounterSamples | Where-Object { $_.Path -match 'Committed Bytes$' } | Select-Object -ExpandProperty CookedValue -First 1))
$commitLimit    = [double](($mem.CounterSamples | Where-Object { $_.Path -match 'Commit Limit$' } | Select-Object -ExpandProperty CookedValue -First 1))
$availMB        = [double](($mem.CounterSamples | Where-Object { $_.Path -match 'Available MBytes$' } | Select-Object -ExpandProperty CookedValue -First 1))
$nonPagedPool   = [double](($mem.CounterSamples | Where-Object { $_.Path -match 'Pool\s+Nonpaged\s+Bytes$' } | Select-Object -ExpandProperty CookedValue -First 1))
$pagedPool      = [double](($mem.CounterSamples | Where-Object { $_.Path -match 'Pool\s+Paged\s+Bytes$' } | Select-Object -ExpandProperty CookedValue -First 1))

Write-Verbose 'Collecting total process counts.'
$totalHandles = (Get-Counter '\Process(_Total)\Handle Count').CounterSamples.CookedValue
$totalThreads = (Get-Counter '\Process(_Total)\Thread Count').CounterSamples.CookedValue

function Get-ProcInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $processes = Get-Process -Name $Name -ErrorAction SilentlyContinue

    if ($processes) {
        [PSCustomObject]@{
            Handles = ($processes | Measure-Object -Property Handles -Sum).Sum
            Threads = ($processes | ForEach-Object { $_.Threads.Count } | Measure-Object -Sum).Sum
            PM_MB   = [Math]::Round((($processes | Measure-Object -Property PM -Sum).Sum / 1MB), 2)
            WS_MB   = [Math]::Round((($processes | Measure-Object -Property WS -Sum).Sum / 1MB), 2)
        }
    }
    else {
        [PSCustomObject]@{
            Handles = 0
            Threads = 0
            PM_MB   = 0
            WS_MB   = 0
        }
    }
}

$oracle  = Get-ProcInfo -Name 'oracle'
$msMpEng = Get-ProcInfo -Name 'MsMpEng'
$msSense = Get-ProcInfo -Name 'MsSense'
$wmiPrv  = Get-ProcInfo -Name 'wmiprvse'

$svcRpc   = (Get-Service -Name RpcSs -ErrorAction SilentlyContinue).Status
$svcDcom  = (Get-Service -Name DcomLaunch -ErrorAction SilentlyContinue).Status
$svcEvent = (Get-Service -Name EventSystem -ErrorAction SilentlyContinue).Status
$svcWmi   = (Get-Service -Name Winmgmt -ErrorAction SilentlyContinue).Status
$svcMsdtc = (Get-Service -Name MSDTC -ErrorAction SilentlyContinue).Status

$result = [PSCustomObject]@{
    Timestamp          = $Timestamp
    CommittedGB        = [Math]::Round($committedBytes / 1GB, 2)
    CommitLimitGB      = [Math]::Round($commitLimit / 1GB, 2)
    AvailableMB        = [Math]::Round($availMB, 0)
    NonPagedPoolMB     = [Math]::Round($nonPagedPool / 1MB, 4)
    PagedPoolMB        = [Math]::Round($pagedPool / 1MB, 4)
    PoolDeltaMB        = [Math]::Round(($pagedPool - $nonPagedPool) / 1MB, 4)

    TotalHandles       = $totalHandles
    TotalThreads       = $totalThreads

    OracleHandles  = $oracle.Handles
    OracleThreads  = $oracle.Threads
    OraclePM_MB    = $oracle.PM_MB
    OracleWS_MB    = $oracle.WS_MB

    MsMpEngHandles = $msMpEng.Handles
    MsMpEngThreads = $msMpEng.Threads
    MsMpEngPM_MB   = $msMpEng.PM_MB
    MsMpEngWS_MB   = $msMpEng.WS_MB

    MsSenseHandles = $msSense.Handles
    MsSenseThreads = $msSense.Threads
    MsSensePM_MB   = $msSense.PM_MB
    MsSenseWS_MB   = $msSense.WS_MB

    WmiPrvHandles  = $wmiPrv.Handles
    WmiPrvThreads  = $wmiPrv.Threads
    WmiPrvPM_MB    = $wmiPrv.PM_MB
    WmiPrvWS_MB    = $wmiPrv.WS_MB

    RpcSs          = $svcRpc
    DcomLaunch     = $svcDcom
    EventSystem    = $svcEvent
    Winmgmt        = $svcWmi
    MSDTC          = $svcMsdtc
}

$scriptBaseName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)
$logDateTime    = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$logFolder      = 'C:\Temp'
$logFileName    = '{0}_{1}_log.csv' -f $scriptBaseName, $logDateTime
$outputPath     = Join-Path -Path $logFolder -ChildPath $logFileName

if (-not (Test-Path -LiteralPath $logFolder)) {
    New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
}

Write-Verbose "Appending snapshot to $outputPath."
if ($PSCmdlet.ShouldProcess($outputPath, 'Append memory leak snapshot')) {
    $result | Export-Csv -Path $outputPath -Append -NoTypeInformation
}

$result