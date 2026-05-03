<#
.SYNOPSIS
    Registers the RestPS listener as a Windows service using NSSM.

.DESCRIPTION
    Uses NSSM (Non-Sucking Service Manager) to install a Windows service that
    runs StartRestPS.ps1 via PowerShell. After installation the service
    description is set, and the service is started. NSSM and Chocolatey must
    already be installed before running this script.

.EXAMPLE
    .\"Make RestPS a Services.ps1"

.NOTES
    FileName:    Make RestPS a Services.ps1
    Author:      Mikael Nystrom
    Contact:     deploymentbunny@outlook.com
    Created:     2026-04-28
    Updated:     2026-04-28
    Twitter:     @mikael_nystrom

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author.
.LINK
    https://www.deploymentbunny.com
#>

#Requires -RunAsAdministrator

#region Configuration
$NewServiceName = 'RestPS'
$PoShScriptPath = 'C:\RestPSService\StartRestPS.ps1'
$ServiceDescription = 'RESTful API Service powered by RestPS'
#endregion

#region Check for elevation
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'This script must be run as Administrator. Aborting.'
    exit 1
}
#endregion

#region Resolve paths
# Prefer pwsh (PowerShell 7+) over powershell (Windows PowerShell) when available.
$NSSMExe = 'C:\ProgramData\chocolatey\bin\nssm.exe'
if (-not (Test-Path $NSSMExe)) {
    Write-Error "nssm.exe not found at '$NSSMExe'. Run 'Install Choclaty and NSSM.ps1' first."
    exit 1
}

$PoShPath = (Get-Command pwsh.exe -ErrorAction SilentlyContinue)?.Source
if (-not $PoShPath) {
    $PoShPath = (Get-Command powershell.exe -ErrorAction Stop).Source
}

if (-not (Test-Path $PoShScriptPath)) {
    Write-Error "Startup script not found at '$PoShScriptPath'."
    exit 1
}
#endregion

#region Install service
$ExistingService = Get-Service -Name $NewServiceName -ErrorAction SilentlyContinue

if ($ExistingService) {
    Write-Host "Service '$NewServiceName' already exists (Status: $($ExistingService.Status)). Skipping install." -ForegroundColor Yellow
}
else {
    Write-Host "Installing service '$NewServiceName'..." -ForegroundColor Cyan

    $PoShArgs = '-ExecutionPolicy Bypass -NoProfile -File "{0}"' -f $PoShScriptPath
    & $NSSMExe install $NewServiceName $PoShPath $PoShArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Error "nssm install failed with exit code $LASTEXITCODE."
        exit 1
    }

    & $NSSMExe set $NewServiceName Description $ServiceDescription
    Write-Host "Service '$NewServiceName' installed." -ForegroundColor Green
}
#endregion

#region Start service
Write-Host "Starting service '$NewServiceName'..." -ForegroundColor Cyan
try {
    Get-Service -Name $NewServiceName | Start-Service -ErrorAction Stop
    Write-Host "Service '$NewServiceName' started." -ForegroundColor Green
}
catch {
    Write-Error "Failed to start service '$NewServiceName': $_"
    exit 1
}
#endregion

#region Verify service
Write-Host "`nService status:" -ForegroundColor Cyan
Get-Service -Name $NewServiceName | Select-Object Name, Status, StartType | Format-Table -AutoSize
#endregion