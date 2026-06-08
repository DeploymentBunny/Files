#requires -Version 5.1

<#
.SYNOPSIS
	Gets console and RDP logon statistics from retained event logs.

.DESCRIPTION
	Collects successful interactive console logons from Security (Event ID 4624,
	LogonType 2) and RDP authentication events from Terminal Services
	RemoteConnectionManager (Event ID 1149).

	Returns:
	- Total number of interactive/console/RDP logons found in retained event log history
	- Number of interactive logons in the last 30 days
	- Number of interactive logons in the last 7 days
	- Number of unique users

.PARAMETER ComputerName
	Computer to query. Defaults to the local computer.

.PARAMETER IncludeServiceAccounts
	Includes machine/service style identities that are excluded by default.

.PARAMETER Force
	Recreates log file content for the current execution.

.EXAMPLE
	.\Get-TSxInteractiveLogons.ps1 -Verbose

.EXAMPLE
	.\Get-TSxInteractiveLogons.ps1 -ComputerName SRV01 -Verbose

.NOTES
	FileName:    Get-TSxInteractiveLogons.ps1
	Version:     1.2.1
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
	[string]$ComputerName = $env:COMPUTERNAME,

	[Parameter()]
	[switch]$IncludeServiceAccounts,

	[Parameter()]
	[switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogRootPath = Join-Path -Path $env:TEMP -ChildPath 'Get-TSxInteractiveLogons'
$script:LogFilePath = Join-Path -Path $script:LogRootPath -ChildPath ('{0}.log' -f [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath))

if (-not (Test-Path -Path $script:LogRootPath -PathType Container)) {
	New-Item -Path $script:LogRootPath -ItemType Directory -Force | Out-Null
}

if ($Force.IsPresent -and (Test-Path -Path $script:LogFilePath -PathType Leaf)) {
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
	Add-Content -Path $script:LogFilePath -Value $entry

	if ($WriteVerbose -or $VerbosePreference -eq 'Continue') {
		Write-Verbose $entry
	}
}

function Test-TSxIncludeUser {
	[CmdletBinding()]
	param(
		[Parameter()]
		[AllowNull()]
		[AllowEmptyString()]
		[string]$Domain,

		[Parameter()]
		[AllowNull()]
		[AllowEmptyString()]
		[string]$UserName,

		[Parameter(Mandatory = $true)]
		[bool]$IncludeServiceIdentities
	)

	if ($IncludeServiceIdentities) {
		return $true
	}

	if ([string]::IsNullOrWhiteSpace($UserName)) {
		return $false
	}

	if ($UserName.EndsWith('$')) {
		return $false
	}

	$excludedUsers = @(
		'SYSTEM',
		'LOCAL SERVICE',
		'NETWORK SERVICE',
		'DWM-1',
		'DWM-2',
		'ANONYMOUS LOGON',
		'UMFD-0',
		'UMFD-1',
		'UMFD-2'
	)

	if ($excludedUsers -contains $UserName.ToUpperInvariant()) {
		return $false
	}

	if ($Domain -eq 'NT AUTHORITY') {
		return $false
	}

	return $true
}

function Get-TSx4624FieldMap {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[System.Diagnostics.Eventing.Reader.EventRecord]$Event
	)

	$fieldMap = @{}

	if ($Event.Properties.Count -gt 8) {
		$fieldMap['TargetUserName'] = [string]$Event.Properties[5].Value
		$fieldMap['TargetDomainName'] = [string]$Event.Properties[6].Value
		$fieldMap['LogonType'] = [string]$Event.Properties[8].Value
	}

	if ([string]::IsNullOrWhiteSpace($fieldMap['TargetUserName']) -or [string]::IsNullOrWhiteSpace($fieldMap['LogonType'])) {
		$eventXml = [xml]$Event.ToXml()
		foreach ($node in $eventXml.Event.EventData.Data) {
			$fieldName = [string]$node.Name
			if ([string]::IsNullOrWhiteSpace($fieldName)) {
				continue
			}

			if ($fieldName -in @('TargetUserName', 'TargetDomainName', 'LogonType')) {
				$fieldMap[$fieldName] = [string]$node.'#text'
			}
		}
	}

	return $fieldMap
}

function Get-TSx1149FieldMap {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[System.Diagnostics.Eventing.Reader.EventRecord]$Event
	)

	$fieldMap = @{}
	$eventXml = [xml]$Event.ToXml()

	$eventNode = $eventXml.Event.UserData.EventXML
	if ($null -ne $eventNode) {
		$fieldMap['User'] = [string]$eventNode.Param1
		$fieldMap['Domain'] = [string]$eventNode.Param2
		$fieldMap['Client'] = [string]$eventNode.Param3
	}

	return $fieldMap
}

$scriptName = Split-Path -Path $PSCommandPath -Leaf
Write-TSxLog -Message ('{0} started' -f $scriptName)
Write-TSxLog -Message ('ComputerName: {0}' -f $ComputerName)
Write-TSxLog -Message ('IncludeServiceAccounts: {0}' -f $IncludeServiceAccounts.IsPresent)
Write-TSxLog -Message ('Log path: {0}' -f $script:LogFilePath)

$totalLogons = 0
$consoleLogons = 0
$rdpLogons = 0
$last30DaysLogons = 0
$last7DaysLogons = 0
$uniqueUsers = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$firstOverallLogon = $null
$firstConsoleLogon = $null
$firstRdpLogon = $null

$now = Get-Date
$thirtyDaysAgo = $now.AddDays(-30)
$sevenDaysAgo = $now.AddDays(-7)

$queryDescription = ('Read Security log Event ID 4624 on {0}' -f $ComputerName)
if ($PSCmdlet.ShouldProcess($ComputerName, $queryDescription)) {
	$filterXPath = "*[System[(EventID=4624)] and EventData[(Data[@Name='LogonType']='2')]]"
	$usedXPathFilter = $true
	Write-TSxLog -Message ('Querying Security log on {0} with XPath filter for console interactive logons (2)' -f $ComputerName) -WriteVerbose

	try {
		$events = Get-WinEvent -LogName 'Security' -FilterXPath $filterXPath -ComputerName $ComputerName -ErrorAction Stop
	}
	catch [System.Exception] {
		if ($_.Exception -is [System.UnauthorizedAccessException]) {
			$usedXPathFilter = $false
			Write-TSxLog -Message ('XPath query not authorized on {0}; falling back to Event ID query' -f $ComputerName) -Level 'WARN' -WriteVerbose
			try {
				$events = Get-WinEvent -FilterHashtable @{
					LogName = 'Security'
					Id      = 4624
				} -ComputerName $ComputerName -ErrorAction Stop
			}
			catch [System.Exception] {
				if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
					$events = $null
					Write-TSxLog -Message ('No matching 4624 events found on {0}' -f $ComputerName) -Level 'WARN' -WriteVerbose
				}
				else {
					throw
				}
			}
		}
		elseif ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
			$events = $null
			Write-TSxLog -Message ('No matching 4624 events found on {0}' -f $ComputerName) -Level 'WARN' -WriteVerbose
		}
		else {
			throw
		}
	}

	$processedEvents = 0
	Write-TSxLog -Message 'Beginning streaming event processing' -WriteVerbose

	foreach ($event in $events) {
		$processedEvents++
		$fieldMap = Get-TSx4624FieldMap -Event $event
		$logonType = [string]$fieldMap['LogonType']
		if ((-not $usedXPathFilter) -and $logonType -ne '2') {
			continue
		}

		$userName = [string]$fieldMap['TargetUserName']
		$domain = [string]$fieldMap['TargetDomainName']
		if (-not (Test-TSxIncludeUser -Domain $domain -UserName $userName -IncludeServiceIdentities $IncludeServiceAccounts.IsPresent)) {
			continue
		}

		$totalLogons++
		$consoleLogons++
		$eventTime = $event.TimeCreated
		if ($null -eq $firstOverallLogon -or $eventTime -lt $firstOverallLogon) {
			$firstOverallLogon = $eventTime
		}
		if ($null -eq $firstConsoleLogon -or $eventTime -lt $firstConsoleLogon) {
			$firstConsoleLogon = $eventTime
		}

		if ($eventTime -ge $thirtyDaysAgo) {
			$last30DaysLogons++
		}

		if ($eventTime -ge $sevenDaysAgo) {
			$last7DaysLogons++
		}

		$identity = if ([string]::IsNullOrWhiteSpace($domain)) {
			$userName
		}
		else {
			'{0}\{1}' -f $domain, $userName
		}

		$null = $uniqueUsers.Add($identity)
	}

	Write-TSxLog -Message ('Processed {0} interactive 4624 event(s)' -f $processedEvents) -WriteVerbose

	$rdpQuery = "*[System[(EventID=1149)]]"
	Write-TSxLog -Message ('Querying RemoteConnectionManager operational log on {0} for RDP auth events (1149)' -f $ComputerName) -WriteVerbose

	try {
		$rdpEvents = Get-WinEvent -LogName 'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational' -FilterXPath $rdpQuery -ComputerName $ComputerName -ErrorAction Stop
	}
	catch [System.Exception] {
		if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
			$rdpEvents = $null
			Write-TSxLog -Message ('No matching 1149 events found on {0}' -f $ComputerName) -Level 'WARN' -WriteVerbose
		}
		else {
			Write-TSxLog -Message ('RDP 1149 query failed on {0}: {1}' -f $ComputerName, $_.Exception.Message) -Level 'WARN' -WriteVerbose
			$rdpEvents = $null
		}
	}

	$processedRdpEvents = 0
	foreach ($rdpEvent in $rdpEvents) {
		$processedRdpEvents++
		$rdpFieldMap = Get-TSx1149FieldMap -Event $rdpEvent
		$userName = [string]$rdpFieldMap['User']
		$domain = [string]$rdpFieldMap['Domain']

		if (-not (Test-TSxIncludeUser -Domain $domain -UserName $userName -IncludeServiceIdentities $IncludeServiceAccounts.IsPresent)) {
			continue
		}

		$totalLogons++
		$rdpLogons++
		$eventTime = $rdpEvent.TimeCreated
		if ($null -eq $firstOverallLogon -or $eventTime -lt $firstOverallLogon) {
			$firstOverallLogon = $eventTime
		}
		if ($null -eq $firstRdpLogon -or $eventTime -lt $firstRdpLogon) {
			$firstRdpLogon = $eventTime
		}

		if ($eventTime -ge $thirtyDaysAgo) {
			$last30DaysLogons++
		}

		if ($eventTime -ge $sevenDaysAgo) {
			$last7DaysLogons++
		}

		$identity = if ([string]::IsNullOrWhiteSpace($domain)) {
			$userName
		}
		else {
			'{0}\{1}' -f $domain, $userName
		}

		$null = $uniqueUsers.Add($identity)
	}

	Write-TSxLog -Message ('Processed {0} RDP 1149 event(s)' -f $processedRdpEvents) -WriteVerbose
}
else {
	Write-TSxLog -Message ('WhatIf: skipped querying Security log on {0}' -f $ComputerName) -Level 'WARN'
}

$daysCoveredTotal = if ($null -ne $firstOverallLogon) { [Math]::Max(1.0, ((Get-Date) - $firstOverallLogon).TotalDays) } else { 0.0 }
$daysCoveredConsole = if ($null -ne $firstConsoleLogon) { [Math]::Max(1.0, ((Get-Date) - $firstConsoleLogon).TotalDays) } else { 0.0 }
$daysCoveredRdp = if ($null -ne $firstRdpLogon) { [Math]::Max(1.0, ((Get-Date) - $firstRdpLogon).TotalDays) } else { 0.0 }

$avgTotalPerDay = if ($daysCoveredTotal -gt 0) { [Math]::Round(($totalLogons / $daysCoveredTotal), 2) } else { 0.0 }
$avgConsolePerDay = if ($daysCoveredConsole -gt 0) { [Math]::Round(($consoleLogons / $daysCoveredConsole), 2) } else { 0.0 }
$avgRdpPerDay = if ($daysCoveredRdp -gt 0) { [Math]::Round(($rdpLogons / $daysCoveredRdp), 2) } else { 0.0 }

$dateTimeFormat = 'yyyy-MM-dd HH:mm:ss'
$queryTimeUtcText = (Get-Date).ToUniversalTime().ToString($dateTimeFormat)
$firstOverallLogonText = if ($null -ne $firstOverallLogon) { $firstOverallLogon.ToString($dateTimeFormat) } else { $null }
$firstConsoleLogonText = if ($null -ne $firstConsoleLogon) { $firstConsoleLogon.ToString($dateTimeFormat) } else { $null }
$firstRdpLogonText = if ($null -ne $firstRdpLogon) { $firstRdpLogon.ToString($dateTimeFormat) } else { $null }

$result = [PSCustomObject]@{
	ComputerName         = $ComputerName
	TotalLogons          = $totalLogons
	ConsoleLogons        = $consoleLogons
	RdpLogons            = $rdpLogons
	LogonsLast30Days     = $last30DaysLogons
	LogonsLast7Days      = $last7DaysLogons
	UniqueUsers          = $uniqueUsers.Count
	FirstOverallLogon    = $firstOverallLogonText
	FirstConsoleLogon    = $firstConsoleLogonText
	FirstRdpLogon        = $firstRdpLogonText
	AverageTotalPerDay   = $avgTotalPerDay
	AverageConsolePerDay = $avgConsolePerDay
	AverageRdpPerDay     = $avgRdpPerDay
	QueryTimeUtc         = $queryTimeUtcText
	Source               = 'Security/4624 (LogonType 2) + RemoteConnectionManager/1149'
	HistoryScope         = 'Entire retained history from both logs (oldest available to newest)'
	LogFile              = $script:LogFilePath
}

Write-TSxLog -Message ('TotalLogons: {0}' -f $result.TotalLogons)
Write-TSxLog -Message ('ConsoleLogons: {0}' -f $result.ConsoleLogons)
Write-TSxLog -Message ('RdpLogons: {0}' -f $result.RdpLogons)
Write-TSxLog -Message ('LogonsLast30Days: {0}' -f $result.LogonsLast30Days)
Write-TSxLog -Message ('LogonsLast7Days: {0}' -f $result.LogonsLast7Days)
Write-TSxLog -Message ('UniqueUsers: {0}' -f $result.UniqueUsers)
Write-TSxLog -Message ('FirstOverallLogon: {0}' -f $result.FirstOverallLogon)
Write-TSxLog -Message ('FirstConsoleLogon: {0}' -f $result.FirstConsoleLogon)
Write-TSxLog -Message ('FirstRdpLogon: {0}' -f $result.FirstRdpLogon)
Write-TSxLog -Message ('AverageTotalPerDay: {0}' -f $result.AverageTotalPerDay)
Write-TSxLog -Message ('AverageConsolePerDay: {0}' -f $result.AverageConsolePerDay)
Write-TSxLog -Message ('AverageRdpPerDay: {0}' -f $result.AverageRdpPerDay)
Write-TSxLog -Message ('{0} completed' -f $scriptName)

Write-Host ''
Write-Host ('Interactive logon statistics for {0}' -f $result.ComputerName) -ForegroundColor Cyan
Write-Host ('Total logons       : {0}' -f $result.TotalLogons)
Write-Host ('Console logons     : {0}' -f $result.ConsoleLogons)
Write-Host ('RDP logons         : {0}' -f $result.RdpLogons)
Write-Host ('Last 30 days       : {0}' -f $result.LogonsLast30Days)
Write-Host ('Last 7 days        : {0}' -f $result.LogonsLast7Days)
Write-Host ('Unique users       : {0}' -f $result.UniqueUsers)
Write-Host ('First total entry  : {0}' -f $(if ($null -ne $result.FirstOverallLogon) { $result.FirstOverallLogon } else { 'N/A' }))
Write-Host ('First console entry: {0}' -f $(if ($null -ne $result.FirstConsoleLogon) { $result.FirstConsoleLogon } else { 'N/A' }))
Write-Host ('First RDP entry    : {0}' -f $(if ($null -ne $result.FirstRdpLogon) { $result.FirstRdpLogon } else { 'N/A' }))
Write-Host ('Avg total/day      : {0}' -f $result.AverageTotalPerDay)
Write-Host ('Avg console/day    : {0}' -f $result.AverageConsolePerDay)
Write-Host ('Avg RDP/day        : {0}' -f $result.AverageRdpPerDay)
Write-Host ('Source             : {0}' -f $result.Source)
Write-Host ('History scope      : {0}' -f $result.HistoryScope)

$result
