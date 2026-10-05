<#
.SYNOPSIS
Registers an Azure Local VM with Azure Arc from the Hyper-V host by running inside the guest.
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [string]$Tenant,

    [Parameter(Mandatory = $true)]
    [string]$Subscription,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [string]$Region = 'eastus',

    [string]$Cloud = 'AzureCloud',

    [System.Management.Automation.PSCredential]$Credentials,

    [string]$ArmAccessToken,

    [string]$TargetSolutionVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$vm = Get-VM -Name $VMName -ErrorAction Stop
if (-not $vm) {
    throw "VM '$VMName' was not found."
}

$params = @{
    TenantId = $Tenant
    SubscriptionID = $Subscription
    ResourceGroup = $ResourceGroup
    Region = $Region
    Cloud = $Cloud
}

if ($PSBoundParameters.ContainsKey('TargetSolutionVersion')) {
    $params.TargetSolutionVersion = $TargetSolutionVersion
}

if ($PSBoundParameters.ContainsKey('ArmAccessToken') -and -not [string]::IsNullOrWhiteSpace($ArmAccessToken)) {
    $params.ArmAccessToken = $ArmAccessToken
}

Invoke-Command -VMId $vm.Id -Credential $Credentials -ScriptBlock {
    $localParams = $using:params
    Invoke-AzStackHciArcInitialization @localParams
}
