
<#
.SYNOPSIS
    Lists the configured Attack Surface Reduction rules and actions.

.DESCRIPTION
    Reads the current Microsoft Defender Attack Surface Reduction configuration and
    maps each rule ID to a friendly name and the configured action.

.EXAMPLE
    .\Get-TSxWindowsASRPolicys.ps1

.NOTES
    FileName:    Get-TSxWindowsASRPolicys.ps1
    Version:     1.0.1
    Author:      Mikael Nystrom
    Contact:     @mikael_nystrom
    Created:     2026-09-16
    Updated:     2026-09-16
    Twitter:     @mikael_nystrom
    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author.

.LINK
    https://www.deploymentbunny.com
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RuleNames = @{
    '56A863A9-875E-4185-98A7-B882C64B5CE5' = 'Block abuse of exploited vulnerable signed drivers'
    'D4F940AB-401B-4EFC-AADC-AD5F3C50688A' = 'Block Office applications from creating child processes'
    '3B576869-A4EC-4529-8536-B80A7769E899' = 'Block Office applications from creating executable content'
    '75668C1F-73B5-4CF0-BB93-3ECF5CB7CC84' = 'Block Office applications from injecting code into other processes'
    '26190899-1602-49E8-8B27-EB1D0A1CE869' = 'Block Office communication applications from creating child processes'
    'BE9BA2D9-53EA-4CDC-84E5-9B1EEEE46550' = 'Block executable content from email and webmail'
    '01443614-CD74-433A-B99E-2ECDC07BFC25' = 'Block executable files unless they meet prevalence, age, or trusted list criteria'
    '5BEB7EFE-FD9A-4556-801D-275E5FFC04CC' = 'Block execution of potentially obfuscated scripts'
    'D3E037E1-3EB8-44C8-A917-57927947596D' = 'Block JavaScript or VBScript from launching downloaded executable content'
    '9E6C4E1F-7D60-472F-BA1A-A39EF669E4B2' = 'Block credential stealing from LSASS'
    'B2B3F03D-6A65-4F7B-A9C7-1C7EF74A9BA4' = 'Block untrusted and unsigned processes running from USB'
    'C1DB55AB-C21A-4637-BB3F-A12568109D35' = 'Use advanced protection against ransomware'
    '92E97FA1-2EDF-4476-BDD6-9DD0B4DDDC7B' = 'Block Win32 API calls from Office macros'
    'C0033C00-D16D-4114-A5A0-DC9B3A7D2CEB' = 'Block use of copied or impersonated system tools'
}

$Actions = @{
    0 = 'Disabled'
    1 = 'Block'
    2 = 'Audit'
    6 = 'Warn'
}

$MpPref = Get-MpPreference -ErrorAction Stop

$ruleIds = @()
if ($null -ne $MpPref.AttackSurfaceReductionRules_Ids) {
    $ruleIds = @($MpPref.AttackSurfaceReductionRules_Ids)
}

$ruleActions = @()
if ($null -ne $MpPref.AttackSurfaceReductionRules_Actions) {
    $ruleActions = @($MpPref.AttackSurfaceReductionRules_Actions)
}

$configuredRules = @{}
$maxCount = $ruleIds.Count
if ($ruleActions.Count -lt $maxCount) {
    $maxCount = $ruleActions.Count
}

for ($i = 0; $i -lt $maxCount; $i++) {
    $ruleId = [string]$ruleIds[$i]
    $configuredRules[$ruleId] = $ruleActions[$i]
}

$results = @()
foreach ($ruleId in ($RuleNames.Keys | Sort-Object)) {
    $actionValue = $configuredRules[$ruleId]
    if ($null -eq $actionValue) {
        $actionName = 'Disabled'
    }
    else {
        switch ([int]$actionValue) {
            0 { $actionName = 'Disabled' }
            1 { $actionName = 'Block' }
            2 { $actionName = 'Audit' }
            6 { $actionName = 'Warn' }
            default { $actionName = "Unknown ($actionValue)" }
        }
    }

    $results += '{0,-90} | {1} | {2}' -f $RuleNames[$ruleId], $ruleId, $actionName
}

$results