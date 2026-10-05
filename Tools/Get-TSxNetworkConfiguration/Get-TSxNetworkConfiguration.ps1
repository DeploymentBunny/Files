<#
.SYNOPSIS
	Collects network adapter and IP configuration data and writes it to a CSV file.

.DESCRIPTION
	Enumerates local network adapters and their network configuration (IP address,
	default gateway, DNS servers, DHCP settings), then writes one row per adapter
	to a CSV file.

	The script is designed to run on Windows 7 and later, and Windows Server 2008 R2
	and later. It uses WMI classes available on these platforms.

	If the output file already exists, the script exits immediately and does not modify anything.

.PARAMETER OutputPath
	Path to the folder where the CSV file will be created.
	The file is always named COMPUTERNAME-NetworkConfiguration.csv.

.PARAMETER Overwrite
	If specified, overwrites the CSV file when it already exists.

.EXAMPLE
	.\Get-TSxNetworkConfiguration.ps1 -OutputPath 'C:\Logs' -Verbose

.EXAMPLE
	.\Get-TSxNetworkConfiguration.ps1 -OutputPath 'C:\Logs' -Overwrite -Verbose

.NOTES
	FileName:    Get-TSxNetworkConfiguration.ps1
	Version:     1.0.6
	Author:      Mikael Nystrom
	Contact:     @mikael_nystrom
	Created:     2026-07-22
	Updated:     2026-07-22
	Twitter:     @mikael_nystrom

	Disclaimer:
	This script is provided "AS IS" with no warranties, confers no rights and
	is not supported by the author.

.LINK
	https://www.deploymentbunny.com
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
	[Parameter(Mandatory = $true)]
	[ValidateNotNullOrEmpty()]
	[string]$OutputPath,

	[Parameter(Mandatory = $false)]
	[switch]$Overwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-TSxArrayToString {
	[CmdletBinding()]
	param(
		[Parameter()]
		[object]$Value
	)

	if ($null -eq $Value) {
		return ''
	}

	if ($Value -is [System.Array]) {
		$filteredValues = @($Value | Where-Object {
			$entry = [string]$_
			(-not [string]::IsNullOrEmpty($entry)) -and (-not [string]::IsNullOrEmpty($entry.Trim()))
		})
		return ($filteredValues -join ';')
	}

	return [string]$Value
}

function Get-TSxNetConnectionStatusText {
	[CmdletBinding()]
	param(
		[Parameter()]
		[int]$Status
	)

	switch ($Status) {
		0 { 'Disconnected' }
		1 { 'Connecting' }
		2 { 'Connected' }
		3 { 'Disconnecting' }
		4 { 'Hardware not present' }
		5 { 'Hardware disabled' }
		6 { 'Hardware malfunction' }
		7 { 'Media disconnected' }
		8 { 'Authenticating' }
		9 { 'Authentication succeeded' }
		10 { 'Authentication failed' }
		11 { 'Invalid address' }
		12 { 'Credentials required' }
		default { 'Unknown' }
	}
}

function Test-TSxIsEthernetOrWifi {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[object]$Adapter
	)

	if ($Adapter.AdapterTypeID -in @(0, 9)) {
		return $true
	}

	$candidateText = @(
		[string]$Adapter.AdapterType,
		[string]$Adapter.Name,
		[string]$Adapter.Description,
		[string]$Adapter.NetConnectionID
	) -join ' '

	if ($candidateText -match '(?i)ethernet|802\.3|wi-?fi|wireless|wlan') {
		return $true
	}

	return $false
}

$scriptName = if ($MyInvocation.MyCommand -and $MyInvocation.MyCommand.Name) { $MyInvocation.MyCommand.Name } else { 'Get-TSxNetworkConfiguration.ps1' }
Write-Verbose ('{0} started on {1}' -f $scriptName, $env:COMPUTERNAME)
Write-Verbose ('Output folder: {0}' -f $OutputPath)

$csvFileName = '{0}-NetworkConfiguration.csv' -f $env:COMPUTERNAME
$resolvedLogFilePath = Join-Path -Path $OutputPath -ChildPath $csvFileName
Write-Verbose ('Output file will be: {0}' -f $resolvedLogFilePath)

if (Test-Path -Path $resolvedLogFilePath) {
	if ($Overwrite) {
		Write-Verbose ('Output file already exists: {0}. Overwrite specified, continuing.' -f $resolvedLogFilePath)
	}
	else {
		Write-Warning ('Output file already exists: {0}. Exiting.' -f $resolvedLogFilePath)
		exit 0
	}
}

if (-not (Test-Path -Path $OutputPath)) {
	if ($PSCmdlet.ShouldProcess($OutputPath, 'Create output folder')) {
		Write-Verbose ('Creating folder: {0}' -f $OutputPath)
		$null = New-Item -Path $OutputPath -ItemType Directory -Force
	}
	else {
		Write-Verbose ('WhatIf: Skipping folder creation for {0}' -f $OutputPath)
		return
	}
}

Write-Verbose 'Reading network adapter inventory from Win32_NetworkAdapter.'
$adapters = @(
	Get-WmiObject -Class Win32_NetworkAdapter -ErrorAction Stop |
	Where-Object { Test-TSxIsEthernetOrWifi -Adapter $_ }
)

Write-Verbose 'Reading network adapter configuration from Win32_NetworkAdapterConfiguration.'
$adapterConfigurations = @(Get-WmiObject -Class Win32_NetworkAdapterConfiguration -ErrorAction Stop)
$configurationByIndex = @{}
foreach ($item in $adapterConfigurations) {
	$configurationByIndex[[int]$item.Index] = $item
}

if ($adapters.Count -eq 0) {
	throw 'No Ethernet or Wi-Fi adapters were returned by Win32_NetworkAdapter.'
}

$results = foreach ($adapter in $adapters) {
	$config = $null
	if ($configurationByIndex.ContainsKey([int]$adapter.Index)) {
		$config = $configurationByIndex[[int]$adapter.Index]
	}

	New-Object -TypeName PSObject -Property @{
		ComputerName         = $env:COMPUTERNAME
		AdapterIndex         = $adapter.Index
		AdapterName          = $adapter.Name
		NetConnectionID      = $adapter.NetConnectionID
		AdapterDescription   = $adapter.Description
		AdapterType          = $adapter.AdapterType
		ServiceName          = $adapter.ServiceName
		MACAddress           = $adapter.MACAddress
		PhysicalAdapter      = $adapter.PhysicalAdapter
		NetEnabled           = $adapter.NetEnabled
		NetConnectionStatus  = Get-TSxNetConnectionStatusText -Status $adapter.NetConnectionStatus
		DHCPEnabled          = if ($null -ne $config) { $config.DHCPEnabled } else { $null }
		DHCPServer           = if ($null -ne $config) { $config.DHCPServer } else { $null }
		IPAddress            = if ($null -ne $config) { Convert-TSxArrayToString -Value $config.IPAddress } else { '' }
		IPSubnet             = if ($null -ne $config) { Convert-TSxArrayToString -Value $config.IPSubnet } else { '' }
		DefaultGateway       = if ($null -ne $config) { Convert-TSxArrayToString -Value $config.DefaultIPGateway } else { '' }
		DNSServers           = if ($null -ne $config) { Convert-TSxArrayToString -Value $config.DNSServerSearchOrder } else { '' }
		DNSDomain            = if ($null -ne $config) { [string]$config.DNSDomain } else { '' }
		DNSHostName          = if ($null -ne $config) { [string]$config.DNSHostName } else { '' }
	}
}

if ($PSCmdlet.ShouldProcess($resolvedLogFilePath, 'Write network configuration CSV')) {
	$csvRows = @(
		$results | Select-Object `
		ComputerName, AdapterIndex, AdapterName, NetConnectionID, AdapterDescription, AdapterType, ServiceName, MACAddress, `
		PhysicalAdapter, NetEnabled, NetConnectionStatus, DHCPEnabled, DHCPServer, IPAddress, IPSubnet, DefaultGateway, `
		DNSServers, DNSDomain, DNSHostName
	)
	Write-Verbose ('Writing {0} adapter record(s) to {1}' -f $csvRows.Count, $resolvedLogFilePath)
	$csvRows | Export-Csv -Path $resolvedLogFilePath -NoTypeInformation -Delimiter ','
	Write-Verbose 'CSV export completed successfully.'
}
else {
	Write-Verbose ('WhatIf: Skipping CSV export to {0}' -f $resolvedLogFilePath)
}
