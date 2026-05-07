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
    - Secure Boot state
    - Kernel DMA protection
    - App Control for Business policy
    - App Control for Business user mode policy
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
    - UAC enabled
    - Defender Antivirus enabled
    - Current user local Administrators membership
    - Additional local users in local Administrators group
    - Domain/Entra/Intune/Workgroup join-state information
    - Windows Defender Firewall profiles
    - Active inbound firewall rules
    - Windows build support
.Example
    .\Check-WindowsClientSecurityBaseline.ps1
.Example
    .\Check-WindowsClientSecurityBaseline.ps1 -OutputPath C:\Temp\SecurityChecks
.Notes
    ScriptName: Check-WindowsClientSecurityBaseline.ps1
    Version:    1.7.27
    Updated:    2026-05-07
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
    [string]$OutputPath = "$env:TEMP\WindowsClientSecurityBaseline",

    [Parameter(Mandatory = $false)]
    [switch]$AsJsonOnly,

    [Parameter(Mandatory = $false)]
    [Alias('ShowIssues')]
    [switch]$IssuesOnly
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
            Add-Result -Check 'Secure Boot?' -Status 'True' -Details 'Secure Boot is enabled.' -RawValue $enabled
            Add-Result -Check 'Secure Boot State?' -Status 'True' -Details 'Secure Boot runtime state is enabled.' -RawValue $enabled
        }
        else {
            Add-Result -Check 'Secure Boot?' -Status 'False' -Details 'Secure Boot is disabled.' -RawValue $enabled
            Add-Result -Check 'Secure Boot State?' -Status 'False' -Details 'Secure Boot runtime state is disabled.' -RawValue $enabled
        }
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match 'Cmdlet not supported on this platform') {
            Add-Result -Check 'Secure Boot?' -Status 'False' -Details 'System is not running in Unified Extensible Firmware Interface (UEFI) mode (legacy BIOS), or firmware does not support the Secure Boot command.' -RawValue $msg
            Add-Result -Check 'Secure Boot State?' -Status 'False' -Details 'Secure Boot runtime state is not available because UEFI/Secure Boot support is not present.' -RawValue $msg
        }
        else {
            Add-Result -Check 'Secure Boot?' -Status 'Unknown' -Details "Unable to validate Secure Boot. $msg" -RawValue $msg
            Add-Result -Check 'Secure Boot State?' -Status 'Unknown' -Details "Unable to read Secure Boot runtime state. $msg" -RawValue $msg
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
                Add-Result -Check 'Secure Boot Certificate Updated?' -Status 'True' -Details 'Secure Boot certificates are updated (Windows UEFI Certificate Authority 2023).' -RawValue $uefica2023Status
                return
            }
            elseif ($uefica2023Status -eq 'Error') {
                Add-Result -Check 'Secure Boot Certificate Updated?' -Status 'False' -Details "Secure Boot certificate update failed. Error: $($servicing.UEFICA2023Error)" -RawValue $servicing.UEFICA2023Error
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
                Add-Result -Check 'Secure Boot Certificate Updated?' -Status 'True' -Details 'Secure Boot certificates are updated (verified via event 1808).' -RawValue $recentEvents.TimeCreated
            }
            elseif ($recentEvents -and $recentEvents.Id -in @(1802, 1803)) {
                Add-Result -Check 'Secure Boot Certificate Updated?' -Status 'False' -Details 'Secure Boot certificate update is blocked.' -RawValue $recentEvents.Id
            }
            elseif ($recentEvents -and $recentEvents.Id -in @(1795, 1796)) {
                Add-Result -Check 'Secure Boot Certificate Updated?' -Status 'False' -Details 'Secure Boot certificate update failed.' -RawValue $recentEvents.Id
            }
            elseif ($recentEvents -and $recentEvents.Id -eq 1801) {
                Add-Result -Check 'Secure Boot Certificate Updated?' -Status 'Unknown' -Details 'Secure Boot certificate update is pending.' -RawValue $recentEvents.Id
            }
            else {
                Add-Result -Check 'Secure Boot Certificate Updated?' -Status 'Unknown' -Details 'No recent Secure Boot update events found.' -RawValue $taskInfo.State
            }
        }
        else {
            Add-Result -Check 'Secure Boot Certificate Updated?' -Status 'Unknown' -Details 'Secure Boot Update scheduled task not found.' -RawValue $null
        }
    }
    catch {
        Add-Result -Check 'Secure Boot Certificate Updated?' -Status 'Unknown' -Details "Unable to validate Secure Boot certificate. $($_.Exception.Message)" -RawValue $null
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
        Add-Result -Check 'Running with Admin Priv?' -Status 'False' -Details 'Script is not running elevated. Some checks may be incomplete.' -RawValue $false
    }
    else {
        Add-Result -Check 'Running with Admin Priv?' -Status 'True' -Details 'Script is running as Administrator.' -RawValue $true
    }

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $build = [int]$os.BuildNumber
    $caption = [string]$os.Caption

    if ($caption -match 'Windows 10|Windows 11') {
        Add-Result -Check 'Running supported OS?' -Status 'True' -Details "Detected $caption (build $build)." -RawValue $caption
    }
    else {
        Add-Result -Check 'Running supported OS?' -Status 'False' -Details "Detected $caption (build $build). Script is intended for Windows 10/11 client OS." -RawValue $caption
    }

    try {
        $cutoffDate = (Get-Date).AddDays(-45)
        $latestHotfix = @(
            Get-HotFix -ErrorAction Stop |
                Where-Object { $_.InstalledOn -is [datetime] } |
                Sort-Object -Property InstalledOn -Descending |
                Select-Object -First 1
        )

        if ($latestHotfix.Count -eq 0) {
            Add-Result -Check 'Windows patched within 45 days?' -Status 'Unknown' -Details 'No installed update with a valid InstalledOn date was found.' -RawValue $null
        }
        else {
            $lastPatchDate = [datetime]$latestHotfix[0].InstalledOn
            $isPatchedRecently = $lastPatchDate -ge $cutoffDate
            if ($isPatchedRecently) {
                Add-Result -Check 'Windows patched within 45 days?' -Status 'True' -Details ("Latest installed update {0} is from {1:yyyy-MM-dd}, within 45 days." -f $latestHotfix[0].HotFixID, $lastPatchDate) -RawValue $lastPatchDate
            }
            else {
                Add-Result -Check 'Windows patched within 45 days?' -Status 'False' -Details ("Latest installed update {0} is from {1:yyyy-MM-dd}, older than 45 days." -f $latestHotfix[0].HotFixID, $lastPatchDate) -RawValue $lastPatchDate
            }
        }
    }
    catch {
        Add-Result -Check 'Windows patched within 45 days?' -Status 'Unknown' -Details "Unable to evaluate recent patch state. $($_.Exception.Message)" -RawValue $null
    }

    try {
        $csInfo = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $isDomainJoined = [bool]$csInfo.PartOfDomain

        if ($isDomainJoined) {
            Add-Result -Check 'Domain Joined?' -Status 'True' -Details ("Domain joined: True (Domain: {0})" -f $csInfo.Domain) -RawValue $csInfo.Domain
            Add-Result -Check 'Workgroup Joined?' -Status 'False' -Details ("Not applicable: device is domain joined (Domain: {0})." -f $csInfo.Domain) -RawValue $csInfo.Workgroup
        }
        else {
            Add-Result -Check 'Domain Joined?' -Status 'False' -Details 'Domain joined: False' -RawValue $false
            Add-Result -Check 'Workgroup Joined?' -Status 'True' -Details ("Workgroup: {0}" -f $csInfo.Workgroup) -RawValue $csInfo.Workgroup
        }
    }
    catch {
        Add-Result -Check 'Domain Joined?' -Status 'Unknown' -Details "Domain joined state unavailable. $($_.Exception.Message)" -RawValue $null
        Add-Result -Check 'Workgroup Joined?' -Status 'Unknown' -Details "Workgroup state unavailable. $($_.Exception.Message)" -RawValue $null
    }

    try {
        $dsRegCmd = Get-Command -Name 'dsregcmd.exe' -ErrorAction SilentlyContinue
        if ($null -eq $dsRegCmd) {
            Add-Result -Check 'Entra ID Joined?' -Status 'Unknown' -Details 'Entra ID join state unavailable (dsregcmd.exe not found).' -RawValue $null
            Add-Result -Check 'Workplace Joined?' -Status 'Unknown' -Details 'Workplace join state unavailable (dsregcmd.exe not found).' -RawValue $null
            Add-Result -Check 'Managed by Intune?' -Status 'Unknown' -Details 'Intune management state unavailable (dsregcmd.exe not found).' -RawValue $null
        }
        else {
            $dsRegRaw = (& dsregcmd.exe /status 2>$null) | Out-String
            $entraJoined = ($dsRegRaw -match '(?im)^\s*AzureAdJoined\s*:\s*YES\s*$')
            $workplaceJoined = ($dsRegRaw -match '(?im)^\s*WorkplaceJoined\s*:\s*YES\s*$')

            $mdmUrlMatch = [regex]::Match($dsRegRaw, '(?im)^\s*MdmUrl\s*:\s*(.+)\s*$')
            $mdmUrl = if ($mdmUrlMatch.Success) { $mdmUrlMatch.Groups[1].Value.Trim() } else { '' }
            $intuneManaged = -not [string]::IsNullOrWhiteSpace($mdmUrl) -and $mdmUrl -notmatch '^(N/?A|-)$'

            $entraDetails = if ($entraJoined) {
                'Entra ID joined: True (device has an Entra device identity).'
            }
            elseif ($workplaceJoined) {
                'Entra ID joined: False (device is not Entra ID joined; it is only workplace registered).'
            }
            else {
                'Entra ID joined: False (no Entra ID join detected).'
            }

            $workplaceDetails = if ($workplaceJoined) {
                'Workplace joined: True (device is Entra registered/workplace joined).'
            }
            else {
                'Workplace joined: False (no workplace registration detected).'
            }

            $intuneDetails = if ($intuneManaged) {
                "Managed by Intune: True (MDM URL detected: {0})" -f $mdmUrl
            }
            else {
                'Managed by Intune: False (no valid MDM URL detected in dsregcmd output).'
            }

            Add-Result -Check 'Entra ID Joined?' -Status ($(if ($entraJoined) { 'True' } else { 'False' })) -Details $entraDetails -RawValue $entraJoined
            Add-Result -Check 'Workplace Joined?' -Status ($(if ($workplaceJoined) { 'True' } else { 'False' })) -Details $workplaceDetails -RawValue $workplaceJoined
            Add-Result -Check 'Managed by Intune?' -Status ($(if ($intuneManaged) { 'True' } else { 'False' })) -Details $intuneDetails -RawValue $mdmUrl
        }
    }
    catch {
        Add-Result -Check 'Entra ID Joined?' -Status 'Unknown' -Details "Entra ID join state unavailable. $($_.Exception.Message)" -RawValue $null
        Add-Result -Check 'Workplace Joined?' -Status 'Unknown' -Details "Workplace join state unavailable. $($_.Exception.Message)" -RawValue $null
        Add-Result -Check 'Managed by Intune?' -Status 'Unknown' -Details "Intune management state unavailable. $($_.Exception.Message)" -RawValue $null
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
            Add-Result -Check 'UEFI Mode?' -Status 'True' -Details 'System firmware mode is Unified Extensible Firmware Interface (UEFI).' -RawValue $firmwareType
        }
        else {
            Add-Result -Check 'UEFI Mode?' -Status 'False' -Details 'System firmware mode is not Unified Extensible Firmware Interface (UEFI); legacy BIOS is in use.' -RawValue $firmwareType
        }
    }
    catch {
        Add-Result -Check 'UEFI Mode?' -Status 'Unknown' -Details "Could not determine firmware mode. $($_.Exception.Message)" -RawValue $null
    }

    Test-SecureBootState

    Test-SecureBootCertificate

    try {
        $tpm = Get-Tpm -ErrorAction Stop
        $tpmPresent = Get-PropertySafe -InputObject $tpm -PropertyName 'TpmPresent'
        $tpmReady = Get-PropertySafe -InputObject $tpm -PropertyName 'TpmReady'
        $specVersion = Get-PropertySafe -InputObject $tpm -PropertyName 'SpecVersion'

        if ($tpmPresent -eq $true -and $tpmReady -eq $true) {
            Add-Result -Check 'TPM exists?' -Status 'True' -Details "Trusted Platform Module (TPM) is present and ready. Specification version: $specVersion" -RawValue $tpm
        }
        elseif ($tpmPresent -eq $true -and $tpmReady -ne $true) {
            Add-Result -Check 'TPM exists?' -Status 'Unknown' -Details "Trusted Platform Module (TPM) is present but not ready. Specification version: $specVersion" -RawValue $tpm
        }
        elseif ($null -eq $tpmPresent -and $null -eq $tpmReady) {
            Add-Result -Check 'TPM exists?' -Status 'Unknown' -Details 'TPM state object did not include expected properties.' -RawValue $tpm
        }
        else {
            Add-Result -Check 'TPM exists?' -Status 'False' -Details 'TPM is not present.' -RawValue $tpm
        }
    }
    catch {
        Add-Result -Check 'TPM exists?' -Status 'Unknown' -Details "Unable to read TPM state. $($_.Exception.Message)" -RawValue $null
    }

    try {
        $osDrive = $env:SystemDrive
        $blv = Get-BitLockerVolume -MountPoint $osDrive -ErrorAction Stop

        if ($blv.ProtectionStatus -eq 'On') {
            Add-Result -Check 'BitLocker (OS Drive)?' -Status 'True' -Details "BitLocker protection is ON for $osDrive. VolumeStatus: $($blv.VolumeStatus)." -RawValue $blv
        }
        elseif ($blv.ProtectionStatus -eq 'Off') {
            Add-Result -Check 'BitLocker (OS Drive)?' -Status 'False' -Details "BitLocker protection is OFF for $osDrive." -RawValue $blv
        }
        else {
            Add-Result -Check 'BitLocker (OS Drive)?' -Status 'Unknown' -Details "BitLocker state for $osDrive is $($blv.ProtectionStatus)." -RawValue $blv
        }
    }
    catch {
        Add-Result -Check 'BitLocker (OS Drive)?' -Status 'Unknown' -Details "Unable to read BitLocker status. $($_.Exception.Message)" -RawValue $null
    }

    $deviceGuard = $null
    try {
        $deviceGuard = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
    }
    catch {
        Write-Log -Message ("Unable to query Win32_DeviceGuard. {0}" -f $_.Exception.Message) -Level 'WARN'
    }

    $vbsStatus = Get-PropertySafe -InputObject $deviceGuard -PropertyName 'VirtualizationBasedSecurityStatus'
    if ($null -eq $vbsStatus) {
        Add-Result -Check 'VBS enabled?' -Status 'Unknown' -Details 'Could not determine Virtualization-Based Security (VBS) status.' -RawValue $vbsStatus
    }
    elseif ($vbsStatus -eq 2) {
        Add-Result -Check 'VBS enabled?' -Status 'True' -Details 'Virtualization-Based Security (VBS) is running.' -RawValue $vbsStatus
    }
    elseif ($vbsStatus -eq 1) {
        Add-Result -Check 'VBS enabled?' -Status 'Unknown' -Details 'Virtualization-Based Security (VBS) is enabled but not running.' -RawValue $vbsStatus
    }
    else {
        Add-Result -Check 'VBS enabled?' -Status 'False' -Details 'Virtualization-Based Security (VBS) is not enabled.' -RawValue $vbsStatus
    }

    try {
        $props = @(Get-ComputerInfo -ErrorAction Stop | Select-Object -ExpandProperty DeviceGuardAvailableSecurityProperties)
        $kernelDmaProtectionSupported = @($props | ForEach-Object { [string]$_ }) -contains 'DMAProtection'

        Add-Result -Check 'Kernel DMA Protection?' -Status ($(if ($kernelDmaProtectionSupported) { 'True' } else { 'False' })) -Details ("Kernel DMA protection support detected via DeviceGuardAvailableSecurityProperties: {0}" -f $kernelDmaProtectionSupported) -RawValue $props
    }
    catch {
        Add-Result -Check 'Kernel DMA Protection?' -Status 'Unknown' -Details "Unable to detect kernel DMA protection support via DeviceGuardAvailableSecurityProperties. $($_.Exception.Message)" -RawValue $null
    }

    $securityServicesRunning = Get-PropertySafe -InputObject $deviceGuard -PropertyName 'SecurityServicesRunning'
    $securityServicesConfigured = Get-PropertySafe -InputObject $deviceGuard -PropertyName 'SecurityServicesConfigured'

    $credentialGuardRunning = $false
    if ($securityServicesRunning) {
        $credentialGuardRunning = [bool]($securityServicesRunning -contains 1)
    }

    if ($credentialGuardRunning) {
        Add-Result -Check 'Credential Guard running?' -Status 'True' -Details 'Credential Guard is running.' -RawValue $securityServicesRunning
    }
    else {
        $configured = $false
        if ($securityServicesConfigured) {
            $configured = [bool]($securityServicesConfigured -contains 1)
        }

        if ($configured) {
            Add-Result -Check 'Credential Guard running?' -Status 'Unknown' -Details 'Credential Guard is configured but not running.' -RawValue $securityServicesConfigured
        }
        else {
            Add-Result -Check 'Credential Guard running?' -Status 'False' -Details 'Credential Guard is not running.' -RawValue $securityServicesRunning
        }
    }

    $hvciRunning = $false
    if ($securityServicesRunning) {
        $hvciRunning = [bool]($securityServicesRunning -contains 2)
    }

    if ($hvciRunning) {
        Add-Result -Check 'HVCI (Memory Integrity) running?' -Status 'True' -Details 'Hypervisor-Protected Code Integrity (HVCI), also known as Memory Integrity, is running.' -RawValue $securityServicesRunning
    }
    else {
        Add-Result -Check 'HVCI (Memory Integrity) running?' -Status 'Unknown' -Details 'Hypervisor-Protected Code Integrity (HVCI), also known as Memory Integrity, is not running.' -RawValue $securityServicesRunning
    }

    $kernelCiStatus = Get-PropertySafe -InputObject $deviceGuard -PropertyName 'CodeIntegrityPolicyEnforcementStatus'
    $umciStatus = Get-PropertySafe -InputObject $deviceGuard -PropertyName 'UsermodeCodeIntegrityPolicyEnforcementStatus'

    if ($kernelCiStatus -eq 2) {
        Add-Result -Check 'Application control policy present?' -Status 'True' -Details 'App Control for Business kernel policy is enforced.' -RawValue $kernelCiStatus
    }
    elseif ($kernelCiStatus -eq 1) {
        Add-Result -Check 'Application control policy present?' -Status 'Unknown' -Details 'App Control for Business kernel policy is in audit mode.' -RawValue $kernelCiStatus
    }
    elseif ($kernelCiStatus -eq 0) {
        Add-Result -Check 'Application control policy present?' -Status 'False' -Details 'App Control for Business kernel policy is not enabled.' -RawValue $kernelCiStatus
    }
    else {
        Add-Result -Check 'Application control policy present?' -Status 'Unknown' -Details 'Unable to determine App Control for Business kernel policy state.' -RawValue $kernelCiStatus
    }

    if ($umciStatus -eq 2) {
        Add-Result -Check 'Application control scope: apps and scripts?' -Status 'True' -Details 'App Control for Business user mode policy is enforced.' -RawValue $umciStatus
    }
    elseif ($umciStatus -eq 1) {
        Add-Result -Check 'Application control scope: apps and scripts?' -Status 'Unknown' -Details 'App Control for Business user mode policy is in audit mode.' -RawValue $umciStatus
    }
    elseif ($umciStatus -eq 0) {
        Add-Result -Check 'Application control scope: apps and scripts?' -Status 'False' -Details 'App Control for Business user mode policy is not enabled.' -RawValue $umciStatus
    }
    else {
        Add-Result -Check 'Application control scope: apps and scripts?' -Status 'Unknown' -Details 'Unable to determine App Control for Business user mode policy state.' -RawValue $umciStatus
    }

    if ($null -eq $umciStatus) {
        Add-Result -Check 'Application control policy enforced?' -Status 'Unknown' -Details 'Unable to determine Windows Defender Application Control (WDAC) enforcement state.' -RawValue $umciStatus
    }
    elseif ($umciStatus -eq 2) {
        Add-Result -Check 'Application control policy enforced?' -Status 'True' -Details 'Windows Defender Application Control (WDAC) policy enforcement is active.' -RawValue $umciStatus
    }
    elseif ($umciStatus -eq 1) {
        Add-Result -Check 'Application control policy enforced?' -Status 'Unknown' -Details 'Windows Defender Application Control (WDAC) policy is in audit mode.' -RawValue $umciStatus
    }
    else {
        Add-Result -Check 'Application control policy enforced?' -Status 'False' -Details 'Windows Defender Application Control (WDAC) policy enforcement is not active.' -RawValue $umciStatus
    }

    try {
        $runAsPpl = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL' -ErrorAction SilentlyContinue).RunAsPPL
        if ($runAsPpl -eq 1 -or $runAsPpl -eq 2) {
            Add-Result -Check 'LSA Protection enabled?' -Status 'True' -Details "Local Security Authority (LSA) protection is enabled (RunAsPPL/Protected Process Light = $runAsPpl)." -RawValue $runAsPpl
            Add-Result -Check 'LSASS Protected Process enabled?' -Status 'True' -Details "Local Security Authority Subsystem Service (LSASS) is configured as a protected process (RunAsPPL/Protected Process Light = $runAsPpl)." -RawValue $runAsPpl
        }
        else {
            Add-Result -Check 'LSA Protection enabled?' -Status 'Unknown' -Details 'Local Security Authority (LSA) protection is not enabled.' -RawValue $runAsPpl
            Add-Result -Check 'LSASS Protected Process enabled?' -Status 'False' -Details 'Local Security Authority Subsystem Service (LSASS) is not configured as a protected process.' -RawValue $runAsPpl
        }
    }
    catch {
        Add-Result -Check 'LSA Protection enabled?' -Status 'Unknown' -Details "Unable to read Local Security Authority (LSA) protection setting. $($_.Exception.Message)" -RawValue $null
        Add-Result -Check 'LSASS Protected Process enabled?' -Status 'Unknown' -Details "Unable to read Local Security Authority Subsystem Service (LSASS) protection setting. $($_.Exception.Message)" -RawValue $null
    }

    try {
        $wdigestUseLogonCredential = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' -Name 'UseLogonCredential' -ErrorAction SilentlyContinue).UseLogonCredential
        if ($null -eq $wdigestUseLogonCredential -or $wdigestUseLogonCredential -eq 0) {
            Add-Result -Check 'WDigest Credential Caching disabled?' -Status 'True' -Details 'Windows Digest Authentication (WDigest) credential caching is disabled.' -RawValue $wdigestUseLogonCredential
        }
        else {
            Add-Result -Check 'WDigest Credential Caching disabled?' -Status 'False' -Details "Windows Digest Authentication (WDigest) credential caching is enabled (UseLogonCredential=$wdigestUseLogonCredential)." -RawValue $wdigestUseLogonCredential
        }
    }
    catch {
        Add-Result -Check 'WDigest Credential Caching disabled?' -Status 'Unknown' -Details "Unable to read WDigest credential caching setting. $($_.Exception.Message)" -RawValue $null
    }

    try {
        $enableLua = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableLUA' -ErrorAction SilentlyContinue).EnableLUA
        if ($enableLua -eq 1) {
            Add-Result -Check 'UAC Enabled?' -Status 'True' -Details 'User Account Control (UAC) is enabled (EnableLUA=1).' -RawValue $enableLua
        }
        else {
            Add-Result -Check 'UAC Enabled?' -Status 'False' -Details ("User Account Control (UAC) is not enabled (EnableLUA={0})." -f $enableLua) -RawValue $enableLua
        }
    }
    catch {
        Add-Result -Check 'UAC Enabled?' -Status 'Unknown' -Details "Unable to read UAC setting. $($_.Exception.Message)" -RawValue $null
    }

    try {
        $cachedLogonsCount = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'CachedLogonsCount' -ErrorAction SilentlyContinue).CachedLogonsCount
        if ([string]::IsNullOrWhiteSpace([string]$cachedLogonsCount)) {
            Add-Result -Check 'Cached Logons Count less or equal to 1?' -Status 'Unknown' -Details 'CachedLogonsCount is not explicitly configured.' -RawValue $cachedLogonsCount
        }
        elseif ([string]$cachedLogonsCount -eq '1') {
            Add-Result -Check 'Cached Logons Count less or equal to 1?' -Status 'True' -Details 'Cached logons count is set to 1.' -RawValue $cachedLogonsCount
        }
        else {
            Add-Result -Check 'Cached Logons Count less or equal to 1?' -Status 'False' -Details "Cached logons count is set to $cachedLogonsCount (recommended: 1)." -RawValue $cachedLogonsCount
        }
    }
    catch {
        Add-Result -Check 'Cached Logons Count less or equal to 1?' -Status 'Unknown' -Details "Unable to read CachedLogonsCount. $($_.Exception.Message)" -RawValue $null
    }

    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        if ($mp.RealTimeProtectionEnabled) {
            Add-Result -Check 'Defender Real-Time Protection running?' -Status 'True' -Details 'Defender real-time protection is enabled.' -RawValue $mp.RealTimeProtectionEnabled
        }
        else {
            Add-Result -Check 'Defender Real-Time Protection running?' -Status 'False' -Details 'Defender real-time protection is disabled.' -RawValue $mp.RealTimeProtectionEnabled
        }
    }
    catch {
        Add-Result -Check 'Defender Real-Time Protection running?' -Status 'Unknown' -Details "Unable to read Defender status. $($_.Exception.Message)" -RawValue $null
    }

    try {
        $senseService = Get-Service -Name 'Sense' -ErrorAction SilentlyContinue
        if ($null -eq $senseService) {
            Add-Result -Check 'Defender EDR Service running?' -Status 'Unknown' -Details 'Microsoft Defender Endpoint Detection and Response (EDR) service (Sense) was not found.' -RawValue $null
        }
        elseif ($senseService.Status -eq 'Running') {
            Add-Result -Check 'Defender EDR Service running?' -Status 'True' -Details 'Microsoft Defender Endpoint Detection and Response (EDR) service (Sense) is running.' -RawValue $senseService.Status
        }
        else {
            Add-Result -Check 'Defender EDR Service running?' -Status 'False' -Details "Microsoft Defender Endpoint Detection and Response (EDR) service (Sense) is $($senseService.Status)." -RawValue $senseService.Status
        }
    }
    catch {
        Add-Result -Check 'Defender EDR Service running?' -Status 'Unknown' -Details "Unable to read Defender EDR service state. $($_.Exception.Message)" -RawValue $null
    }

    try {
        $defenderService = Get-Service -Name 'WinDefend' -ErrorAction SilentlyContinue
        if ($null -eq $defenderService) {
            Add-Result -Check 'Defender Antivirus running?' -Status 'Unknown' -Details 'Defender Antivirus service (WinDefend) was not found.' -RawValue $null
        }
        elseif ($defenderService.Status -eq 'Running' -and $defenderService.StartType -ne 'Disabled') {
            Add-Result -Check 'Defender Antivirus running?' -Status 'True' -Details 'Defender Antivirus service (WinDefend) is running and not disabled.' -RawValue $defenderService.Status
        }
        else {
            Add-Result -Check 'Defender Antivirus running?' -Status 'False' -Details ("Defender Antivirus service (WinDefend) state is {0} with startup type {1}." -f $defenderService.Status, $defenderService.StartType) -RawValue $defenderService.Status
        }
    }
    catch {
        Add-Result -Check 'Defender Antivirus running?' -Status 'Unknown' -Details "Unable to read Defender Antivirus service state. $($_.Exception.Message)" -RawValue $null
    }

    try {
        $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $currentName = $currentIdentity.Name
        $currentShortName = if ($currentName -match '^[^\\]+\\(.+)$') { $matches[1] } else { $currentName }

        $netOutput = @(& net.exe localgroup Administrators 2>&1)
        if ($LASTEXITCODE -ne 0 -or $netOutput.Count -eq 0) {
            throw "net localgroup Administrators failed. Exit code: $LASTEXITCODE"
        }

        $adminMembers = New-Object System.Collections.Generic.List[string]
        $inMembersSection = $false
        $seenMember = $false
        foreach ($line in $netOutput) {
            $trimmed = ([string]$line).Trim()

            if (-not $inMembersSection) {
                if ($trimmed -match '^-{3,}$') {
                    $inMembersSection = $true
                }
                continue
            }

            if ([string]::IsNullOrWhiteSpace($trimmed)) {
                if ($seenMember) {
                    break
                }
                continue
            }

            $member = $trimmed.TrimStart('*').Trim()
            if (-not [string]::IsNullOrWhiteSpace($member)) {
                $adminMembers.Add($member) | Out-Null
                $seenMember = $true
            }
        }

        if ($adminMembers.Count -eq 0) {
            throw 'No members parsed from net localgroup Administrators output.'
        }

        $possibleCurrentNames = @(
            $currentName,
            $currentShortName,
            ("{0}\\{1}" -f $env:USERDOMAIN, $env:USERNAME),
            ("{0}\\{1}" -f $env:COMPUTERNAME, $env:USERNAME),
            $env:USERNAME
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

        $currentIsAdmin = @($adminMembers | Where-Object { $possibleCurrentNames -contains $_ }).Count -gt 0

        if ($currentIsAdmin) {
            Add-Result -Check 'Current User member of Local Administrators group?' -Status 'True' -Details ("Current user {0} is a member of local Administrators." -f $currentName) -RawValue $currentName
        }
        else {
            Add-Result -Check 'Current User member of Local Administrators group?' -Status 'False' -Details ("Current user {0} is not a member of local Administrators." -f $currentName) -RawValue $currentName
        }

        $localUserNames = @()
        try {
            $localUserNames = @(Get-LocalUser -ErrorAction Stop | Select-Object -ExpandProperty Name)
        }
        catch {
            $localUserNames = @('Administrator')
        }

        $localUserMembers = @(
            $adminMembers | Where-Object {
                $nameOnly = if ($_ -match '^[^\\]+\\(.+)$') { $matches[1] } else { $_ }
                $localUserNames -contains $nameOnly
            }
        )

        $extraLocalUserMembers = @(
            $localUserMembers | Where-Object {
                $nameOnly = if ($_ -match '^[^\\]+\\(.+)$') { $matches[1] } else { $_ }
                ($nameOnly -ne 'Administrator') -and ($possibleCurrentNames -notcontains $_) -and ($possibleCurrentNames -notcontains $nameOnly)
            }
        )

        if ($extraLocalUserMembers.Count -gt 0) {
            $memberNames = @($extraLocalUserMembers | Select-Object -Unique) -join ', '
            Add-Result -Check 'Extra Local Users in Administrators group?' -Status 'True' -Details ("Additional local user account(s) are members of local Administrators: {0}" -f $memberNames) -RawValue $memberNames
        }
        else {
            Add-Result -Check 'Extra Local Users in Administrators group?' -Status 'False' -Details 'No additional local user accounts were found in local Administrators (excluding built-in Administrator and current user).' -RawValue $null
        }
    }
    catch {
        Add-Result -Check 'Current User member of Local Administrators group?' -Status 'Unknown' -Details "Unable to evaluate current user local Administrators membership. $($_.Exception.Message)" -RawValue $null
        Add-Result -Check 'Extra Local Users in Administrators group?' -Status 'Unknown' -Details "Unable to evaluate additional local user memberships in local Administrators. $($_.Exception.Message)" -RawValue $null
    }

    try {
        if (-not $isElevated) {
            Add-Result -Check 'SMB1 Disabled?' -Status 'Unknown' -Details 'Server Message Block version 1 (SMB1) check requires elevation. Run elevated to evaluate.' -RawValue $null
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
                Add-Result -Check 'SMB1 Disabled?' -Status 'True' -Details 'Server Message Block version 1 (SMB1) is disabled.' -RawValue $null
            }
            else {
                Add-Result -Check 'SMB1 Disabled?' -Status 'False' -Details 'Server Message Block version 1 (SMB1) appears enabled on one or more components.' -RawValue $null
            }
        }
    }
    catch {
        Add-Result -Check 'SMB1 Disabled?' -Status 'Unknown' -Details "Unable to evaluate SMB1 state. $($_.Exception.Message)" -RawValue $null
    }

    try {
        $lsaKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
        $msvKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0'

        $lsaProps = Get-ItemProperty -Path $lsaKey -ErrorAction SilentlyContinue
        $msvProps = Get-ItemProperty -Path $msvKey -ErrorAction SilentlyContinue

        $lmCompatibilityLevel = Get-PropertySafe -InputObject $lsaProps -PropertyName 'LmCompatibilityLevel'
        $restrictSending = Get-PropertySafe -InputObject $msvProps -PropertyName 'RestrictSendingNTLMTraffic'
        $restrictReceiving = Get-PropertySafe -InputObject $msvProps -PropertyName 'RestrictReceivingNTLMTraffic'

        $lmHardened = ($lmCompatibilityLevel -ge 5)
        $sendRestricted = ($restrictSending -eq 2)
        $receiveRestricted = ($restrictReceiving -eq 2)

        $lmValueText = if ($null -eq $lmCompatibilityLevel -or [string]::IsNullOrWhiteSpace([string]$lmCompatibilityLevel)) {
            'Not configured'
        }
        else {
            [string]$lmCompatibilityLevel
        }

        $restrictSendingText = switch ($restrictSending) {
            0 { '0 (Allow all outgoing NTLM traffic)' }
            1 { '1 (Audit outgoing NTLM traffic)' }
            2 { '2 (Deny all outgoing NTLM traffic - hardened target)' }
            default {
                if ($null -eq $restrictSending -or [string]::IsNullOrWhiteSpace([string]$restrictSending)) {
                    'Not configured'
                }
                else {
                    "{0} (unknown value)" -f $restrictSending
                }
            }
        }

        $restrictReceivingText = switch ($restrictReceiving) {
            0 { '0 (Allow all incoming NTLM traffic)' }
            1 { '1 (Deny domain accounts - incoming NTLM)' }
            2 { '2 (Deny all accounts - incoming NTLM, hardened target)' }
            default {
                if ($null -eq $restrictReceiving -or [string]::IsNullOrWhiteSpace([string]$restrictReceiving)) {
                    'Not configured'
                }
                else {
                    "{0} (unknown value)" -f $restrictReceiving
                }
            }
        }

        Add-Result -Check 'NTLM LmCompatibilityLevel Hardened?' -Status ($(if ($lmHardened) { 'True' } else { 'False' })) -Details ("LmCompatibilityLevel>=5: {0} (current value: {1})." -f $lmHardened, $lmValueText) -RawValue $lmCompatibilityLevel
        Add-Result -Check 'NTLM Restrict Sending Traffic ok?' -Status ($(if ($sendRestricted) { 'True' } else { 'False' })) -Details ("RestrictSendingNTLMTraffic=2: {0}. 2 means Deny all outgoing NTLM traffic. Current setting: {1}." -f $sendRestricted, $restrictSendingText) -RawValue $restrictSending
        Add-Result -Check 'NTLM Restrict Receiving Traffic ok?' -Status ($(if ($receiveRestricted) { 'True' } else { 'False' })) -Details ("RestrictReceivingNTLMTraffic=2: {0}. 2 means Deny all incoming NTLM traffic. Current setting: {1}." -f $receiveRestricted, $restrictReceivingText) -RawValue $restrictReceiving
    }
    catch {
        Add-Result -Check 'NTLM LmCompatibilityLevel Hardened?' -Status 'Unknown' -Details "Unable to evaluate NTLM setting LmCompatibilityLevel. $($_.Exception.Message)" -RawValue $null
        Add-Result -Check 'NTLM Restrict Sending Traffic ok?' -Status 'Unknown' -Details "Unable to evaluate NTLM setting RestrictSendingNTLMTraffic. $($_.Exception.Message)" -RawValue $null
        Add-Result -Check 'NTLM Restrict Receiving Traffic ok?' -Status 'Unknown' -Details "Unable to evaluate NTLM setting RestrictReceivingNTLMTraffic. $($_.Exception.Message)" -RawValue $null
    }

    try {
        $enableMulticast = (Get-ItemProperty -Path 'HKLM:\Software\Policies\Microsoft\Windows NT\DNSClient' -Name 'EnableMulticast' -ErrorAction SilentlyContinue).EnableMulticast
        if ($null -eq $enableMulticast) {
            Add-Result -Check 'Is Multicast Name Resolution disabled' -Status 'False' -Details 'Multicast Name Resolution (LLMNR) policy is not configured; LLMNR is active by default.' -RawValue $enableMulticast
        }
        elseif ($enableMulticast -eq 0) {
            Add-Result -Check 'Is Multicast Name Resolution disabled' -Status 'True' -Details 'Multicast Name Resolution (LLMNR) is disabled via policy.' -RawValue $enableMulticast
        }
        else {
            Add-Result -Check 'Is Multicast Name Resolution disabled' -Status 'False' -Details "Multicast Name Resolution (LLMNR) is enabled (EnableMulticast=$enableMulticast)." -RawValue $enableMulticast
        }
    }
    catch {
        Add-Result -Check 'Is Multicast Name Resolution disabled' -Status 'Unknown' -Details "Unable to read Multicast Name Resolution setting. $($_.Exception.Message)" -RawValue $null
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

        $fwProfilesAll = @(Get-NetFirewallProfile -ErrorAction Stop)
        $domainProfile = @($fwProfilesAll | Where-Object { $_.Name -eq 'Domain' } | Select-Object -First 1)
        $privateProfile = @($fwProfilesAll | Where-Object { $_.Name -eq 'Private' } | Select-Object -First 1)
        $publicProfile = @($fwProfilesAll | Where-Object { $_.Name -eq 'Public' } | Select-Object -First 1)

        if ($publicProfile.Count -eq 1) {
            Add-Result -Check 'Windows Firewall profile Public enabled?' -Status ($(if ($publicProfile[0].Enabled) { 'True' } else { 'False' })) -Details ("Windows Firewall Public profile enabled: {0}." -f [bool]$publicProfile[0].Enabled) -RawValue $publicProfile[0]
        }
        else {
            Add-Result -Check 'Windows Firewall profile Public enabled?' -Status 'Unknown' -Details 'Windows Firewall Public profile was not found.' -RawValue $null
        }

        if ($domainProfile.Count -eq 1) {
            Add-Result -Check 'Windows Firewall profile Domain Enabled?' -Status ($(if ($domainProfile[0].Enabled) { 'True' } else { 'False' })) -Details ("Windows Firewall Domain profile enabled: {0}." -f [bool]$domainProfile[0].Enabled) -RawValue $domainProfile[0]
        }
        else {
            Add-Result -Check 'Windows Firewall profile Domain Enabled?' -Status 'Unknown' -Details 'Windows Firewall Domain profile was not found.' -RawValue $null
        }

        if ($privateProfile.Count -eq 1) {
            Add-Result -Check 'Windows Firewall profile Internal enabled?' -Status ($(if ($privateProfile[0].Enabled) { 'True' } else { 'False' })) -Details ("Windows Firewall Internal (Private) profile enabled: {0}." -f [bool]$privateProfile[0].Enabled) -RawValue $privateProfile[0]
        }
        else {
            Add-Result -Check 'Windows Firewall profile Internal enabled?' -Status 'Unknown' -Details 'Windows Firewall Internal (Private) profile was not found.' -RawValue $null
        }

        if ($activeFirewallProfiles.Count -eq 0) {
            Add-Result -Check 'Current Windows Firewall profile active?' -Status 'False' -Details 'No active network connection profile was detected.' -RawValue $null
        }
        else {
            $profileNames = $activeFirewallProfiles -join ', '
            Add-Result -Check 'Current Windows Firewall profile active?' -Status 'True' -Details "Active network profile(s): $profileNames" -RawValue $activeFirewallProfiles
        }
    }
    catch {
        Add-Result -Check 'Windows Firewall profile Public enabled?' -Status 'Unknown' -Details "Unable to read Windows Firewall Public profile status. $($_.Exception.Message)" -RawValue $null
        Add-Result -Check 'Windows Firewall profile Domain Enabled?' -Status 'Unknown' -Details "Unable to read Windows Firewall Domain profile status. $($_.Exception.Message)" -RawValue $null
        Add-Result -Check 'Windows Firewall profile Internal enabled?' -Status 'Unknown' -Details "Unable to read Windows Firewall Internal (Private) profile status. $($_.Exception.Message)" -RawValue $null
        Add-Result -Check 'Current Windows Firewall profile active?' -Status 'Unknown' -Details "Unable to read active network profile state. $($_.Exception.Message)" -RawValue $null
    }

    try {
        if ($activeFirewallProfiles.Count -eq 0) {
            Add-Result -Check 'Active Inbound Firewall rules in current profile?' -Status 'Unknown' -Details 'No active network connection profile was detected.' -RawValue $null
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
                Add-Result -Check 'Active Inbound Firewall rules in current profile?' -Status 'True' -Details "Found $($inboundRules.Count) active inbound firewall rule(s) for active profile(s): $profileNames" -RawValue $inboundRules.Count
            }
            else {
                $profileNames = $activeFirewallProfiles -join ', '
                Add-Result -Check 'Active Inbound Firewall rules in current profile?' -Status 'False' -Details "No active inbound firewall rules found for active profile(s): $profileNames" -RawValue 0
            }
        }
    }
    catch {
        Add-Result -Check 'Active Inbound Firewall rules in current profile?' -Status 'Unknown' -Details "Unable to read inbound firewall rules for active profile(s). $($_.Exception.Message)" -RawValue $null
    }

    try {
        if (-not $isElevated) {
            Add-Result -Check 'AppLocker being used?' -Status 'Unknown' -Details 'AppLocker check requires elevation. Run elevated to evaluate.' -RawValue $null
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
                Add-Result -Check 'AppLocker being used?' -Status 'True' -Details "AppLocker has enforced rule collections. AppIDSvc state: $serviceState." -RawValue $effectivePolicy
            }
            elseif ($auditCollections.Count -gt 0) {
                $serviceState = if ($appIdService) { $appIdService.Status } else { 'Unknown' }
                Add-Result -Check 'AppLocker being used?' -Status 'Unknown' -Details "AppLocker is configured in audit mode only. AppIDSvc state: $serviceState." -RawValue $effectivePolicy
            }
            elseif ($configuredCollections.Count -eq 0) {
                Add-Result -Check 'AppLocker being used?' -Status 'False' -Details 'No effective AppLocker policy is configured.' -RawValue $effectivePolicy
            }
            else {
                Add-Result -Check 'AppLocker being used?' -Status 'Unknown' -Details 'AppLocker policy detected but could not determine effective enforcement mode.' -RawValue $effectivePolicy
            }
        }
    }
    catch {
        Add-Result -Check 'AppLocker being used?' -Status 'Unknown' -Details "Unable to evaluate AppLocker status. $($_.Exception.Message)" -RawValue $null
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

    $riskWhenTrueChecks = @(
        'Current User member of Local Administrators group?',
        'Extra Local Users in Administrators group?',
        'Active Inbound Firewall rules in current profile?'
    )

    $issueWhenFalseChecks = @(
        'Running with Admin Priv?',
        'Running supported OS?',
        'Windows patched within 45 days?',
        'UEFI Mode?',
        'Secure Boot?',
        'Secure Boot State?',
        'Secure Boot Certificate Updated?',
        'TPM exists?',
        'BitLocker (OS Drive)?',
        'VBS enabled?',
        'Kernel DMA Protection?',
        'Credential Guard running?',
        'HVCI (Memory Integrity) running?',
        'Application control policy present?',
        'Application control scope: apps and scripts?',
        'Application control policy enforced?',
        'LSA Protection enabled?',
        'LSASS Protected Process enabled?',
        'WDigest Credential Caching disabled?',
        'UAC Enabled?',
        'Cached Logons Count less or equal to 1?',
        'Defender Real-Time Protection running?',
        'Defender EDR Service running?',
        'Defender Antivirus running?',
        'SMB1 Disabled?',
        'NTLM LmCompatibilityLevel Hardened?',
        'NTLM Restrict Sending Traffic ok?',
        'NTLM Restrict Receiving Traffic ok?',
        'Is Multicast Name Resolution disabled',
        'Windows Firewall profile Public enabled?',
        'Windows Firewall profile Domain Enabled?',
        'Windows Firewall profile Internal enabled?',
        'Current Windows Firewall profile active?',
        'AppLocker being used?'
    )

    $issueWhenTrueChecks = @(
        'Current User member of Local Administrators group?',
        'Extra Local Users in Administrators group?',
        'Active Inbound Firewall rules in current profile?'
    )

    if ($IssuesOnly) {
        Write-Output (
            $report.Result | Where-Object {
                (( $_.Check -in $issueWhenFalseChecks) -and ($_.Status -eq 'False')) -or
                (( $_.Check -in $issueWhenTrueChecks) -and ($_.Status -eq 'True'))
            }
        )
    }
    else {
        Write-Output $report.Result
    }

    $problemTrueCount = @(
        $script:Results | Where-Object {
            ($_.Check -in $riskWhenTrueChecks) -and ($_.Status -eq 'True')
        }
    ).Count

    if (($falseCount + $problemTrueCount) -gt 0) {
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

