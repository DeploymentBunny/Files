<#
.SYNOPSIS
Downloads and refreshes local Microsoft ESD catalog XML files.

.DESCRIPTION
Retrieves known Microsoft catalog CAB sources, extracts XML catalog files,
and stores normalized catalog XML files in the target Catalogs folder.

.PARAMETER CatalogPath
Optional destination path for refreshed catalog XML files.

.PARAMETER Force
Re-downloads catalog files even when they already exist and overwrites them.

.PARAMETER NoProgress
Suppresses host progress output.

.EXAMPLE
.\Update-TSxESDCatalogs.ps1

.NOTES
	FileName:    Update-TSxESDCatalogs.ps1
	Version:     1.3.10
	Author:      Mikael Nystrom
	Contact:     deploymentbunny@outlook.com
	Created:     2026-04-23
	Updated:     2026-05-21
	Twitter:     @mikael_nystrom

	Disclaimer:
	This script is provided "AS IS" with no warranties, confers no rights and
	is not supported by the author.
.LINK
	https://www.deploymentbunny.com
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
	[string]$CatalogPath,
	[switch]$Force,
	[switch]$NoProgress
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:LogRootPath = Join-Path $env:TEMP 'Get-TSxWIMfileFromInternet'
$Script:LogFilePath = Join-Path $Script:LogRootPath 'TSxESDCatalogs.log'

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
	if (-not $WhatIfPreference) {
		Add-Content -Path $Script:LogFilePath -Value $entry
	}

	if ($WriteVerbose) {
		Write-Verbose $entry
	}
}

if (-not $WhatIfPreference -and -not (Test-Path -Path $Script:LogRootPath)) {
	New-Item -Path $Script:LogRootPath -ItemType Directory -Force | Out-Null
}
Write-TSxLog -Message "Script start. CatalogPath=$CatalogPath; Force=$($Force.IsPresent); VerboseEnabled=$($VerbosePreference -ne 'SilentlyContinue')" -WriteVerbose

function Write-TSxProgress {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[int]$Id,

		[Parameter(Mandatory = $true)]
		[string]$Activity,

		[Parameter(Mandatory = $true)]
		[string]$Status,

		[int]$PercentComplete = -1
	)

	if ($NoProgress) {
		return
	}

	if ($PercentComplete -ge 0) {
		Write-Progress -Id $Id -Activity $Activity -Status $Status -PercentComplete $PercentComplete
	}
	else {
		Write-Progress -Id $Id -Activity $Activity -Status $Status
	}
}

function Complete-TSxProgress {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[int]$Id,

		[Parameter(Mandatory = $true)]
		[string]$Activity
	)

	if ($NoProgress) {
		return
	}

	Write-Progress -Id $Id -Activity $Activity -Completed
}

$Script:DefaultCatalogPath = Join-Path $PSScriptRoot 'Catalogs'

function Get-Microsoft25H2CatalogUrl {
	[CmdletBinding()]
	param()

	$uri = 'https://fe3.delivery.mp.microsoft.com/UpdateMetadataService/updates/search/v1/bydeviceinfo'
	$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) MediaCreationTool/10.0'
	$targetVersions = @('26200.0.0.0', '26100.0.0.0')
	$deviceAttributes = @(
		'MediaBranch=br_release'
		'App=Setup360'
		'LCUVersion=10.0.28000.1340'
		'OfflineAttributesOnly=0'
		'MediaVersion=10.0.28000.1340'
		'AppVer=10.0'
		'PreviewBuilds=1'
		'CompositionEditionId=Enterprise'
		'CurrentBranch=br_release'
		'OSArchitecture=AMD64'
		'InstallationType=Client'
		'FlightingBranchName=CanaryChannel'
		'DUInternal=0'
		'FlightRing=External'
		'BuildFlighting=1'
		'HotPatchEligible=0'
		'OSSKUId=48'
		'IsoCountryShortCode=US'
		'OSVersion=10.0.26100.1'
		'AttrDataVer=338'
		'EditionId=Professional'
		'DUScan=1'
	) -join ';'

	foreach ($targetVersion in $targetVersions) {
		$body = @{ Products = "PN=Windows.Products.Cab.amd64&V=$targetVersion"; DeviceAttributes = $deviceAttributes } | ConvertTo-Json -Compress
		Write-TSxLog -Message "Trying 25H2 catalog lookup for target version: $targetVersion" -WriteVerbose

		try {
			$response = Invoke-RestMethod -Uri $uri -Method Post -Body $body -Headers @{ 'Content-Type' = 'application/json'; Accept = '*/*'; 'User-Agent' = $ua } -TimeoutSec 60
			if ($response -is [array] -and $response.Count -gt 0 -and $response[0].FileLocations) {
				return $response[0].FileLocations[0].Url
			}

			if ($response.FileLocations) {
				return $response.FileLocations[0].Url
			}

			if ($response.Updates -and $response.Updates.Count -gt 0 -and $response.Updates[0].FileLocations) {
				return $response.Updates[0].FileLocations[0].Url
			}
		} catch {
			Write-TSxLog -Level 'WARN' -Message "25H2 lookup attempt failed for ${targetVersion}: $($_.Exception.Message)" -WriteVerbose
			continue
		}
	}

	throw 'Unable to resolve a Microsoft 25H2 catalog URL.'
}

function Update-MicrosoftCatalogFiles {
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	param(
		[string]$CatalogPath,
		[switch]$Force
	)

	$targetPath = if ($CatalogPath) { $CatalogPath } else { $Script:DefaultCatalogPath }
	Write-TSxLog -Message "Using catalog target path: $targetPath" -WriteVerbose
	if (-not (Test-Path -Path $targetPath)) {
		if ($PSCmdlet.ShouldProcess($targetPath, 'Create catalog directory')) {
			New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
		} else {
			Write-TSxLog -Message "Skipping directory creation due to WhatIf: $targetPath" -WriteVerbose
		}
	}

	$catalogSources = @(
		@{ Name = '19045.3803-win10-22h2.xml'; Url = 'https://download.microsoft.com/download/7/9/c/79cbc22a-0eea-4a0d-89c0-054a1b3aa8e0/products.cab' }
		@{ Name = '22000.318-win11-21h2.xml'; Url = 'https://download.microsoft.com/download/1/b/4/1b4e06e2-767a-4c9a-9899-230fe94ba530/products_Win11_20211115.cab' }
		@{ Name = '22621.1702-win11-22h2.xml'; Url = 'https://download.microsoft.com/download/b/1/9/b19bd7fd-78c4-4f88-8c40-3e52aee143c2/products_win11_20230510.cab.cab' }
		@{ Name = '22631.2861-win11-23h2.xml'; Url = 'https://download.microsoft.com/download/6/2/b/62b47bc5-1b28-4bfa-9422-e7a098d326d4/products_win11_20231208.cab' }
		@{ Name = '26100.4349-win11-24h2.xml'; Url = 'https://download.microsoft.com/download/8e0c23e7-ddc2-45c4-b7e1-85a808b408ee/Products-Win11-24H2-6B.cab' }
		@{ Name = '26200.8246-win11-25h2.xml'; UrlScript = { Get-Microsoft25H2CatalogUrl } }
	)

	$results = New-Object System.Collections.Generic.List[object]
	$totalSources = $catalogSources.Count
	$sourceIndex = 0
	foreach ($source in $catalogSources) {
		$sourceIndex++
		$destinationPath = Join-Path $targetPath $source.Name
		$sourcePercentComplete = if ($totalSources -gt 0) { [int](($sourceIndex / $totalSources) * 100) } else { 0 }
		Write-TSxProgress -Id 1400 -Activity 'Refreshing ESD catalogs' -Status ("Processing {0} ({1}/{2})" -f $source.Name, $sourceIndex, $totalSources) -PercentComplete $sourcePercentComplete
		if ((Test-Path -Path $destinationPath) -and -not $Force) {
			Write-TSxLog -Message "Skipping existing catalog file (use -Force to refresh): $destinationPath" -WriteVerbose
			continue
		}

		if (-not $PSCmdlet.ShouldProcess($destinationPath, 'Refresh catalog XML from Microsoft source')) {
			Write-TSxLog -Message "Skipping catalog update due to WhatIf: $destinationPath" -WriteVerbose
			continue
		}

		$sourceUrl = if ($source.ContainsKey('UrlScript')) { & $source.UrlScript } else { [string]$source.Url }
		Write-TSxLog -Message "Updating catalog source $($source.Name) from $sourceUrl" -WriteVerbose
		$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
		New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

		try {
			$sourceFile = Join-Path $tempRoot 'source.cab'
			Write-TSxProgress -Id 1400 -Activity 'Refreshing ESD catalogs' -Status ("Downloading {0}" -f $source.Name) -PercentComplete $sourcePercentComplete
			Invoke-WebRequest -Uri $sourceUrl -OutFile $sourceFile -UseBasicParsing -ErrorAction Stop
			Write-TSxProgress -Id 1400 -Activity 'Refreshing ESD catalogs' -Status ("Extracting {0}" -f $source.Name) -PercentComplete $sourcePercentComplete
			& expand.exe -R $sourceFile -F:* $tempRoot | Out-Null

			$xmlFile = Get-ChildItem -Path $tempRoot -Filter '*.xml' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
			if (-not $xmlFile) {
				throw "No XML was extracted from $sourceUrl"
			}

			Copy-Item -Path $xmlFile.FullName -Destination $destinationPath -Force
			Write-TSxLog -Message "Updated catalog file: $($source.Name)" -WriteVerbose
			$results.Add([PSCustomObject]@{ Name = $source.Name; Source = $sourceUrl; Path = $destinationPath })
		} finally {
			Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
		}
	}
	Complete-TSxProgress -Id 1400 -Activity 'Refreshing ESD catalogs'

	return $results
}

function Test-ExecutionPrerequisites {
	[CmdletBinding()]
	param()

	if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
		throw 'This script requires Windows PowerShell 5.1.'
	}
}

try {
	Test-ExecutionPrerequisites
	$effectiveCatalogPath = if ([string]::IsNullOrWhiteSpace($CatalogPath)) { $Script:DefaultCatalogPath } else { $CatalogPath }
	Write-Verbose "[Update-TSxESDCatalogs] Catalog storage path: $effectiveCatalogPath"
	Write-TSxLog -Message "Catalog storage path resolved to: $effectiveCatalogPath" -WriteVerbose
	$result = @(Update-MicrosoftCatalogFiles -CatalogPath $CatalogPath -Force:$Force)
	Write-TSxLog -Message "Catalog update completed. Updated $(@($result).Count) file(s)." -WriteVerbose
	$result | Format-Table -AutoSize
} catch {
	Write-TSxLog -Level 'ERROR' -Message "Unhandled error: $($_.Exception.Message)" -WriteVerbose
	throw
} finally {
	Write-TSxLog -Message 'Script end.' -WriteVerbose
}
