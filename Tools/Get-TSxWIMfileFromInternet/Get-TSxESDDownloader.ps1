<#
.SYNOPSIS
Downloads an ESD from a URL or catalog item and can optionally call the WIM converter script.

.DESCRIPTION
Resolves an ESD download source from direct parameters or a piped catalog object,
downloads the ESD to a target folder, and can hand off conversion to
Convert-TSxToWIM.ps1 when WIM output is requested.

.PARAMETER CatalogItem
Optional input object that can provide FilePath and FileName properties.

.PARAMETER Url
Direct source URL to the ESD file.

.PARAMETER FileName
Optional target file name for the downloaded ESD.

.PARAMETER OutputPath
Folder where the ESD file will be stored.

.PARAMETER ConvertToWim
When set, calls Convert-TSxToWIM.ps1 to convert the downloaded ESD to WIM.

.PARAMETER WimPath
Optional destination path for the WIM file.

.PARAMETER Force
Overwrites existing ESD or WIM files.

.EXAMPLE
.\Get-TSxESDDownloader.ps1 -Url "https://example.com/install.esd" -ConvertToWim

.NOTES
Version: 1.1.0
Date: 2026-05-18
#>
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
Write-TSxLog -Message "Script start. ConvertToWim=$($ConvertToWim.IsPresent); OutputPath=$OutputPath"

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

function Save-EsdFile {
	[CmdletBinding(SupportsShouldProcess = $true)]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Url,

		[Parameter(Mandatory = $true)]
		[string]$DestinationPath,

		[switch]$Force
	)

	function Get-RemoteFileSize {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$Url
		)

		$headResponse = $null
		try {
			$headResponse = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -ErrorAction Stop
		} catch {
			# Some endpoints do not support HEAD; skip size comparison in that case.
			return $null
		}

		$contentLengthHeader = $headResponse.Headers['Content-Length']
		if (-not $contentLengthHeader) {
			return $null
		}

		$parsedLength = 0L
		if ([long]::TryParse([string]$contentLengthHeader, [ref]$parsedLength)) {
			return $parsedLength
		}

		return $null
	}

	function Invoke-EsdDownload {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$Url,

			[Parameter(Mandatory = $true)]
			[string]$DestinationPath
		)

		$bitsCommand = Get-Command -Name Start-BitsTransfer -ErrorAction SilentlyContinue
		if ($bitsCommand) {
			Write-Verbose "Downloading with Start-BitsTransfer: $DestinationPath"
			Start-BitsTransfer -Source $Url -Destination $DestinationPath -Description "Download $([System.IO.Path]::GetFileName($DestinationPath))" -DisplayName 'Get-TSxESDDownloader' -ErrorAction Stop
			return
		}

		Write-Verbose "Start-BitsTransfer is not available, falling back to Invoke-WebRequest: $DestinationPath"
		Invoke-WebRequest -Uri $Url -OutFile $DestinationPath -UseBasicParsing -ErrorAction Stop
	}

	$destinationDirectory = Split-Path -Path $DestinationPath -Parent
	if (-not (Test-Path -Path $destinationDirectory)) {
		New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null
	}

	if ((Test-Path -Path $DestinationPath) -and -not $Force) {
		$existingFile = Get-Item -Path $DestinationPath -ErrorAction Stop
		$remoteSize = Get-RemoteFileSize -Url $Url

		if ($null -ne $remoteSize -and $existingFile.Length -eq $remoteSize) {
			Write-Verbose "Skipping download because existing file size matches remote size: $DestinationPath"
			return $DestinationPath
		}

		if ($null -eq $remoteSize) {
			Write-Verbose "Remote file size could not be determined, downloading to ensure latest file: $DestinationPath"
		} else {
			Write-Verbose "Existing file size differs from remote file size, downloading again: $DestinationPath"
		}
	}

	if ((Test-Path -Path $DestinationPath) -and $Force) {
		Write-Verbose "Force specified, removing existing file before download: $DestinationPath"
		Write-TSxLog -Level 'WARN' -Message "Force enabled, removing existing file: $DestinationPath"
		Remove-Item -Path $DestinationPath -Force
	}

	if ($PSCmdlet.ShouldProcess($DestinationPath, "Download from $Url")) {
		Write-TSxLog -Message "Downloading $Url to $DestinationPath"
		Invoke-EsdDownload -Url $Url -DestinationPath $DestinationPath
		Write-TSxLog -Message "Download complete: $DestinationPath"
	}

	return $DestinationPath
}

try {
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
		Write-TSxLog -Message "Resolved source URL=$($source.Url); FileName=$($source.FileName)"

		$esdPath = Join-Path $OutputPath $source.FileName
		$downloadedPath = Save-EsdFile -Url $source.Url -DestinationPath $esdPath -Force:$Force -WhatIf:$WhatIfPreference

		if ($ConvertToWim) {
			$converterScript = Join-Path $PSScriptRoot 'Convert-TSxToWIM.ps1'
			if (-not (Test-Path -Path $converterScript)) {
				Write-TSxLog -Level 'ERROR' -Message "Required converter script not found: $converterScript"
				throw "Required converter script not found: $converterScript"
			}

			$resolvedWimPath = if ([string]::IsNullOrWhiteSpace($WimPath)) { [System.IO.Path]::ChangeExtension($downloadedPath, '.wim') } else { $WimPath }
			if (-not $WhatIfPreference) {
				Write-TSxLog -Message "Starting converter script for ESD=$downloadedPath WIM=$resolvedWimPath"
				$null = & $converterScript -EsdPath $downloadedPath -WimPath $resolvedWimPath -Force:$Force -Verbose:$($VerbosePreference -ne 'SilentlyContinue')
				Write-TSxLog -Message "Converter script completed for ESD=$downloadedPath"
			}
		}

		[PSCustomObject]@{
			SourceUrl     = $source.Url
			FileName      = $source.FileName
			EsdPath       = $downloadedPath
			DownloadedPath = $downloadedPath
			OutputPath    = $OutputPath
		}
	}
} catch {
	Write-TSxLog -Level 'ERROR' -Message "Unhandled error: $($_.Exception.Message)"
	throw
} finally {
	Write-TSxLog -Message 'Script end.'
}