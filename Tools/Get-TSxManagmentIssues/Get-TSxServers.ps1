#requires -Version 5.1

<#
.SYNOPSIS
	Gets enabled server computer accounts from Active Directory.

.DESCRIPTION
	Queries Active Directory for enabled computer accounts where OperatingSystem
	contains "Server" and returns the result as objects so the output can be
	piped to additional commands.

	If -Online is specified, the script evaluates online state using two checks:
	1) If LastLogonDate is older than 14 days (or missing), the server is
	   classified as Offline.
	2) WinRM is tested first.
	3) If WinRM fails, RPC is tested.

	The output includes protocol test fields so downstream pipeline commands can
	choose either WinRM or RPC per server.

	The query runs against the current domain by default. You can scope to a
	specific domain with -Domain and optionally to a specific OU with -OUPath.

.PARAMETER Domain
	DNS name of the domain to query. If not specified, the current domain is used.

.PARAMETER OUPath
	Distinguished name of the OU/container to use as SearchBase. If not
	specified, the entire domain naming context is queried.

.PARAMETER Online
	Evaluates server online state using AD LastLogonDate and protocol tests.
	WinRM is tested first; RPC is tested only if WinRM fails.

.EXAMPLE
	.\Get-TSxServers.ps1

.EXAMPLE
	.\Get-TSxServers.ps1 -Online -Verbose

.EXAMPLE
	.\Get-TSxServers.ps1 -Domain corp.contoso.com -OUPath "OU=Servers,DC=corp,DC=contoso,DC=com" -Online

.NOTES
	FileName:    Get-TSxServers.ps1
	Version:     1.2.2
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
	[string]$Domain,

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string]$OUPath,

	[Parameter()]
	[switch]$Online
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-TSxLog {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Message,

		[ValidateSet('INFO', 'WARN', 'ERROR')]
		[string]$Level = 'INFO'
	)

	if ($VerbosePreference -eq 'Continue') {
		$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
		Write-Verbose ("{0} [{1}] {2}" -f $timestamp, $Level, $Message)
	}
}

Import-Module ActiveDirectory -ErrorAction Stop

$staleThreshold = (Get-Date).AddDays(-14)
Write-TSxLog -Message ('Domain parameter: {0}' -f $(if ([string]::IsNullOrWhiteSpace($Domain)) { '<current>' } else { $Domain }))
Write-TSxLog -Message ('OUPath parameter: {0}' -f $(if ([string]::IsNullOrWhiteSpace($OUPath)) { '<domain root>' } else { $OUPath }))
Write-TSxLog -Message ('Online checks enabled: {0}' -f $Online.IsPresent)
Write-TSxLog -Message ('Stale LastLogonDate cutoff: {0}' -f $staleThreshold.ToString('yyyy-MM-dd HH:mm:ss'))

$domainParams = @{
	ErrorAction = 'Stop'
}

if (-not [string]::IsNullOrWhiteSpace($Domain)) {
	$domainParams['Identity'] = $Domain
	$domainParams['Server'] = $Domain
}

$domainInfo = Get-ADDomain @domainParams
$domainDnsRoot = [string]$domainInfo.DNSRoot
$searchBase = if ([string]::IsNullOrWhiteSpace($OUPath)) { [string]$domainInfo.DistinguishedName } else { $OUPath }

Write-TSxLog -Message ('Resolved domain: {0}' -f $domainDnsRoot)
Write-TSxLog -Message ('AD SearchBase: {0}' -f $searchBase)

$adParams = @{
	Filter      = 'Enabled -eq $true -and OperatingSystem -like "*Server*"'
	Server      = $domainDnsRoot
	SearchBase  = $searchBase
	Properties  = @('DNSHostName', 'OperatingSystem', 'LastLogonDate', 'Enabled', 'DistinguishedName')
	ErrorAction = 'Stop'
}

$servers = @(Get-ADComputer @adParams | Sort-Object -Property Name)
Write-TSxLog -Message ('Enabled server objects found in AD: {0}' -f @($servers).Count)

foreach ($server in $servers) {
	$targetName = if ([string]::IsNullOrWhiteSpace([string]$server.DNSHostName)) { [string]$server.Name } else { [string]$server.DNSHostName }
	$lastLogonDate = $server.LastLogonDate

	$onlineState = 'NotChecked'
	$onlineValue = $null
	$onlineReason = 'Online evaluation not requested.'
	$adRecencyStatus = 'NotChecked'
	$winRmStatus = 'NotTested'
	$winRmReason = 'WinRM evaluation not requested.'
	$rpcStatus = 'NotTested'
	$rpcReason = 'RPC evaluation not requested.'
	$preferredProtocol = 'None'

	if ($null -eq $lastLogonDate) {
		$adRecencyStatus = 'Missing'
	}
	elseif ($lastLogonDate -lt $staleThreshold) {
		$adRecencyStatus = 'Stale'
	}
	else {
		$adRecencyStatus = 'Recent'
	}

	if ($Online.IsPresent) {
		if ($adRecencyStatus -eq 'Missing') {
			$onlineState = 'Offline'
			$onlineValue = $false
			$onlineReason = 'LastLogonDate is missing in AD.'
			$winRmStatus = 'Skipped'
			$winRmReason = 'Skipped because LastLogonDate is missing in AD.'
			$rpcStatus = 'Skipped'
			$rpcReason = 'Skipped because LastLogonDate is missing in AD.'
			$preferredProtocol = 'None'
		}
		elseif ($adRecencyStatus -eq 'Stale') {
			$onlineState = 'Offline'
			$onlineValue = $false
			$onlineReason = 'LastLogonDate is older than 14 days.'
			$winRmStatus = 'Skipped'
			$winRmReason = 'Skipped because LastLogonDate is older than 14 days.'
			$rpcStatus = 'Skipped'
			$rpcReason = 'Skipped because LastLogonDate is older than 14 days.'
			$preferredProtocol = 'None'
		}
		elseif ($PSCmdlet.ShouldProcess($targetName, 'Test WinRM and RPC connectivity')) {
			try {
				$null = Test-WSMan -ComputerName $targetName -ErrorAction Stop
				$winRmStatus = 'Available'
				$winRmReason = 'WinRM responded successfully.'
				$rpcStatus = 'Skipped'
				$rpcReason = 'Skipped because WinRM is available.'
				$preferredProtocol = 'WinRM'
			}
			catch {
				$winRmStatus = 'Unavailable'
				$winRmReason = 'WinRM test failed: {0}' -f $_.Exception.Message

				try {
					$null = Get-WinEvent -ListLog 'Security' -ComputerName $targetName -ErrorAction Stop
					$rpcStatus = 'Available'
					$rpcReason = 'RPC EventLog endpoint responded successfully.'
					$preferredProtocol = 'RPC'
				}
				catch {
					$rpcStatus = 'Unavailable'
					$rpcReason = 'RPC test failed: {0}' -f $_.Exception.Message
					$preferredProtocol = 'None'
				}
			}

			if ($preferredProtocol -eq 'WinRM') {
				$onlineState = 'Online'
				$onlineValue = $true
				$onlineReason = 'WinRM responded successfully.'
			}
			elseif ($preferredProtocol -eq 'RPC') {
				$onlineState = 'Online'
				$onlineValue = $true
				$onlineReason = 'WinRM unavailable, RPC is available.'
			}
			else {
				$onlineState = 'Offline'
				$onlineValue = $false
				$onlineReason = 'Neither WinRM nor RPC is available.'
			}
		}
		else {
			$onlineState = 'NotChecked'
			$onlineValue = $null
			$onlineReason = 'Skipped by WhatIf.'
			$winRmStatus = 'NotTested'
			$winRmReason = 'Skipped by WhatIf.'
			$rpcStatus = 'NotTested'
			$rpcReason = 'Skipped by WhatIf.'
			$preferredProtocol = 'None'
		}
	}

	# When -Online is requested, emit only objects confirmed as online.
	if ($Online.IsPresent -and $onlineValue -ne $true) {
		continue
	}

	[pscustomobject]@{
		Name              = [string]$server.Name
		Domain            = $domainDnsRoot
		DNSHostName       = [string]$server.DNSHostName
		OperatingSystem   = [string]$server.OperatingSystem
		Enabled           = [bool]$server.Enabled
		DistinguishedName = [string]$server.DistinguishedName
		SearchBase        = $searchBase
		LastLogonDate     = $lastLogonDate
		AdRecencyStatus   = $adRecencyStatus
		Online            = $onlineValue
		OnlineState       = $onlineState
		OnlineReason      = $onlineReason
		WinRMStatus       = $winRmStatus
		WinRMReason       = $winRmReason
		RpcStatus         = $rpcStatus
		RpcReason         = $rpcReason
		PreferredProtocol = $preferredProtocol
	}
}
