[CmdletBinding(SupportsShouldProcess = $true)]
param(
	[Parameter(ValueFromPipeline = $true)]
	[object]$CatalogItem,

	[string]$Url,
	[string]$FileName,
	[string]$OutputPath = (Join-Path $PSScriptRoot 'Downloads'),
	[switch]$ConvertToWim,
	[string]$WimPath,
	[switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-DownloadSource {
	[CmdletBinding()]
	param(
		[object]$CatalogItem,
		[string]$Url,
		[string]$FileName
	)

	$resolvedUrl = $Url
	$resolvedFileName = $FileName

	if ($CatalogItem) {
		if ($CatalogItem -is [string] -and [string]::IsNullOrWhiteSpace($resolvedUrl)) {
			$resolvedUrl = $CatalogItem
		}

		$sourceProp = $CatalogItem.PSObject.Properties['FilePath']
		if ($sourceProp -and -not [string]::IsNullOrWhiteSpace([string]$sourceProp.Value) -and [string]::IsNullOrWhiteSpace($resolvedUrl)) {
			$resolvedUrl = [string]$sourceProp.Value
		}

		$fileNameProp = $CatalogItem.PSObject.Properties['FileName']
		if ($fileNameProp -and -not [string]::IsNullOrWhiteSpace([string]$fileNameProp.Value) -and [string]::IsNullOrWhiteSpace($resolvedFileName)) {
			$resolvedFileName = [string]$fileNameProp.Value
		}
	}

	if ([string]::IsNullOrWhiteSpace($resolvedUrl)) {
		throw 'No URL was provided. Pass -Url or pipe an object with a FilePath property.'
	}

	if ([string]::IsNullOrWhiteSpace($resolvedFileName)) {
		try {
			$uri = [System.Uri]$resolvedUrl
			$resolvedFileName = [System.IO.Path]::GetFileName($uri.AbsolutePath)
		} catch {
			$resolvedFileName = [System.IO.Path]::GetFileName(($resolvedUrl -split '\?')[0])
		}
	}

	if ([string]::IsNullOrWhiteSpace($resolvedFileName)) {
		throw "Unable to determine file name from URL: $resolvedUrl"
	}

	[PSCustomObject]@{
		Url = $resolvedUrl
		FileName = $resolvedFileName
	}
}

function Download-EsdFile {
	[CmdletBinding(SupportsShouldProcess = $true)]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Url,

		[Parameter(Mandatory = $true)]
		[string]$DestinationPath,

		[switch]$Force
	)

	$destinationDirectory = Split-Path -Path $DestinationPath -Parent
	if (-not (Test-Path -Path $destinationDirectory)) {
		New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null
	}

	if ((Test-Path -Path $DestinationPath) -and -not $Force) {
		return $DestinationPath
	}

	if ((Test-Path -Path $DestinationPath) -and $Force) {
		Remove-Item -Path $DestinationPath -Force
	}

	if ($PSCmdlet.ShouldProcess($DestinationPath, "Download from $Url")) {
		Invoke-WebRequest -Uri $Url -OutFile $DestinationPath -UseBasicParsing -ErrorAction Stop
	}

	return $DestinationPath
}

function Get-EsdIndexes {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$EsdPath
	)

	$infoOutput = & dism.exe /English /Get-WimInfo /WimFile:$EsdPath
	if ($LASTEXITCODE -ne 0) {
		throw "DISM failed while reading ESD metadata from $EsdPath"
	}

	$indexes = New-Object System.Collections.Generic.List[int]
	foreach ($line in $infoOutput) {
		if ($line -match '^Index\s*:\s*(\d+)$') {
			$indexes.Add([int]$Matches[1])
		}
	}

	if ($indexes.Count -eq 0) {
		throw "No image indexes were found in $EsdPath"
	}

	return $indexes
}

function Convert-EsdToWim {
	[CmdletBinding(SupportsShouldProcess = $true)]
	param(
		[Parameter(Mandatory = $true)]
		[string]$EsdPath,

		[Parameter(Mandatory = $true)]
		[string]$WimPath,

		[switch]$Force
	)

	$wimDirectory = Split-Path -Path $WimPath -Parent
	if (-not (Test-Path -Path $wimDirectory)) {
		New-Item -Path $wimDirectory -ItemType Directory -Force | Out-Null
	}

	if ((Test-Path -Path $WimPath) -and -not $Force) {
		return $WimPath
	}

	if ((Test-Path -Path $WimPath) -and $Force) {
		Remove-Item -Path $WimPath -Force
	}

	$indexes = Get-EsdIndexes -EsdPath $EsdPath
	foreach ($index in $indexes) {
		$action = "Export index $index from $EsdPath"
		if ($PSCmdlet.ShouldProcess($WimPath, $action)) {
			& dism.exe /Export-Image /SourceImageFile:$EsdPath /SourceIndex:$index /DestinationImageFile:$WimPath /Compress:max /CheckIntegrity
			if ($LASTEXITCODE -ne 0) {
				throw "DISM failed while exporting index $index from $EsdPath"
			}
		}
	}

	return $WimPath
}

$items = New-Object System.Collections.Generic.List[object]
if ($MyInvocation.ExpectingInput) {
	foreach ($item in $input) {
		$items.Add($item)
	}
} elseif ($PSBoundParameters.ContainsKey('CatalogItem')) {
	$items.Add($CatalogItem)
}

if ($items.Count -eq 0) {
	$items.Add($null)
}

foreach ($item in $items) {
	$source = Resolve-DownloadSource -CatalogItem $item -Url $Url -FileName $FileName

	$esdPath = Join-Path $OutputPath $source.FileName
	$downloadedPath = Download-EsdFile -Url $source.Url -DestinationPath $esdPath -Force:$Force -WhatIf:$WhatIfPreference

	$resolvedWimPath = $null
	if ($ConvertToWim) {
		if ([string]::IsNullOrWhiteSpace($WimPath)) {
			$resolvedWimPath = [System.IO.Path]::ChangeExtension($downloadedPath, '.wim')
		} else {
			$resolvedWimPath = $WimPath
		}

		if (-not $WhatIfPreference) {
			$resolvedWimPath = Convert-EsdToWim -EsdPath $downloadedPath -WimPath $resolvedWimPath -Force:$Force -WhatIf:$WhatIfPreference
		}
	}

	[PSCustomObject]@{
		SourceUrl  = $source.Url
		FileName   = $source.FileName
		EsdPath    = $downloadedPath
		WimPath    = $resolvedWimPath
		Converted  = $ConvertToWim.IsPresent
		OutputPath = $OutputPath
	}
}