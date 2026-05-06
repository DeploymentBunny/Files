<#
.Synopsis
    Windows 10/11 security baseline assessment.
.Description
    Evaluates core Windows client security controls and reports whether each
    control is True, False, Unknown, or NA. Designed for support and security
    validation on Windows 10 and Windows 11 devices.

    Requested checks:
    - UEFI
    - Secure Boot
    - TPM
    - BitLocker active
    - WDAC active
    - Credential Guard active
    - VBS active

    Additional checks:
    - Secure Boot Certificate configuration
    - AppLocker active
    - HVCI (Memory Integrity)
    - LSA protection (RunAsPPL)
    - LSASS protected process
    - WDigest credential caching disabled
    - Cached logons count (target 1)
    - Microsoft Defender real-time protection
    - Microsoft Defender EDR service
    - SMB1 disabled
    - NTLM hardening
    - Multicast Name Resolution (LLMNR) disabled
    - Windows Defender Firewall profiles
    - Active inbound firewall rules
    - Windows build support
    - Use -FalseOnly to return only checks that are not True
.Example
    .\Check-WindowsClientSecurityBaseline.ps1
.Example
    .\Check-WindowsClientSecurityBaseline.ps1 -OutputPath C:\Temp\SecurityChecks
.Notes
    ScriptName: Check-WindowsClientSecurityBaseline.ps1
    Version:    1.6.0
    Updated:    2026-05-06
    Author:     Mikael Nystrom
    Blog:       https://www.deploymentbunny.com
    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the authors or Deployment Artist.
.Link
    https://www.deploymentbunny.com
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "$env:ProgramData\WindowsClientSecurityBaseline",

    [Parameter(Mandatory = $false)]
    [switch]$AsJsonOnly,

    [Parameter(Mandatory = $false)]
    [switch]$FalseOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogFile = $null
$script:Results = New-Object System.Collections.Generic.List[object]
$script:FatalError = $null

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    Write-Verbose -Message $line

    if (-not [string]::IsNullOrWhiteSpace($script:LogFile)) {
        try {
            Add-Content -Path $script:LogFile -Value $line -ErrorAction Stop
        }
        catch {
            Write-Verbose -Message ("[{0}] [WARN] Failed to write log file: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message)
        }
    }
}

function Add-Result {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CheckName,

        [Parameter(Mandatory = $true)]
        [ValidateSet('True', 'False', 'Unknown', 'NA')]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$Details,

        [Parameter(Mandatory = $false)]
        [object]$RawValue
    )

    $obj = [PSCustomObject]@{
        Check    = $CheckName
        Status   = $Status
        Details  = $Details
    }

    $script:Results.Add($obj) | Out-Null

    if ($Status -eq 'True' -or $Status -eq 'NA') {
        Write-Log -Message ('{0}: {1} - {2}' -f $CheckName, $Status, $Details)
    }
    elseif ($Status -eq 'Unknown') {
        Write-Log -Message ('{0}: {1} - {2}' -f $CheckName, $Status, $Details) -Level 'WARN'
    }
    else {
        Write-Log -Message ('{0}: {1} - {2}' -f $CheckName, $Status, $Details) -Level 'ERROR'
    }
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PropertySafe {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $prop = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -eq $prop) {
        return $null
    }

    return $prop.Value
}

function Convert-ToSerializableRawValue {
    param(
        [Parameter(Mandatory = $false)]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    if (
        $Value -is [string] -or
        $Value -is [bool] -or
        $Value -is [byte] -or
        $Value -is [int16] -or
        $Value -is [int32] -or
        $Value -is [int64] -or
        $Value -is [uint16] -or
        $Value -is [uint32] -or
        $Value -is [uint64] -or
        $Value -is [decimal] -or
        $Value -is [double] -or
        $Value -is [datetime]
    ) {
        return $Value
    }

    if ($Value -is [array]) {
        return @($Value | ForEach-Object { Convert-ToSerializableRawValue -Value $_ })
    }

    try {
        return (($Value | Out-String).Trim())
    }
    catch {
        return [string]$Value
    }
}

function Test-SecureBootState {
    try {
        $enabled = Confirm-SecureBootUEFI -ErrorAction Stop
        if ($enabled) {
            Add-Result -Check 'Secure Boot' -Status 'True' -Details 'Secure Boot is enabled.' -RawValue $enabled
        }
        else {
            Add-Result -Check 'Secure Boot' -Status 'False' -Details 'Secure Boot is disabled.' -RawValue $enabled
        }
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match 'Cmdlet not supported on this platform') {
            Add-Result -Check 'Secure Boot' -Status 'False' -Details 'System is not running in Unified Extensible Firmware Interface (UEFI) mode (legacy BIOS), or firmware does not support the Secure Boot command.' -RawValue $msg
        }
        else {
            Add-Result -Check 'Secure Boot' -Status 'Unknown' -Details "Unable to validate Secure Boot. $msg" -RawValue $msg
        }
    }
}

function Test-SecureBootCertificate {
    try {
        # Check Secure Boot servicing registry
        $servicing = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing' -ErrorAction SilentlyContinue
        
        if ($null -ne $servicing) {
            # Check UEFICA2023 status (or similar certificate update status)
            $uefica2023Status = $servicing.UEFICA2023Status
            
            if ($uefica2023Status -eq 'Updated') {
                Add-Result -Check 'Secure Boot Certificate' -Status 'True' -Details 'Secure Boot certificates are updated (Windows UEFI Certificate Authority 2023).' -RawValue $uefica2023Status
                return
            }
            elseif ($uefica2023Status -eq 'Error') {
                Add-Result -Check 'Secure Boot Certificate' -Status 'False' -Details "Secure Boot certificate update failed. Error: $($servicing.UEFICA2023Error)" -RawValue $servicing.UEFICA2023Error
                return
            }
        }

        # Check Secure Boot Update scheduled task status
        $sbTask = Get-ScheduledTask -TaskPath '\Microsoft\Windows\PI\' -TaskName 'Secure-Boot-Update' -ErrorAction SilentlyContinue
        
        if ($sbTask) {
            $taskInfo = Get-ScheduledTaskInfo -Task $sbTask -ErrorAction SilentlyContinue
            
            # Check recent System events for Secure Boot certificate updates (Event 1808 = Updated)
            $recentEvents = Get-WinEvent -FilterHashtable @{
                LogName   = 'System'
                Id        = @(1808, 1801, 1802, 1803, 1795, 1796)
                StartTime = (Get-Date).AddDays(-90)
            } -ErrorAction SilentlyContinue | Select-Object -First 1
            
            if ($recentEvents -and $recentEvents.Id -eq 1808) {
                Add-Result -Check 'Secure Boot Certificate' -Status 'True' -Details 'Secure Boot certificates are updated (verified via event 1808).' -RawValue $recentEvents.TimeCreated
            }
            elseif ($recentEvents -and $recentEvents.Id -in @(1802, 1803)) {
                Add-Result -Check 'Secure Boot Certificate' -Status 'False' -Details 'Secure Boot certificate update is blocked.' -RawValue $recentEvents.Id
            }
            elseif ($recentEvents -and $recentEvents.Id -in @(1795, 1796)) {
                Add-Result -Check 'Secure Boot Certificate' -Status 'False' -Details 'Secure Boot certificate update failed.' -RawValue $recentEvents.Id
            }
            elseif ($recentEvents -and $recentEvents.Id -eq 1801) {
                Add-Result -Check 'Secure Boot Certificate' -Status 'Unknown' -Details 'Secure Boot certificate update is pending.' -RawValue $recentEvents.Id
            }
            else {
                Add-Result -Check 'Secure Boot Certificate' -Status 'Unknown' -Details 'No recent Secure Boot update events found.' -RawValue $taskInfo.State
            }
        }
        else {
            Add-Result -Check 'Secure Boot Certificate' -Status 'Unknown' -Details 'Secure Boot Update scheduled task not found.' -RawValue $null
        }
    }
    catch {
        Add-Result -Check 'Secure Boot Certificate' -Status 'Unknown' -Details "Unable to validate Secure Boot certificate. $($_.Exception.Message)" -RawValue $null
    }
}


try {
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $computerName = $env:COMPUTERNAME
    $prefix = "SecurityBaseline_{0}_{1}" -f $computerName, $timestamp

    $script:LogFile = Join-Path -Path $OutputPath -ChildPath ("{0}.log" -f $prefix)
    $jsonFile = Join-Path -Path $OutputPath -ChildPath ("{0}.json" -f $prefix)
    $txtFile = Join-Path -Path $OutputPath -ChildPath ("{0}.txt" -f $prefix)

    "Windows security baseline assessment started: $(Get-Date -Format s)" | Out-File -FilePath $script:LogFile -Encoding UTF8

    Write-Log -Message "Output path: $OutputPath"

    $isElevated = Test-Administrator
    if (-not $isElevated) {
        Add-Result -Check 'Administrative Privileges' -Status 'Unknown' -Details 'Script is not running elevated. Some checks may be incomplete.' -RawValue $false
    }
    else {
        Add-Result -Check 'Administrative Privileges' -Status 'True' -Details 'Script is running as Administrator.' -RawValue $true
    }

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $build = [int]$os.BuildNumber
    $caption = [string]$os.Caption

    if ($caption -match 'Windows 10|Windows 11') {
        Add-Result -Check 'Supported OS' -Status 'True' -Details "Detected $caption (build $build)." -RawValue $caption
    }
    else {
        Add-Result -Check 'Supported OS' -Status 'Unknown' -Details "Detected $caption (build $build). Script is intended for Windows 10/11 client OS." -RawValue $caption
    }

    $firmwareType = $null
    try {
        # First, try to read from environment variable
        if (-not [string]::IsNullOrWhiteSpace($env:firmware_type)) {
            $firmwareTypeEnv = $env:firmware_type.ToUpper()
            if ($firmwareTypeEnv -eq 'UEFI') {
                $firmwareType = 2
                Write-Log -Message "Detected UEFI via \$env:firmware_type environment variable." -Level 'INFO'
            }
            elseif ($firmwareTypeEnv -eq 'BIOS' -or $firmwareTypeEnv -eq 'LEGACY') {
                $firmwareType = 1
                Write-Log -Message "Detected legacy BIOS via \$env:firmware_type environment variable." -Level 'INFO'
            }
        }

        # If not found via environment variable, try registry
        if ($null -eq $firmwareType) {
            $firmwareType = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'PEFirmwareType' -ErrorAction SilentlyContinue).PEFirmwareType
        }

        # If PEFirmwareType doesn't exist, try alternative method: check for EFI variables
        if ($null -eq $firmwareType) {
            if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Firmware\EFI' -ErrorAction SilentlyContinue) {
                $firmwareType = 2  # Value 2 represents UEFI
                Write-Log -Message "PEFirmwareType registry value not present, detected UEFI via EFI firmware path." -Level 'INFO'
            }
            else {
                $firmwareType = 1  # Value 1 represents legacy BIOS
                Write-Log -Message "PEFirmwareType registry value not present, assuming legacy BIOS." -Level 'INFO'
            }
        }

        if ($firmwareType -eq 2) {
            Add-Result -Check 'UEFI' -Status 'True' -Details 'System firmware mode is Unified Extensible Firmware Interface (UEFI).' -RawValue $firmwareType
        }
        else {
            Add-Result -Check 'UEFI' -Status 'False' -Details 'System firmware mode is not Unified Extensible Firmware Interface (UEFI); legacy BIOS is in use.' -RawValue $firmwareType
        }
    }
    catch {
        Add-Result -Check 'UEFI' -Status 'Unknown' -Details "Could not determine firmware mode. $($_.Exception.Message)" -RawValue $null
    }

    Test-SecureBootState

    Test-SecureBootCertificate

    try {
        $tpm = Get-Tpm -ErrorAction Stop
        $tpmPresent = Get-PropertySafe -InputObject $tpm -PropertyName 'TpmPresent'
        $tpmReady = Get-PropertySafe -InputObject $tpm -PropertyName 'TpmReady'
        $specVersion = Get-PropertySafe -InputObject $tpm -PropertyName 'SpecVersion'

        if ($tpmPresent -eq $true -and $tpmReady -eq $true) {
            Add-Result -Check 'TPM' -Status 'True' -Details "Trusted Platform Module (TPM) is present and ready. Specification version: $specVersion" -RawValue $tpm
        }
        elseif ($tpmPresent -eq $true -and $tpmReady -ne $true) {
            Add-Result -Check 'TPM' -Status 'Unknown' -Details "Trusted Platform Module (TPM) is present but not ready. Specification version: $specVersion" -RawValue $tpm
        }
        elseif ($null -eq $tpmPresent -and $null -eq $tpmReady) {
            Add-Result -Check 'TPM' -Status 'Unknown' -Details 'TPM state object did not include expected properties.' -RawValue $tpm
        }
        else {
            Add-Result -Check 'TPM' -Status 'False' -Details 'TPM is not present.' -RawValue $tpm
        }
    }
    catch {
        Add-Result -Check 'TPM' -Status 'Unknown' -Details "Unable to read TPM state. $($_.Exception.Message)" -RawValue $null
    }

    try {
        $osDrive = $env:SystemDrive
        $blv = Get-BitLockerVolume -MountPoint $osDrive -ErrorAction Stop

        if ($blv.ProtectionStatus -eq 'On') {
            Add-Result -Check 'BitLocker (OS Drive)' -Status 'True' -Details "BitLocker protection is ON for $osDrive. VolumeStatus: $($blv.VolumeStatus)." -RawValue $blv
        }
        elseif ($blv.ProtectionStatus -eq 'Off') {
            Add-Result -Check 'BitLocker (OS Drive)' -Status 'False' -Details "BitLocker protection is OFF for $osDrive." -RawValue $blv
        }
        else {
            Add-Result -Check 'BitLocker (OS Drive)' -Status 'Unknown' -Details "BitLocker state for $osDrive is $($blv.ProtectionStatus)." -RawValue $blv
        }
    }
    catch {
        Add-Result -Check 'BitLocker (OS Drive)' -Status 'Unknown' -Details "Unable to read BitLocker status. $($_.Exception.Message)" -RawValue $null
    }

    $deviceGuard = $null
    try {
        $deviceGuard = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        Add-Result -Check 'Device Guard Data' -Status 'NA' -Details 'Successfully queried Win32_DeviceGuard.' -RawValue $deviceGuard
    }
    catch {
        Add-Result -Check 'Device Guard Data' -Status 'Unknown' -Details "Unable to query Win32_DeviceGuard. $($_.Exception.Message)" -RawValue $null
    }

    $vbsStatus = Get-PropertySafe -InputObject $deviceGuard -PropertyName 'VirtualizationBasedSecurityStatus'
    if ($null -eq $vbsStatus) {
        Add-Result -Check 'VBS' -Status 'Unknown' -Details 'Could not determine Virtualization-Based Security (VBS) status.' -RawValue $vbsStatus
    }
    elseif ($vbsStatus -eq 2) {
        Add-Result -Check 'VBS' -Status 'True' -Details 'Virtualization-Based Security (VBS) is running.' -RawValue $vbsStatus
    }
    elseif ($vbsStatus -eq 1) {
        Add-Result -Check 'VBS' -Status 'Unknown' -Details 'Virtualization-Based Security (VBS) is enabled but not running.' -RawValue $vbsStatus
    }
    else {
        Add-Result -Check 'VBS' -Status 'False' -Details 'Virtualization-Based Security (VBS) is not enabled.' -RawValue $vbsStatus
    }

    $securityServicesRunning = Get-PropertySafe -InputObject $deviceGuard -PropertyName 'SecurityServicesRunning'
    $securityServicesConfigured = Get-PropertySafe -InputObject $deviceGuard -PropertyName 'SecurityServicesConfigured'

    $credentialGuardRunning = $false
    if ($securityServicesRunning) {
        $credentialGuardRunning = [bool]($securityServicesRunning -contains 1)
    }

    if ($credentialGuardRunning) {
        Add-Result -Check 'Credential Guard' -Status 'True' -Details 'Credential Guard is running.' -RawValue $securityServicesRunning
    }
    else {
        $configured = $false
        if ($securityServicesConfigured) {
            $configured = [bool]($securityServicesConfigured -contains 1)
        }

        if ($configured) {
            Add-Result -Check 'Credential Guard' -Status 'Unknown' -Details 'Credential Guard is configured but not running.' -RawValue $securityServicesConfigured
        }
        else {
            Add-Result -Check 'Credential Guard' -Status 'False' -Details 'Credential Guard is not running.' -RawValue $securityServicesRunning
        }
    }

    $hvciRunning = $false
    if ($securityServicesRunning) {
        $hvciRunning = [bool]($securityServicesRunning -contains 2)
    }

    if ($hvciRunning) {
        Add-Result -Check 'HVCI (Memory Integrity)' -Status 'True' -Details 'Hypervisor-Protected Code Integrity (HVCI), also known as Memory Integrity, is running.' -RawValue $securityServicesRunning
    }
    else {
        Add-Result -Check 'HVCI (Memory Integrity)' -Status 'Unknown' -Details 'Hypervisor-Protected Code Integrity (HVCI), also known as Memory Integrity, is not running.' -RawValue $securityServicesRunning
    }

    $umciStatus = Get-PropertySafe -InputObject $deviceGuard -PropertyName 'UsermodeCodeIntegrityPolicyEnforcementStatus'
    if ($null -eq $umciStatus) {
        Add-Result -Check 'WDAC' -Status 'Unknown' -Details 'Unable to determine Windows Defender Application Control (WDAC) enforcement state.' -RawValue $umciStatus
    }
    elseif ($umciStatus -eq 2) {
        Add-Result -Check 'WDAC' -Status 'True' -Details 'Windows Defender Application Control (WDAC) policy enforcement is active.' -RawValue $umciStatus
    }
    elseif ($umciStatus -eq 1) {
        Add-Result -Check 'WDAC' -Status 'Unknown' -Details 'Windows Defender Application Control (WDAC) policy is in audit mode.' -RawValue $umciStatus
    }
    else {
        Add-Result -Check 'WDAC' -Status 'False' -Details 'Windows Defender Application Control (WDAC) policy enforcement is not active.' -RawValue $umciStatus
    }

    try {
        $runAsPpl = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL' -ErrorAction SilentlyContinue).RunAsPPL
        if ($runAsPpl -eq 1 -or $runAsPpl -eq 2) {
            Add-Result -Check 'LSA Protection (RunAsPPL)' -Status 'True' -Details "Local Security Authority (LSA) protection is enabled (RunAsPPL/Protected Process Light = $runAsPpl)." -RawValue $runAsPpl
            Add-Result -Check 'LSASS Protected Process' -Status 'True' -Details "Local Security Authority Subsystem Service (LSASS) is configured as a protected process (RunAsPPL/Protected Process Light = $runAsPpl)." -RawValue $runAsPpl
        }
        else {
            Add-Result -Check 'LSA Protection (RunAsPPL)' -Status 'Unknown' -Details 'Local Security Authority (LSA) protection is not enabled.' -RawValue $runAsPpl
            Add-Result -Check 'LSASS Protected Process' -Status 'False' -Details 'Local Security Authority Subsystem Service (LSASS) is not configured as a protected process.' -RawValue $runAsPpl
        }
    }
    catch {
        Add-Result -Check 'LSA Protection (RunAsPPL)' -Status 'Unknown' -Details "Unable to read Local Security Authority (LSA) protection setting. $($_.Exception.Message)" -RawValue $null
        Add-Result -Check 'LSASS Protected Process' -Status 'Unknown' -Details "Unable to read Local Security Authority Subsystem Service (LSASS) protection setting. $($_.Exception.Message)" -RawValue $null
    }

    try {
        $wdigestUseLogonCredential = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' -Name 'UseLogonCredential' -ErrorAction SilentlyContinue).UseLogonCredential
        if ($null -eq $wdigestUseLogonCredential -or $wdigestUseLogonCredential -eq 0) {
            Add-Result -Check 'WDigest Credential Caching' -Status 'True' -Details 'Windows Digest Authentication (WDigest) credential caching is disabled.' -RawValue $wdigestUseLogonCredential
        }
        else {
            Add-Result -Check 'WDigest Credential Caching' -Status 'False' -Details "Windows Digest Authentication (WDigest) credential caching is enabled (UseLogonCredential=$wdigestUseLogonCredential)." -RawValue $wdigestUseLogonCredential
        }
    }
    catch {
        Add-Result -Check 'WDigest Credential Caching' -Status 'Unknown' -Details "Unable to read WDigest credential caching setting. $($_.Exception.Message)" -RawValue $null
    }

    try {
        $cachedLogonsCount = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'CachedLogonsCount' -ErrorAction SilentlyContinue).CachedLogonsCount
        if ([string]::IsNullOrWhiteSpace([string]$cachedLogonsCount)) {
            Add-Result -Check 'Cached Logons Count' -Status 'Unknown' -Details 'CachedLogonsCount is not explicitly configured.' -RawValue $cachedLogonsCount
        }
        elseif ([string]$cachedLogonsCount -eq '1') {
            Add-Result -Check 'Cached Logons Count' -Status 'True' -Details 'Cached logons count is set to 1.' -RawValue $cachedLogonsCount
        }
        else {
            Add-Result -Check 'Cached Logons Count' -Status 'False' -Details "Cached logons count is set to $cachedLogonsCount (recommended: 1)." -RawValue $cachedLogonsCount
        }
    }
    catch {
        Add-Result -Check 'Cached Logons Count' -Status 'Unknown' -Details "Unable to read CachedLogonsCount. $($_.Exception.Message)" -RawValue $null
    }

    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        if ($mp.RealTimeProtectionEnabled) {
            Add-Result -Check 'Defender Real-Time Protection' -Status 'True' -Details 'Defender real-time protection is enabled.' -RawValue $mp.RealTimeProtectionEnabled
        }
        else {
            Add-Result -Check 'Defender Real-Time Protection' -Status 'Unknown' -Details 'Defender real-time protection is disabled.' -RawValue $mp.RealTimeProtectionEnabled
        }
    }
    catch {
        Add-Result -Check 'Defender Real-Time Protection' -Status 'Unknown' -Details "Unable to read Defender status. $($_.Exception.Message)" -RawValue $null
    }

    try {
        $senseService = Get-Service -Name 'Sense' -ErrorAction SilentlyContinue
        if ($null -eq $senseService) {
            Add-Result -Check 'Defender EDR Service' -Status 'Unknown' -Details 'Microsoft Defender Endpoint Detection and Response (EDR) service (Sense) was not found.' -RawValue $null
        }
        elseif ($senseService.Status -eq 'Running') {
            Add-Result -Check 'Defender EDR Service' -Status 'True' -Details 'Microsoft Defender Endpoint Detection and Response (EDR) service (Sense) is running.' -RawValue $senseService.Status
        }
        else {
            Add-Result -Check 'Defender EDR Service' -Status 'False' -Details "Microsoft Defender Endpoint Detection and Response (EDR) service (Sense) is $($senseService.Status)." -RawValue $senseService.Status
        }
    }
    catch {
        Add-Result -Check 'Defender EDR Service' -Status 'Unknown' -Details "Unable to read Defender EDR service state. $($_.Exception.Message)" -RawValue $null
    }

    try {
        if (-not $isElevated) {
            Add-Result -Check 'SMB1' -Status 'Unknown' -Details 'Server Message Block version 1 (SMB1) check requires elevation. Run elevated to evaluate.' -RawValue $null
        }
        else {
        $smbServerEnabled = $null
        $smbClientEnabled = $null

            try {
                $smbServerEnabled = (Get-SmbServerConfiguration -ErrorAction Stop).EnableSMB1Protocol
            }
            catch {
                $smbServerEnabled = $null
            }

            try {
                $smbClientEnabled = (Get-SmbClientConfiguration -ErrorAction Stop).EnableSMB1Protocol
            }
            catch {
                $smbClientEnabled = $null
            }

            $serverDisabled = ($null -eq $smbServerEnabled -or $smbServerEnabled -eq $false)
            $clientDisabled = ($null -eq $smbClientEnabled -or $smbClientEnabled -eq $false)

            if ($serverDisabled -and $clientDisabled) {
                Add-Result -Check 'SMB1' -Status 'True' -Details 'Server Message Block version 1 (SMB1) is disabled.' -RawValue $null
            }
            else {
                Add-Result -Check 'SMB1' -Status 'False' -Details 'Server Message Block version 1 (SMB1) appears enabled on one or more components.' -RawValue $null
            }
        }
    }
    catch {
        Add-Result -Check 'SMB1' -Status 'Unknown' -Details "Unable to evaluate SMB1 state. $($_.Exception.Message)" -RawValue $null
    }

    try {
        $lsaKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
        $msvKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0'

        $lsaProps = Get-ItemProperty -Path $lsaKey -ErrorAction SilentlyContinue
        $msvProps = Get-ItemProperty -Path $msvKey -ErrorAction SilentlyContinue

        $lmCompatibilityLevel = Get-PropertySafe -InputObject $lsaProps -PropertyName 'LmCompatibilityLevel'
        $restrictSending = Get-PropertySafe -InputObject $msvProps -PropertyName 'RestrictSendingNTLMTraffic'
        $restrictReceiving = Get-PropertySafe -InputObject $msvProps -PropertyName 'RestrictReceivingNTLMTraffic'

        if ($lmCompatibilityLevel -ge 5 -and $restrictSending -eq 2 -and $restrictReceiving -eq 2) {
            Add-Result -Check 'NTLM Hardening' -Status 'True' -Details 'NT LAN Manager (NTLM) restrictions are hardened (LmCompatibilityLevel>=5 and NTLM traffic is restricted).' -RawValue $null
        }
        elseif ($lmCompatibilityLevel -ge 5) {
            Add-Result -Check 'NTLM Hardening' -Status 'Unknown' -Details 'LmCompatibilityLevel is hardened, but NT LAN Manager (NTLM) traffic restrictions are not fully enforced.' -RawValue $null
        }
        else {
            Add-Result -Check 'NTLM Hardening' -Status 'False' -Details 'NT LAN Manager (NTLM) settings are not hardened.' -RawValue $null
        }
    }
    catch {
        Add-Result -Check 'NTLM Hardening' -Status 'Unknown' -Details "Unable to evaluate NTLM settings. $($_.Exception.Message)" -RawValue $null
    }

    try {
        $enableMulticast = (Get-ItemProperty -Path 'HKLM:\Software\Policies\Microsoft\Windows NT\DNSClient' -Name 'EnableMulticast' -ErrorAction SilentlyContinue).EnableMulticast
        if ($null -eq $enableMulticast) {
            Add-Result -Check 'Multicast Name Resolution' -Status 'False' -Details 'Multicast Name Resolution (LLMNR) policy is not configured; LLMNR is active by default.' -RawValue $enableMulticast
        }
        elseif ($enableMulticast -eq 0) {
            Add-Result -Check 'Multicast Name Resolution' -Status 'True' -Details 'Multicast Name Resolution (LLMNR) is disabled via policy.' -RawValue $enableMulticast
        }
        else {
            Add-Result -Check 'Multicast Name Resolution' -Status 'False' -Details "Multicast Name Resolution (LLMNR) is enabled (EnableMulticast=$enableMulticast)." -RawValue $enableMulticast
        }
    }
    catch {
        Add-Result -Check 'Multicast Name Resolution' -Status 'Unknown' -Details "Unable to read Multicast Name Resolution setting. $($_.Exception.Message)" -RawValue $null
    }

    $activeFirewallProfiles = @()
    try {
        $activeConnections = @(Get-NetConnectionProfile -ErrorAction Stop)
        $activeFirewallProfiles = @(
            $activeConnections |
                ForEach-Object {
                    switch ($_.NetworkCategory.ToString()) {
                        'DomainAuthenticated' { 'Domain' }
                        'Private' { 'Private' }
                        'Public' { 'Public' }
                        default { $null }
                    }
                } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )

        if ($activeFirewallProfiles.Count -eq 0) {
            Add-Result -Check 'Windows Firewall Profiles' -Status 'Unknown' -Details 'No active network connection profile was detected.' -RawValue $null
        }
        else {
            $fwProfiles = @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { $activeFirewallProfiles -contains $_.Name })
            $disabledProfiles = @($fwProfiles | Where-Object { -not $_.Enabled })
            if ($disabledProfiles.Count -eq 0) {
                $profileNames = $activeFirewallProfiles -join ', '
                Add-Result -Check 'Windows Firewall Profiles' -Status 'True' -Details "Active firewall profile(s) are enabled: $profileNames" -RawValue $fwProfiles
            }
            else {
                $disabledNames = @($disabledProfiles | Select-Object -ExpandProperty Name) -join ', '
                Add-Result -Check 'Windows Firewall Profiles' -Status 'False' -Details "Disabled active firewall profile(s): $disabledNames" -RawValue $fwProfiles
            }
        }
    }
    catch {
        Add-Result -Check 'Windows Firewall Profiles' -Status 'Unknown' -Details "Unable to read active firewall profile status. $($_.Exception.Message)" -RawValue $null
    }

    try {
        if ($activeFirewallProfiles.Count -eq 0) {
            Add-Result -Check 'Active Inbound Firewall Rules' -Status 'Unknown' -Details 'No active network connection profile was detected.' -RawValue $null
        }
        else {
            $inboundRules = @(
                Get-NetFirewallRule -Direction Inbound -ErrorAction Stop |
                    Where-Object {
                        $ruleProfile = [string]$_.Profile
                        $matchesActiveProfile = $false
                        foreach ($activeProfile in $activeFirewallProfiles) {
                            if ($ruleProfile -match "(^|,\s*)$([regex]::Escape($activeProfile))(,|$)") {
                                $matchesActiveProfile = $true
                                break
                            }
                        }

                        ($_.Enabled -eq 'True' -or $_.Enabled -eq $true) -and ($ruleProfile -eq 'Any' -or $matchesActiveProfile)
                    }
            )

            if ($inboundRules.Count -gt 0) {
                $profileNames = $activeFirewallProfiles -join ', '
                Add-Result -Check 'Active Inbound Firewall Rules' -Status 'True' -Details "Found $($inboundRules.Count) active inbound firewall rule(s) for active profile(s): $profileNames" -RawValue $inboundRules.Count
            }
            else {
                $profileNames = $activeFirewallProfiles -join ', '
                Add-Result -Check 'Active Inbound Firewall Rules' -Status 'False' -Details "No active inbound firewall rules found for active profile(s): $profileNames" -RawValue 0
            }
        }
    }
    catch {
        Add-Result -Check 'Active Inbound Firewall Rules' -Status 'Unknown' -Details "Unable to read inbound firewall rules for active profile(s). $($_.Exception.Message)" -RawValue $null
    }

    try {
        if (-not $isElevated) {
            Add-Result -Check 'AppLocker' -Status 'Unknown' -Details 'AppLocker check requires elevation. Run elevated to evaluate.' -RawValue $null
        }
        else {
            $appIdService = Get-Service -Name 'AppIDSvc' -ErrorAction SilentlyContinue
            $effectivePolicy = Get-AppLockerPolicy -Effective -ErrorAction Stop
            $ruleCollections = @($effectivePolicy.RuleCollections)

            $configuredCollections = @($ruleCollections | Where-Object { $_.EnforcementMode -ne 'NotConfigured' })
            $enforcedCollections = @($ruleCollections | Where-Object { $_.EnforcementMode -eq 'Enabled' })
            $auditCollections = @($ruleCollections | Where-Object { $_.EnforcementMode -eq 'AuditOnly' })

            if ($enforcedCollections.Count -gt 0) {
                $serviceState = if ($appIdService) { $appIdService.Status } else { 'Unknown' }
                Add-Result -Check 'AppLocker' -Status 'True' -Details "AppLocker has enforced rule collections. AppIDSvc state: $serviceState." -RawValue $effectivePolicy
            }
            elseif ($auditCollections.Count -gt 0) {
                $serviceState = if ($appIdService) { $appIdService.Status } else { 'Unknown' }
                Add-Result -Check 'AppLocker' -Status 'Unknown' -Details "AppLocker is configured in audit mode only. AppIDSvc state: $serviceState." -RawValue $effectivePolicy
            }
            elseif ($configuredCollections.Count -eq 0) {
                Add-Result -Check 'AppLocker' -Status 'False' -Details 'No effective AppLocker policy is configured.' -RawValue $effectivePolicy
            }
            else {
                Add-Result -Check 'AppLocker' -Status 'Unknown' -Details 'AppLocker policy detected but could not determine effective enforcement mode.' -RawValue $effectivePolicy
            }
        }
    }
    catch {
        Add-Result -Check 'AppLocker' -Status 'Unknown' -Details "Unable to evaluate AppLocker status. $($_.Exception.Message)" -RawValue $null
    }

    $trueCount = @($script:Results | Where-Object { $_.Status -eq 'True' }).Count
    $unknownCount = @($script:Results | Where-Object { $_.Status -eq 'Unknown' }).Count
    $falseCount = @($script:Results | Where-Object { $_.Status -eq 'False' }).Count
    $naCount = @($script:Results | Where-Object { $_.Status -eq 'NA' }).Count

    $resultWithLogFiles = @(
        $script:Results.ToArray()
        [PSCustomObject]@{
            Check = 'Json File'
            Status = 'NA'
            Details = $jsonFile
        }
        [PSCustomObject]@{
            Check = 'Text File'
            Status = 'NA'
            Details = $txtFile
        }
        [PSCustomObject]@{
            Check = 'Log File'
            Status = 'NA'
            Details = $script:LogFile
        }
    )

    $report = [PSCustomObject]@{
        ComputerName = $computerName
        Timestamp = (Get-Date)
        TrueCount = $trueCount
        UnknownCount = $unknownCount
        FalseCount = $falseCount
        NACount = $naCount
        TotalCount = $resultWithLogFiles.Count
        Result = $resultWithLogFiles
    }

    $reportForFile = [PSCustomObject]@{
        ComputerName = $report.ComputerName
        Timestamp = $report.Timestamp
        TrueCount = $report.TrueCount
        UnknownCount = $report.UnknownCount
        FalseCount = $report.FalseCount
        NACount = $report.NACount
        TotalCount = $report.TotalCount
        Result = @(
            $report.Result | ForEach-Object {
                [PSCustomObject]@{
                    Check = $_.Check
                    Status = $_.Status
                    Details = $_.Details
                }
            }
        )
    }

    $reportForFile | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonFile -Encoding UTF8

    $textLines = New-Object System.Collections.Generic.List[string]
    $textLines.Add("ComputerName: $computerName") | Out-Null
    $textLines.Add("Timestamp: $(Get-Date -Format s)") | Out-Null
    $textLines.Add('') | Out-Null
    $textLines.Add('Check Results:') | Out-Null

    foreach ($item in $script:Results) {
        $textLines.Add("- $($item.Check): $($item.Status) - $($item.Details)") | Out-Null
    }

    $textLines | Out-File -FilePath $txtFile -Encoding UTF8

    Write-Log -Message "Assessment complete."
    Write-Log -Message "JSON report: $jsonFile"
    Write-Log -Message "Text report: $txtFile"

    Write-Verbose -Message "JSON report: $jsonFile"
    Write-Verbose -Message "Text report: $txtFile"

    if ($FalseOnly) {
        Write-Output ($report.Result | Where-Object { $_.Status -ne 'True' })
    }
    else {
        Write-Output $report.Result
    }

    if ($falseCount -gt 0) {
        exit 2
    }
    elseif ($unknownCount -gt 0) {
        exit 1
    }
    else {
        exit 0
    }
}
catch {
    $script:FatalError = $_
    $position = $_.InvocationInfo.PositionMessage
    $stack = $_.ScriptStackTrace
    Write-Log -Message "Fatal error: $($_.Exception.Message)" -Level 'ERROR'
    if (-not [string]::IsNullOrWhiteSpace($position)) {
        Write-Log -Message "Fatal error position: $position" -Level 'ERROR'
    }
    if (-not [string]::IsNullOrWhiteSpace($stack)) {
        Write-Log -Message "Fatal error stack: $stack" -Level 'ERROR'
    }
    Write-Error "Security baseline assessment failed: $($_.Exception.Message)"
    exit 99
}

