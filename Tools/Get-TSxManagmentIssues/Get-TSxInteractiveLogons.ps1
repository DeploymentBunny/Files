#requires -Version 5.1

<#
.SYNOPSIS
	Gets console and RDP logon statistics from retained event logs.

.DESCRIPTION
	Collects successful interactive console logons from Security (Event ID 4624,
	LogonType 2) and RDP authentication events from Terminal Services
	RemoteConnectionManager (Event ID 1149).
	If RPC event log access is unavailable, the script attempts a WinRM
	Invoke-Command fallback.

	Returns:
	- Total number of interactive/console/RDP logons found in retained event log history
	- Number of interactive logons in the last 30 days
	- Number of interactive logons in the last 7 days
	- Number of unique users

.PARAMETER ComputerName
	Computer to query. Defaults to the local computer.
	Accepts pipeline input by property name from Name, DNSHostName,
	ComputerName and PSComputerName.

.PARAMETER Protocol
	Protocol preference for remote collection. Valid values are Auto, WinRM,
	RPC, and None. Auto selects WinRM first and falls back to RPC.
	When piped from Get-TSxServers.ps1, PreferredProtocol is honored.

.PARAMETER IncludeServiceAccounts
	Includes machine/service style identities that are excluded by default.

.PARAMETER Force
	Recreates log file content for the current execution.

.EXAMPLE
	.\Get-TSxInteractiveLogons.ps1 -Verbose

.EXAMPLE
	.\Get-TSxInteractiveLogons.ps1 -ComputerName SRV01 -Verbose

.EXAMPLE
	.\Get-TSxServers.ps1 -Online | .\Get-TSxInteractiveLogons.ps1 -Verbose

.NOTES
	FileName:    Get-TSxInteractiveLogons.ps1
	Version:     1.4.5
	Author:      Mikael Nystrom
	Contact:     @mikael_nystrom
	Created:     2026-06-08
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
	[Alias('Name', 'DNSHostName', 'PSComputerName')]
	[ValidateNotNullOrEmpty()]
	[string]$ComputerName = $env:COMPUTERNAME,

	[Parameter()]
	[Alias('PreferredProtocol')]
	[ValidateSet('Auto', 'WinRM', 'RPC', 'None')]
	[string]$Protocol = 'Auto',

	[Parameter(ValueFromPipeline = $true)]
	[AllowNull()]
	[object]$InputObject,

	[Parameter()]
	[switch]$IncludeServiceAccounts,

	[Parameter()]
	[switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:EnableFileLog = (($PSBoundParameters.ContainsKey('Debug') -and [bool]$PSBoundParameters['Debug']) -or $DebugPreference -eq 'Continue')
$script:LogRootPath = Join-Path -Path $env:TEMP -ChildPath 'Get-TSxInteractiveLogons'
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

function Test-TSxRpcUnavailableError {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[System.Exception]$Exception
	)

	$errorText = [string]$Exception.Message
	if ([string]::IsNullOrWhiteSpace($errorText)) {
		return $false
	}

	return (
		$errorText -match '(?i)rpc.*unavailable' -or
		$errorText -match '(?i)rpc-servern\s+är\s+inte\s+tillgänglig'
	)
}

function Get-TSxSecurity4624ViaWinRM {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$ComputerName
	)

	$scriptBlock = {
		$filterXPath = "*[System[(EventID=4624)] and EventData[(Data[@Name='LogonType']='2')]]"
		$events = @()
		$usedXPathFilter = $true

		try {
			$events = Get-WinEvent -LogName 'Security' -FilterXPath $filterXPath -ErrorAction Stop
		}
		catch [System.Exception] {
			if ($_.Exception -is [System.UnauthorizedAccessException]) {
				$usedXPathFilter = $false
				$events = Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4624 } -ErrorAction Stop
			}
			elseif ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
				$events = $null
			}
			else {
				throw
			}
		}

		$parsed = New-Object System.Collections.Generic.List[object]
		foreach ($eventRecord in @($events)) {
			if ($null -eq $eventRecord) {
				continue
			}

			$targetUserName = $null
			$targetDomainName = $null
			$logonType = $null
			$eventXml = $null
			try {
				$eventXml = [xml]$eventRecord.ToXml()
			}
			catch {
				continue
			}

			if ($null -eq $eventXml.Event -or $null -eq $eventXml.Event.EventData) {
				continue
			}

			foreach ($node in $eventXml.Event.EventData.Data) {
				switch ([string]$node.Name) {
					'TargetUserName' { $targetUserName = [string]$node.'#text'; continue }
					'TargetDomainName' { $targetDomainName = [string]$node.'#text'; continue }
					'LogonType' { $logonType = [string]$node.'#text'; continue }
				}
			}

			if ((-not $usedXPathFilter) -and $logonType -ne '2') {
				continue
			}

			$null = $parsed.Add([pscustomobject]@{
				TimeCreated      = $eventRecord.TimeCreated
				TargetUserName   = $targetUserName
				TargetDomainName = $targetDomainName
				LogonType        = $logonType
			})
		}

		return @($parsed.ToArray())
	}

	return Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock -ErrorAction Stop
}

function Get-TSxRdp1149ViaWinRM {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$ComputerName
	)

	$scriptBlock = {
		$events = @()
		$rdpQuery = "*[System[(EventID=1149)]]"
		try {
			$events = Get-WinEvent -LogName 'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational' -FilterXPath $rdpQuery -ErrorAction Stop
		}
		catch [System.Exception] {
			if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
				$events = $null
			}
			else {
				throw
			}
		}

		$parsed = New-Object System.Collections.Generic.List[object]
		foreach ($eventRecord in @($events)) {
			if ($null -eq $eventRecord) {
				continue
			}

			$eventXml = $null
			try {
				$eventXml = [xml]$eventRecord.ToXml()
			}
			catch {
				continue
			}

			if ($null -eq $eventXml.Event) {
				continue
			}

			$eventNode = $eventXml.Event.UserData.EventXML
			if ($null -eq $eventNode) {
				continue
			}

			$null = $parsed.Add([pscustomobject]@{
				TimeCreated = $eventRecord.TimeCreated
				User        = [string]$eventNode.Param1
				Domain      = [string]$eventNode.Param2
			})
		}

		return @($parsed.ToArray())
	}

	return Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock -ErrorAction Stop
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

function Get-TSxNormalizedIdentity {
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

		[Parameter()]
		[AllowNull()]
		[AllowEmptyString()]
		[string]$ComputerName
	)

	$normalizedUser = if ($null -eq $UserName) { '' } else { $UserName.Trim() }
	$normalizedDomain = if ($null -eq $Domain) { '' } else { $Domain.Trim() }

	if ([string]::IsNullOrWhiteSpace($normalizedUser)) {
		return [pscustomobject]@{
			UserName    = ''
			Domain      = ''
			IdentityKey = ''
		}
	}

	if ($normalizedUser.Contains('@')) {
		$upnParts = $normalizedUser.Split('@', 2)
		if ($upnParts.Count -eq 2) {
			$normalizedUser = [string]$upnParts[0]
			if ([string]::IsNullOrWhiteSpace($normalizedDomain)) {
				$normalizedDomain = [string]$upnParts[1]
			}
		}
	}

	if ($normalizedUser.Contains('\')) {
		$slashParts = $normalizedUser.Split('\', 2)
		if ($slashParts.Count -eq 2) {
			if ([string]::IsNullOrWhiteSpace($normalizedDomain)) {
				$normalizedDomain = [string]$slashParts[0]
			}

			$normalizedUser = [string]$slashParts[1]
		}
	}

	if (-not [string]::IsNullOrWhiteSpace($normalizedDomain) -and $normalizedDomain.Contains('.')) {
		$normalizedDomain = [string]$normalizedDomain.Split('.', 2)[0]
	}

	$computerShortName = if ([string]::IsNullOrWhiteSpace($ComputerName)) {
		''
	}
	else {
		([string]$ComputerName).Split('.', 2)[0]
	}

	if (-not [string]::IsNullOrWhiteSpace($normalizedDomain)) {
		$domainUpper = $normalizedDomain.ToUpperInvariant()
		$computerUpper = $computerShortName.ToUpperInvariant()
		if ($domainUpper -eq $computerUpper -or $domainUpper -eq 'LOCALHOST') {
			$normalizedDomain = $computerShortName
		}
	}

	$normalizedUser = $normalizedUser.Trim()
	$normalizedDomain = $normalizedDomain.Trim()

	$identityKey = if ([string]::IsNullOrWhiteSpace($normalizedDomain)) {
		$normalizedUser.ToUpperInvariant()
	}
	else {
		('{0}\{1}' -f $normalizedDomain, $normalizedUser).ToUpperInvariant()
	}

	return [pscustomobject]@{
		UserName    = $normalizedUser
		Domain      = $normalizedDomain
		IdentityKey = $identityKey
	}
}

function Get-TSx4624FieldMap {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[System.Diagnostics.Eventing.Reader.EventRecord]$EventRecord
	)

	$fieldMap = @{}

	if ($EventRecord.Properties.Count -gt 8) {
		$fieldMap['TargetUserName'] = [string]$EventRecord.Properties[5].Value
		$fieldMap['TargetDomainName'] = [string]$EventRecord.Properties[6].Value
		$fieldMap['LogonType'] = [string]$EventRecord.Properties[8].Value
	}

	if ([string]::IsNullOrWhiteSpace($fieldMap['TargetUserName']) -or [string]::IsNullOrWhiteSpace($fieldMap['LogonType'])) {
		$eventXml = [xml]$EventRecord.ToXml()
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
		[System.Diagnostics.Eventing.Reader.EventRecord]$EventRecord
	)

	$fieldMap = @{}
	$eventXml = [xml]$EventRecord.ToXml()

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
Write-TSxLog -Message ('IncludeServiceAccounts: {0}' -f $IncludeServiceAccounts.IsPresent)
Write-TSxLog -Message ('File logging enabled: {0}' -f $script:EnableFileLog)
if ($script:EnableFileLog) {
	Write-TSxLog -Message ('Log path: {0}' -f $script:LogFilePath)
}

function Invoke-TSxInteractiveLogonCollection {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$TargetComputerName,

		[Parameter()]
		[ValidateSet('Auto', 'WinRM', 'RPC', 'None')]
		[string]$ProtocolPreference = 'Auto'
	)

	$effectiveProtocol = if ([string]::IsNullOrWhiteSpace($ProtocolPreference) -or $ProtocolPreference -eq 'None') { 'Auto' } else { $ProtocolPreference }
	$preferWinRm = ($effectiveProtocol -eq 'Auto' -or $effectiveProtocol -eq 'WinRM')
	$allowRpcFallback = ($effectiveProtocol -eq 'Auto')
	$skipSecurityRpcQuery = $false
	$skipRdpRpcQuery = $false

	Write-TSxLog -Message ('ComputerName: {0}' -f $TargetComputerName)
	Write-TSxLog -Message ('Protocol preference: {0}' -f $effectiveProtocol) -WriteVerbose

	$totalLogons = 0
	$consoleLogons = 0
	$rdpLogons = 0
	$last30DaysLogons = 0
	$last7DaysLogons = 0
	$queryIssues = New-Object System.Collections.Generic.List[string]
	$uniqueUsers = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
	$firstOverallLogon = $null
	$firstConsoleLogon = $null
	$firstRdpLogon = $null

	$now = Get-Date
	$thirtyDaysAgo = $now.AddDays(-30)
	$sevenDaysAgo = $now.AddDays(-7)
	$events = @()
	$rdpEvents = @()
	$securityWinRmEvents = @()
	$rdpWinRmEvents = @()

	$queryDescription = ('Read Security log Event ID 4624 on {0}' -f $TargetComputerName)
	if ($PSCmdlet.ShouldProcess($TargetComputerName, $queryDescription)) {
		if ($preferWinRm) {
			Write-TSxLog -Message ('Trying WinRM first on {0}' -f $TargetComputerName) -WriteVerbose
			try {
				$securityWinRmEvents = @(Get-TSxSecurity4624ViaWinRM -ComputerName $TargetComputerName)
				$skipSecurityRpcQuery = $true
				Write-TSxLog -Message ('WinRM first-path returned {0} Security 4624 event(s) on {1}' -f @($securityWinRmEvents).Count, $TargetComputerName) -WriteVerbose
			}
			catch {
				$issueText = 'Security 4624 WinRM first-path failed: {0}' -f $_.Exception.Message
				$null = $queryIssues.Add($issueText)
				Write-TSxLog -Message ('{0} on {1}' -f $issueText, $TargetComputerName) -Level 'WARN' -WriteVerbose
				if (-not $allowRpcFallback) {
					$skipSecurityRpcQuery = $true
				}
			}

			try {
				$rdpWinRmEvents = @(Get-TSxRdp1149ViaWinRM -ComputerName $TargetComputerName)
				$skipRdpRpcQuery = $true
				Write-TSxLog -Message ('WinRM first-path returned {0} RDP 1149 event(s) on {1}' -f @($rdpWinRmEvents).Count, $TargetComputerName) -WriteVerbose
			}
			catch {
				$issueText = 'RDP 1149 WinRM first-path failed: {0}' -f $_.Exception.Message
				$null = $queryIssues.Add($issueText)
				Write-TSxLog -Message ('{0} on {1}' -f $issueText, $TargetComputerName) -Level 'WARN' -WriteVerbose
				if (-not $allowRpcFallback) {
					$skipRdpRpcQuery = $true
				}
			}
		}

		$filterXPath = "*[System[(EventID=4624)] and EventData[(Data[@Name='LogonType']='2')]]"
		$usedXPathFilter = $true
		if (-not $skipSecurityRpcQuery) {
			Write-TSxLog -Message ('Querying Security log on {0} with XPath filter for console interactive logons (2)' -f $TargetComputerName) -WriteVerbose
		}

		if (-not $skipSecurityRpcQuery) {
			try {
				$events = Get-WinEvent -LogName 'Security' -FilterXPath $filterXPath -ComputerName $TargetComputerName -ErrorAction Stop
			}
			catch [System.Exception] {
			if ($_.Exception -is [System.UnauthorizedAccessException]) {
				$usedXPathFilter = $false
				Write-TSxLog -Message ('XPath query not authorized on {0}; falling back to Event ID query' -f $TargetComputerName) -Level 'WARN' -WriteVerbose
				try {
					$events = Get-WinEvent -FilterHashtable @{
						LogName = 'Security'
						Id      = 4624
					} -ComputerName $TargetComputerName -ErrorAction Stop
				}
				catch [System.Exception] {
					if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
						$events = $null
						Write-TSxLog -Message ('No matching 4624 events found on {0}' -f $TargetComputerName) -Level 'WARN' -WriteVerbose
					}
					else {
						$events = $null
						$issueText = 'Security 4624 fallback query failed: {0}' -f $_.Exception.Message
						$null = $queryIssues.Add($issueText)
						Write-TSxLog -Message ('{0} on {1}' -f $issueText, $TargetComputerName) -Level 'WARN' -WriteVerbose
					}
				}
			}
			elseif ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
				$events = $null
				Write-TSxLog -Message ('No matching 4624 events found on {0}' -f $TargetComputerName) -Level 'WARN' -WriteVerbose
			}
			else {
				$events = $null
				$issueText = 'Security 4624 query failed: {0}' -f $_.Exception.Message
				$null = $queryIssues.Add($issueText)
				Write-TSxLog -Message ('{0} on {1}' -f $issueText, $TargetComputerName) -Level 'WARN' -WriteVerbose
			}
			}
		}

		$processedEvents = 0
		Write-TSxLog -Message 'Beginning streaming event processing' -WriteVerbose

		foreach ($securityEvent in @($events)) {
			if ($null -eq $securityEvent) {
				continue
			}

			$processedEvents++
			$fieldMap = Get-TSx4624FieldMap -EventRecord $securityEvent
			$logonType = [string]$fieldMap['LogonType']
			if ((-not $usedXPathFilter) -and $logonType -ne '2') {
				continue
			}

			$userName = [string]$fieldMap['TargetUserName']
			$domain = [string]$fieldMap['TargetDomainName']
			$identityInfo = Get-TSxNormalizedIdentity -Domain $domain -UserName $userName -ComputerName $TargetComputerName
			$userName = [string]$identityInfo.UserName
			$domain = [string]$identityInfo.Domain
			if (-not (Test-TSxIncludeUser -Domain $domain -UserName $userName -IncludeServiceIdentities $IncludeServiceAccounts.IsPresent)) {
				continue
			}

			$totalLogons++
			$consoleLogons++
			$eventTime = $securityEvent.TimeCreated
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

			if (-not [string]::IsNullOrWhiteSpace([string]$identityInfo.IdentityKey)) {
				$null = $uniqueUsers.Add([string]$identityInfo.IdentityKey)
			}
		}

		foreach ($securityEvent in @($securityWinRmEvents)) {
			$processedEvents++
			$logonType = [string]$securityEvent.LogonType
			if ($logonType -ne '2') {
				continue
			}

			$userName = [string]$securityEvent.TargetUserName
			$domain = [string]$securityEvent.TargetDomainName
			$identityInfo = Get-TSxNormalizedIdentity -Domain $domain -UserName $userName -ComputerName $TargetComputerName
			$userName = [string]$identityInfo.UserName
			$domain = [string]$identityInfo.Domain
			if (-not (Test-TSxIncludeUser -Domain $domain -UserName $userName -IncludeServiceIdentities $IncludeServiceAccounts.IsPresent)) {
				continue
			}

			$totalLogons++
			$consoleLogons++
			$eventTime = $securityEvent.TimeCreated
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

			if (-not [string]::IsNullOrWhiteSpace([string]$identityInfo.IdentityKey)) {
				$null = $uniqueUsers.Add([string]$identityInfo.IdentityKey)
			}
		}

		Write-TSxLog -Message ('Processed {0} interactive 4624 event(s)' -f $processedEvents) -WriteVerbose

		$rdpQuery = "*[System[(EventID=1149)]]"
		if (-not $skipRdpRpcQuery) {
			Write-TSxLog -Message ('Querying RemoteConnectionManager operational log on {0} for RDP auth events (1149)' -f $TargetComputerName) -WriteVerbose
		}

		if (-not $skipRdpRpcQuery) {
			try {
				$rdpEvents = Get-WinEvent -LogName 'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational' -FilterXPath $rdpQuery -ComputerName $TargetComputerName -ErrorAction Stop
			}
			catch [System.Exception] {
			if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
				$rdpEvents = $null
				Write-TSxLog -Message ('No matching 1149 events found on {0}' -f $TargetComputerName) -Level 'WARN' -WriteVerbose
			}
			else {
				$issueText = 'RDP 1149 query failed: {0}' -f $_.Exception.Message
				$null = $queryIssues.Add($issueText)
				Write-TSxLog -Message ('RDP 1149 query failed on {0}: {1}' -f $TargetComputerName, $_.Exception.Message) -Level 'WARN' -WriteVerbose
				$rdpEvents = $null
			}
			}
		}

		$processedRdpEvents = 0
		foreach ($rdpEvent in @($rdpEvents)) {
			if ($null -eq $rdpEvent) {
				continue
			}

			$processedRdpEvents++
			$rdpFieldMap = Get-TSx1149FieldMap -EventRecord $rdpEvent
			$userName = [string]$rdpFieldMap['User']
			$domain = [string]$rdpFieldMap['Domain']
			$identityInfo = Get-TSxNormalizedIdentity -Domain $domain -UserName $userName -ComputerName $TargetComputerName
			$userName = [string]$identityInfo.UserName
			$domain = [string]$identityInfo.Domain

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

			if (-not [string]::IsNullOrWhiteSpace([string]$identityInfo.IdentityKey)) {
				$null = $uniqueUsers.Add([string]$identityInfo.IdentityKey)
			}
		}

		foreach ($rdpEvent in @($rdpWinRmEvents)) {
			$processedRdpEvents++
			$userName = [string]$rdpEvent.User
			$domain = [string]$rdpEvent.Domain
			$identityInfo = Get-TSxNormalizedIdentity -Domain $domain -UserName $userName -ComputerName $TargetComputerName
			$userName = [string]$identityInfo.UserName
			$domain = [string]$identityInfo.Domain

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

			if (-not [string]::IsNullOrWhiteSpace([string]$identityInfo.IdentityKey)) {
				$null = $uniqueUsers.Add([string]$identityInfo.IdentityKey)
			}
		}

		Write-TSxLog -Message ('Processed {0} RDP 1149 event(s)' -f $processedRdpEvents) -WriteVerbose
	}
	else {
		Write-TSxLog -Message ('WhatIf: skipped querying Security log on {0}' -f $TargetComputerName) -Level 'WARN'
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
		ComputerName         = $TargetComputerName
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
		QueryStatus          = $(if (@($queryIssues).Count -gt 0) { 'Warning' } else { 'OK' })
		QueryIssues          = @($queryIssues)
		QueryTimeUtc         = $queryTimeUtcText
		Source               = 'Security/4624 (LogonType 2) + RemoteConnectionManager/1149'
		HistoryScope         = 'Entire retained history from both logs (oldest available to newest)'
		LogFile              = $(if ($script:EnableFileLog) { $script:LogFilePath } else { $null })
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
	Write-TSxLog -Message ('QueryStatus: {0}' -f $result.QueryStatus)
	if (@($result.QueryIssues).Count -gt 0) {
		Write-TSxLog -Message ('QueryIssues: {0}' -f ($result.QueryIssues -join ' | ')) -Level 'WARN'
	}

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
	Write-Host ('Query status       : {0}' -f $result.QueryStatus)
	if (@($result.QueryIssues).Count -gt 0) {
		Write-Host ('Query issues       : {0}' -f ($result.QueryIssues -join ' | '))
	}
	Write-Host ('Source             : {0}' -f $result.Source)
	Write-Host ('History scope      : {0}' -f $result.HistoryScope)

	return $result
}

$targetComputers = New-Object System.Collections.Generic.List[object]
$seenTargets = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

if ($PSBoundParameters.ContainsKey('ComputerName')) {
	foreach ($target in @($ComputerName)) {
		if (-not [string]::IsNullOrWhiteSpace([string]$target) -and $seenTargets.Add([string]$target)) {
			$null = $targetComputers.Add([pscustomobject]@{
				ComputerName = [string]$target
				Protocol     = $Protocol
			})
		}
	}
}

$pipedItems = New-Object System.Collections.Generic.List[object]
if ($null -ne $InputObject) {
	$null = $pipedItems.Add($InputObject)
}

foreach ($queuedInputObject in $input) {
	$null = $pipedItems.Add($queuedInputObject)
}

foreach ($pipedObject in $pipedItems) {
	if ($null -eq $pipedObject) {
		continue
	}

	$resolvedComputerName = $null
	$resolvedProtocol = $null
	if ($pipedObject -is [string]) {
		$resolvedComputerName = [string]$pipedObject
		$resolvedProtocol = $Protocol
	}
	else {
		foreach ($propertyName in @('ComputerName', 'DNSHostName', 'Name', 'PSComputerName')) {
			$property = $pipedObject.PSObject.Properties[$propertyName]
			if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
				$resolvedComputerName = [string]$property.Value
				break
			}
		}

		$protocolProperty = $pipedObject.PSObject.Properties['PreferredProtocol']
		if ($null -eq $protocolProperty) {
			$protocolProperty = $pipedObject.PSObject.Properties['Protocol']
		}

		if ($null -ne $protocolProperty -and -not [string]::IsNullOrWhiteSpace([string]$protocolProperty.Value)) {
			$resolvedProtocol = [string]$protocolProperty.Value
		}
		else {
			$resolvedProtocol = $Protocol
		}
	}

	if (-not [string]::IsNullOrWhiteSpace($resolvedComputerName) -and $seenTargets.Add($resolvedComputerName)) {
		$null = $targetComputers.Add([pscustomobject]@{
			ComputerName = $resolvedComputerName
			Protocol     = $resolvedProtocol
		})
	}
}

if ($targetComputers.Count -eq 0) {
	$null = $targetComputers.Add([pscustomobject]@{
		ComputerName = $env:COMPUTERNAME
		Protocol     = $Protocol
	})
}

foreach ($targetComputer in $targetComputers) {
	$entryProtocol = if ([string]::IsNullOrWhiteSpace([string]$targetComputer.Protocol)) { 'Auto' } else { [string]$targetComputer.Protocol }
	Invoke-TSxInteractiveLogonCollection -TargetComputerName $targetComputer.ComputerName -ProtocolPreference $entryProtocol
}

Write-TSxLog -Message ('{0} completed' -f $scriptName)
