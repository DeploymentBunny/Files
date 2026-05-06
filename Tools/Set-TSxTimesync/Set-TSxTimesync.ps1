<#
.SYNOPSIS
    Configure Windows time synchronization.
.DESCRIPTION
    Configures Windows time synchronization by setting the NTP time source, applying
    registry settings, restarting the Windows Time service, and resyncing the clock.
    Defaults to pool.ntp.org if no time source is specified. Requires local
    Administrator privileges and exits if not running elevated. Writes a log to
    %TEMP% and supports -Verbose for detailed progress output. Supports -WhatIf for
    dry-run simulation of configuration changes.
.EXAMPLE
    .\Set-TSxTimesync.ps1
.EXAMPLE
    .\Set-TSxTimesync.ps1 -TimeSource "se.pool.ntp.org"
.NOTES
    FileName:    Set-TSxTimesync.ps1
    Version:     1.1.0
    Author:      Mikael Nystrom
    Contact:     deploymentbunny@outlook.com
    Created:     2015-12-15
    Updated:     2026-05-07
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
    and status. Writes a timestamped log file to %TEMP%. If not elevated, the
    script stops and reports that Administrator privileges are required. Uses
    ShouldProcess to support -WhatIf and emits detailed step output with -Verbose.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
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
    Write-Error "Set-TSxTimesync requires an elevated PowerShell session. Start PowerShell as Administrator and run the script again."
    exit 1
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
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $runUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    Add-Content -Path $Script:LogFile -Value ("[{0}] [{1}] [User: {2}] {3}" -f $timestamp, $Level, $runUser, $Message)
}

function Write-TSxStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    Write-TSxLog -Message $Message -Level $Level

    if ($Level -eq 'ERROR') {
        Write-Error $Message
        return
    }

    if ($Level -eq 'WARN') {
        Write-Warning $Message
        return
    }

    Write-Verbose $Message
}

$Script:LogFile = Join-Path $env:TEMP ("Set-TSxTimesync_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
Write-TSxStatus -Message "Log file: $Script:LogFile"
Write-TSxStatus -Message "Set-TSxTimesync started. TimeSource=$TimeSource"

try {
    #Set Values
    $NTPServer = $TimeSource + ',0x1'
    Write-TSxStatus -Message "NTP server string: $NTPServer"

    # Set Registry Values
    if ($PSCmdlet.ShouldProcess('HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters', 'Set Type=NTP')) {
        Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters\ -Name Type -Value NTP
        Write-TSxStatus -Message "Set registry value: Type=NTP"
    }

    if ($PSCmdlet.ShouldProcess('HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config', 'Set AnnounceFlags=5')) {
        Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config\ -Name AnnounceFlags -Value 5
        Write-TSxStatus -Message "Set registry value: AnnounceFlags=5"
    }

    if ($PSCmdlet.ShouldProcess('HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpServer', 'Set Enabled=1')) {
        Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpServer -Name Enabled -Value 1
        Write-TSxStatus -Message "Set registry value: NtpServer Enabled=1"
    }

    if ($PSCmdlet.ShouldProcess('HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters', "Set NtpServer=$NTPServer")) {
        Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters -Name NtpServer -Value $NTPServer
        Write-TSxStatus -Message "Set registry value: NtpServer=$NTPServer"
    }

    if ($PSCmdlet.ShouldProcess('HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient', 'Set SpecialPollInterval=900')) {
        Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient -Name SpecialPollInterval -Value 900
        Write-TSxStatus -Message "Set registry value: SpecialPollInterval=900"
    }

    if ($PSCmdlet.ShouldProcess('HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config', 'Set MaxPosPhaseCorrection=3600')) {
        Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config\ -Name MaxPosPhaseCorrection -Value 3600
        Write-TSxStatus -Message "Set registry value: MaxPosPhaseCorrection=3600"
    }

    if (Get-IsVirtual) {
        if ($PSCmdlet.ShouldProcess('HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\VMICTimeProvider', 'Set Enabled=0')) {
            Write-TSxStatus -Message "Virtual machine detected - disabling VMICTimeProvider"
            Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\VMICTimeProvider -Name Enabled -Value 0
        }
    }

    #Restart the NTP Client
    if ($PSCmdlet.ShouldProcess('W32Time service', 'Restart service')) {
        Write-TSxStatus -Message "Registering WMI event for W32Time service stop"
        Register-WmiEvent -Query `
         "select * from __InstanceModificationEvent within 5 where targetinstance isa 'win32_service'" `
         -SourceIdentifier stopped
        Write-TSxStatus -Message "Stopping W32Time service"
        Stop-Service -Name W32Time
        Wait-Event -SourceIdentifier stopped | Out-Null
        Write-TSxStatus -Message "Starting W32Time service"
        Start-Service -Name W32Time
        Unregister-Event -SourceIdentifier stopped
    }

    if ($PSCmdlet.ShouldProcess('Local system clock', 'Run w32tm /resync')) {
        Write-TSxStatus -Message "Running w32tm /resync"
        Start-Process w32tm.exe /resync -Wait
    }

    # Show current time configuration
    Write-Output ""
    Write-Output "Current time configuration:"
    w32tm /query /configuration
    Write-Output ""
    Write-Output "Current time status:"
    w32tm /query /status

    Write-TSxStatus -Message "Set-TSxTimesync completed successfully"
    Write-Verbose "Log written to: $Script:LogFile"
}
catch {
    Write-TSxLog -Message ("Set-TSxTimesync failed: {0}" -f $_.Exception.Message) -Level 'ERROR'
    throw
}
