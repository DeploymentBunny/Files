#requires -Version 5.1

<#
.SYNOPSIS
	Gets AD user accounts from a specific OU and reports on UPN suffix mismatches.

.DESCRIPTION
	Queries Active Directory for user accounts under a given OU (SearchBase) and
	returns the accounts whose UserPrincipalName does NOT use the expected UPN
	suffix. Results can also be filtered by account status (Enabled/Disabled/All).

	If -ExpectedUPNSuffix is not supplied, all users in scope are returned
	(subject to the AccountStatus filter) without any UPN suffix comparison.

.PARAMETER SearchBase
	Distinguished name of the OU to search, e.g. 'OU=Users,DC=contoso,DC=com'.
	If omitted, the current domain's root is used.

.PARAMETER ExpectedUPNSuffix
	The UPN suffix that accounts are expected to have, e.g. 'contoso.com'.
	When supplied, only accounts whose UserPrincipalName does NOT end with
	this suffix are returned.

.PARAMETER AccountStatus
	Filters the result by account status. Valid values are 'All', 'Enabled',
	and 'Disabled'. Defaults to 'All'.

.PARAMETER UsersWithAdminCount1
	Only returns users whose AdminCount attribute is set to 1 (protected/privileged accounts).

.PARAMETER SearchScope
	AD search scope to use under SearchBase. Valid values are 'Base',
	'OneLevel', and 'Subtree'. Defaults to 'Subtree'.

.PARAMETER Server
	Optional domain controller to target for the query.

.PARAMETER Details
	Includes per-user details in the console output.

.PARAMETER IncludeDistinguishedName
	Adds the DistinguishedName property to the returned user objects and details table.

.PARAMETER Summary
	Writes a summary report to the console. Omitted by default so only the user objects are emitted to the pipeline.

.PARAMETER Force
	Recreates log file content for the current execution (when -Debug is enabled).

.EXAMPLE
	.\Get-TSxADusers.ps1 -SearchBase 'OU=Users,DC=contoso,DC=com' -ExpectedUPNSuffix 'contoso.com' -Verbose

.EXAMPLE
	.\Get-TSxADusers.ps1 -SearchBase 'OU=Users,DC=contoso,DC=com' -ExpectedUPNSuffix 'contoso.com' -AccountStatus Enabled -Details

.EXAMPLE
	.\Get-TSxADusers.ps1 -SearchBase 'OU=Users,DC=contoso,DC=com' -ExpectedUPNSuffix 'contoso.com' | Out-GridView

.NOTES
	FileName:    Get-TSxADusers.ps1
	Version:     1.5.0
	Author:      Mikael Nystrom
	Contact:     deploymentbunny@outlook.com
	Created:     2026-09-11
	Updated:     2026-09-11
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
	[string]$SearchBase,

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string]$ExpectedUPNSuffix,

	[Parameter()]
	[ValidateSet('All', 'Enabled', 'Disabled')]
	[string]$AccountStatus = 'All',

	[Parameter()]
	[switch]$UsersWithAdminCount1,

	[Parameter()]
	[ValidateSet('Base', 'OneLevel', 'Subtree')]
	[string]$SearchScope = 'Subtree',

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string]$Server,

	[Parameter()]
	[switch]$Details,

	[Parameter()]
	[switch]$IncludeDistinguishedName,

	[Parameter()]
	[switch]$Summary,

	[Parameter()]
	[switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:EnableFileLog = (($PSBoundParameters.ContainsKey('Debug') -and [bool]$PSBoundParameters['Debug']) -or $DebugPreference -eq 'Continue')
$script:LogRootPath = Join-Path -Path $env:TEMP -ChildPath 'Get-TSxADusers'
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

if ([string]::IsNullOrWhiteSpace($SearchBase)) {
	$rootDsePath = if ([string]::IsNullOrWhiteSpace($Server)) { 'LDAP://RootDSE' } else { "LDAP://$Server/RootDSE" }
	$SearchBase = ([adsi]$rootDsePath).defaultNamingContext.ToString()
}

Write-TSxLog -Message ('{0} started' -f $scriptName)
Write-TSxLog -Message ('SearchBase: {0}' -f $SearchBase)
Write-TSxLog -Message ('ExpectedUPNSuffix: {0}' -f $(if ([string]::IsNullOrWhiteSpace($ExpectedUPNSuffix)) { '(none)' } else { $ExpectedUPNSuffix }))
Write-TSxLog -Message ('AccountStatus: {0}' -f $AccountStatus)
Write-TSxLog -Message ('UsersWithAdminCount1: {0}' -f $UsersWithAdminCount1.IsPresent)
Write-TSxLog -Message ('SearchScope: {0}' -f $SearchScope)
Write-TSxLog -Message ('Server: {0}' -f $Server)
Write-TSxLog -Message ('File logging enabled: {0}' -f $script:EnableFileLog)
if ($script:EnableFileLog) {
	Write-TSxLog -Message ('Log path: {0}' -f $script:LogFilePath)
}

$result = [PSCustomObject]@{
	DomainController  = $null
	SearchBase        = $SearchBase
	SearchScope       = $SearchScope
	AccountStatus     = $AccountStatus
	UsersWithAdminCount1 = $UsersWithAdminCount1.IsPresent
	ExpectedUPNSuffix = $(if ([string]::IsNullOrWhiteSpace($ExpectedUPNSuffix)) { $null } else { $ExpectedUPNSuffix })
	TotalUsersInScope = 0
	MismatchCount     = 0
	QueryTimeUtc      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
	DetailsIncluded   = $Details.IsPresent
	Details           = @()
	LogFile           = $(if ($script:EnableFileLog) { $script:LogFilePath } else { $null })
}

$script:UserReport = @()

$queryTarget = if ([string]::IsNullOrWhiteSpace($Server)) { "Active Directory OU '$SearchBase'" } else { "Active Directory OU '$SearchBase' on server $Server" }
if ($PSCmdlet.ShouldProcess($queryTarget, 'Find user accounts and evaluate UPN suffix')) {
	Import-Module ActiveDirectory -ErrorAction Stop

	$adParams = @{
		SearchBase  = $SearchBase
		SearchScope = $SearchScope
		Filter      = '*'
		Properties  = @('DisplayName', 'SamAccountName', 'UserPrincipalName', 'Enabled', 'AdminCount')
		ErrorAction = 'Stop'
	}

	if (-not [string]::IsNullOrWhiteSpace($Server)) {
		$adParams['Server'] = $Server
		$result.DomainController = $Server
	}

	Write-TSxLog -Message 'Querying Active Directory for user accounts' -WriteVerbose
	$users = @(Get-ADUser @adParams)

	switch ($AccountStatus) {
		'Enabled' { $users = @($users | Where-Object { $_.Enabled }) }
		'Disabled' { $users = @($users | Where-Object { -not $_.Enabled }) }
	}

	if ($UsersWithAdminCount1.IsPresent) {
		$users = @($users | Where-Object { $_.AdminCount -eq 1 })
		Write-TSxLog -Message ('Filtered to {0} user(s) with AdminCount=1' -f $users.Count) -WriteVerbose
	}

	$result.TotalUsersInScope = $users.Count
	Write-TSxLog -Message ('Found {0} user(s) matching account status {1}' -f $users.Count, $AccountStatus) -WriteVerbose

	$mismatched = $users
	if (-not [string]::IsNullOrWhiteSpace($ExpectedUPNSuffix)) {
		$suffixPattern = '@{0}$' -f [regex]::Escape($ExpectedUPNSuffix)
		$mismatched = @($users | Where-Object { [string]::IsNullOrWhiteSpace($_.UserPrincipalName) -or $_.UserPrincipalName -notmatch $suffixPattern })
	}

	$result.MismatchCount = $mismatched.Count

	$userProperties = @(
		@{Name = 'Name'; Expression = { if (-not [string]::IsNullOrWhiteSpace($_.DisplayName)) { $_.DisplayName } else { $_.Name } } },
		'SamAccountName',
		'UserPrincipalName',
		'Enabled'
	)
	if ($IncludeDistinguishedName.IsPresent) {
		$userProperties += 'DistinguishedName'
	}

	$script:UserReport = @(
		$mismatched |
		Sort-Object -Property SamAccountName |
		Select-Object -Property $userProperties
	)
	$result.Details = $script:UserReport

	if ($null -eq $result.DomainController) {
		$result.DomainController = ([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()).PdcRoleOwner.Name
	}

	Write-TSxLog -Message ('Found {0} user(s) not matching the expected UPN suffix' -f $result.MismatchCount)
}
else {
	Write-TSxLog -Message 'WhatIf: skipped Active Directory query' -Level 'WARN'
}

Write-TSxLog -Message ('{0} completed' -f $scriptName)

if ($Summary.IsPresent) {
	Write-Host ''
	Write-Host 'AD user UPN suffix report' -ForegroundColor Cyan
	Write-Host ('SearchBase        : {0}' -f $result.SearchBase)
	Write-Host ('Domain controller : {0}' -f $(if (-not [string]::IsNullOrWhiteSpace($result.DomainController)) { $result.DomainController } else { 'N/A' }))
	Write-Host ('Account status    : {0}' -f $result.AccountStatus)
	Write-Host ('AdminCount=1 only : {0}' -f $result.UsersWithAdminCount1)
	Write-Host ('Expected suffix   : {0}' -f $(if ($result.ExpectedUPNSuffix) { $result.ExpectedUPNSuffix } else { '(not specified)' }))
	Write-Host ('Users in scope    : {0}' -f $result.TotalUsersInScope)
	Write-Host ('Mismatched users  : {0}' -f $result.MismatchCount)
	Write-Host ('Query time (UTC)  : {0}' -f $result.QueryTimeUtc)
}

if ($Details.IsPresent) {
	Write-Host ''
	Write-Host 'User details' -ForegroundColor Yellow

	if ($result.Details.Count -gt 0) {
		$tableProperties = @('Name', 'SamAccountName', 'UserPrincipalName', 'Enabled')
		if ($IncludeDistinguishedName.IsPresent) {
			$tableProperties += 'DistinguishedName'
		}

		$result.Details |
			Format-Table -Property $tableProperties -AutoSize |
			Out-Host
	}
	else {
		Write-Host '(no matching users)'
	}
}

# Emit user objects (not the summary wrapper) so results can be piped, e.g. to Out-GridView
Write-Output $script:UserReport
