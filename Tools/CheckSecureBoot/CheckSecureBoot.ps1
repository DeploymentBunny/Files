
<#
.SYNOPSIS
  Comprehensive Secure Boot diagnostics with registry,
  scheduled task, event correlation, and auto-classification.

.DESCRIPTION
  Designed for enterprise support escalation and OEM troubleshooting.
  Collects Secure Boot servicing signals and determines system state.

.OUTPUTS
  - Console summary
  - Log file (.log)
  - JSON diagnostics bundle (.json)

.NOTES
  Author: Secure Boot Support Toolkit
  Requires: Admin, UEFI system
#>

[CmdletBinding()]
param (
    [int]$SinceDays = 90,
    [string]$OutputDirectory = "$PSScriptRoot\SecureBoot-Diagnostics"
)

# --- Prep -----------------------------------------------------
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$LogFile   = "$OutputDirectory\SecureBoot-$Timestamp.log"
$JsonFile  = "$OutputDirectory\SecureBoot-$Timestamp.json"

function Write-Log {
    param($Message)
    $entry = "$(Get-Date -Format s) | $Message"
    $entry | Tee-Object -FilePath $LogFile -Append
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
$TaskPath = '\Microsoft\Windows\PI\Secure-Boot-Update'
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

# --- Output Bundle -------------------------------------------
$Result = [PSCustomObject]@{
    ComputerName = $env:COMPUTERNAME
    Timestamp    = Get-Date
    SystemState  = $SystemState
    Registry     = $Registry
    TaskHealth   = $TaskHealth
    Events       = $Events
}

$Result | ConvertTo-Json -Depth 5 | Out-File $JsonFile -Encoding UTF8
Write-Log "Diagnostics written to $JsonFile"

# --- Console Summary -----------------------------------------
Write-Host "`nSecure Boot System State: $SystemState" -ForegroundColor Cyan
Write-Host "Log file: $LogFile"
Write-Host "JSON bundle: $JsonFile"
