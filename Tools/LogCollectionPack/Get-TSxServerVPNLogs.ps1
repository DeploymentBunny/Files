<#
.SYNOPSIS
	Collects Windows Server RRAS/IKEv2 VPN troubleshooting data.

.DESCRIPTION
	Captures RRAS VPN settings, IPsec policy, certificate metadata, listener and
	network state, related services, and recent RRAS, IKE, NPS, and certificate
	events and recent NPS accounting logs. No certificate private keys, RADIUS
	configuration secrets, or preshared keys are exported. Run elevated on the VPN
	server. Events and accounting logs can contain sensitive connection details;
	review output before sharing.

.PARAMETER OutputRoot
	Root directory for timestamped collections. Default: C:\Temp\VPN-Server-Diagnostics.
.PARAMETER DaysBack
	Number of days of event history to collect. Default: 7.
.PARAMETER MaxEventsPerLog
	Maximum events per log in CSV output. Default: 2000.
.PARAMETER NpsLogPath
	Directory containing NPS IN*.log accounting files. Default: Windows LogFiles directory.

.NOTES
	FileName: Get-TSxServerVPNLogs.ps1
	Version: 1.0.4
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
	[string]$OutputRoot = 'C:\Temp\VPN-Server-Diagnostics',
	[ValidateRange(1, 365)][int]$DaysBack = 7,
	[ValidateRange(1, 10000)][int]$MaxEventsPerLog = 2000,
	[string]$NpsLogPath = "$env:windir\System32\LogFiles"
)

$ErrorActionPreference = 'Stop'
$collectionPath = Join-Path $OutputRoot (Get-Date -Format 'yyyyMMdd_HHmmss')
if (-not $PSCmdlet.ShouldProcess($collectionPath, 'Collect Windows Server VPN diagnostics')) { return }

$startTime = (Get-Date).AddDays(-$DaysBack)
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

Invoke-Collection 'VPN services' {
	Get-CimInstance Win32_Service -Filter "Name='RemoteAccess' OR Name='IKEEXT' OR Name='PolicyAgent' OR Name='EapHost' OR Name='IAS' OR Name='SstpSvc' OR Name='RasMan'" |
		Select-Object Name, State, StartMode, ExitCode, ProcessId |
		Export-Csv -LiteralPath (Join-Path $collectionPath 'VPNServices.csv') -NoTypeInformation -Encoding UTF8
}

Invoke-Collection 'RRAS settings' {
	Get-RemoteAccess -ErrorAction Stop |
		Select-Object VpnStatus, VpnType, RoutingStatus, DirectAccessStatus, InternetInterface, InternalInterface,
			SslCertificate, CertificateThumbprint |
		Export-Csv -LiteralPath (Join-Path $collectionPath 'RemoteAccess.csv') -NoTypeInformation -Encoding UTF8
}

Invoke-Collection 'IKEv2 server settings' {
	Get-VpnServerConfiguration -TunnelType Ikev2 -ErrorAction Stop |
		Select-Object TunnelType, NumberOfPorts, AuthenticationMethod, EncryptionType,
			CertificateThumbprint, SSLCertHash, MachineCertificateIssuerFilter, RootCertificateName |
		Export-Csv -LiteralPath (Join-Path $collectionPath 'IKEv2ServerConfiguration.csv') -NoTypeInformation -Encoding UTF8
}

Invoke-Collection 'IKEv2 IPsec settings' {
	Get-VpnServerIPsecConfiguration -ErrorAction Stop |
		Select-Object AuthenticationTransformConstants, CipherTransformConstants, DHGroup,
			EncryptionMethod, IntegrityCheckMethod, PfsGroup, SALifeTimeSeconds,
			SADataSizeForRenegotiationKilobytes |
		Export-Csv -LiteralPath (Join-Path $collectionPath 'IKEv2IPsecConfiguration.csv') -NoTypeInformation -Encoding UTF8
}

Invoke-Collection 'RRAS connection statistics' {
	Get-RemoteAccessConnectionStatistics -StartDateTime $startTime -EndDateTime (Get-Date) -ErrorAction Stop |
		Select-Object UserName, ConnectionStartTime, ConnectionType, TunnelType, ClientIPv4Address,
			ServerIPv4Address, ConnectionDuration |
		Export-Csv -LiteralPath (Join-Path $collectionPath 'RRASConnections.csv') -NoTypeInformation -Encoding UTF8
}

Invoke-Collection 'VPN adapters' {
	Get-NetAdapter -IncludeHidden |
		Select-Object Name, InterfaceDescription, Status, MacAddress, LinkSpeed, InterfaceIndex |
		Export-Csv -LiteralPath (Join-Path $collectionPath 'Adapters.csv') -NoTypeInformation -Encoding UTF8
}

Invoke-Collection 'VPN UDP endpoints' {
	Get-NetUDPEndpoint -ErrorAction Stop | Where-Object { $_.LocalPort -in 500, 4500 } |
		Select-Object LocalAddress, LocalPort, OwningProcess |
		Export-Csv -LiteralPath (Join-Path $collectionPath 'IKEv2Listeners.csv') -NoTypeInformation -Encoding UTF8
}

Invoke-Collection 'VPN firewall rules' {
	Get-NetFirewallRule -ErrorAction Stop |
		Where-Object { $_.DisplayGroup -match 'Routing and Remote Access|Remote Access|Network Policy Server' } |
		Select-Object DisplayName, DisplayGroup, Enabled, Direction, Action, Profile |
		Export-Csv -LiteralPath (Join-Path $collectionPath 'VPNFirewallRules.csv') -NoTypeInformation -Encoding UTF8
}

foreach ($store in @('Cert:\LocalMachine\My', 'Cert:\LocalMachine\Root', 'Cert:\LocalMachine\CA')) {
	Invoke-Collection "Certificates $store" {
		Get-ChildItem -Path $store |
			Select-Object Subject, Issuer, Thumbprint, SerialNumber, NotBefore, NotAfter, HasPrivateKey,
				@{ Name = 'EnhancedKeyUsage'; Expression = { ($_.EnhancedKeyUsageList | ForEach-Object { "$($_.FriendlyName) [$($_.ObjectId)]" }) -join '; ' } } |
			Export-Csv -LiteralPath (Join-Path $collectionPath ("Certificates-$($store.Split('\')[2]).csv")) -NoTypeInformation -Encoding UTF8
	}
}

Save-CommandOutput 'IPConfiguration' 'ipconfig.exe' @('/all')
Save-CommandOutput 'Routes' 'route.exe' @('print')
Save-CommandOutput 'WinHTTPProxy' 'netsh.exe' @('winhttp', 'show', 'proxy')

if (Test-Path -LiteralPath $NpsLogPath -PathType Container) {
	Invoke-Collection 'NPS accounting logs' {
		$accountingLogs = @(Get-ChildItem -LiteralPath $NpsLogPath -Filter 'IN*.log' -File -ErrorAction Stop |
			Where-Object { $_.LastWriteTime -ge $startTime } |
			Sort-Object LastWriteTime -Descending | Select-Object -First 10)
		foreach ($logFile in $accountingLogs) {
			if ($logFile.Length -gt 25MB) {
				Write-Verbose "Skipping NPS accounting log over 25 MB: $($logFile.Name)"
				continue
			}
			$destination = Join-Path $collectionPath 'NPSAccounting'
			if (-not (Test-Path -LiteralPath $destination)) {
				New-Item -ItemType Directory -Path $destination -Force | Out-Null
			}
			Copy-Item -LiteralPath $logFile.FullName -Destination $destination -ErrorAction Stop
		}
	}
}

$eventLogs = @(
	@{ Name = 'System'; Providers = @('RemoteAccess', 'Rasman', 'Schannel', 'Microsoft-Windows-IKEEXT') },
	@{ Name = 'Application'; Providers = @('IAS', 'RemoteAccess') },
	@{ Name = 'Security'; Ids = @(6272, 6273, 6274, 6275, 6276, 6277, 6278, 6279, 6280) },
	@{ Name = 'Microsoft-Windows-RemoteAccess/Operational' },
	@{ Name = 'Microsoft-Windows-RasMan/Operational' },
	@{ Name = 'Microsoft-Windows-IKEEXT/Operational' },
	@{ Name = 'Microsoft-Windows-EapHost/Operational' },
	@{ Name = 'Microsoft-Windows-CAPI2/Operational' },
	@{ Name = 'Microsoft-Windows-NPS/Operational' }
)

foreach ($eventLog in $eventLogs) {
	$logName = $eventLog.Name
	try { $availableLog = Get-WinEvent -ListLog $logName -ErrorAction Stop }
	catch { Write-Verbose "Event log unavailable: $logName"; continue }
	if (-not $availableLog.IsEnabled) { Write-Verbose "Event log disabled: $logName"; continue }

	Invoke-Collection "Events $logName" {
		$safeName = $logName -replace '[^a-zA-Z0-9_-]', '_'
		$events = @()
		$providers = @($eventLog.Providers)
		if ($providers.Count -eq 0) { $providers = @($null) }
		foreach ($provider in $providers) {
			$filter = @{ LogName = $logName; StartTime = $startTime }
			if ($provider) { $filter.ProviderName = $provider }
			if ($eventLog.Ids) { $filter.Id = $eventLog.Ids }
			try { $events += @(Get-WinEvent -FilterHashtable $filter -MaxEvents $MaxEventsPerLog -ErrorAction Stop) }
			catch {
				if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound|NoMatchingProvidersFound' -or
					$_.Exception.Message -match 'There is not an event provider|specified providers do not write events') {
					Write-Verbose "No available events for $provider in $logName"
					continue
				}
				throw
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