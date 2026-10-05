<#
.SYNOPSIS
	Exports selected Windows event logs for a specific time range.

.DESCRIPTION
	Exports events recorded between 2026-09-24 18:30 and 19:15 to individual
	CSV files. WinRM is included when present, and CAPI2 is included when enabled.

.PARAMETER OutputDirectory
	Directory where the CSV files are written.

.NOTES
	FileName: Get-TSxSpecificLogandSpecificTime.ps1
	Version: 1.0.0
	Author: Deployment Bunny
	Contact: info@deploymentbunny.com
	Created: 2026-09-24
	Updated: 2026-09-24
	Twitter: @DeploymentBunny
	Disclaimer: This script is provided AS IS without warranty.

.LINK
	https://www.deploymentbunny.com
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
	[string]$OutputDirectory = 'C:\Temp'
)

$StartTime = [datetime]'2026-09-24 18:30:00'
$EndTime = [datetime]'2026-09-24 19:15:00'

$LogNames = @(
	'Application'
	'System'
	'Microsoft-Windows-WMI-Activity/Operational'
	'Microsoft-Windows-TaskScheduler/Operational'
	'Microsoft-Windows-GroupPolicy/Operational'
	'Microsoft-Windows-Windows Defender/Operational'
)

$WinRMLogName = 'Microsoft-Windows-WinRM/Operational'
$WinRMLog = Get-WinEvent -ListLog $WinRMLogName -ErrorAction SilentlyContinue
if ($null -ne $WinRMLog) {
	Write-Verbose "Including available event log: $WinRMLogName"
	$LogNames += $WinRMLogName
}
else {
	Write-Verbose "Skipping unavailable event log: $WinRMLogName"
}

$CAPI2LogName = 'Microsoft-Windows-CAPI2/Operational'
$CAPI2Log = Get-WinEvent -ListLog $CAPI2LogName -ErrorAction SilentlyContinue
if (($null -ne $CAPI2Log) -and $CAPI2Log.IsEnabled) {
	Write-Verbose "Including enabled event log: $CAPI2LogName"
	$LogNames += $CAPI2LogName
}
else {
	Write-Verbose "Skipping unavailable or disabled event log: $CAPI2LogName"
}

if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
	if ($PSCmdlet.ShouldProcess($OutputDirectory, 'Create output directory')) {
		New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
	}
}

foreach ($LogName in $LogNames) {
	$FileName = ($LogName -replace '[\\/:*?"<>| ]', '_') + '.csv'
	$OutputPath = Join-Path -Path $OutputDirectory -ChildPath $FileName

	if (-not $PSCmdlet.ShouldProcess($OutputPath, "Export events from $LogName")) {
		continue
	}

	try {
		Write-Verbose "Exporting $LogName events from $StartTime through $EndTime."
		Get-WinEvent -FilterHashtable @{
			LogName = $LogName
			StartTime = $StartTime
			EndTime = $EndTime
		} -ErrorAction Stop |
		Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, ProcessId, ThreadId, Message |
		Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Force
	}
	catch {
		Write-Warning "$LogName`: $($_.Exception.Message)"
	}
}
