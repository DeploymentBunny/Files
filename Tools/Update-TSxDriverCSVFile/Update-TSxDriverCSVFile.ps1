#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
Updates Models.csv based on discovered driver folder names.

.DESCRIPTION
Scans the folder structure under Path recursively and evaluates directories named
with the pattern OperatingSystem-ModelName. Currently, only Windows10 and
Windows11 are considered operating systems.

The script updates Models.csv so each model has explicit true/false values for
Windows10 and Windows11 based on the discovered folders.
The filesystem is treated as the source of truth, so models that do not exist
in the discovered folder structure are removed from the CSV.

.PARAMETER Path
Root folder containing the driver folder structure and Models.csv.

.PARAMETER CSVFile
Full path to the Models.csv file that should be updated.

.PARAMETER NoRecurse
Only evaluate directories directly under Path.

.PARAMETER BackupExistingCsv
Creates a timestamped backup of Models.csv before writing updates.

.PARAMETER PassThru
Returns the resulting model objects.

.EXAMPLE
.\Update-TSxDriverCSVFile.ps1 -Path C:\Drivers -CSVFile C:\Drivers\Models.csv -Verbose

.EXAMPLE
.\Update-TSxDriverCSVFile.ps1 -Path C:\Drivers -CSVFile C:\Drivers\Models.csv -BackupExistingCsv

.NOTES
	FileName:    Update-TSxDriverCSVFile.ps1
	Version:     1.0.3
	Author:      Mikael Nystrom
	Contact:     deploymentbunny@outlook.com
	Created:     2026-06-02
	Updated:     2026-06-02
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
	[string]$Path,

	[Parameter(Mandatory = $true)]
	[Alias('CsvPath')]
	[ValidateNotNullOrEmpty()]
	[string]$CSVFile,

	[Parameter()]
	[switch]$NoRecurse,

	[Parameter()]
	[switch]$BackupExistingCsv,

	[Parameter()]
	[switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogRootPath = Join-Path $env:TEMP 'Update-TSxDriverCSVFile'
$script:LogFilePath = Join-Path $script:LogRootPath ('{0}.log' -f [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath))

if (-not (Test-Path -Path $script:LogRootPath -PathType Container)) {
	New-Item -Path $script:LogRootPath -ItemType Directory -Force | Out-Null
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
	Add-Content -Path $script:LogFilePath -Value $entry

	if ($WriteVerbose -or $VerbosePreference -eq 'Continue') {
		Write-Verbose $entry
	}
}

function Get-ExistingModelRows {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$FilePath
	)

	if (-not (Test-Path -Path $FilePath -PathType Leaf)) {
		return @()
	}

	$rows = @(Import-Csv -Path $FilePath)
	return $rows
}

function ConvertTo-BoolString {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[bool]$Value
	)

	if ($Value) {
		return 'true'
	}

	return 'false'
}

function Parse-DriverFolderName {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$FolderName
	)

	if ($FolderName -notmatch '^[^-]+-.+$') {
		return $null
	}

	$parts = $FolderName -split '-', 2
	$operatingSystem = $parts[0]
	$modelName = $parts[1]
	$modelName = ($modelName -replace '_', ' ').Trim()

	if ([string]::IsNullOrWhiteSpace($operatingSystem) -or [string]::IsNullOrWhiteSpace($modelName)) {
		return $null
	}

	if ($operatingSystem -notin @('Windows10', 'Windows11')) {
		return $null
	}

	[pscustomobject]@{
		OperatingSystem = $operatingSystem
		ModelName       = $modelName
	}
}

$resolvedPath = (Resolve-Path -Path $Path).Path
$resolvedCsvFile = [System.IO.Path]::GetFullPath($CSVFile)

Write-TSxLog -Message "Script started. Path=$resolvedPath CSVFile=$resolvedCsvFile NoRecurse=$NoRecurse" -WriteVerbose

if (-not (Test-Path -Path $resolvedPath -PathType Container)) {
	throw "Path not found: $resolvedPath"
}

$existingRows = @(Get-ExistingModelRows -FilePath $resolvedCsvFile)
Write-TSxLog -Message "Loaded $($existingRows.Count) existing row(s) from Models.csv." -WriteVerbose

$directories = if ($NoRecurse) {
	@(Get-ChildItem -Path $resolvedPath -Directory -ErrorAction Stop)
}
else {
	@(Get-ChildItem -Path $resolvedPath -Directory -Recurse -ErrorAction Stop)
}

Write-TSxLog -Message "Discovered $($directories.Count) directorie(s) to evaluate." -WriteVerbose

$discoveredRows = @()
foreach ($directory in $directories) {
	$parsed = Parse-DriverFolderName -FolderName $directory.Name
	if ($null -eq $parsed) {
		continue
	}

	$discoveredRows += $parsed
}

Write-TSxLog -Message "Parsed $($discoveredRows.Count) matching driver folder entrie(s)." -WriteVerbose

$modelMap = @{}

foreach ($row in $discoveredRows) {
	$modelName = $row.ModelName
	if (-not $modelMap.ContainsKey($modelName)) {
		$modelMap[$modelName] = [ordered]@{
			ModelName = $modelName
			Windows10 = $false
			Windows11 = $false
		}
	}

	if ($row.OperatingSystem -eq 'Windows10') {
		$modelMap[$modelName].Windows10 = $true
	}
	elseif ($row.OperatingSystem -eq 'Windows11') {
		$modelMap[$modelName].Windows11 = $true
	}
}

$existingModelNames = @($existingRows | ForEach-Object { [string]$_.ModelName } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
$discoveredModelNames = @($modelMap.Keys)
$removedModelNames = @($existingModelNames | Where-Object { $_ -notin $discoveredModelNames })
if ($removedModelNames.Count -gt 0) {
	Write-TSxLog -Level 'WARN' -Message "Removing $($removedModelNames.Count) model(s) from CSV because they were not found in filesystem scan." -WriteVerbose
}

$outputRows = @(
	$modelMap.Values |
	Sort-Object -Property ModelName |
	ForEach-Object {
		[pscustomobject]@{
			ModelName = $_.ModelName
			Windows10 = ConvertTo-BoolString -Value ([bool]$_.Windows10)
			Windows11 = ConvertTo-BoolString -Value ([bool]$_.Windows11)
		}
	}
)

if ($BackupExistingCsv -and (Test-Path -Path $resolvedCsvFile -PathType Leaf)) {
	$backupPath = '{0}.{1}.bak' -f $resolvedCsvFile, (Get-Date -Format 'yyyyMMddHHmmss')
	if ($PSCmdlet.ShouldProcess($resolvedCsvFile, "Create backup at $backupPath")) {
		Copy-Item -Path $resolvedCsvFile -Destination $backupPath -Force
		Write-TSxLog -Message "Backup created: $backupPath" -WriteVerbose
	}
}

if ($PSCmdlet.ShouldProcess($resolvedCsvFile, "Write $($outputRows.Count) model row(s)")) {
	$outputRows | Export-Csv -Path $resolvedCsvFile -NoTypeInformation -Encoding UTF8
	Write-TSxLog -Message "Models.csv updated with $($outputRows.Count) row(s)." -WriteVerbose
}

$windows10Count = @($outputRows | Where-Object { $_.Windows10 -eq 'true' }).Count
$windows11Count = @($outputRows | Where-Object { $_.Windows11 -eq 'true' }).Count

$result = [pscustomobject]@{
	Path                     = $resolvedPath
	CSVFile                  = $resolvedCsvFile
	ModelsTotal              = $outputRows.Count
	ModelsWithWindows10      = $windows10Count
	ModelsWithWindows11      = $windows11Count
	ParsedDriverFoldersTotal = $discoveredRows.Count
	LogFilePath              = $script:LogFilePath
}

Write-TSxLog -Message "Script completed. ModelsTotal=$($result.ModelsTotal) Windows10=$($result.ModelsWithWindows10) Windows11=$($result.ModelsWithWindows11)" -WriteVerbose

if ($PassThru) {
	$outputRows
}
else {
	$result
}
