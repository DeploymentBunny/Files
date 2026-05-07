
<#
.Synopsis
        Comprehensive Secure Boot diagnostics and state classification.
.Description
        Collects Secure Boot servicing telemetry from event logs, registry, and
        scheduled task health to determine an overall system state.

        This script is intended for enterprise support and escalation workflows
        where Secure Boot update readiness, failures, and blocking conditions need
        fast triage with repeatable output artifacts.

        Output artifacts:
        - Console summary
        - Log file (.log)
        - JSON diagnostics bundle (.json)
        - Recommended actions based on detected state
.Example
    .\check-secureboot.ps1
.Example
    .\check-secureboot.ps1 -SinceDays 45 -OutputDirectory C:\Temp\SecureBoot
.Example
    .\check-secureboot.ps1 -Silent
.Notes
    ScriptName: check-secureboot.ps1
    Version:    1.0.2
        Updated:    2026-05-07
        Author:     Mikael Nystrom
        Blog:       https://www.deploymentbunny.com
        Disclaimer:
        This script is provided "AS IS" with no warranties, confers no rights and
        is not supported by the author.
.Link
        https://www.deploymentbunny.com
#>

[CmdletBinding()]
param (
    [int]$SinceDays = 90,
    [string]$OutputPath = "$env:TEMP\SecureBoot-Diagnostics",
    [switch]$Silent
)

# --- Prep -----------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = $OutputPath.Trim()
    $rootPath = [System.IO.Path]::GetPathRoot($OutputPath)
    if (-not [string]::IsNullOrWhiteSpace($rootPath) -and $OutputPath.Length -gt $rootPath.Length) {
        $OutputPath = $OutputPath.TrimEnd('\')
    }
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$LogFile   = "$OutputPath\SecureBoot-$Timestamp.log"
$JsonFile  = "$OutputPath\SecureBoot-$Timestamp.json"

function Write-Log {
    param($Message)
    $entry = "$(Get-Date -Format s) | $Message"

    if ($Silent) {
        Add-Content -Path $LogFile -Value $entry
    }
    else {
        $entry | Tee-Object -FilePath $LogFile -Append
    }
}

Write-Log "Starting Secure Boot diagnostics"

# --- Event Collection ----------------------------------------
$SecureBootEventIds = @(1032,1034,1036,1043,1044,1045,1795,1796,1799,1801,1802,1803,1808)

$Events = Get-WinEvent -FilterHashtable @{
    LogName   = 'System'
    Id        = $SecureBootEventIds
    StartTime = (Get-Date).AddDays(-$SinceDays)
} -ErrorAction SilentlyContinue |
Sort-Object TimeCreated |
Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message

Write-Log "Collected $($Events.Count) Secure Boot events"

# --- Registry Correlation ------------------------------------
$RegPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing'
$Registry = $null

if (Test-Path $RegPath) {
    $r = Get-ItemProperty $RegPath
    $Registry = [PSCustomObject]@{
        UEFICA2023Status      = $r.UEFICA2023Status
        UEFICA2023Error       = $r.UEFICA2023Error
        UEFICA2023ErrorEvent  = $r.UEFICA2023ErrorEvent
    }
    Write-Log "Read Secure Boot servicing registry"
} else {
    Write-Log "Secure Boot servicing registry not present"
}

# --- Scheduled Task Health -----------------------------------
$Task = Get-ScheduledTask -TaskPath '\Microsoft\Windows\PI\' `
                           -TaskName 'Secure-Boot-Update' `
                           -ErrorAction SilentlyContinue

$TaskHealth = if ($Task) {
    [PSCustomObject]@{
        Exists  = $true
        State   = (Get-ScheduledTaskInfo $Task).State
        Enabled = $Task.Enabled
    }
} else {
    [PSCustomObject]@{
        Exists  = $false
        State   = 'Missing'
        Enabled = $false
    }
}

Write-Log "Scheduled task exists: $($TaskHealth.Exists)"

# --- Auto Classification -------------------------------------
$EventIdsSeen = $Events.Id | Select-Object -Unique

$SystemState =
    if ($EventIdsSeen -contains 1808 -or $Registry.UEFICA2023Status -eq 'Updated') {
        '✅ OK'
    }
    elseif ($EventIdsSeen -contains 1802 -or $EventIdsSeen -contains 1803) {
        '❌ BLOCKED'
    }
    elseif ($EventIdsSeen | Where-Object { $_ -in 1795,1796 }) {
        '❌ FAILED'
    }
    elseif ($EventIdsSeen -contains 1801) {
        '⚠️ PENDING'
    }
    else {
        '❓ UNKNOWN'
    }

Write-Log "Classified system state as: $SystemState"

$RecommendedActions = switch ($SystemState) {
    '✅ OK' {
        @(
            'No immediate action required.',
            'Keep monthly quality updates current.',
            'Retain the Secure-Boot-Update scheduled task enabled for future servicing.'
        )
    }
    '⚠️ PENDING' {
        @(
            'Restart the device to allow pending Secure Boot servicing to continue.',
            'After restart, re-run this diagnostic script to verify completion.',
            'Confirm the Secure-Boot-Update scheduled task is enabled and healthy.'
        )
    }
    '❌ BLOCKED' {
        @(
            'Review Secure Boot policy and firmware settings for update blocks.',
            'Inspect recent Secure Boot servicing events (1802/1803) and registry error fields.',
            'Apply latest firmware/BIOS updates from the OEM before retrying servicing.'
        )
    }
    '❌ FAILED' {
        @(
            'Inspect failure events (1795/1796) and related Secure Boot servicing errors.',
            'Run SFC and DISM health checks, then install latest cumulative updates.',
            'Re-run Secure Boot servicing task and collect logs for escalation if failure persists.'
        )
    }
    default {
        @(
            'Collect additional diagnostics and verify firmware mode is UEFI with Secure Boot support.',
            'Confirm required registry/task artifacts exist and are readable.',
            'Escalate with generated JSON/log bundle if state remains unknown.'
        )
    }
}

Write-Log "Recommended actions generated: $($RecommendedActions.Count)"

# --- Output Bundle -------------------------------------------
$Result = [PSCustomObject]@{
    ComputerName = $env:COMPUTERNAME
    Timestamp    = Get-Date
    SystemState  = $SystemState
    RecommendedActions = $RecommendedActions
    Registry     = $Registry
    TaskHealth   = $TaskHealth
    Events       = $Events
}

$Result | ConvertTo-Json -Depth 5 | Out-File $JsonFile -Encoding UTF8
Write-Log "Diagnostics written to $JsonFile"

# --- Console Summary -----------------------------------------
if (-not $Silent) {
    Write-Host "`nSecure Boot System State: $SystemState" -ForegroundColor Cyan
    Write-Host "Recommended actions:" -ForegroundColor Yellow
    foreach ($action in $RecommendedActions) {
        Write-Host (" - {0}" -f $action)
    }
    Write-Host "Log file: $LogFile"
    Write-Host "JSON bundle: $JsonFile"
}
