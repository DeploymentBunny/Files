<#
.SYNOPSIS
    Installs Chocolatey and the NSSM service manager.

.DESCRIPTION
    Bootstraps the Chocolatey package manager using the official install
    script, then uses Chocolatey to install NSSM (Non-Sucking Service
    Manager), which is used to register PowerShell scripts as Windows
    services.

    The script will:
    - Verify it is running with Administrator privileges and exit if not.
    - Skip the Chocolatey bootstrap when choco.exe is already present.
    - Skip the NSSM install when nssm.exe is already present.
    - Use Invoke-WebRequest + a temp file instead of Invoke-Expression on a
      live download, reducing the attack surface of the bootstrap.

.EXAMPLE
    .\"Install Choclaty and NSSM.ps1"

.NOTES
    FileName:    Install Choclaty and NSSM.ps1
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

#region Install Chocolatey
# Skip if choco.exe is already available on PATH.
if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
    Write-Host "Chocolatey is already installed ($(choco --version)). Skipping." -ForegroundColor Green
}
else {
    Write-Host "Installing Chocolatey..." -ForegroundColor Cyan

    # Download the bootstrap script to a temp file and execute it from disk
    # rather than piping a live HTTP response directly into Invoke-Expression.
    $ChocoInstallScript = Join-Path $env:TEMP 'Install-Chocolatey.ps1'
    try {
        Invoke-WebRequest -Uri 'https://community.chocolatey.org/install.ps1' `
                          -OutFile $ChocoInstallScript `
                          -UseBasicParsing `
                          -ErrorAction Stop

        & $ChocoInstallScript
        Write-Host "Chocolatey installed successfully." -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to install Chocolatey: $_"
        exit 1
    }
    finally {
        if (Test-Path $ChocoInstallScript) { Remove-Item $ChocoInstallScript -Force }
    }

    # Refresh PATH so choco.exe is available in the current session.
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path', 'User')
}
#endregion

#region Install NSSM
# Skip if nssm.exe is already available on PATH.
if (Get-Command nssm.exe -ErrorAction SilentlyContinue) {
    Write-Host "NSSM is already installed. Skipping." -ForegroundColor Green
}
else {
    Write-Host "Installing NSSM via Chocolatey..." -ForegroundColor Cyan
    choco install nssm --yes --no-progress
    if ($LASTEXITCODE -ne 0) {
        Write-Error "choco install nssm failed with exit code $LASTEXITCODE."
        exit 1
    }
    Write-Host "NSSM installed successfully." -ForegroundColor Green
}
#endregion