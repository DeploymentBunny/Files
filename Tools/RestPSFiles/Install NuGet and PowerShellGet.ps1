<#
.SYNOPSIS
    Installs the NuGet provider, updates PowerShellGet, and refreshes all modules.

.DESCRIPTION
    Ensures the NuGet package provider is present so that Install-Module works
    reliably, upgrades PowerShellGet to the latest version, and then updates
    all currently installed modules. Run this as a prerequisite before
    installing RestPS or other Gallery modules.

.EXAMPLE
    .\"Install NuGet and PowerShellGet.ps1"

.NOTES
    FileName:    Install NuGet and PowerShellGet.ps1
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

#region Check for elevation
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator. Aborting."
    exit 1
}
#endregion

#region Install or update NuGet provider
# NuGet is required for Install-Module to work against the PowerShell Gallery.
Write-Host "Checking NuGet package provider..." -ForegroundColor Cyan

$NuGetInstalled = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
$NuGetGallery   = Find-PackageProvider -Name NuGet -ErrorAction Stop | Select-Object -First 1

if ($NuGetInstalled -and ($NuGetInstalled.Version -ge $NuGetGallery.Version)) {
    Write-Host "  NuGet $($NuGetInstalled.Version) is already up to date. Skipping." -ForegroundColor Green
}
else {
    Write-Host "  Installing NuGet $($NuGetGallery.Version)..." -ForegroundColor Yellow
    Install-PackageProvider -Name NuGet -Force -Verbose -ErrorAction Stop
    Write-Host "  NuGet installed." -ForegroundColor Green
}
#endregion

#region Install or update PowerShellGet
# PowerShellGet must be updated before other modules so the latest
# Install-Module / Find-Module cmdlets are available.
Write-Host "Checking PowerShellGet module..." -ForegroundColor Cyan

$PSGetInstalled = Get-Module -Name PowerShellGet -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
$PSGetGallery   = Find-Module -Name PowerShellGet -ErrorAction Stop

if ($PSGetInstalled -and ($PSGetInstalled.Version -ge $PSGetGallery.Version)) {
    Write-Host "  PowerShellGet $($PSGetInstalled.Version) is already up to date. Skipping." -ForegroundColor Green
}
else {
    Write-Host "  Installing PowerShellGet $($PSGetGallery.Version)..." -ForegroundColor Yellow
    Install-Module -Name PowerShellGet -Force -SkipPublisherCheck -Verbose -ErrorAction Stop
    Write-Host "  PowerShellGet installed. Restart the session to use the new version." -ForegroundColor Green
}
#endregion

#region Update all installed modules
# Update all modules that have a newer version available in the Gallery.
Write-Host "Updating all installed modules..." -ForegroundColor Cyan
try {
    Update-Module -Force -Verbose -ErrorAction Stop
    Write-Host "All modules updated." -ForegroundColor Green
}
catch {
    Write-Warning "One or more modules could not be updated: $_"
}
#endregion
