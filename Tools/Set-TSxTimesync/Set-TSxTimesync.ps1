<#
.SYNOPSIS
    Configure Windows time synchronization.
.DESCRIPTION
    Configures Windows time synchronization by setting the NTP time source, applying
    registry settings, restarting the Windows Time service, and resyncing the clock.
    Defaults to pool.ntp.org if no time source is specified. Self-elevates to local
    Administrator if not already running elevated. Writes a log to %TEMP% and supports
    -Verbose for detailed progress output.
.EXAMPLE
    .\Set-TSxTimesync.ps1
.EXAMPLE
    .\Set-TSxTimesync.ps1 -TimeSource "se.pool.ntp.org"
.NOTES
    FileName:    Set-TSxTimesync.ps1
    Author:      Mikael Nystrom
    Contact:     deploymentbunny@outlook.com
    Created:     2015-12-15
    Updated:     2026-04-23
    Web:         https://www.deploymentbunny.com
    Twitter:     @mikael_nystrom

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author.
.LINK
    https://www.deploymentbunny.com
.FUNCTIONALITY
    Sets W32Time registry values for NTP synchronization, optionally disables the
    Hyper-V time sync provider on virtual machines, restarts the W32Time service,
    resyncs the clock via w32tm /resync, and outputs the resulting configuration
    and status. Writes a timestamped log file to %TEMP%.
#>

[cmdletbinding()]
Param(
    [Parameter(Mandatory=$False,HelpMessage="Timeserver FQDN.")]
    [ValidateNotNullOrEmpty()]
    [String]$TimeSource = "pool.ntp.org"
)

# Check for elevation
$myWindowsID = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal($myWindowsID)
$adminRole = [System.Security.Principal.WindowsBuiltInRole]::Administrator

if ($myWindowsPrincipal.IsInRole($adminRole)) {
    $Host.UI.RawUI.WindowTitle = $myInvocation.MyCommand.Definition + " (Elevated)"
}
else {
    $newProcess = New-Object System.Diagnostics.ProcessStartInfo "PowerShell"
    $newProcess.Arguments = "-NoProfile -File `"$($myInvocation.MyCommand.Definition)`" -TimeSource `"$TimeSource`""
    $newProcess.Verb = "runas"
    $newProcess.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Minimized

    [System.Diagnostics.Process]::Start($newProcess) | Out-Null
    exit
}

function Get-IsVirtual {
    $WMISystem = Get-WmiObject Win32_ComputerSystem
    $IsVirtual = $False
    if($WMISystem.Model -like "*Virtual*"){$IsVirtual = $true}
    return $IsVirtual 
}

function Write-TSxLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $runUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    Add-Content -Path $Script:LogFile -Value ("[{0}] [User: {1}] {2}" -f $timestamp, $runUser, $Message)
}

$Script:LogFile = Join-Path $env:TEMP ("Set-TSxTimesync_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
Write-Verbose "Log file: $Script:LogFile"
Write-TSxLog -Message "Set-TSxTimesync started. TimeSource=$TimeSource"

#Set Values
$NTPServer = $TimeSource + ',0x1'
Write-Verbose "NTP server string: $NTPServer"
Write-TSxLog -Message "NTP server string: $NTPServer"

# Set Registry Values
Write-Verbose "Setting registry: Type=NTP"
Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters\ -Name Type -Value NTP
Write-Verbose "Setting registry: AnnounceFlags=5"
Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config\ -Name AnnounceFlags -Value 5
Write-Verbose "Setting registry: NtpServer Enabled=1"
Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpServer -Name Enabled -Value 1
Write-Verbose "Setting registry: NtpServer=$NTPServer"
Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters -Name NtpServer -Value $NTPServer
Write-Verbose "Setting registry: SpecialPollInterval=900"
Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient -Name SpecialPollInterval -Value 900
Write-Verbose "Setting registry: MaxPosPhaseCorrection=3600"
Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config\ -Name MaxPosPhaseCorrection -Value 3600
Write-TSxLog -Message "Registry values set"

if(Get-IsVirtual = "True"){
    Write-Verbose "Running a Virtual Machine - disabling VMICTimeProvider"
    Write-TSxLog -Message "Virtual machine detected - disabling VMICTimeProvider"
    Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\VMICTimeProvider -Name Enabled -Value 0
}

#Restart the NTP Client
Write-Verbose "Registering WMI event for W32Time service stop"
Register-WmiEvent -Query `
 "select * from __InstanceModificationEvent within 5 where targetinstance isa 'win32_service'" `
 -SourceIdentifier stopped
Write-Verbose "Stopping W32Time service"
Write-TSxLog -Message "Stopping W32Time service"
Stop-Service -Name W32Time
Wait-Event -SourceIdentifier stopped | Out-Null
Write-Verbose "Starting W32Time service"
Write-TSxLog -Message "Starting W32Time service"
Start-Service -Name W32Time
Unregister-Event -SourceIdentifier stopped
Write-Verbose "Running w32tm /resync"
Write-TSxLog -Message "Running w32tm /resync"
Start-Process w32tm.exe /resync -Wait

# Show current time configuration
Write-Output ""
Write-Output "Current time configuration:"
w32tm /query /configuration
Write-Output ""
Write-Output "Current time status:"
w32tm /query /status

Write-TSxLog -Message "Set-TSxTimesync completed successfully"
Write-Verbose "Log written to: $Script:LogFile"
