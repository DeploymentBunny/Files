<#
.SYNOPSIS
Downloads an ESD from a URL or catalog item.

.DESCRIPTION
Resolves an ESD download source from direct parameters or a piped catalog object,
and downloads the ESD to a target folder.

.PARAMETER CatalogItem
Optional input object that can provide FilePath and FileName properties.

.PARAMETER Url
Direct source URL to the ESD file.

.PARAMETER FileName
Optional target file name for the downloaded ESD, a full destination path, or a destination folder path.

.PARAMETER OutputPath
Folder where the ESD file will be stored.

.PARAMETER Force
Overwrites existing ESD files.

.EXAMPLE
.\Get-TSxESDDownload.ps1 -Url "https://example.com/install.esd"

.NOTES
	FileName:    Get-TSxESDDownload.ps1
	Version:     1.3.1
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
[CmdletBinding(SupportsShouldProcess = $true)]
param(
	[Parameter(ValueFromPipeline = $true)]
	[object]$CatalogItem,

	[string]$Url,
	[string]$FileName,
	[string]$OutputPath = (Join-Path $PSScriptRoot 'Downloads'),
	[switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:LogRootPath = Join-Path $env:TEMP 'Get-TSxWIMfileFromInternet'
$Script:LogFilePath = Join-Path $Script:LogRootPath ("{0}.log" -f [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath))

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
	Add-Content -Path $Script:LogFilePath -Value $entry

	if ($WriteVerbose) {
		Write-Verbose $entry
	}
}

if (-not (Test-Path -Path $Script:LogRootPath)) {
	New-Item -Path $Script:LogRootPath -ItemType Directory -Force | Out-Null
}
Write-TSxLog -Message "Script start. OutputPath=$OutputPath" -WriteVerbose

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

function Resolve-DestinationPath {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$ResolvedFileName,

		[Parameter(Mandatory = $true)]
		[string]$OutputPath,

		[Parameter(Mandatory = $true)]
		[string]$SourceUrl
	)

	$derivedLeafName = [System.IO.Path]::GetFileName(($SourceUrl -split '\?')[0])
	if ([string]::IsNullOrWhiteSpace($derivedLeafName)) {
		$derivedLeafName = 'download.esd'
	}

	if (-not [System.IO.Path]::IsPathRooted($ResolvedFileName)) {
		return (Join-Path $OutputPath $ResolvedFileName)
	}

	$directoryHint = $ResolvedFileName.EndsWith([System.IO.Path]::DirectorySeparatorChar) -or $ResolvedFileName.EndsWith([System.IO.Path]::AltDirectorySeparatorChar)
	$existingContainer = (Test-Path -Path $ResolvedFileName -PathType Container)
	if ($directoryHint -or $existingContainer) {
		return (Join-Path $ResolvedFileName $derivedLeafName)
	}

	return $ResolvedFileName
}

function Test-SufficientDiskSpace {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$TargetPath,

		[Parameter(Mandatory = $true)]
		[long]$RequiredBytes
	)

	$root = [System.IO.Path]::GetPathRoot($TargetPath)
	$drive = Get-PSDrive -Name ($root.TrimEnd('\').TrimEnd(':')) -ErrorAction SilentlyContinue
	if ($null -eq $drive) {
		$drive = Get-PSDrive | Where-Object { $_.Root -eq $root } | Select-Object -First 1
	}

	$freeBytes = $null
	if ($null -ne $drive -and $null -ne $drive.Free) {
		$freeBytes = $drive.Free
	} else {
		try {
			$driveInfo = New-Object System.IO.DriveInfo($root)
			$freeBytes = $driveInfo.AvailableFreeSpace
		} catch {
			Write-TSxLog -Level 'WARN' -Message "Unable to determine free space on $root. Skipping space check." -WriteVerbose
			return
		}
	}

	$requiredGB = [math]::Round($RequiredBytes / 1GB, 1)
	$freeGB = [math]::Round($freeBytes / 1GB, 1)
	Write-TSxLog -Message "Disk space check. Drive=$root Required=${requiredGB}GB Free=${freeGB}GB" -WriteVerbose

	if ($freeBytes -lt $RequiredBytes) {
		Write-Host "`n" -NoNewline
		Write-Host "----------------------------------------------------------------------" -ForegroundColor Red
		Write-Host "ERROR: Not enough disk space" -ForegroundColor Red -BackgroundColor Black
		Write-Host "----------------------------------------------------------------------" -ForegroundColor Red
		Write-Host "Drive:          $root" -ForegroundColor Red
		Write-Host "Space Required: ${requiredGB} GB" -ForegroundColor Red
		Write-Host "Space Available: ${freeGB} GB" -ForegroundColor Yellow
		Write-Host "----------------------------------------------------------------------" -ForegroundColor Red
		Write-Host "Please select another path or free up space." -ForegroundColor Red
		Write-Host "----------------------------------------------------------------------" -ForegroundColor Red
		Write-Host "`n" -NoNewline
		Write-TSxLog -Level 'ERROR' -Message "Insufficient disk space. Required: ${requiredGB} GB, Available: ${freeGB} GB on $root" -WriteVerbose
		exit 1
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

		function Test-IsInsufficientDiskSpaceError {
			[CmdletBinding()]
			param(
				[Parameter(Mandatory = $true)]
				[string]$Message
			)

			return ($Message -match '(?i)not enough space|insufficient disk space|disk full|0x80070070')
		}

		$bitsCommand = Get-Command -Name Start-BitsTransfer -ErrorAction SilentlyContinue
		if ($bitsCommand) {
			$maxBitsAttempts = 10
			for ($attempt = 1; $attempt -le $maxBitsAttempts; $attempt++) {
				Write-Verbose "Downloading with Start-BitsTransfer (attempt $attempt/$maxBitsAttempts): $DestinationPath"
				try {
					Start-BitsTransfer -Source $Url -Destination $DestinationPath -Description "Download $([System.IO.Path]::GetFileName($DestinationPath))" -DisplayName 'Get-TSxESDDownload' -ErrorAction Stop
					return
				} catch {
					$errorMessage = [string]$_.Exception.Message
					Write-TSxLog -Level 'WARN' -Message "Start-BitsTransfer attempt $attempt failed. $errorMessage" -WriteVerbose
					if (Test-Path -Path $DestinationPath -PathType Leaf) {
						Remove-Item -Path $DestinationPath -Force -ErrorAction SilentlyContinue
					}

					if (Test-IsInsufficientDiskSpaceError -Message $errorMessage) {
						Write-TSxLog -Level 'ERROR' -Message "BITS failed due to insufficient disk space at destination. Retries and fallback skipped. DestinationPath=$DestinationPath" -WriteVerbose
						throw "Insufficient disk space for download destination: $DestinationPath"
					}

					if ($attempt -eq $maxBitsAttempts) {
						Write-TSxLog -Level 'WARN' -Message 'Start-BitsTransfer retries exhausted, falling back to Invoke-WebRequest.' -WriteVerbose
					}
				}
			}
		}

		Write-Verbose "Start-BitsTransfer is not available, falling back to Invoke-WebRequest: $DestinationPath"
		Invoke-WebRequest -Uri $Url -OutFile $DestinationPath -UseBasicParsing -ErrorAction Stop
	}

	$destinationDirectory = Split-Path -Path $DestinationPath -Parent
	if (-not (Test-Path -Path $destinationDirectory)) {
		New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null
	}

	$remoteFileSizeForSpaceCheck = Get-RemoteFileSize -Url $Url
	if ($null -ne $remoteFileSizeForSpaceCheck) {
		$safetyBufferBytes = 5GB
		$requiredBytes = $remoteFileSizeForSpaceCheck + $safetyBufferBytes
		Test-SufficientDiskSpace -TargetPath $DestinationPath -RequiredBytes $requiredBytes
	} else {
		Write-TSxLog -Level 'WARN' -Message 'Remote file size could not be determined; skipping pre-flight disk space check.' -WriteVerbose
	}

	if (Test-Path -Path $DestinationPath -PathType Container) {
		throw "Destination path points to a directory, expected a file path: $DestinationPath"
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

function Test-ExecutionPrerequisites {
	[CmdletBinding()]
	param()

	if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
		throw 'This script requires Windows PowerShell 5.1.'
	}

	$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
	$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
	if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
		throw 'This script must be run from an elevated Windows PowerShell 5.1 session (Run as Administrator).'
	}
}

try {
	Test-ExecutionPrerequisites
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

		$esdPath = Resolve-DestinationPath -ResolvedFileName $source.FileName -OutputPath $OutputPath -SourceUrl $source.Url
		Write-TSxLog -Message "Resolved destination path: $esdPath" -WriteVerbose
		$downloadedPath = Save-EsdFile -Url $source.Url -DestinationPath $esdPath -Force:$Force -WhatIf:$WhatIfPreference

		[PSCustomObject]@{
			SourceUrl     = $source.Url
			FileName      = $source.FileName
			EsdPath       = $downloadedPath
			DownloadedPath = $downloadedPath
			OutputPath    = Split-Path -Path $downloadedPath -Parent
		}
	}
} catch {
	Write-TSxLog -Level 'ERROR' -Message "Unhandled error: $($_.Exception.Message)" -WriteVerbose
	throw
} finally {
	Write-TSxLog -Message 'Script end.' -WriteVerbose
}