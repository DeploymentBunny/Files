<#
.Synopsis
    Script for Deployment Fundamentals Vol 6
.DESCRIPTION
    Script for Deployment Fundamentals Vol 6
.EXAMPLE
    Set-TSxTimeSync.ps1 –TimeSource "se.pool.ntp.org"
.NOTES
    Created:	 2015-12-15
    Version:	 1.0

    Author - Mikael Nystrom
    Twitter: @mikael_nystrom
    Blog   : http://deploymentbunny.com

    Author - Johan Arwidmark
    Twitter: @jarwidmark
    Blog   : http://deploymentresearch.com

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and 
    is not supported by the authors or Deployment Artist.
.LINK
    http://www.deploymentfundamentals.com
#>

[cmdletbinding(SupportsShouldProcess=$True)]
Param(
    [Parameter(Mandatory=$True,HelpMessage="Timeserver FQDN.")]
    [ValidateNotNullOrEmpty()]
    [String]$TimeSource
)

# Check for elevation
If (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
    [Security.Principal.WindowsBuiltInRole] "Administrator"))
{
    Write-Warning "Oupps, you need to run this script from an elevated PowerShell prompt!`nPlease start the PowerShell prompt as an Administrator and re-run the script."
	Write-Warning "Aborting script..."
    Throw
}

function Get-IsVirtual {
    $WMISystem = Get-WmiObject Win32_ComputerSystem
    $IsVirtual = $False
    if($WMISystem.Model -like "*Virtual*"){$IsVirtual = $true}
    return $IsVirtual 
} 

#Set Values
$NTPServer = $TimeSource + ',0x1'

# Set Registry Values
Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters\ -Name Type -Value NTP
Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config\ -Name AnnounceFlags -Value 5
Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpServer -Name Enabled -Value 1
Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters -Name NtpServer -Value $NTPServer
Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient -Name SpecialPollInterval -Value 900
Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config\ -Name MaxPosPhaseCorrection -Value 3600

if(Get-IsVirtual = "True"){
    Write-Verbose "Running a Virtual Machine"
    Write-Verbose "Will disable WMI TimeSync"
    Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\VMICTimeProvider -Name Enabled -Value 0
    }

#Restart the NTP Client
Register-WmiEvent -Query `
 "select * from __InstanceModificationEvent within 5 where targetinstance isa 'win32_service'" `
 -SourceIdentifier stopped
Stop-Service -Name W32Time
Wait-Event -SourceIdentifier stopped
Start-Service -Name W32Time
Unregister-Event -SourceIdentifier stopped
Start-Process w32tm.exe /resync -Wait
