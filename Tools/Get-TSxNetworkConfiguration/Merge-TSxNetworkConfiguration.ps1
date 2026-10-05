<#
.SYNOPSIS
	Merges all network configuration CSV files in a folder into one consolidated CSV.

.DESCRIPTION
	Reads all CSV files in the specified folder, merges the rows into a single output
	file, and writes the result to Merged-NetworkConfiguration.csv.

	The script is intended to consolidate the per-computer exports created by
	Get-TSxNetworkConfiguration.ps1 so all computers can be analyzed in one file.

.PARAMETER Path
	Path to the folder that contains the network configuration CSV files.

.PARAMETER Overwrite
	If specified, overwrites the merged CSV file when it already exists.

.EXAMPLE
	.\Merge-TSxNetworkConfiguration.ps1 -Path 'C:\Logs' -Verbose

.EXAMPLE
	.\Merge-TSxNetworkConfiguration.ps1 -Path 'C:\Logs' -Overwrite -Verbose

.NOTES
	FileName:    Merge-TSxNetworkConfiguration.ps1
	Version:     1.0.0
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

.FUNCTIONALITY
	Consolidates per-computer network configuration CSV files into one merged CSV.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
	[Parameter(Mandatory = $true)]
	[ValidateNotNullOrEmpty()]
	[string]$Path,

	[Parameter(Mandatory = $false)]
	[switch]$Overwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptName = if ($MyInvocation.MyCommand -and $MyInvocation.MyCommand.Name) { $MyInvocation.MyCommand.Name } else { 'Merge-TSxNetworkConfiguration.ps1' }
Write-Verbose ('{0} started' -f $scriptName)
Write-Verbose ('Source folder: {0}' -f $Path)

if (-not (Test-Path -Path $Path)) {
	throw ('The folder {0} does not exist.' -f $Path)
}

$mergedFileName = 'Merged-NetworkConfiguration.csv'
$mergedFilePath = Join-Path -Path $Path -ChildPath $mergedFileName
Write-Verbose ('Merged output file: {0}' -f $mergedFilePath)

if (Test-Path -Path $mergedFilePath) {
	if ($Overwrite) {
		Write-Verbose ('Merged file already exists: {0}. Overwrite specified, continuing.' -f $mergedFilePath)
	}
	else {
		Write-Warning ('Merged file already exists: {0}. Exiting.' -f $mergedFilePath)
		exit 0
	}
}

$sourceFiles = @(
	Get-ChildItem -Path $Path | Where-Object {
		(-not $_.PSIsContainer) -and
		($_.Extension -ieq '.csv') -and
		($_.FullName -ne $mergedFilePath)
	}
)

if ($sourceFiles.Count -eq 0) {
	throw ('No CSV files were found in {0}.' -f $Path)
}

Write-Verbose ('Found {0} CSV file(s) to merge.' -f $sourceFiles.Count)

$mergedRows = New-Object System.Collections.Generic.List[object]

foreach ($sourceFile in ($sourceFiles | Sort-Object Name)) {
	Write-Verbose ('Importing {0}' -f $sourceFile.Name)
	$importedRows = @(Import-Csv -Path $sourceFile.FullName)
	if ($importedRows.Count -gt 0) {
		foreach ($row in $importedRows) {
			$null = $mergedRows.Add($row)
		}
	}
	else {
		Write-Verbose ('Skipping empty CSV file {0}' -f $sourceFile.Name)
	}
}

if ($mergedRows.Count -eq 0) {
	throw 'No rows were imported from the source CSV files.'
}

$orderedRows = @(
	$mergedRows |
	Sort-Object ComputerName, AdapterIndex, AdapterName |
	Select-Object ComputerName, AdapterIndex, AdapterName, NetConnectionID, AdapterDescription, AdapterType, ServiceName, MACAddress, PhysicalAdapter, NetEnabled, NetConnectionStatus, DHCPEnabled, DHCPServer, IPAddress, IPSubnet, DefaultGateway, DNSServers, DNSDomain, DNSHostName
)

if ($PSCmdlet.ShouldProcess($mergedFilePath, 'Write merged CSV')) {
	if (Test-Path -Path $mergedFilePath) {
		Remove-Item -Path $mergedFilePath -Force
	}

	Write-Verbose ('Writing {0} merged row(s) to {1}' -f $orderedRows.Count, $mergedFilePath)
	$orderedRows | Export-Csv -Path $mergedFilePath -NoTypeInformation -Delimiter ','
	Write-Verbose 'Merge completed successfully.'
}
else {
	Write-Verbose ('WhatIf: Skipping merged CSV write to {0}' -f $mergedFilePath)
}
