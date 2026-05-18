<#
.SYNOPSIS
Converts an ESD file to a WIM file.

.DESCRIPTION
Accepts an ESD path directly or from a piped object, reads the available image
indexes, and exports them to a WIM file with visible progress reporting.

.PARAMETER InputObject
Optional piped object that contains an EsdPath, FilePath, or FullName property.

.PARAMETER EsdPath
Path to the source ESD file.

.PARAMETER WimPath
Optional destination path for the WIM file. If omitted, the script uses the
same path as the ESD file and changes the extension to .wim.

.PARAMETER Force
Overwrites an existing WIM file.

.PARAMETER Index
Optional image index list to export from the ESD (for example 1,2,3).
If omitted, all image indexes are exported.

.EXAMPLE
.\Convert-TSxToWIM.ps1 -EsdPath "C:\Temp\ESD\install.esd"

.EXAMPLE
$download | .\Convert-TSxToWIM.ps1 -Verbose

.EXAMPLE
.\Convert-TSxToWIM.ps1 -EsdPath "C:\Temp\ESD\install.esd" -WimPath "C:\Temp\ESD\install.wim" -Index 1,2,3

.NOTES
Version: 1.0.6
Date: 2026-05-18
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
	[Parameter(ValueFromPipeline = $true)]
	[object]$InputObject,

	[string]$EsdPath,
	[string]$WimPath,
	[int[]]$Index,
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
Write-TSxLog -Message 'Script start.'

function Write-ConversionStatus {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Message
	)

	Write-Host "[Convert-TSxToWIM] $Message"
	Write-TSxLog -Message $Message
}

function Test-IsAdministrator {
	[CmdletBinding()]
	param()

	$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
	$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
	return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-EsdSourcePath {
	[CmdletBinding()]
	param(
		[object]$InputObject,
		[string]$EsdPath
	)

	if (-not [string]::IsNullOrWhiteSpace($EsdPath)) {
		return $EsdPath
	}

	if (-not $InputObject) {
		throw 'No ESD path was provided. Pass -EsdPath or pipe an object with an EsdPath property.'
	}

	foreach ($propertyName in @('EsdPath', 'FilePath', 'FullName')) {
		$property = $InputObject.PSObject.Properties[$propertyName]
		if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
			return [string]$property.Value
		}
	}

	if ($InputObject -is [string] -and -not [string]::IsNullOrWhiteSpace($InputObject)) {
		return [string]$InputObject
	}

	throw 'Unable to resolve ESD path from pipeline input. Use -EsdPath or pipe an object with EsdPath, FilePath, or FullName.'
}

function Get-EsdImageInfo {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$EsdPath
	)

	try {
		return @(Get-WindowsImage -ImagePath $EsdPath -ErrorAction Stop)
	} catch {
		throw "Get-WindowsImage failed while reading ESD metadata from $EsdPath. $($_.Exception.Message)"
	}
}

function Test-HealthyMountedImages {
	[CmdletBinding()]
	param()

	$mountedImages = @()
	try {
		$mountedImages = @(Get-WindowsImage -Mounted -ErrorAction Stop)
	} catch {
		throw "Unable to query mounted Windows images before conversion. $($_.Exception.Message)"
	}

	if ($mountedImages.Count -eq 0) {
		return
	}

	$potentiallyBroken = New-Object System.Collections.Generic.List[object]
	foreach ($mountedImage in $mountedImages) {
		$mountStatus = ''
		if ($mountedImage.PSObject.Properties['MountStatus']) {
			$mountStatus = [string]$mountedImage.MountStatus
		} elseif ($mountedImage.PSObject.Properties['Status']) {
			$mountStatus = [string]$mountedImage.Status
		}

		$path = $null
		if ($mountedImage.PSObject.Properties['Path']) {
			$path = [string]$mountedImage.Path
		}

		$pathMissing = $false
		if (-not [string]::IsNullOrWhiteSpace($path)) {
			$pathMissing = -not (Test-Path -Path $path)
		}

		$statusLooksBad = -not [string]::IsNullOrWhiteSpace($mountStatus) -and ($mountStatus -notmatch '^(Ok|Mounted)$')
		if ($statusLooksBad -or $pathMissing) {
			$potentiallyBroken.Add([PSCustomObject]@{
				ImagePath   = [string]$mountedImage.ImagePath
				Path        = $path
				MountStatus = $mountStatus
			})
		}
	}

	if ($potentiallyBroken.Count -gt 0) {
		$brokenSummary = $potentiallyBroken | ForEach-Object {
			"ImagePath='$($_.ImagePath)', Path='$($_.Path)', MountStatus='$($_.MountStatus)'"
		}

		throw "Broken or stale mounted image(s) were detected before conversion: $($brokenSummary -join '; '). Clean up mounted images and retry."
	}
}

function Convert-EsdPathToWim {
	[CmdletBinding(SupportsShouldProcess = $true)]
	param(
		[Parameter(Mandatory = $true)]
		[string]$EsdPath,

		[Parameter(Mandatory = $true)]
		[string]$WimPath,

		[int[]]$Index,

		[switch]$Force
	)

	if (-not (Test-Path -Path $EsdPath)) {
		throw "ESD file not found: $EsdPath"
	}

	Write-ConversionStatus "Preparing conversion. Source: $EsdPath | Destination: $WimPath"

	if (-not (Test-IsAdministrator)) {
		Write-TSxLog -Level 'ERROR' -Message 'Administrator privileges are required for ESD to WIM conversion.'
		throw 'Administrator privileges are required for ESD to WIM conversion. Start PowerShell as Administrator and run the command again.'
	}

	Write-ConversionStatus 'Administrator check passed.'
	Write-ConversionStatus 'Checking mounted image health...'
	$mountedCheckStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
	Test-HealthyMountedImages
	$mountedCheckStopwatch.Stop()
	Write-ConversionStatus "Mounted image health check passed in $($mountedCheckStopwatch.Elapsed.TotalSeconds.ToString('0.0')) second(s)."

	$wimDirectory = Split-Path -Path $WimPath -Parent
	if (-not (Test-Path -Path $wimDirectory)) {
		New-Item -Path $wimDirectory -ItemType Directory -Force | Out-Null
	}

	if ((Test-Path -Path $WimPath) -and -not $Force) {
		Write-ConversionStatus "WIM already exists, skipping conversion: $WimPath"
		Write-Verbose "WIM file already exists and Force was not specified: $WimPath"
		return $WimPath
	}

	if ((Test-Path -Path $WimPath) -and $Force) {
		Write-ConversionStatus "Force enabled, removing existing WIM: $WimPath"
		Write-TSxLog -Level 'WARN' -Message "Force enabled, removing WIM file: $WimPath"
		Write-Verbose "Force specified, removing existing WIM file before conversion: $WimPath"
		Remove-Item -Path $WimPath -Force
	}

	Write-ConversionStatus 'Reading ESD image metadata...'
	$metadataStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
	$images = Get-EsdImageInfo -EsdPath $EsdPath
	$metadataStopwatch.Stop()
	Write-ConversionStatus "ESD metadata loaded in $($metadataStopwatch.Elapsed.TotalSeconds.ToString('0.0')) second(s)."
	if ($images.Count -eq 0) {
		throw "No image indexes were found in $EsdPath"
	}

	$imagesToExport = @($images)
	if ($PSBoundParameters.ContainsKey('Index') -and $Index.Count -gt 0) {
		$availableIndexes = @($images | ForEach-Object { [int]$_.ImageIndex })
		$requestedIndexes = @($Index | Select-Object -Unique)
		$missingIndexes = @($requestedIndexes | Where-Object { $_ -notin $availableIndexes })
		if ($missingIndexes.Count -gt 0) {
			throw "Requested image index(es) were not found in $EsdPath: $($missingIndexes -join ', ')"
		}

		$imagesToExport = @($images | Where-Object { [int]$_.ImageIndex -in $requestedIndexes })
		Write-ConversionStatus "Index filter applied. Exporting index(es): $($requestedIndexes -join ', ')"
	}

	Write-ConversionStatus "Starting conversion of $EsdPath to $WimPath ($($imagesToExport.Count) image index(es))."

	$totalImages = $imagesToExport.Count
	$currentImage = 0
	foreach ($image in $imagesToExport) {
		$currentImage++
		$index = [int]$image.ImageIndex
		$imageLabel = if ([string]::IsNullOrWhiteSpace([string]$image.ImageName)) { "Index $index" } else { "Index $index - $($image.ImageName)" }
		Write-ConversionStatus "Exporting $imageLabel ($currentImage/$totalImages)..."
		$percentComplete = [int](($currentImage / $totalImages) * 100)
		Write-Progress -Id 1 -Activity 'Converting ESD to WIM' -Status "Exporting $imageLabel ($currentImage of $totalImages)" -PercentComplete $percentComplete
		Write-Verbose "Converting $imageLabel to $WimPath ($currentImage of $totalImages)"

		$action = "Export index $index from $EsdPath"
		if ($PSCmdlet.ShouldProcess($WimPath, $action)) {
			try {
				Export-WindowsImage -SourceImagePath $EsdPath -SourceIndex $index -DestinationImagePath $WimPath -CompressionType Max -CheckIntegrity -ErrorAction Stop | Out-Null
			} catch {
				Write-Progress -Id 1 -Activity 'Converting ESD to WIM' -Completed
				Write-TSxLog -Level 'ERROR' -Message "Export-WindowsImage failed for index $index. $($_.Exception.Message)"
				throw "Export-WindowsImage failed while exporting index $index from $EsdPath. $($_.Exception.Message)"
			}
		}
	}

	Write-Progress -Id 1 -Activity 'Converting ESD to WIM' -Completed
	Write-ConversionStatus "Conversion completed: $WimPath"
	return $WimPath
}

try {
	$items = New-Object System.Collections.Generic.List[object]
	if ($MyInvocation.ExpectingInput) {
		foreach ($item in $input) {
			$items.Add($item)
		}
	} elseif ($PSBoundParameters.ContainsKey('InputObject')) {
		$items.Add($InputObject)
	}

	if ($items.Count -eq 0) {
		$items.Add($null)
	}

	foreach ($item in $items) {
		$resolvedEsdPath = Resolve-EsdSourcePath -InputObject $item -EsdPath $EsdPath
		$resolvedWimPath = if ([string]::IsNullOrWhiteSpace($WimPath)) { [System.IO.Path]::ChangeExtension($resolvedEsdPath, '.wim') } else { $WimPath }
		$indexText = if ($PSBoundParameters.ContainsKey('Index') -and $Index.Count -gt 0) { $Index -join ',' } else { 'all' }
		Write-TSxLog -Message "Resolved conversion job. EsdPath=$resolvedEsdPath; WimPath=$resolvedWimPath; Index=$indexText"
		$finalWimPath = Convert-EsdPathToWim -EsdPath $resolvedEsdPath -WimPath $resolvedWimPath -Index $Index -Force:$Force -WhatIf:$WhatIfPreference

		[PSCustomObject]@{
			EsdPath   = $resolvedEsdPath
			WimPath   = $finalWimPath
			Converted = $true
		}
	}
} catch {
	Write-TSxLog -Level 'ERROR' -Message "Unhandled error: $($_.Exception.Message)"
	throw
} finally {
	Write-TSxLog -Message 'Script end.'
}