<#
.SYNOPSIS
Gets basic computer hardware information in a copy-friendly text format.

.DESCRIPTION
Collects make, model, serial number, logical disk count and size, CPU count and model,
and total physical memory from the local computer. The output is plain text so it can
be copied into another tool for comparing different hardware models.

.EXAMPLE
.\Get-TSxBasicComputerInfo.ps1

Returns a simple hardware summary for the local computer.

.EXAMPLE
.\Get-TSxBasicComputerInfo.ps1 -Verbose

Returns the hardware summary and writes diagnostic logging to the verbose stream.

.NOTES
	FileName:    Get-TSxBasicComputerInfo.ps1
	Version:     1.0.0
	Author:      Mikael Nystrom
	Contact:     deploymentbunny@outlook.com
	Created:     2026-09-09
	Updated:     2026-09-09
	Twitter:     @mikael_nystrom

	Version history:
	1.0.0 - Initial release.

	Disclaimer:
	This script is provided "AS IS" with no warranties, confers no rights and
	is not supported by the author.
.LINK
	https://www.deploymentbunny.com
#>
[CmdletBinding(SupportsShouldProcess = $true)]
[OutputType([string])]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:LogRootPath = Join-Path $env:TEMP 'Get-TSxBasicComputerInfo'
$Script:LogFilePath = Join-Path $Script:LogRootPath ("{0}.log" -f [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath))
$Script:EnableTSxLog = (-not $WhatIfPreference)

function Write-TSxLog {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Message,

		[ValidateSet('INFO', 'WARN', 'ERROR')]
		[string]$Level = 'INFO',

		[switch]$WriteVerbose
	)

	if (-not $Script:EnableTSxLog) {
		return
	}

	$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
	$entry = "$timestamp [$Level] $Message"
	Add-Content -Path $Script:LogFilePath -Value $entry

	if ($WriteVerbose) {
		Write-Verbose $entry
	}
}

function ConvertTo-TSxSizeText {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[UInt64]$Bytes
	)

	if ($Bytes -ge 1TB) {
		return ('{0:N2} TB' -f ($Bytes / 1TB))
	}

	return ('{0:N2} GB' -f ($Bytes / 1GB))
}

if ($Script:EnableTSxLog -and -not (Test-Path -Path $Script:LogRootPath)) {
	New-Item -Path $Script:LogRootPath -ItemType Directory -Force | Out-Null
}

Write-TSxLog -Message 'Script start.' -WriteVerbose

if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Collect basic computer hardware information')) {
	Write-TSxLog -Message 'Script skipped by ShouldProcess.' -WriteVerbose
	return
}

Write-TSxLog -Message 'Collecting computer system information.' -WriteVerbose
$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem

Write-TSxLog -Message 'Collecting BIOS information.' -WriteVerbose
$bios = Get-CimInstance -ClassName Win32_BIOS

Write-TSxLog -Message 'Collecting logical disk information.' -WriteVerbose
$logicalDisks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' | Sort-Object -Property DeviceID)

Write-TSxLog -Message 'Collecting processor information.' -WriteVerbose
$processors = @(Get-CimInstance -ClassName Win32_Processor | Sort-Object -Property SocketDesignation, DeviceID)

$totalDiskBytes = [UInt64](($logicalDisks | Measure-Object -Property Size -Sum).Sum)
$totalMemoryBytes = [UInt64]$computerSystem.TotalPhysicalMemory
$totalCores = [int](($processors | Measure-Object -Property NumberOfCores -Sum).Sum)
$totalLogicalProcessors = [int](($processors | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)
$processorNames = @($processors | Select-Object -ExpandProperty Name -Unique)

$report = [System.Collections.Generic.List[string]]::new()
$report.Add('Basic Computer Information')
$report.Add('==========================')
$report.Add("Computer Name: $($env:COMPUTERNAME)")
$report.Add("Make: $($computerSystem.Manufacturer)")
$report.Add("Model: $($computerSystem.Model)")
$report.Add("Serial Number: $($bios.SerialNumber)")
$report.Add("Total Memory: $(ConvertTo-TSxSizeText -Bytes $totalMemoryBytes)")
$report.Add("CPU Count: $($processors.Count) physical CPU(s), $totalCores core(s), $totalLogicalProcessors logical processor(s)")
$report.Add("CPU Model: $($processorNames -join '; ')")
$report.Add("Logical Disk Count: $($logicalDisks.Count)")
$report.Add("Total Logical Disk Size: $(ConvertTo-TSxSizeText -Bytes $totalDiskBytes)")
$report.Add('Logical Disks:')

foreach ($logicalDisk in $logicalDisks) {
	$report.Add("  $($logicalDisk.DeviceID) $($logicalDisk.VolumeName) - Size: $(ConvertTo-TSxSizeText -Bytes ([UInt64]$logicalDisk.Size)); Free: $(ConvertTo-TSxSizeText -Bytes ([UInt64]$logicalDisk.FreeSpace))")
}

Write-TSxLog -Message 'Script complete.' -WriteVerbose
$report
