#requires -Version 5.1

<#
.SYNOPSIS
	Gets enabled AD computer accounts that have not authenticated for more than one year.

.DESCRIPTION
	Queries Active Directory for enabled computer accounts and returns those that
	have not authenticated for more than one year, including computers that have
	never authenticated.

	Returns the result as an object and optionally includes per-account details.

.PARAMETER Details
	Includes per-computer details with computer names, last password change, and
	last logon time.

.PARAMETER Server
	Optional domain controller to target for the query.

.PARAMETER InactiveDays
	Number of days since last authentication used to classify a computer account
	as legacy. Defaults to 365.

.PARAMETER Force
	Recreates log file content for the current execution (when -Debug is enabled).

.EXAMPLE
	.\Get-TSxLegacyComputerAccounts.ps1 -Verbose

.EXAMPLE
	.\Get-TSxLegacyComputerAccounts.ps1 -Details -Server 'dc01.contoso.com' -Verbose

.NOTES
	FileName:    Get-TSxLegacyComputerAccounts.ps1
	Version:     1.0.0
	Author:      Mikael Nystrom
	Contact:     @mikael_nystrom
	Created:     2026-06-09
	Updated:     2026-06-09
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
	[ValidateRange(1, 36500)]
	[int]$InactiveDays = 365,

	[Parameter()]
	[switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:EnableFileLog = (($PSBoundParameters.ContainsKey('Debug') -and [bool]$PSBoundParameters['Debug']) -or $DebugPreference -eq 'Continue')
$script:LogRootPath = Join-Path -Path $env:TEMP -ChildPath 'Get-TSxLegacyComputerAccounts'
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

function Get-TSxOsCategory {
	[CmdletBinding()]
	param(
		[Parameter()]
		[AllowNull()]
		[string]$OperatingSystem
	)

	if ([string]::IsNullOrWhiteSpace($OperatingSystem)) {
		return 'Unknown'
	}

	if ($OperatingSystem -match '(?i)server') {
		return 'Server'
	}

	if ($OperatingSystem -match '(?i)windows') {
		return 'Client'
	}

	return 'Unknown'
}

$scriptName = Split-Path -Path $PSCommandPath -Leaf
$cutoffDateUtc = (Get-Date).ToUniversalTime().AddDays(-$InactiveDays)
$cutoffDateLocalText = $cutoffDateUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
$cutoffFileTime = $cutoffDateUtc.ToFileTimeUtc()

Write-TSxLog -Message ('{0} started' -f $scriptName)
Write-TSxLog -Message ('Server: {0}' -f $Server)
Write-TSxLog -Message ('Details: {0}' -f $Details.IsPresent)
Write-TSxLog -Message ('InactiveDays: {0}' -f $InactiveDays)
Write-TSxLog -Message ('Cutoff (local): {0}' -f $cutoffDateLocalText)
Write-TSxLog -Message ('File logging enabled: {0}' -f $script:EnableFileLog)
if ($script:EnableFileLog) {
	Write-TSxLog -Message ('Log path: {0}' -f $script:LogFilePath)
}

$result = [PSCustomObject]@{
	DomainController       = $null
	Scope                  = 'Entire Active Directory'
	InactiveDaysThreshold  = $InactiveDays
	InactiveBefore         = $cutoffDateLocalText
	LegacyComputerAccounts = 0
	ClientOsAccounts       = 0
	ServerOsAccounts       = 0
	UnknownOsAccounts      = 0
	QueryTimeUtc           = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
	Filter                 = 'Enabled computer accounts with lastLogonTimestamp older than threshold or never authenticated'
	DetailsIncluded        = $Details.IsPresent
	Details                = @()
	LogFile                = $(if ($script:EnableFileLog) { $script:LogFilePath } else { $null })
}

$queryTarget = if ([string]::IsNullOrWhiteSpace($Server)) { 'Active Directory (default domain context)' } else { "Active Directory on server $Server" }
if ($PSCmdlet.ShouldProcess($queryTarget, ('Find enabled computer accounts inactive for more than {0} days' -f $InactiveDays))) {
	Import-Module ActiveDirectory -ErrorAction Stop

	$ldapFilter = '(&(objectCategory=computer)(!(userAccountControl:1.2.840.113556.1.4.803:=2))(|(!(lastLogonTimestamp=*))(lastLogonTimestamp<={0})))' -f $cutoffFileTime
	$adParams = @{
		LDAPFilter    = $ldapFilter
		Properties    = @('SamAccountName', 'DNSHostName', 'PasswordLastSet', 'LastLogonDate', 'lastLogonTimestamp', 'Enabled', 'OperatingSystem')
		ResultSetSize = $null
		ErrorAction   = 'Stop'
	}

	if (-not [string]::IsNullOrWhiteSpace($Server)) {
		$adParams['Server'] = $Server
		$result.DomainController = $Server
	}

	Write-TSxLog -Message 'Querying Active Directory for enabled legacy computer accounts' -WriteVerbose
	$computers = @(Get-ADComputer @adParams)
	$result.LegacyComputerAccounts = $computers.Count

	$clientCount = 0
	$serverCount = 0
	$unknownCount = 0
	foreach ($computer in $computers) {
		$osCategory = Get-TSxOsCategory -OperatingSystem $computer.OperatingSystem
		switch ($osCategory) {
			'Client' { $clientCount++ }
			'Server' { $serverCount++ }
			default { $unknownCount++ }
		}
	}

	$result.ClientOsAccounts = $clientCount
	$result.ServerOsAccounts = $serverCount
	$result.UnknownOsAccounts = $unknownCount

	if ($Details.IsPresent) {
		$result.Details = @(
			$computers |
			Sort-Object -Property Name |
			Select-Object Name,
						  SamAccountName,
						  DNSHostName,
						  OperatingSystem,
						  @{Name='OsCategory';Expression={ Get-TSxOsCategory -OperatingSystem $_.OperatingSystem }},
						  @{Name='PasswordLastSet';Expression={ Convert-TSxNullableDateTimeToText -Value $_.PasswordLastSet }},
						  @{Name='LastLogonTime';Expression={ Convert-TSxNullableDateTimeToText -Value $_.LastLogonDate }}
		)

		Write-TSxLog -Message ('Added detail rows for {0} computer account(s)' -f $result.Details.Count) -WriteVerbose
	}

	if ($null -eq $result.DomainController) {
		$result.DomainController = ([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()).PdcRoleOwner.Name
	}

	Write-TSxLog -Message ('Counted {0} enabled legacy computer account(s)' -f $result.LegacyComputerAccounts)
}
else {
	Write-TSxLog -Message 'WhatIf: skipped Active Directory query' -Level 'WARN'
}

Write-TSxLog -Message ('{0} completed' -f $scriptName)

Write-Host ''
Write-Host ('Legacy AD computer accounts (enabled, inactive > {0} days)' -f $InactiveDays) -ForegroundColor Cyan
Write-Host ('Domain controller : {0}' -f $(if (-not [string]::IsNullOrWhiteSpace($result.DomainController)) { $result.DomainController } else { 'N/A' }))
Write-Host ('Scope             : {0}' -f $result.Scope)
Write-Host ('Inactive before   : {0}' -f $result.InactiveBefore)
Write-Host ('Count             : {0}' -f $result.LegacyComputerAccounts)
Write-Host ('Client OS         : {0}' -f $result.ClientOsAccounts)
Write-Host ('Server OS         : {0}' -f $result.ServerOsAccounts)
Write-Host ('Unknown OS        : {0}' -f $result.UnknownOsAccounts)
Write-Host ('Query time (UTC)  : {0}' -f $result.QueryTimeUtc)

if ($Details.IsPresent) {
	Write-Host ''
	Write-Host 'Computer details' -ForegroundColor Yellow

	if ($result.Details.Count -gt 0) {
		$result.Details |
			Format-Table -Property Name, SamAccountName, DNSHostName, OperatingSystem, OsCategory, PasswordLastSet, LastLogonTime -AutoSize |
			Out-Host
	}
	else {
		Write-Host 'No matching computer accounts found.'
	}
}

$result
