#requires -Version 5.1

<#
.SYNOPSIS
	Gets the number of active AD user accounts with adminCount set to 1.

.DESCRIPTION
	Queries Active Directory for enabled user accounts where adminCount equals 1
	and returns the result as an object.

.PARAMETER Details
	Includes per-account details with account names, last password change, and
	last logon time.

.PARAMETER Server
	Optional domain controller to target for the query.

.PARAMETER Force
	Recreates log file content for the current execution.

.EXAMPLE
	.\Get-TSxActiveAdminCountAccounts.ps1 -Verbose

.EXAMPLE
	.\Get-TSxActiveAdminCountAccounts.ps1 -Server 'dc01.contoso.com' -Verbose

.NOTES
	FileName:    Get-TSxActiveAdminCountAccounts.ps1
	Version:     1.1.1
	Author:      Mikael Nystrom
	Contact:     @mikael_nystrom
	Created:     2026-06-08
	Updated:     2026-06-08
	Twitter:     @mikael_nystrom

	Disclaimer:
	This script is provided "AS IS" with no warranties, confers no rights and
	is not supported by the author.
.LINK
	https://www.deploymentbunny.com
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string]$Server,

	[Parameter()]
	[switch]$Details,

	[Parameter()]
	[switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:EnableFileLog = (($PSBoundParameters.ContainsKey('Debug') -and [bool]$PSBoundParameters['Debug']) -or $DebugPreference -eq 'Continue')
$script:LogRootPath = Join-Path -Path $env:TEMP -ChildPath 'Get-TSxActiveAdminCountAccounts'
$script:LogFilePath = Join-Path -Path $script:LogRootPath -ChildPath ('{0}.log' -f [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath))

if ($script:EnableFileLog -and -not (Test-Path -Path $script:LogRootPath -PathType Container)) {
	New-Item -Path $script:LogRootPath -ItemType Directory -Force | Out-Null
}

if ($script:EnableFileLog -and $Force.IsPresent -and (Test-Path -Path $script:LogFilePath -PathType Leaf)) {
	Clear-Content -Path $script:LogFilePath -ErrorAction SilentlyContinue
}

function Write-TSxLog {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Message,

		[ValidateSet('INFO', 'WARN', 'ERROR')]
		[string]$Level = 'INFO',

		[switch]$WriteVerbose
	)

	$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
	$entry = "$timestamp [$Level] $Message"
	if ($script:EnableFileLog) {
		Add-Content -Path $script:LogFilePath -Value $entry
	}

	if ($WriteVerbose -or $VerbosePreference -eq 'Continue') {
		Write-Verbose $entry
	}
}

function Convert-TSxNullableDateTimeToText {
	[CmdletBinding()]
	param(
		[Parameter()]
		[AllowNull()]
		[datetime]$Value
	)

	if ($null -eq $Value) {
		return $null
	}

	return $Value.ToString('yyyy-MM-dd HH:mm:ss')
}

$scriptName = Split-Path -Path $PSCommandPath -Leaf
Write-TSxLog -Message ('{0} started' -f $scriptName)
Write-TSxLog -Message ('Server: {0}' -f $Server)
Write-TSxLog -Message ('Details: {0}' -f $Details.IsPresent)
Write-TSxLog -Message ('File logging enabled: {0}' -f $script:EnableFileLog)
if ($script:EnableFileLog) {
	Write-TSxLog -Message ('Log path: {0}' -f $script:LogFilePath)
}

$result = [PSCustomObject]@{
	DomainController              = $null
	Scope                         = 'Entire Active Directory'
	ActiveAdminCount1UserAccounts = 0
	QueryTimeUtc                  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
	Filter                        = 'Enabled -eq $true and adminCount -eq 1'
	DetailsIncluded               = $Details.IsPresent
	Details                       = @()
	LogFile                       = $(if ($script:EnableFileLog) { $script:LogFilePath } else { $null })
}

$queryTarget = if ([string]::IsNullOrWhiteSpace($Server)) { 'Active Directory (default domain context)' } else { "Active Directory on server $Server" }
if ($PSCmdlet.ShouldProcess($queryTarget, 'Count enabled user accounts with adminCount=1')) {
	Import-Module ActiveDirectory -ErrorAction Stop

	$adParams = @{
		Filter     = 'Enabled -eq $true -and adminCount -eq 1'
		Properties = @('adminCount', 'Enabled', 'DisplayName', 'SamAccountName', 'PasswordLastSet', 'LastLogonDate')
		ResultSetSize = $null
		ErrorAction = 'Stop'
	}

	if (-not [string]::IsNullOrWhiteSpace($Server)) {
		$adParams['Server'] = $Server
		$result.DomainController = $Server
	}

	Write-TSxLog -Message 'Querying Active Directory for enabled users with adminCount=1' -WriteVerbose
	$accounts = @(Get-ADUser @adParams)
	$result.ActiveAdminCount1UserAccounts = $accounts.Count

	if ($Details.IsPresent) {
		$result.Details = @(
			$accounts |
			Sort-Object -Property SamAccountName |
			Select-Object @{Name='Name';Expression={ if (-not [string]::IsNullOrWhiteSpace($_.DisplayName)) { $_.DisplayName } else { $_.Name } }},
						  SamAccountName,
						  @{Name='PasswordLastSet';Expression={ Convert-TSxNullableDateTimeToText -Value $_.PasswordLastSet }},
						  @{Name='LastLogonTime';Expression={ Convert-TSxNullableDateTimeToText -Value $_.LastLogonDate }}
		)

		Write-TSxLog -Message ('Added detail rows for {0} account(s)' -f $result.Details.Count) -WriteVerbose
	}

	if ($null -eq $result.DomainController) {
		$result.DomainController = ([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()).PdcRoleOwner.Name
	}

	Write-TSxLog -Message ('Counted {0} enabled user account(s) with adminCount=1' -f $result.ActiveAdminCount1UserAccounts)
}
else {
	Write-TSxLog -Message 'WhatIf: skipped Active Directory query' -Level 'WARN'
}

Write-TSxLog -Message ('{0} completed' -f $scriptName)

Write-Host ''
Write-Host ('Active AD accounts with adminCount=1') -ForegroundColor Cyan
Write-Host ('Domain controller : {0}' -f $(if (-not [string]::IsNullOrWhiteSpace($result.DomainController)) { $result.DomainController } else { 'N/A' }))
Write-Host ('Scope             : {0}' -f $result.Scope)
Write-Host ('Count             : {0}' -f $result.ActiveAdminCount1UserAccounts)
Write-Host ('Query time (UTC)  : {0}' -f $result.QueryTimeUtc)

if ($Details.IsPresent) {
	Write-Host ''
	Write-Host 'Account details' -ForegroundColor Yellow

	if ($result.Details.Count -gt 0) {
		$result.Details |
			Format-Table -Property Name, SamAccountName, PasswordLastSet, LastLogonTime -AutoSize |
			Out-Host
	}
	else {
		Write-Host 'No matching accounts found.'
	}
}

$result
