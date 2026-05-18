<#
.SYNOPSIS
Downloads and refreshes local Microsoft ESD catalog XML files.

.DESCRIPTION
Retrieves known Microsoft catalog CAB sources, extracts XML catalog files,
and stores normalized catalog XML files in the target Catalogs folder.

.PARAMETER CatalogPath
Optional destination path for refreshed catalog XML files.

.EXAMPLE
.\Update-TSxESDCatalogs.ps1

.NOTES
Version: 1.1.0
Date: 2026-05-18
#>
param(
	[string]$CatalogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:LogRootPath = Join-Path $env:TEMP 'TSxWimFileFromInternet'
$Script:LogFilePath = Join-Path $Script:LogRootPath ("{0}.log" -f [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath))

function Write-TSxLog {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Message,

		[ValidateSet('INFO', 'WARN', 'ERROR')]
		[string]$Level = 'INFO'
	)

	$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
	Add-Content -Path $Script:LogFilePath -Value "$timestamp [$Level] $Message"
}

if (-not (Test-Path -Path $Script:LogRootPath)) {
	New-Item -Path $Script:LogRootPath -ItemType Directory -Force | Out-Null
}
Write-TSxLog -Message "Script start. CatalogPath=$CatalogPath"

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
		Write-TSxLog -Message "Trying 25H2 catalog lookup for target version: $targetVersion"

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
			Write-TSxLog -Level 'WARN' -Message "25H2 lookup attempt failed for $targetVersion: $($_.Exception.Message)"
			continue
		}
	}

	throw 'Unable to resolve a Microsoft 25H2 catalog URL.'
}

function Update-MicrosoftCatalogFiles {
	[CmdletBinding()]
	param(
		[string]$CatalogPath
	)

	$targetPath = if ($CatalogPath) { $CatalogPath } else { $Script:DefaultCatalogPath }
	Write-TSxLog -Message "Using catalog target path: $targetPath"
	if (-not (Test-Path -Path $targetPath)) {
		New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
	}

	$catalogSources = @(
		@{ Name = '19045.3803-win10-22h2.xml'; Url = 'https://download.microsoft.com/download/7/9/c/79cbc22a-0eea-4a0d-89c0-054a1b3aa8e0/products.cab' }
		@{ Name = '22000.318-win11-21h2.xml'; Url = 'https://download.microsoft.com/download/1/b/4/1b4e06e2-767a-4c9a-9899-230fe94ba530/products_Win11_20211115.cab' }
		@{ Name = '22621.1702-win11-22h2.xml'; Url = 'https://download.microsoft.com/download/b/1/9/b19bd7fd-78c4-4f88-8c40-3e52aee143c2/products_win11_20230510.cab.cab' }
		@{ Name = '22631.2861-win11-23h2.xml'; Url = 'https://download.microsoft.com/download/6/2/b/62b47bc5-1b28-4bfa-9422-e7a098d326d4/products_win11_20231208.cab' }
		@{ Name = '26100.4349-win11-24h2.xml'; Url = 'https://download.microsoft.com/download/8e0c23e7-ddc2-45c4-b7e1-85a808b408ee/Products-Win11-24H2-6B.cab' }
	)

	$catalogSources += @{
		Name = '26200.8246-win11-25h2.xml'
		Url = Get-Microsoft25H2CatalogUrl
	}

	$results = New-Object System.Collections.Generic.List[object]
	foreach ($source in $catalogSources) {
		Write-TSxLog -Message "Updating catalog source $($source.Name) from $($source.Url)"
		$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
		New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

		try {
			$sourceFile = Join-Path $tempRoot 'source.cab'
			Invoke-WebRequest -Uri $source.Url -OutFile $sourceFile -UseBasicParsing -ErrorAction Stop
			& expand.exe -R $sourceFile -F:* $tempRoot | Out-Null

			$xmlFile = Get-ChildItem -Path $tempRoot -Filter '*.xml' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
			if (-not $xmlFile) {
				throw "No XML was extracted from $($source.Url)"
			}

			Copy-Item -Path $xmlFile.FullName -Destination (Join-Path $targetPath $source.Name) -Force
			Write-TSxLog -Message "Updated catalog file: $($source.Name)"
			$results.Add([PSCustomObject]@{ Name = $source.Name; Source = $source.Url; Path = (Join-Path $targetPath $source.Name) })
		} finally {
			Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
		}
	}

	return $results
}

try {
	$result = Update-MicrosoftCatalogFiles -CatalogPath $CatalogPath
	Write-TSxLog -Message "Catalog update completed. Updated $($result.Count) file(s)."
	$result | Format-Table -AutoSize
	exit 0
} catch {
	Write-TSxLog -Level 'ERROR' -Message "Unhandled error: $($_.Exception.Message)"
	Write-Error $_
	exit 1
} finally {
	Write-TSxLog -Message 'Script end.'
}
