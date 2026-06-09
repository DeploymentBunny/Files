#requires -Version 5.1

<#
.SYNOPSIS
	Checks configured event log sizes on servers.

.DESCRIPTION
	Collects configured maximum size for System, Application, and Security
	event logs and validates each against role-based thresholds.

	Thresholds:
	- Domain Controller: each log must be larger than 2 GB
	- Member Server: each log must be larger than 1 GB

	Supports pipeline input from Get-TSxServers.ps1 and honors
	PreferredProtocol when Protocol is Auto.

.PARAMETER ComputerName
	Computer to query. Defaults to the local computer.
	Accepts pipeline input by property name from Name, DNSHostName,
	ComputerName, and PSComputerName.

.PARAMETER Protocol
	Protocol preference for remote collection. Valid values are Auto, WinRM,
	RPC, and None. Auto tries WinRM first and falls back to RPC.
	When piped from Get-TSxServers.ps1, PreferredProtocol is honored.

.EXAMPLE
	.\Get-TSxServerLogfileSize.ps1 -ComputerName SRV01 -Verbose

.EXAMPLE
	.\Get-TSxServers.ps1 -Online | .\Get-TSxServerLogfileSize.ps1 -Verbose

.NOTES
	FileName:    Get-TSxServerLogfileSize.ps1
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
	[Alias('Name', 'DNSHostName', 'PSComputerName')]
	[ValidateNotNullOrEmpty()]
	[string]$ComputerName = $env:COMPUTERNAME,

	[Parameter()]
	[Alias('PreferredProtocol')]
	[ValidateSet('Auto', 'WinRM', 'RPC', 'None')]
	[string]$Protocol = 'Auto',

	[Parameter(ValueFromPipeline = $true)]
	[AllowNull()]
	[object]$InputObject
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

function Get-TSxTargetComputerName {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[AllowNull()]
		[object]$Object,

		[Parameter(Mandatory = $true)]
		[string]$FallbackComputerName
	)

	if ($null -eq $Object) {
		return $FallbackComputerName
	}

	foreach ($propertyName in @('ComputerName', 'DNSHostName', 'Name', 'PSComputerName')) {
		$property = $Object.PSObject.Properties[$propertyName]
		if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
			return [string]$property.Value
		}
	}

	return $FallbackComputerName
}

function Get-TSxTargetProtocol {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[AllowNull()]
		[object]$Object,

		[Parameter(Mandatory = $true)]
		[string]$FallbackProtocol
	)

	if ($null -eq $Object) {
		return $FallbackProtocol
	}

	foreach ($propertyName in @('PreferredProtocol', 'Protocol')) {
		$property = $Object.PSObject.Properties[$propertyName]
		if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
			$candidate = [string]$property.Value
			if ($candidate -in @('Auto', 'WinRM', 'RPC', 'None')) {
				return $candidate
			}
		}
	}

	return $FallbackProtocol
}

function Get-TSxLogConfigurationLocal {
	[CmdletBinding()]
	param()

	$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
	$domainRole = [int]$computerSystem.DomainRole
	$logNames = @('System', 'Application', 'Security')
	$sizes = @{}

	foreach ($logName in $logNames) {
		$logConfig = Get-WinEvent -ListLog $logName -ErrorAction Stop
		$sizes[$logName] = [int64]$logConfig.MaximumSizeInBytes
	}

	return [pscustomobject]@{
		DomainRole = $domainRole
		Sizes      = $sizes
	}
}

function Get-TSxLogConfigurationViaWinRM {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$ComputerName
	)

	$scriptBlock = {
		$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
		$domainRole = [int]$computerSystem.DomainRole
		$logNames = @('System', 'Application', 'Security')
		$sizes = @{}

		foreach ($logName in $logNames) {
			$logConfig = Get-WinEvent -ListLog $logName -ErrorAction Stop
			$sizes[$logName] = [int64]$logConfig.MaximumSizeInBytes
		}

		[pscustomobject]@{
			DomainRole = $domainRole
			Sizes      = $sizes
		}
	}

	Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock -ErrorAction Stop
}

function Get-TSxLogConfigurationViaRpc {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$ComputerName
	)

	$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $ComputerName -ErrorAction Stop
	$domainRole = [int]$computerSystem.DomainRole
	$logNames = @('System', 'Application', 'Security')
	$sizes = @{}

	foreach ($logName in $logNames) {
		$logConfig = Get-WinEvent -ListLog $logName -ComputerName $ComputerName -ErrorAction Stop
		$sizes[$logName] = [int64]$logConfig.MaximumSizeInBytes
	}

	return [pscustomobject]@{
		DomainRole = $domainRole
		Sizes      = $sizes
	}
}

function New-TSxResultObject {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$ComputerName,

		[Parameter(Mandatory = $true)]
		[string]$RequestedProtocol,

		[Parameter(Mandatory = $true)]
		[string]$ProtocolUsed,

		[Parameter()]
		[AllowNull()]
		[Nullable[int]]$DomainRole,

		[Parameter()]
		[AllowNull()]
		[int64]$SystemSizeBytes,

		[Parameter()]
		[AllowNull()]
		[int64]$ApplicationSizeBytes,

		[Parameter()]
		[AllowNull()]
		[int64]$SecuritySizeBytes,

		[Parameter()]
		[string]$QueryStatus,

		[Parameter()]
		[string[]]$QueryIssues
	)

	$isDomainController = $false
	$serverRole = 'Unknown'
	$thresholdBytes = [int64]0
	$thresholdGb = 0

	if ($null -ne $DomainRole) {
		$isDomainController = ($DomainRole -in @(4, 5))
		$serverRole = if ($isDomainController) { 'DomainController' } else { 'MemberServer' }
		$thresholdBytes = if ($isDomainController) { [int64](2GB) } else { [int64](1GB) }
		$thresholdGb = if ($isDomainController) { 2 } else { 1 }
	}

	$hasThreshold = ($thresholdBytes -gt 0)
	$hasSystemSize = ($PSBoundParameters.ContainsKey('SystemSizeBytes') -and $null -ne $SystemSizeBytes)
	$hasApplicationSize = ($PSBoundParameters.ContainsKey('ApplicationSizeBytes') -and $null -ne $ApplicationSizeBytes)
	$hasSecuritySize = ($PSBoundParameters.ContainsKey('SecuritySizeBytes') -and $null -ne $SecuritySizeBytes)

	$systemOk = ($hasThreshold -and $hasSystemSize -and $SystemSizeBytes -gt $thresholdBytes)
	$applicationOk = ($hasThreshold -and $hasApplicationSize -and $ApplicationSizeBytes -gt $thresholdBytes)
	$securityOk = ($hasThreshold -and $hasSecuritySize -and $SecuritySizeBytes -gt $thresholdBytes)
	$allOk = ($systemOk -and $applicationOk -and $securityOk)

	$systemStatus = if (-not $hasThreshold -or -not $hasSystemSize) { 'Unknown' } elseif ($systemOk) { 'OK' } else { 'NotOK' }
	$applicationStatus = if (-not $hasThreshold -or -not $hasApplicationSize) { 'Unknown' } elseif ($applicationOk) { 'OK' } else { 'NotOK' }
	$securityStatus = if (-not $hasThreshold -or -not $hasSecuritySize) { 'Unknown' } elseif ($securityOk) { 'OK' } else { 'NotOK' }
	$allLogsStatus = if (-not $hasThreshold -or -not $hasSystemSize -or -not $hasApplicationSize -or -not $hasSecuritySize) { 'Unknown' } elseif ($allOk) { 'OK' } else { 'NotOK' }

	[pscustomobject]@{
		ComputerName         = $ComputerName
		RequestedProtocol    = $RequestedProtocol
		ProtocolUsed         = $ProtocolUsed
		DomainRole           = $DomainRole
		ServerRole           = $serverRole
		IsDomainController   = $isDomainController
		RequiredMinimumGb    = $thresholdGb
		RequiredMinimumBytes = $thresholdBytes
		SystemSizeBytes      = $SystemSizeBytes
		SystemSizeGb         = $(if ($SystemSizeBytes -gt 0) { [Math]::Round(($SystemSizeBytes / 1GB), 2) } else { $null })
		SystemStatus         = $systemStatus
		ApplicationSizeBytes = $ApplicationSizeBytes
		ApplicationSizeGb    = $(if ($ApplicationSizeBytes -gt 0) { [Math]::Round(($ApplicationSizeBytes / 1GB), 2) } else { $null })
		ApplicationStatus    = $applicationStatus
		SecuritySizeBytes    = $SecuritySizeBytes
		SecuritySizeGb       = $(if ($SecuritySizeBytes -gt 0) { [Math]::Round(($SecuritySizeBytes / 1GB), 2) } else { $null })
		SecurityStatus       = $securityStatus
		AllLogsStatus        = $allLogsStatus
		AllLogsOk            = $allOk
		QueryStatus          = $QueryStatus
		QueryIssues          = @($QueryIssues)
		QueryTimeUtc         = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
	}
}

$scriptName = Split-Path -Path $PSCommandPath -Leaf
Write-TSxLog -Message ('{0} started' -f $scriptName)
Write-TSxLog -Message ('ComputerName parameter: {0}' -f $ComputerName)
Write-TSxLog -Message ('Protocol parameter: {0}' -f $Protocol)

$targets = New-Object System.Collections.Generic.List[object]
$seenTargets = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$inputObjects = New-Object System.Collections.Generic.List[object]
if ($PSBoundParameters.ContainsKey('InputObject') -and $null -ne $InputObject) {
	$null = $inputObjects.Add($InputObject)
}

foreach ($obj in @($input)) {
	if ($null -ne $obj) {
		$null = $inputObjects.Add($obj)
	}
}

foreach ($obj in $inputObjects) {
	$targetName = Get-TSxTargetComputerName -Object $obj -FallbackComputerName $ComputerName
	$targetProtocol = Get-TSxTargetProtocol -Object $obj -FallbackProtocol $Protocol
	$targetKey = '{0}|{1}' -f $targetName, $targetProtocol
	if ($seenTargets.Add($targetKey)) {
		$null = $targets.Add([pscustomobject]@{ ComputerName = $targetName; Protocol = $targetProtocol })
	}
}

if ($targets.Count -eq 0) {
	$targetKey = '{0}|{1}' -f $ComputerName, $Protocol
	if ($seenTargets.Add($targetKey)) {
		$null = $targets.Add([pscustomobject]@{ ComputerName = $ComputerName; Protocol = $Protocol })
	}
}

foreach ($target in $targets) {
	$targetName = [string]$target.ComputerName
	$protocolPreference = [string]$target.Protocol

	Write-TSxLog -Message ('ComputerName: {0}' -f $targetName)
	Write-TSxLog -Message ('Protocol preference: {0}' -f $protocolPreference)

	if (-not $PSCmdlet.ShouldProcess($targetName, 'Read System/Application/Security maximum log sizes')) {
		Write-TSxLog -Message ('Skipped by WhatIf: {0}' -f $targetName) -Level 'WARN'
		New-TSxResultObject -ComputerName $targetName -RequestedProtocol $protocolPreference -ProtocolUsed 'None' -QueryStatus 'NotChecked' -QueryIssues @('Skipped by WhatIf.')
		continue
	}

	$issues = New-Object System.Collections.Generic.List[string]
	$data = $null
	$protocolUsed = 'None'

	if ($targetName -eq '.' -or $targetName -eq 'localhost' -or $targetName -eq $env:COMPUTERNAME) {
		try {
			$data = Get-TSxLogConfigurationLocal
			$protocolUsed = 'Local'
		}
		catch {
			$null = $issues.Add('Local query failed: {0}' -f $_.Exception.Message)
		}
	}
	else {
		switch ($protocolPreference) {
			'None' {
				$null = $issues.Add('Protocol None requested; query skipped.')
			}
			'WinRM' {
				try {
					$data = Get-TSxLogConfigurationViaWinRM -ComputerName $targetName
					$protocolUsed = 'WinRM'
				}
				catch {
					$null = $issues.Add('WinRM query failed: {0}' -f $_.Exception.Message)
				}
			}
			'RPC' {
				try {
					$data = Get-TSxLogConfigurationViaRpc -ComputerName $targetName
					$protocolUsed = 'RPC'
				}
				catch {
					$null = $issues.Add('RPC query failed: {0}' -f $_.Exception.Message)
				}
			}
			default {
				try {
					$data = Get-TSxLogConfigurationViaWinRM -ComputerName $targetName
					$protocolUsed = 'WinRM'
				}
				catch {
					$null = $issues.Add('WinRM query failed: {0}' -f $_.Exception.Message)
					try {
						$data = Get-TSxLogConfigurationViaRpc -ComputerName $targetName
						$protocolUsed = 'RPC'
					}
					catch {
						$null = $issues.Add('RPC query failed: {0}' -f $_.Exception.Message)
					}
				}
			}
		}
	}

	if ($null -eq $data) {
		New-TSxResultObject -ComputerName $targetName -RequestedProtocol $protocolPreference -ProtocolUsed $protocolUsed -QueryStatus 'Warning' -QueryIssues @($issues)
		continue
	}

	$systemSize = [int64]$data.Sizes['System']
	$applicationSize = [int64]$data.Sizes['Application']
	$securitySize = [int64]$data.Sizes['Security']

	$result = New-TSxResultObject `
		-ComputerName $targetName `
		-RequestedProtocol $protocolPreference `
		-ProtocolUsed $protocolUsed `
		-DomainRole ([int]$data.DomainRole) `
		-SystemSizeBytes $systemSize `
		-ApplicationSizeBytes $applicationSize `
		-SecuritySizeBytes $securitySize `
		-QueryStatus $(if (@($issues).Count -gt 0) { 'Warning' } else { 'OK' }) `
		-QueryIssues @($issues)

	Write-TSxLog -Message ('Result for {0}: AllLogsStatus={1}, Role={2}, ProtocolUsed={3}' -f $targetName, $result.AllLogsStatus, $result.ServerRole, $result.ProtocolUsed)
	$result
}

Write-TSxLog -Message ('{0} completed' -f $scriptName)
