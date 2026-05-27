<#
.SYNOPSIS
Invokes ESD download from a URL or catalog item.

.DESCRIPTION
Resolves an ESD download source from direct parameters or a piped catalog object,
then downloads the ESD to a target folder.

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

.PARAMETER NoProgress
Suppresses host progress output.

.EXAMPLE
.\Invoke-TSxESDDownload.ps1 -Url "https://example.com/install.esd"

.NOTES
	FileName:    Invoke-TSxESDDownload.ps1
	Version:     1.3.4
	Author:      Mikael Nystrom
	Contact:     deploymentbunny@outlook.com
	Created:     2026-04-23
	Updated:     2026-05-25
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
	[switch]$Force,
	[switch]$NoProgress
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
		$spaceMessage = "Insufficient disk space. Drive: $root Required: ${requiredGB} GB Available: ${freeGB} GB"
		Write-TSxLog -Level 'ERROR' -Message $spaceMessage -WriteVerbose
		throw $spaceMessage
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

		function Get-BitsJobIdentifier {
			[CmdletBinding()]
			param(
				[Parameter(Mandatory = $true)]
				[object]$BitsJob
			)

			if ($BitsJob.PSObject.Properties['JobId'] -and $BitsJob.JobId) {
				return $BitsJob.JobId
			}

			if ($BitsJob.PSObject.Properties['Id'] -and $BitsJob.Id) {
				return $BitsJob.Id
			}

			return $null
		}

		function Invoke-HttpDownload {
			[CmdletBinding()]
			param(
				[Parameter(Mandatory = $true)]
				[string]$Url,

				[Parameter(Mandatory = $true)]
				[string]$DestinationPath
			)

			$response = $null
			$responseStream = $null
			$fileStream = $null

			try {
				$request = [System.Net.HttpWebRequest]::Create($Url)
				$request.Method = 'GET'
				$response = $request.GetResponse()
				$responseStream = $response.GetResponseStream()
				$fileStream = [System.IO.File]::Open($DestinationPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

				$buffer = New-Object byte[] 81920
				$totalBytes = [int64]$response.ContentLength
				$totalRead = [int64]0

				while (($bytesRead = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
					$fileStream.Write($buffer, 0, $bytesRead)
					$totalRead += $bytesRead

					if ($totalBytes -gt 0) {
						$percentComplete = [int](($totalRead * 100) / $totalBytes)
						$status = '{0:N1} MB / {1:N1} MB' -f ($totalRead / 1MB), ($totalBytes / 1MB)
						Write-TSxProgress -Id 1301 -Activity 'Downloading ESD file' -Status $status -PercentComplete $percentComplete
					}
					else {
						Write-TSxProgress -Id 1301 -Activity 'Downloading ESD file' -Status ('{0:N1} MB downloaded' -f ($totalRead / 1MB))
					}
				}
			}
			finally {
				if ($fileStream) { $fileStream.Dispose() }
				if ($responseStream) { $responseStream.Dispose() }
				if ($response) { $response.Dispose() }
			}
		}

		$bitsCommand = Get-Command -Name Start-BitsTransfer -ErrorAction SilentlyContinue
		if ($bitsCommand) {
			$maxBitsAttempts = 10
			for ($attempt = 1; $attempt -le $maxBitsAttempts; $attempt++) {
				$bitsJob = $null
				Write-Verbose "Downloading with Start-BitsTransfer (attempt $attempt/$maxBitsAttempts): $DestinationPath"
				try {
					if ($NoProgress) {
						Start-BitsTransfer -Source $Url -Destination $DestinationPath -Description "Download $([System.IO.Path]::GetFileName($DestinationPath))" -DisplayName 'Invoke-TSxESDDownload' -ErrorAction Stop
					}
					else {
						Write-TSxProgress -Id 1301 -Activity 'Downloading ESD file' -Status ("Starting BITS attempt {0}/{1}" -f $attempt, $maxBitsAttempts)
						$bitsJob = Start-BitsTransfer -Source $Url -Destination $DestinationPath -Description "Download $([System.IO.Path]::GetFileName($DestinationPath))" -DisplayName 'Invoke-TSxESDDownload' -Asynchronous -ErrorAction Stop
						$bitsJobId = Get-BitsJobIdentifier -BitsJob $bitsJob
						if (-not $bitsJobId) {
							throw 'BITS did not return a valid job identifier.'
						}

						while ($true) {
							$bitsJob = Get-BitsTransfer -JobId $bitsJobId -ErrorAction Stop

							if ($bitsJob.BytesTotal -gt 0) {
								$percentComplete = [int](($bitsJob.BytesTransferred * 100) / $bitsJob.BytesTotal)
								$status = '{0:N1} MB / {1:N1} MB' -f ($bitsJob.BytesTransferred / 1MB), ($bitsJob.BytesTotal / 1MB)
								Write-TSxProgress -Id 1301 -Activity 'Downloading ESD file' -Status $status -PercentComplete $percentComplete
							}
							else {
								Write-TSxProgress -Id 1301 -Activity 'Downloading ESD file' -Status ('{0:N1} MB downloaded' -f ($bitsJob.BytesTransferred / 1MB))
							}

							if ($bitsJob.JobState -in @('Transferred', 'Acknowledged')) {
								Complete-BitsTransfer -BitsJob $bitsJob -ErrorAction Stop
								$bitsJob = $null
								break
							}

							if ($bitsJob.JobState -in @('Error', 'TransientError', 'Cancelled')) {
								$bitsError = if ($bitsJob.ErrorDescription) { $bitsJob.ErrorDescription } else { ('BITS state: {0}' -f $bitsJob.JobState) }
								Remove-BitsTransfer -BitsJob $bitsJob -ErrorAction SilentlyContinue
								throw $bitsError
							}

							[System.Threading.Thread]::Sleep(500)
						}
					}
					Complete-TSxProgress -Id 1301 -Activity 'Downloading ESD file'
					return
				} catch {
					$errorMessage = [string]$_.Exception.Message
					Write-TSxLog -Level 'WARN' -Message "Start-BitsTransfer attempt $attempt failed. $errorMessage" -WriteVerbose
					if (-not $NoProgress) {
						Write-TSxProgress -Id 1301 -Activity 'Downloading ESD file' -Status ("BITS attempt {0}/{1} failed" -f $attempt, $maxBitsAttempts)
					}
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
				} finally {
					if ($bitsJob) {
						try {
							$bitsJobId = Get-BitsJobIdentifier -BitsJob $bitsJob
							if ($bitsJobId) {
								$existingBitsJob = Get-BitsTransfer -JobId $bitsJobId -ErrorAction SilentlyContinue
								if ($existingBitsJob -and $existingBitsJob.JobState -notin @('Cancelled', 'Transferred', 'Acknowledged')) {
									Remove-BitsTransfer -BitsJob $existingBitsJob -ErrorAction SilentlyContinue
								}
							}
						} catch {
						}
					}
				}
			}
		}

		Write-Verbose "Start-BitsTransfer is not available, falling back to Invoke-WebRequest: $DestinationPath"
		Write-TSxProgress -Id 1301 -Activity 'Downloading ESD file' -Status 'Downloading with HTTP fallback'
		Invoke-HttpDownload -Url $Url -DestinationPath $DestinationPath
		Complete-TSxProgress -Id 1301 -Activity 'Downloading ESD file'
	}

	$destinationDirectory = Split-Path -Path $DestinationPath -Parent
	if (-not (Test-Path -Path $destinationDirectory)) {
		if ($PSCmdlet.ShouldProcess($destinationDirectory, 'Create destination directory')) {
			New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null
		} else {
			Write-TSxLog -Message "Skipping destination directory creation due to WhatIf: $destinationDirectory" -WriteVerbose
		}
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
		if ($PSCmdlet.ShouldProcess($DestinationPath, 'Remove existing file before download')) {
			Remove-Item -Path $DestinationPath -Force
		} else {
			Write-TSxLog -Message "Skipping file removal due to WhatIf: $DestinationPath" -WriteVerbose
		}
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

	$totalItems = $items.Count
	$itemIndex = 0
	foreach ($item in $items) {
		$itemIndex++
		$source = Resolve-DownloadSource -CatalogItem $item -Url $Url -FileName $FileName
		$itemPercentComplete = if ($totalItems -gt 0) { [int](($itemIndex / $totalItems) * 100) } else { 0 }
		Write-TSxProgress -Id 1300 -Activity 'Preparing ESD downloads' -Status ("Resolving download {0}/{1}: {2}" -f $itemIndex, $totalItems, [System.IO.Path]::GetFileName($source.FileName)) -PercentComplete $itemPercentComplete
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
	Complete-TSxProgress -Id 1300 -Activity 'Preparing ESD downloads'
} catch {
	Write-TSxLog -Level 'ERROR' -Message "Unhandled error: $($_.Exception.Message)" -WriteVerbose
	throw
} finally {
	Write-TSxLog -Message 'Script end.' -WriteVerbose
}