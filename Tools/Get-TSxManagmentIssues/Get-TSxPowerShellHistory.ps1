#requires -Version 5.1

<#
.SYNOPSIS
	Collects PowerShell command history from PSReadLine history files.

.DESCRIPTION
	Reads the PSReadLine history files from the local computer or from a remote
	computer supplied through -ComputerName. The script returns each command as a
	structured object so the caller can filter, sort, or export the history.

	By default the script runs locally. When -ComputerName is specified, the
	history is collected through PowerShell remoting.

.PARAMETER ComputerName
	Computer to query. Defaults to the local computer.

.EXAMPLE
	.\Get-TSxPowerShellHistory.ps1

.EXAMPLE
	.\Get-TSxPowerShellHistory.ps1 -ComputerName SRV01

.NOTES
	FileName:    Get-TSxPowerShellHistory.ps1
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

[CmdletBinding()]
param(
	[Parameter()]
	[Alias('CompterName')]
	[ValidateNotNullOrEmpty()]
	[string]$ComputerName = $env:COMPUTERNAME
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TSxPowerShellHistoryEntries {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$TargetComputerName
	)

	$historyRoots = @(
		(Join-Path -Path $env:APPDATA -ChildPath 'Microsoft\Windows\PowerShell\PSReadLine'),
		(Join-Path -Path $env:APPDATA -ChildPath 'Microsoft\PowerShell\PSReadLine')
	)

	$results = New-Object System.Collections.Generic.List[object]
	$seenFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

	foreach ($historyRoot in $historyRoots) {
		if (-not (Test-Path -LiteralPath $historyRoot -PathType Container)) {
			continue
		}

		$historyFiles = @(Get-ChildItem -LiteralPath $historyRoot -Filter '*history.txt' -File -ErrorAction SilentlyContinue)
		foreach ($historyFile in $historyFiles) {
			if (-not $seenFiles.Add($historyFile.FullName)) {
				continue
			}

			$lineNumber = 0
			foreach ($line in Get-Content -LiteralPath $historyFile.FullName -ErrorAction Stop) {
				$lineNumber++
				if ([string]::IsNullOrWhiteSpace($line)) {
					continue
				}

				$null = $results.Add([pscustomobject]@{
					ComputerName = $TargetComputerName
					HistoryPath  = $historyFile.FullName
					HistoryFile  = $historyFile.Name
					HistoryHost  = [System.IO.Path]::GetFileNameWithoutExtension($historyFile.Name)
					LineNumber   = $lineNumber
					Command      = $line
					Source       = 'PSReadLine'
				})
			}
		}
	}

	return $results
}

$isLocalComputer = @(
	$env:COMPUTERNAME,
	'localhost',
	'127.0.0.1',
	'::1',
	'.'
) -contains $ComputerName

if ($isLocalComputer) {
	Get-TSxPowerShellHistoryEntries -TargetComputerName $env:COMPUTERNAME
	return
}

Invoke-Command -ComputerName $ComputerName -ErrorAction Stop -ScriptBlock {
	param(
		[string]$TargetComputerName
	)

	function Get-TSxPowerShellHistoryEntries {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$TargetComputerName
		)

		$historyRoots = @(
			(Join-Path -Path $env:APPDATA -ChildPath 'Microsoft\Windows\PowerShell\PSReadLine'),
			(Join-Path -Path $env:APPDATA -ChildPath 'Microsoft\PowerShell\PSReadLine')
		)

		$results = New-Object System.Collections.Generic.List[object]
		$seenFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

		foreach ($historyRoot in $historyRoots) {
			if (-not (Test-Path -LiteralPath $historyRoot -PathType Container)) {
				continue
			}

			$historyFiles = @(Get-ChildItem -LiteralPath $historyRoot -Filter '*history.txt' -File -ErrorAction SilentlyContinue)
			foreach ($historyFile in $historyFiles) {
				if (-not $seenFiles.Add($historyFile.FullName)) {
					continue
				}

				$lineNumber = 0
				foreach ($line in Get-Content -LiteralPath $historyFile.FullName -ErrorAction Stop) {
					$lineNumber++
					if ([string]::IsNullOrWhiteSpace($line)) {
						continue
					}

					$null = $results.Add([pscustomobject]@{
						ComputerName = $TargetComputerName
						HistoryPath  = $historyFile.FullName
						HistoryFile  = $historyFile.Name
						HistoryHost  = [System.IO.Path]::GetFileNameWithoutExtension($historyFile.Name)
						LineNumber   = $lineNumber
						Command      = $line
						Source       = 'PSReadLine'
					})
				}
			}
		}

		return $results
	}

	Get-TSxPowerShellHistoryEntries -TargetComputerName $TargetComputerName
} -ArgumentList $ComputerName
