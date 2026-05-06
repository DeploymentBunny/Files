<#
.Synopsis
    Windows 10/11 security baseline remediation.
.Description
    Applies configurable remediation actions for common controls identified by
    Check-WindowsClientSecurityBaseline.ps1.

    Supported remediation actions:
    - Enable VBS
    - Enable Credential Guard
    - Enable HVCI (Memory Integrity)
    - Enable LSA protection (RunAsPPL)
    - Enable LSASS protected process
    - Disable WDigest credential caching
    - Set cached logons count to 1
    - Enable Defender real-time protection
    - Enable Microsoft Defender EDR service
    - Disable SMB1
    - Harden NTLM settings
    - Enable Windows Defender Firewall profiles
    - Set default inbound firewall action to Block
    - Disable all enabled inbound firewall rules

    Preset actions:
    - HardenRecommended (curated safe subset)

    Many settings require a reboot before they are effective.
.Example
    .\Remediate-WindowsClientSecurityBaseline.ps1 -EnableVBS -EnableCredentialGuard -EnableHVCI -EnableLsaProtection -EnableFirewallProfiles
.Example
    .\Remediate-WindowsClientSecurityBaseline.ps1 -DisableAllInboundFirewallRules -WhatIf
.Example
    .\Remediate-WindowsClientSecurityBaseline.ps1 -HardenRecommended
.Example
    $r = .\Check-WindowsClientSecurityBaseline.ps1
    .\Remediate-WindowsClientSecurityBaseline.ps1 -BaselineResult $r -AutoFromBaseline
.Notes
    ScriptName: Remediate-WindowsClientSecurityBaseline.ps1
    Version:    1.4.0
    Updated:    2026-05-06
    Author:     Mikael Nystrom
    Blog:       https://www.deploymentbunny.com
    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the authors or Deployment Artist.
.Link
    https://www.deploymentbunny.com
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $false)]
    [object]$BaselineResult,

    [Parameter(Mandatory = $false)]
    [switch]$AutoFromBaseline,

    [Parameter(Mandatory = $false)]
    [switch]$HardenRecommended,

    [Parameter(Mandatory = $false)]
    [switch]$EnableVBS,

    [Parameter(Mandatory = $false)]
    [switch]$EnableCredentialGuard,

    [Parameter(Mandatory = $false)]
    [switch]$EnableHVCI,

    [Parameter(Mandatory = $false)]
    [switch]$EnableLsaProtection,

    [Parameter(Mandatory = $false)]
    [switch]$EnableLsassProtectedProcess,

    [Parameter(Mandatory = $false)]
    [switch]$DisableWDigestCredentialCaching,

    [Parameter(Mandatory = $false)]
    [switch]$SetCachedLogonsCount1,

    [Parameter(Mandatory = $false)]
    [switch]$EnableDefenderRealtimeProtection,

    [Parameter(Mandatory = $false)]
    [switch]$EnableDefenderEdrService,

    [Parameter(Mandatory = $false)]
    [switch]$DisableSMB1,

    [Parameter(Mandatory = $false)]
    [switch]$HardenNTLM,

    [Parameter(Mandatory = $false)]
    [switch]$EnableFirewallProfiles,

    [Parameter(Mandatory = $false)]
    [switch]$SetInboundDefaultBlock,

    [Parameter(Mandatory = $false)]
    [switch]$DisableAllInboundFirewallRules,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "$env:ProgramData\WindowsClientSecurityBaseline"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogFile = $null
$script:RestartRequired = $false
$script:Actions = New-Object System.Collections.Generic.List[object]

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

function Add-ActionResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Changed', 'NoChange', 'Skipped', 'Failed')]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$Details
    )

    $obj = [PSCustomObject]@{
        Action  = $Action
        Status  = $Status
        Details = $Details
    }

    $script:Actions.Add($obj) | Out-Null

    switch ($Status) {
        'Changed' { Write-Log -Message ("{0}: {1}" -f $Action, $Details) -Level 'INFO' }
        'NoChange' { Write-Log -Message ("{0}: {1}" -f $Action, $Details) -Level 'INFO' }
        'Skipped' { Write-Log -Message ("{0}: {1}" -f $Action, $Details) -Level 'WARN' }
        'Failed' { Write-Log -Message ("{0}: {1}" -f $Action, $Details) -Level 'ERROR' }
    }
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Set-RegistryDwordValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [int]$Value,

        [Parameter(Mandatory = $true)]
        [string]$ActionName
    )

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            if ($WhatIfPreference) {
                Add-ActionResult -Action $ActionName -Status 'Skipped' -Details ("WhatIf: would create registry key {0}." -f $Path)
                return
            }
            else {
                New-Item -Path $Path -Force | Out-Null
            }
        }

        $current = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
        if ($current -eq $Value) {
            Add-ActionResult -Action $ActionName -Status 'NoChange' -Details ("{0} is already set to {1}." -f $Name, $Value)
            return
        }

        if ($WhatIfPreference) {
            Add-ActionResult -Action $ActionName -Status 'Skipped' -Details ("WhatIf: would set {0} to {1}." -f $Name, $Value)
        }
        else {
            New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
            $script:RestartRequired = $true
            Add-ActionResult -Action $ActionName -Status 'Changed' -Details ("Set {0} to {1}." -f $Name, $Value)
        }
    }
    catch {
        Add-ActionResult -Action $ActionName -Status 'Failed' -Details $_.Exception.Message
    }
}

function Invoke-EnableVBS {
    Set-RegistryDwordValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -Name 'EnableVirtualizationBasedSecurity' -Value 1 -ActionName 'Enable VBS'
    Set-RegistryDwordValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -Name 'RequirePlatformSecurityFeatures' -Value 1 -ActionName 'Enable VBS'
}

function Invoke-EnableCredentialGuard {
    Set-RegistryDwordValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'LsaCfgFlags' -Value 1 -ActionName 'Enable Credential Guard'
}

function Invoke-EnableHVCI {
    Set-RegistryDwordValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name 'Enabled' -Value 1 -ActionName 'Enable HVCI'
}

function Invoke-EnableLsaProtection {
    Set-RegistryDwordValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL' -Value 2 -ActionName 'Enable LSA Protection'
}

function Invoke-EnableLsassProtectedProcess {
    Set-RegistryDwordValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL' -Value 2 -ActionName 'Enable LSASS Protected Process'
}

function Set-RegistryStringValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [string]$ActionName
    )

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            if ($WhatIfPreference) {
                Add-ActionResult -Action $ActionName -Status 'Skipped' -Details ("WhatIf: would create registry key {0}." -f $Path)
                return
            }
            else {
                New-Item -Path $Path -Force | Out-Null
            }
        }

        $current = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
        if ([string]$current -eq $Value) {
            Add-ActionResult -Action $ActionName -Status 'NoChange' -Details ("{0} is already set to {1}." -f $Name, $Value)
            return
        }

        if ($WhatIfPreference) {
            Add-ActionResult -Action $ActionName -Status 'Skipped' -Details ("WhatIf: would set {0} to {1}." -f $Name, $Value)
        }
        else {
            New-ItemProperty -Path $Path -Name $Name -PropertyType String -Value $Value -Force | Out-Null
            Add-ActionResult -Action $ActionName -Status 'Changed' -Details ("Set {0} to {1}." -f $Name, $Value)
        }
    }
    catch {
        Add-ActionResult -Action $ActionName -Status 'Failed' -Details $_.Exception.Message
    }
}

function Invoke-DisableWDigestCredentialCaching {
    Set-RegistryDwordValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' -Name 'UseLogonCredential' -Value 0 -ActionName 'Disable WDigest Credential Caching'
}

function Invoke-SetCachedLogonsCount1 {
    Set-RegistryStringValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'CachedLogonsCount' -Value '1' -ActionName 'Set Cached Logons Count to 1'
}

function Invoke-EnableDefenderRealtimeProtection {
    $actionName = 'Enable Defender Real-Time Protection'
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        if ($mp.RealTimeProtectionEnabled) {
            Add-ActionResult -Action $actionName -Status 'NoChange' -Details 'Defender real-time protection is already enabled.'
            return
        }

        if ($WhatIfPreference) {
            Add-ActionResult -Action $actionName -Status 'Skipped' -Details 'WhatIf: would enable Defender real-time protection.'
        }
        else {
            Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
            Add-ActionResult -Action $actionName -Status 'Changed' -Details 'Enabled Defender real-time protection.'
        }
    }
    catch {
        Add-ActionResult -Action $actionName -Status 'Failed' -Details $_.Exception.Message
    }
}

function Invoke-EnableDefenderEdrService {
    $actionName = 'Enable Defender EDR Service'
    try {
        $senseService = Get-Service -Name 'Sense' -ErrorAction SilentlyContinue
        if ($null -eq $senseService) {
            Add-ActionResult -Action $actionName -Status 'Failed' -Details 'Defender EDR service (Sense) was not found.'
            return
        }

        if ($senseService.StartType -eq 'Disabled') {
            if ($WhatIfPreference) {
                Add-ActionResult -Action $actionName -Status 'Skipped' -Details 'WhatIf: would set Sense startup type to Automatic.'
            }
            else {
                Set-Service -Name 'Sense' -StartupType Automatic -ErrorAction Stop
            }
        }

        $senseService = Get-Service -Name 'Sense' -ErrorAction Stop
        if ($senseService.Status -eq 'Running') {
            Add-ActionResult -Action $actionName -Status 'NoChange' -Details 'Defender EDR service (Sense) is already running.'
            return
        }

        if ($WhatIfPreference) {
            Add-ActionResult -Action $actionName -Status 'Skipped' -Details 'WhatIf: would start Defender EDR service (Sense).'
        }
        else {
            Start-Service -Name 'Sense' -ErrorAction Stop
            Add-ActionResult -Action $actionName -Status 'Changed' -Details 'Started Defender EDR service (Sense).'
        }
    }
    catch {
        Add-ActionResult -Action $actionName -Status 'Failed' -Details $_.Exception.Message
    }
}

function Invoke-DisableSMB1 {
    $actionName = 'Disable SMB1'
    try {
        $changed = @()

        if ($WhatIfPreference) {
            Add-ActionResult -Action $actionName -Status 'Skipped' -Details 'WhatIf: would disable SMB1 optional feature and SMB1 client/server protocol.'
            return
        }

        $smbFeature = Get-WindowsOptionalFeature -Online -FeatureName 'SMB1Protocol' -ErrorAction SilentlyContinue
        if ($null -ne $smbFeature -and $smbFeature.State -ne 'Disabled') {
            Disable-WindowsOptionalFeature -Online -FeatureName 'SMB1Protocol' -NoRestart -ErrorAction Stop | Out-Null
            $changed += 'Windows Optional Feature'
        }

        try {
            $serverConfig = Get-SmbServerConfiguration -ErrorAction Stop
            if ($serverConfig.EnableSMB1Protocol) {
                Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction Stop
                $changed += 'SMB Server Protocol'
            }
        }
        catch {
        }

        try {
            $clientConfig = Get-SmbClientConfiguration -ErrorAction Stop
            if ($clientConfig.EnableSMB1Protocol) {
                Set-SmbClientConfiguration -EnableSMB1Protocol $false -Force -ErrorAction Stop
                $changed += 'SMB Client Protocol'
            }
        }
        catch {
        }

        if ($changed.Count -gt 0) {
            $script:RestartRequired = $true
            Add-ActionResult -Action $actionName -Status 'Changed' -Details ("Disabled SMB1 components: {0}" -f ($changed -join ', '))
        }
        else {
            Add-ActionResult -Action $actionName -Status 'NoChange' -Details 'SMB1 is already disabled.'
        }
    }
    catch {
        Add-ActionResult -Action $actionName -Status 'Failed' -Details $_.Exception.Message
    }
}

function Invoke-HardenNTLM {
    Set-RegistryDwordValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'LmCompatibilityLevel' -Value 5 -ActionName 'Harden NTLM (LmCompatibilityLevel)'
    Set-RegistryDwordValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0' -Name 'RestrictSendingNTLMTraffic' -Value 2 -ActionName 'Harden NTLM (RestrictSendingNTLMTraffic)'
    Set-RegistryDwordValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0' -Name 'RestrictReceivingNTLMTraffic' -Value 2 -ActionName 'Harden NTLM (RestrictReceivingNTLMTraffic)'
}

function Invoke-EnableFirewallProfiles {
    $actionName = 'Enable Firewall Profiles'
    try {
        $firewallProfileNames = @('Domain', 'Private', 'Public')
        $changed = @()

        foreach ($fwProfileName in $firewallProfileNames) {
            $state = (Get-NetFirewallProfile -Profile $fwProfileName -ErrorAction Stop).Enabled
            if (-not $state) {
                if ($WhatIfPreference) {
                    $changed += $fwProfileName
                }
                else {
                    Set-NetFirewallProfile -Profile $fwProfileName -Enabled True -ErrorAction Stop
                    $changed += $fwProfileName
                }
            }
        }

        if ($changed.Count -gt 0) {
            if ($WhatIfPreference) {
                Add-ActionResult -Action $actionName -Status 'Skipped' -Details ("WhatIf: would enable profile(s): {0}" -f ($changed -join ', '))
            }
            else {
                Add-ActionResult -Action $actionName -Status 'Changed' -Details ("Enabled profile(s): {0}" -f ($changed -join ', '))
            }
        }
        else {
            Add-ActionResult -Action $actionName -Status 'NoChange' -Details 'All firewall profiles are already enabled.'
        }
    }
    catch {
        Add-ActionResult -Action $actionName -Status 'Failed' -Details $_.Exception.Message
    }
}

function Invoke-SetInboundDefaultBlock {
    $actionName = 'Set Firewall Inbound Default Block'
    try {
        if ($WhatIfPreference) {
            Add-ActionResult -Action $actionName -Status 'Skipped' -Details 'WhatIf: would set default inbound action to Block for all profiles.'
        }
        else {
            Set-NetFirewallProfile -Profile Domain,Private,Public -DefaultInboundAction Block -ErrorAction Stop
            Add-ActionResult -Action $actionName -Status 'Changed' -Details 'Set default inbound action to Block for all profiles.'
        }
    }
    catch {
        Add-ActionResult -Action $actionName -Status 'Failed' -Details $_.Exception.Message
    }
}

function Invoke-DisableAllInboundFirewallRules {
    $actionName = 'Disable All Inbound Firewall Rules'
    try {
        $rules = @(Get-NetFirewallRule -Direction Inbound -ErrorAction Stop | Where-Object { $_.Enabled -eq 'True' -or $_.Enabled -eq $true })
        if ($rules.Count -eq 0) {
            Add-ActionResult -Action $actionName -Status 'NoChange' -Details 'No enabled inbound firewall rules were found.'
            return
        }

        if ($WhatIfPreference) {
            Add-ActionResult -Action $actionName -Status 'Skipped' -Details ("WhatIf: would disable {0} inbound firewall rule(s)." -f $rules.Count)
        }
        else {
            $rules | Set-NetFirewallRule -Enabled False -ErrorAction Stop
            Add-ActionResult -Action $actionName -Status 'Changed' -Details ("Disabled {0} inbound firewall rule(s)." -f $rules.Count)
        }
    }
    catch {
        Add-ActionResult -Action $actionName -Status 'Failed' -Details $_.Exception.Message
    }
}

function Enable-FromBaseline {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Results
    )

    $problemChecks = @($Results | Where-Object { $_.Status -in @('False', 'Unknown') } | Select-Object -ExpandProperty Check -Unique)

    if ($problemChecks -contains 'VBS') { $script:EnableVBS = $true }
    if ($problemChecks -contains 'Credential Guard') { $script:EnableCredentialGuard = $true }
    if ($problemChecks -contains 'HVCI (Memory Integrity)') { $script:EnableHVCI = $true }
    if ($problemChecks -contains 'LSA Protection (RunAsPPL)') { $script:EnableLsaProtection = $true }
    if ($problemChecks -contains 'LSASS Protected Process') { $script:EnableLsassProtectedProcess = $true }
    if ($problemChecks -contains 'WDigest Credential Caching') { $script:DisableWDigestCredentialCaching = $true }
    if ($problemChecks -contains 'Cached Logons Count') { $script:SetCachedLogonsCount1 = $true }
    if ($problemChecks -contains 'Defender Real-Time Protection') { $script:EnableDefenderRealtimeProtection = $true }
    if ($problemChecks -contains 'Defender EDR Service') { $script:EnableDefenderEdrService = $true }
    if ($problemChecks -contains 'SMB1') { $script:DisableSMB1 = $true }
    if ($problemChecks -contains 'NTLM Hardening') { $script:HardenNTLM = $true }
    if ($problemChecks -contains 'Windows Firewall Profiles') { $script:EnableFirewallProfiles = $true }
    if ($problemChecks -contains 'Active Inbound Firewall Rules') { $script:SetInboundDefaultBlock = $true }
}

try {
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:LogFile = Join-Path -Path $OutputPath -ChildPath ("SecurityBaselineRemediation_{0}_{1}.log" -f $env:COMPUTERNAME, $timestamp)

    Write-Log -Message 'Starting remediation run.'

    if (-not (Test-IsAdmin)) {
        throw 'Run this script in an elevated PowerShell session (Administrator).'
    }

    if ($AutoFromBaseline) {
        if ($null -eq $BaselineResult) {
            throw 'AutoFromBaseline was specified but BaselineResult was not provided.'
        }

        $baselineChecks = $null
        if ($BaselineResult.PSObject.Properties['Result']) {
            $baselineChecks = @($BaselineResult.Result)
        }
        elseif ($BaselineResult -is [array]) {
            $baselineChecks = @($BaselineResult)
        }

        if ($null -eq $baselineChecks -or $baselineChecks.Count -eq 0) {
            throw 'Could not parse baseline results. Provide object from Check-WindowsClientSecurityBaseline.ps1.'
        }

        Enable-FromBaseline -Results $baselineChecks
        Write-Log -Message 'Enabled remediation actions from baseline result object.'
    }

    if ($HardenRecommended) {
        $EnableDefenderRealtimeProtection = $true
        $EnableDefenderEdrService = $true
        $EnableFirewallProfiles = $true
        $SetInboundDefaultBlock = $true
        $EnableLsaProtection = $true
        $EnableLsassProtectedProcess = $true
        $DisableWDigestCredentialCaching = $true
        $SetCachedLogonsCount1 = $true
        $DisableSMB1 = $true
        $HardenNTLM = $true
        Write-Log -Message 'Applied HardenRecommended preset: Defender RTP/EDR, firewall hardening, LSASS protection, WDigest disable, cached logons count 1, SMB1 disable, and NTLM hardening.'
    }

    if ($EnableVBS) { Invoke-EnableVBS }
    if ($EnableCredentialGuard) { Invoke-EnableCredentialGuard }
    if ($EnableHVCI) { Invoke-EnableHVCI }
    if ($EnableLsaProtection) { Invoke-EnableLsaProtection }
    if ($EnableLsassProtectedProcess) { Invoke-EnableLsassProtectedProcess }
    if ($DisableWDigestCredentialCaching) { Invoke-DisableWDigestCredentialCaching }
    if ($SetCachedLogonsCount1) { Invoke-SetCachedLogonsCount1 }
    if ($EnableDefenderRealtimeProtection) { Invoke-EnableDefenderRealtimeProtection }
    if ($EnableDefenderEdrService) { Invoke-EnableDefenderEdrService }
    if ($DisableSMB1) { Invoke-DisableSMB1 }
    if ($HardenNTLM) { Invoke-HardenNTLM }
    if ($EnableFirewallProfiles) { Invoke-EnableFirewallProfiles }
    if ($SetInboundDefaultBlock) { Invoke-SetInboundDefaultBlock }
    if ($DisableAllInboundFirewallRules) { Invoke-DisableAllInboundFirewallRules }

    if (
        -not $EnableVBS -and
        -not $EnableCredentialGuard -and
        -not $EnableHVCI -and
        -not $EnableLsaProtection -and
        -not $EnableLsassProtectedProcess -and
        -not $DisableWDigestCredentialCaching -and
        -not $SetCachedLogonsCount1 -and
        -not $EnableDefenderRealtimeProtection -and
        -not $EnableDefenderEdrService -and
        -not $DisableSMB1 -and
        -not $HardenNTLM -and
        -not $EnableFirewallProfiles -and
        -not $SetInboundDefaultBlock -and
        -not $DisableAllInboundFirewallRules -and
        -not $HardenRecommended
    ) {
        Add-ActionResult -Action 'Remediation Selection' -Status 'Skipped' -Details 'No remediation switches were selected.'
    }

    $changedCount = @($script:Actions | Where-Object { $_.Status -eq 'Changed' }).Count
    $failedCount = @($script:Actions | Where-Object { $_.Status -eq 'Failed' }).Count

    $summary = [PSCustomObject]@{
        ComputerName = $env:COMPUTERNAME
        Timestamp = Get-Date
        ChangedCount = $changedCount
        FailedCount = $failedCount
        RestartRequired = $script:RestartRequired
        LogFile = $script:LogFile
        Result = $script:Actions.ToArray()
    }

    Write-Log -Message ("Remediation complete. Changed={0}, Failed={1}, RestartRequired={2}" -f $changedCount, $failedCount, $script:RestartRequired)
    Write-Output $summary

    if ($failedCount -gt 0) {
        exit 2
    }

    if ($script:RestartRequired) {
        exit 1
    }

    exit 0
}
catch {
    Write-Log -Message ("Fatal error: {0}" -f $_.Exception.Message) -Level 'ERROR'
    Write-Error ("Remediation failed: {0}" -f $_.Exception.Message)
    exit 99
}
