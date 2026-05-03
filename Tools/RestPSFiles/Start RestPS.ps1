<#
.SYNOPSIS
    Starts the RestPS listener interactively.

.DESCRIPTION
    Launches Start-RestPSListener with a specified routes file and port.
    Use this script to start RestPS manually in an interactive session for
    testing or development. For a persistent service-based deployment use
    StartRestPS.ps1 together with NSSM.

.EXAMPLE
    .\"Start RestPS.ps1"

.NOTES
    FileName:    Start RestPS.ps1
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

#region Configuration
$RoutesFilePath = 'C:\RestPS\endpoints\RestPSRoutes.json'
$Port           = '8080'
#endregion

#region Pre-flight checks
# Verify the RestPS module is available before trying to start the listener.
if (-not (Get-Module -Name RestPS -ListAvailable)) {
    Write-Error "RestPS module is not installed. Run 'Install and Configure RestPS.ps1' first."
    exit 1
}

# Verify the routes file exists before starting.
if (-not (Test-Path $RoutesFilePath)) {
    Write-Error "Routes file not found at '$RoutesFilePath'. Run 'Install and Configure RestPS.ps1' first."
    exit 1
}
#endregion

#region Import module
Import-Module RestPS -Force -ErrorAction Stop
#endregion

#region Start listener
Write-Host "Starting RestPS listener on port $Port..." -ForegroundColor Cyan
Write-Host "Routes file: $RoutesFilePath" -ForegroundColor DarkGray
Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray

$RestPSparams = @{
    RoutesFilePath = $RoutesFilePath
    Port           = $Port
}
Start-RestPSListener @RestPSparams
#endregion