<#
.SYNOPSIS
	Collects Windows 10/11 built-in VPN client troubleshooting data.

.DESCRIPTION
	Captures VPN profiles, routes, DNS and network state, related services, certificate
	metadata, per-profile EAP configuration, private-key access test results, and
	recent connection events. Does not export phonebooks or private keys. Run in the
	affected user's session for per-user profiles; elevation improves access to event
	logs and machine-wide configuration. EAP XML may contain sensitive authentication
	settings or credentials; review and protect the output before sharing it. Key
	access checks run as the current process, not as the VPN service account.

.PARAMETER OutputRoot
	Root directory for timestamped collections. Default: C:\Temp\VPN-Diagnostics.
.PARAMETER DaysBack
	Number of days of event history to collect. Default: 7.
.PARAMETER MaxEventsPerLog
	Maximum events per log in CSV output. Default: 2000.

.NOTES
	FileName: Get-TSxClientVPNLogs.ps1
	Version: 1.0.5
	Author: Deployment Bunny
	Contact: info@deploymentbunny.com
	Created: 2026-09-29
	Updated: 2026-09-29
	Twitter: @DeploymentBunny
	Disclaimer: This script is provided AS IS without warranty.

.LINK
	https://www.deploymentbunny.com
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
	[string]$OutputRoot = 'C:\Temp\VPN-Diagnostics',
	[ValidateRange(1, 365)][int]$DaysBack = 7,
	[ValidateRange(1, 10000)][int]$MaxEventsPerLog = 2000
)

$ErrorActionPreference = 'Stop'
$collectionPath = Join-Path $OutputRoot (Get-Date -Format 'yyyyMMdd_HHmmss')
if (-not $PSCmdlet.ShouldProcess($collectionPath, 'Collect Windows VPN diagnostics')) { return }

New-Item -ItemType Directory -Path $collectionPath -Force | Out-Null
$issuesPath = Join-Path $collectionPath 'CollectionIssues.txt'

function Invoke-Collection {
	param([string]$Name, [scriptblock]$Action)

	Write-Verbose "Collecting $Name"
	try { & $Action }
	catch {
		$message = '{0}: {1}' -f $Name, $_.Exception.Message
		Write-Warning $message
		Add-Content -LiteralPath $issuesPath -Value $message
	}
}

function Save-CommandOutput {
	param([string]$Name, [string]$Command, [string[]]$Arguments)

	Invoke-Collection $Name {
		$output = & $Command @Arguments 2>&1 | Out-String
		$output | Out-File -LiteralPath (Join-Path $collectionPath "$Name.txt") -Encoding UTF8
		if ($LASTEXITCODE -ne 0) { throw "$Command exited with code $LASTEXITCODE" }
	}
}

Invoke-Collection 'System' {
	Get-CimInstance Win32_OperatingSystem |
		Select-Object Caption, Version, BuildNumber, OSArchitecture, LastBootUpTime, CSName |
		Export-Csv -LiteralPath (Join-Path $collectionPath 'System.csv') -NoTypeInformation -Encoding UTF8
}

Invoke-Collection 'VPN profiles' {
	$profiles = @()
	$profiles += @(Get-VpnConnection -ErrorAction Stop)
	try { $profiles += @(Get-VpnConnection -AllUserConnection -ErrorAction Stop) }
	catch {
		Add-Content -LiteralPath $issuesPath -Value "All-user VPN profiles: $($_.Exception.Message)"
	}

	$profiles | Select-Object Name, ServerAddress, TunnelType, AuthenticationMethod,
		EncryptionLevel, SplitTunneling, RememberCredential, AllUserConnection,
		ConnectionStatus, IdleDisconnectSeconds, MachineCertificateIssuerFilter, RootCertificateName |
		Export-Csv -LiteralPath (Join-Path $collectionPath 'VPNProfiles.csv') -NoTypeInformation -Encoding UTF8

	$profiles | Where-Object { $_.TunnelType -eq 'Ikev2' } |
		Select-Object Name,
			@{ Name = 'Scope'; Expression = { if ($_.AllUserConnection) { 'AllUsers' } else { 'CurrentUser' } } },
			@{ Name = 'AuthenticationMethod'; Expression = { $_.AuthenticationMethod -join ', ' } },
			@{ Name = 'IPsecCustomPolicy'; Expression = { if ($_.IPsecCustomPolicy) { $_.IPsecCustomPolicy | Format-List * | Out-String } } } |
		Export-Csv -LiteralPath (Join-Path $collectionPath 'IKEv2Policies.csv') -NoTypeInformation -Encoding UTF8

	$eapManifest = @()
	$profileIndex = 0
	foreach ($profile in $profiles) {
		$profileIndex++
		$entry = '' | Select-Object Name, Scope, EapFile, Status
		$entry.Name = $profile.Name
		$entry.Scope = if ($profile.AllUserConnection) { 'AllUsers' } else { 'CurrentUser' }
		$entry.Status = 'NotConfigured'
		if ($profile.EapConfigXmlStream -and $profile.EapConfigXmlStream.InnerXml) {
			$entry.EapFile = 'EAPConfig-{0:D3}.xml' -f $profileIndex
			try {
				$profile.EapConfigXmlStream.InnerXml |
					Out-File -LiteralPath (Join-Path $collectionPath $entry.EapFile) -Encoding UTF8 -ErrorAction Stop
				$entry.Status = 'Exported'
			}
			catch {
				$entry.Status = 'Failed'
				Add-Content -LiteralPath $issuesPath -Value "EAP configuration for $($profile.Name): $($_.Exception.Message)"
			}
		}
		$eapManifest += $entry
	}
	$eapManifest | Export-Csv -LiteralPath (Join-Path $collectionPath 'EAPConfigurations.csv') -NoTypeInformation -Encoding UTF8
	if (@($eapManifest | Where-Object { $_.Status -eq 'Exported' }).Count -gt 0) {
		Write-Warning 'EAP XML may contain sensitive authentication settings or credentials. Review before sharing.'
	}
}

Invoke-Collection 'VPN services' {
	Get-CimInstance Win32_Service -Filter "Name='RasMan' OR Name='SstpSvc' OR Name='IKEEXT' OR Name='PolicyAgent' OR Name='EapHost' OR Name='NlaSvc' OR Name='Dnscache'" |
		Select-Object Name, State, StartMode, ExitCode, ProcessId |
		Export-Csv -LiteralPath (Join-Path $collectionPath 'VPNServices.csv') -NoTypeInformation -Encoding UTF8
}

Invoke-Collection 'VPN adapters' {
	Get-NetAdapter -IncludeHidden |
		Select-Object Name, InterfaceDescription, Status, MacAddress, LinkSpeed, InterfaceIndex |
		Export-Csv -LiteralPath (Join-Path $collectionPath 'Adapters.csv') -NoTypeInformation -Encoding UTF8
}

Invoke-Collection 'DNS servers' {
	Get-DnsClientServerAddress |
		Select-Object InterfaceAlias, AddressFamily, ServerAddresses |
		Export-Csv -LiteralPath (Join-Path $collectionPath 'DNSServers.csv') -NoTypeInformation -Encoding UTF8
}

Invoke-Collection 'DNS suffix policies' {
	Get-DnsClientNrptPolicy |
		Select-Object Namespace, NameServers, DirectAccessDnsServers, DnsSecValidationRequired |
		Export-Csv -LiteralPath (Join-Path $collectionPath 'NRPT.csv') -NoTypeInformation -Encoding UTF8
}

Invoke-Collection 'Firewall profiles' {
	Get-NetFirewallProfile |
		Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction |
		Export-Csv -LiteralPath (Join-Path $collectionPath 'FirewallProfiles.csv') -NoTypeInformation -Encoding UTF8
}

foreach ($store in @('Cert:\CurrentUser\My', 'Cert:\LocalMachine\My')) {
	Invoke-Collection "Certificates $store" {
		$certificates = @(Get-ChildItem -Path $store -ErrorAction Stop)
		$certificates |
			Select-Object Subject, Issuer, Thumbprint, SerialNumber, NotBefore, NotAfter, HasPrivateKey,
				@{ Name = 'EnhancedKeyUsage'; Expression = { ($_.EnhancedKeyUsageList | ForEach-Object { "$($_.FriendlyName) [$($_.ObjectId)]" }) -join '; ' } } |
			Export-Csv -LiteralPath (Join-Path $collectionPath ("Certificates-$($store.Split('\')[1]).csv")) -NoTypeInformation -Encoding UTF8

		$certificates | ForEach-Object {
			$certificate = $_
			$status = 'NotPresent'
			if ($certificate.HasPrivateKey) {
				$certutilArguments = @('-Silent')
				if ($store -eq 'Cert:\CurrentUser\My') { $certutilArguments += '-user' }
				$certutilArguments += @('-store', 'My', $certificate.Thumbprint)
				try {
					$probeOutput = & certutil.exe @certutilArguments 2>&1 | Out-String
					$status = if ($LASTEXITCODE -ne 0 -or $probeOutput -match '(?i)(signature|encryption) test failed') {
						'Failed'
					} elseif ($probeOutput -match '(?i)(signature|encryption) test passed') {
						'Verified'
					} else { 'Inconclusive' }
				}
				catch { $status = 'Inconclusive' }
			}
			$entry = '' | Select-Object Subject, Thumbprint, Store, HasPrivateKey, KeyAccessAsCurrentProcess
			$entry.Subject = $certificate.Subject
			$entry.Thumbprint = $certificate.Thumbprint
			$entry.Store = $store
			$entry.HasPrivateKey = $certificate.HasPrivateKey
			$entry.KeyAccessAsCurrentProcess = $status
			$entry
		} | Export-Csv -LiteralPath (Join-Path $collectionPath ("KeyAccess-$($store.Split('\')[1]).csv")) -NoTypeInformation -Encoding UTF8
	}
}

Save-CommandOutput 'IPConfiguration' 'ipconfig.exe' @('/all')
Save-CommandOutput 'Routes' 'route.exe' @('print')
Save-CommandOutput 'RasDial' 'rasdial.exe' @()
Save-CommandOutput 'WinHTTPProxy' 'netsh.exe' @('winhttp', 'show', 'proxy')
Save-CommandOutput 'NetworkInterfaces' 'netsh.exe' @('interface', 'show', 'interface')

$startTime = (Get-Date).AddDays(-$DaysBack)
$eventLogs = @(
	@{ Name = 'Application'; Providers = @('RasClient') },
	@{ Name = 'System'; Providers = @('Rasman', 'Schannel') },
	@{ Name = 'Microsoft-Windows-RasClient/Operational'; Providers = @() },
	@{ Name = 'Microsoft-Windows-RasMan/Operational'; Providers = @() },
	@{ Name = 'Microsoft-Windows-IKEEXT/Operational'; Providers = @() },
	@{ Name = 'Microsoft-Windows-EapHost/Operational'; Providers = @() },
	@{ Name = 'Microsoft-Windows-CAPI2/Operational'; Providers = @() },
	@{ Name = 'Microsoft-Windows-NetworkProfile/Operational'; Providers = @() },
	@{ Name = 'Microsoft-Windows-VpnClient/Operational'; Providers = @() }
)

foreach ($eventLog in $eventLogs) {
	$logName = $eventLog.Name
	try { $availableLog = Get-WinEvent -ListLog $logName -ErrorAction Stop }
	catch {
		Write-Verbose "Event log unavailable: $logName"
		continue
	}
	if (-not $availableLog.IsEnabled) {
		Write-Verbose "Event log disabled: $logName"
		continue
	}

	Invoke-Collection "Events $logName" {
		$safeName = $logName -replace '[^a-zA-Z0-9_-]', '_'
		$events = @()
		$providers = @($eventLog.Providers)
		if ($providers.Count -eq 0) { $providers = @($null) }
		foreach ($provider in $providers) {
			$filter = @{ LogName = $logName; StartTime = $startTime }
			if ($provider) { $filter.ProviderName = $provider }
			try {
				$events += @(Get-WinEvent -FilterHashtable $filter -MaxEvents $MaxEventsPerLog -ErrorAction Stop)
			}
			catch {
				if ($_.FullyQualifiedErrorId -notmatch 'NoMatchingEventsFound') { throw }
				Write-Verbose "No recent events for $provider in $logName"
			}
		}
		if ($events.Count -gt 0) {
			$events | Sort-Object TimeCreated -Descending | Select-Object -First $MaxEventsPerLog `
				-Property TimeCreated, Id, ProviderName, LevelDisplayName, MachineName, Message |
				Export-Csv -LiteralPath (Join-Path $collectionPath "Events-$safeName.csv") -NoTypeInformation -Encoding UTF8
		}
	}
}

Write-Output $collectionPath
