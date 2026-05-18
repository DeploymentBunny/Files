<#
.SYNOPSIS
Lists Windows ESD entries from local Microsoft catalog XML files.

.DESCRIPTION
Parses catalog XML files from the bundled Catalogs folder or a supplied path,
normalizes operating system metadata, and returns filterable ESD download entries.

.PARAMETER AsJson
Outputs the resulting entries as JSON instead of PowerShell objects.

.PARAMETER CatalogPath
Optional path to catalog XML files.

.PARAMETER Architecture
Optional architecture filter, for example amd64 or arm64.

.PARAMETER Language
Optional language filter matching language code or language name.

.PARAMETER Version
Optional version filter matching OS version, build, or build version.

.PARAMETER OSLicense
Optional activation channel filter, for example Retail or Volume.

.EXAMPLE
.\Show-TSxESDFiles.ps1 -Architecture amd64 -Language en-us

.NOTES
Version: 1.1.1
Date: 2026-05-18
#>
param(
	[switch]$AsJson,
	[string]$CatalogPath,
	[string]$Architecture,
	[string]$Language,
	[string]$Version,
	[string]$OSLicense
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
Write-TSxLog -Message "Script start. AsJson=$($AsJson.IsPresent); CatalogPath=$CatalogPath"

# Catalog XML files (MCT format) ship alongside this script in the Catalogs subfolder.
# To use a different set of XML files, supply -CatalogPath.
$Script:DefaultCatalogPath = Join-Path $PSScriptRoot 'Catalogs'

function Get-OSDCloudCatalogXmlSource {
	[CmdletBinding()]
	param(
		[string]$CatalogPath
	)

	# 1 — explicit path supplied by caller
	if ($CatalogPath) {
		if (-not (Test-Path -Path $CatalogPath)) {
			throw "CatalogPath not found: $CatalogPath"
		}
		return [PSCustomObject]@{ Mode = 'Local'; Path = $CatalogPath }
	}

	# 2 — bundled Catalogs subfolder (default)
	Write-Verbose "Using bundled catalogs from: $Script:DefaultCatalogPath"
	return [PSCustomObject]@{ Mode = 'Local'; Path = $Script:DefaultCatalogPath }
}

function ConvertTo-OSDCloudOperatingSystemName {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$OSBuild
	)

	switch ($OSBuild) {
		'19045' { return [PSCustomObject]@{ OperatingSystem = 'Windows 10 22H2'; OSName = 'Windows 10'; OSVersion = '22H2' } }
		'22000' { return [PSCustomObject]@{ OperatingSystem = 'Windows 11 21H2'; OSName = 'Windows 11'; OSVersion = '21H2' } }
		'22621' { return [PSCustomObject]@{ OperatingSystem = 'Windows 11 22H2'; OSName = 'Windows 11'; OSVersion = '22H2' } }
		'22631' { return [PSCustomObject]@{ OperatingSystem = 'Windows 11 23H2'; OSName = 'Windows 11'; OSVersion = '23H2' } }
		'26100' { return [PSCustomObject]@{ OperatingSystem = 'Windows 11 24H2'; OSName = 'Windows 11'; OSVersion = '24H2' } }
		'26200' { return [PSCustomObject]@{ OperatingSystem = 'Windows 11 25H2'; OSName = 'Windows 11'; OSVersion = '25H2' } }
		'28000' { return [PSCustomObject]@{ OperatingSystem = 'Windows 11 26H1'; OSName = 'Windows 11'; OSVersion = '26H1' } }
		default { return $null }
	}
}

function Get-NodePropertyValue {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[object]$Node,

		[Parameter(Mandatory = $true)]
		[string[]]$Names
	)

	foreach ($name in $Names) {
		$prop = $Node.PSObject.Properties[$name]
		if ($prop -and $null -ne $prop.Value -and "$($prop.Value)" -ne '') {
			return "$($prop.Value)"
		}
	}

	return $null
}

function Test-FilterMatch {
	[CmdletBinding()]
	param(
		[string]$Value,
		[string]$Filter
	)

	if (-not $Filter) {
		return $true
	}

	if (-not $Value) {
		return $false
	}

	return $Value -like "*$Filter*"
}

function Get-CollectionCount {
	[CmdletBinding()]
	param(
		[object]$InputObject
	)

	if ($null -eq $InputObject) {
		return 0
	}

	if ($InputObject -is [System.Collections.ICollection]) {
		return $InputObject.Count
	}

	return @($InputObject).Count
}

function Get-OSDCloudCatalogNodes {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Path
	)

	$nodes = New-Object System.Collections.Generic.List[object]

	$xmlFiles = Get-ChildItem -Path $Path -Filter '*.xml' -File -Recurse | Sort-Object FullName
	Write-TSxLog -Message "Discovered $(Get-CollectionCount -InputObject $xmlFiles) catalog XML file(s) in path: $Path"
	foreach ($file in $xmlFiles) {
		$xml = [xml](Get-Content -Path $file.FullName -Raw)
		$fileNodes = $xml.MCT.Catalogs.Catalog.PublishedMedia.Files.File
		if (-not $fileNodes) { continue }
		foreach ($node in ($fileNodes | Sort-Object FileName)) {
			$nodes.Add($node)
		}
	}

	return $nodes
}

function Get-OSDCloudEsdFiles {
	[CmdletBinding()]
	param(
		[string]$CatalogPath
	)

	$source = Get-OSDCloudCatalogXmlSource -CatalogPath $CatalogPath
	$catalogNodes = Get-OSDCloudCatalogNodes -Path $source.Path

	$results = New-Object System.Collections.Generic.List[object]
	$seenIds = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

	foreach ($node in $catalogNodes) {
		$fileName = Get-NodePropertyValue -Node $node -Names @('FileName', 'Filename')
		if (-not $fileName) { continue }
		if ($fileName -notmatch '(?i)\.esd$') { continue }

		$languageCode = Get-NodePropertyValue -Node $node -Names @('LanguageCode', 'Language')
		$languageName = Get-NodePropertyValue -Node $node -Names @('Language', 'LanguageCode')
		$architectureValue = Get-NodePropertyValue -Node $node -Names @('Architecture')
		$sizeValue = Get-NodePropertyValue -Node $node -Names @('Size')
		$sha1Value = Get-NodePropertyValue -Node $node -Names @('Sha1', 'SHA1')
		$sha256Value = Get-NodePropertyValue -Node $node -Names @('Sha256', 'SHA256')
		$filePathValue = Get-NodePropertyValue -Node $node -Names @('FilePath', 'Url', 'URL')

		$osBuild = $null
		try {
			$osBuild = $fileName.Substring(0, 5)
		}
		catch {
			continue
		}

		$osInfo = ConvertTo-OSDCloudOperatingSystemName -OSBuild $osBuild
		if (-not $osInfo) { continue }

		$osArchitecture = $null
		if ($architectureValue -match 'x64') {
			$osArchitecture = 'amd64'
		}
		elseif ($architectureValue -match 'arm64') {
			$osArchitecture = 'arm64'
		}
		else {
			continue
		}

		$osActivation = $null
		if ($fileName -match 'clientconsumer_ret') {
			$osActivation = 'Retail'
		}
		elseif ($fileName -match 'CLIENTBUSINESS_VOL') {
			$osActivation = 'Volume'
		}
		else {
			continue
		}

		$osBuildVersion = ($fileName -split '\.', 3)[0..1] -join '.'
		$id = "$($osInfo.OperatingSystem) $osArchitecture $osActivation $languageCode $osBuildVersion"
		if (-not $seenIds.Add($id)) { continue }

		$results.Add([PSCustomObject]@{
			Id             = $id
			OperatingSystem = $osInfo.OperatingSystem
			OSName         = $osInfo.OSName
			OSVersion      = $osInfo.OSVersion
			OSArchitecture = $osArchitecture
			OSActivation   = $osActivation
			OSLanguageCode = $languageCode
			OSLanguage     = $languageName
			OSBuild        = $osBuild
			OSBuildVersion = $osBuildVersion
			Size           = $sizeValue
			Sha1           = $sha1Value
			Sha256         = $sha256Value
			FileName       = $fileName
			FilePath       = $filePathValue
			CatalogSource  = $source.Mode
		})
	}

	Write-TSxLog -Message "Catalog parsing complete. Collected $($results.Count) ESD record(s) before final sort."
	$results |
		Sort-Object -Property FileName -Unique |
		Sort-Object -Property @{ Expression = { $_.OperatingSystem }; Descending = $true }, OSArchitecture, OSActivation, OSLanguageCode
}

try {
	$downloads = Get-OSDCloudEsdFiles -CatalogPath $CatalogPath
	Write-TSxLog -Message "Loaded $(Get-CollectionCount -InputObject $downloads) ESD record(s) before filtering."

	if ($Architecture -or $Language -or $Version -or $OSLicense) {
		$downloads = $downloads | Where-Object {
			$architectureMatch = Test-FilterMatch -Value $_.OSArchitecture -Filter $Architecture
			$languageMatch = (Test-FilterMatch -Value $_.OSLanguageCode -Filter $Language) -or (Test-FilterMatch -Value $_.OSLanguage -Filter $Language)
			$versionMatch = (Test-FilterMatch -Value $_.OSVersion -Filter $Version) -or (Test-FilterMatch -Value $_.OSBuild -Filter $Version) -or (Test-FilterMatch -Value $_.OSBuildVersion -Filter $Version)
			$licenseMatch = Test-FilterMatch -Value $_.OSActivation -Filter $OSLicense
			$architectureMatch -and $languageMatch -and $versionMatch -and $licenseMatch
		}
		Write-TSxLog -Message "Applied filters. Remaining $(Get-CollectionCount -InputObject $downloads) ESD record(s)."
	}

	if ($AsJson) {
		Write-TSxLog -Message 'Rendering output as JSON.'
		if (-not $downloads) {
			'[]'
		}
		else {
			$downloads | ConvertTo-Json -Depth 3
		}
	}
	else {
		$downloads
	}
} catch {
	Write-TSxLog -Level 'ERROR' -Message "Unhandled error: $($_.Exception.Message)"
	throw
} finally {
	Write-TSxLog -Message 'Script end.'
}

