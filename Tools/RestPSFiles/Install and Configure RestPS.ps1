<#
.SYNOPSIS
    Installs and performs initial configuration of the RestPS module.

.DESCRIPTION
    Downloads the RestPS module from the PowerShell Gallery, imports it,
    and runs Invoke-DeployRestPS to scaffold the initial directory structure
    and configuration files under C:\RestPS.

    The script will:
    - Verify it is running with Administrator privileges and exit if not.
    - Check whether RestPS is already installed and skip installation if the
      current version is already up to date.
    - Install or update the module from the PowerShell Gallery.
    - Import the module into the current session.
    - Run Invoke-DeployRestPS only when C:\RestPS does not yet exist, to
      avoid overwriting an existing configuration.

.EXAMPLE
    .\"Install and Configure RestPS.ps1"

.NOTES
    FileName:    Install and Configure RestPS.ps1
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

$ModuleName = 'RestPS'
$LocalDir   = 'C:\RestPS'

#region Check for elevation
# #Requires -RunAsAdministrator handles this, but an explicit message helps
# when the script is dot-sourced or called from another script.
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator. Aborting."
    exit 1
}
#endregion

#region Install or update the module
# Check whether the module is already installed and whether a newer version
# is available in the Gallery before attempting an install.
Write-Host "Checking PowerShell Gallery for module: $ModuleName" -ForegroundColor Cyan

$GalleryModule    = Find-Module -Name $ModuleName -ErrorAction Stop
$InstalledModule  = Get-Module -Name $ModuleName -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1

if ($InstalledModule -and ($InstalledModule.Version -ge $GalleryModule.Version)) {
    Write-Host "  $ModuleName $($InstalledModule.Version) is already up to date. Skipping install." -ForegroundColor Green
}
else {
    if ($InstalledModule) {
        Write-Host "  Updating $ModuleName from $($InstalledModule.Version) to $($GalleryModule.Version)..." -ForegroundColor Yellow
    }
    else {
        Write-Host "  Installing $ModuleName $($GalleryModule.Version)..." -ForegroundColor Yellow
    }
    Install-Module -Name $ModuleName -SkipPublisherCheck -Force -Verbose
}
#endregion

#region Import the module
Write-Host "Importing module: $ModuleName" -ForegroundColor Cyan
Import-Module -Name $ModuleName -Force -Verbose
#endregion

#region Initial configuration
# Only scaffold the RestPS directory when it does not already exist, so that
# a re-run of this script does not overwrite customised route or config files.
if (Test-Path -Path $LocalDir) {
    Write-Host "Local directory '$LocalDir' already exists. Skipping Invoke-DeployRestPS." -ForegroundColor Yellow
}
else {
    Write-Host "Running initial deployment to '$LocalDir'..." -ForegroundColor Cyan
    Invoke-DeployRestPS -LocalDir $LocalDir -Verbose
    Write-Host "Initial configuration complete." -ForegroundColor Green
}
#endregion


