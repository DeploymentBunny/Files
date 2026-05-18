<#
.SYNOPSIS
Gets image information from an ESD file.

.DESCRIPTION
Reads an ESD file and returns the list of contained image indexes and details.
Accepts an ESD path directly or from pipeline input objects.

.PARAMETER InputObject
Optional piped object that contains an EsdPath, FilePath, or FullName property.

.PARAMETER EsdPath
Path to the source ESD file.

.EXAMPLE
.\Get-TSxESDInfo.ps1 -EsdPath "C:\Temp\ESD\install.esd"

.EXAMPLE
$download | .\Get-TSxESDInfo.ps1

.NOTES
Version: 1.0.7
Date: 2026-05-18
#>
[CmdletBinding()]
param(
	[Parameter(ValueFromPipeline = $true)]
	[object]$InputObject,

	[string]$EsdPath
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

function Write-InfoStatus {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Message
	)

	Write-Host "[Get-TSxESDInfo] $Message"
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

function Get-OptionalPropertyValue {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[object]$InputObject,

		[Parameter(Mandatory = $true)]
		[string]$PropertyName
	)

	$property = $InputObject.PSObject.Properties[$PropertyName]
	if ($null -eq $property) {
		return $null
	}

	return $property.Value
}

function Get-EsdImageInfo {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$EsdPath
	)

	if (-not (Test-Path -Path $EsdPath)) {
		throw "ESD file not found: $EsdPath"
	}

	try {
		return @(Get-WindowsImage -ImagePath $EsdPath -ErrorAction Stop)
	} catch {
		throw "Get-WindowsImage failed while reading ESD metadata from $EsdPath. $($_.Exception.Message)"
	}
}

function Test-HealthyMountedImages {
	[CmdletBinding()]
	param()

	$startInfo = New-Object System.Diagnostics.ProcessStartInfo
	$startInfo.FileName = 'dism.exe'
	$startInfo.Arguments = '/English /Get-MountedWimInfo'
	$startInfo.UseShellExecute = $false
	$startInfo.RedirectStandardOutput = $true
	$startInfo.RedirectStandardError = $true
	$startInfo.CreateNoWindow = $true

	$process = New-Object System.Diagnostics.Process
	$process.StartInfo = $startInfo
	if (-not $process.Start()) {
		throw 'Unable to start DISM while checking mounted Windows images.'
	}

	if (-not $process.WaitForExit(15000)) {
		try {
			$process.Kill()
		} catch {
		}

		throw 'Timed out while checking mounted Windows images. DISM may be blocked by a stale mount state.'
	}

	$standardOutput = $process.StandardOutput.ReadToEnd()
	$standardError = $process.StandardError.ReadToEnd()
	if ($process.ExitCode -ne 0) {
		$failureText = ($standardError, $standardOutput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' '
		throw "Unable to query mounted Windows images before reading ESD metadata. $failureText"
	}

	if ($standardOutput -match 'No mounted images found\.') {
		return
	}

	$mountedImages = New-Object System.Collections.Generic.List[object]
	$currentImage = $null
	foreach ($line in ($standardOutput -split "`r?`n")) {
		if ($line -match '^Mount Dir\s*:\s*(.+)$') {
			if ($null -ne $currentImage) {
				$mountedImages.Add($currentImage)
			}

			$currentImage = [PSCustomObject]@{
				ImagePath   = $null
				Path        = $Matches[1].Trim()
				MountStatus = ''
			}
			continue
		}

		if ($null -eq $currentImage) {
			continue
		}

		if ($line -match '^Image File\s*:\s*(.+)$') {
			$currentImage.ImagePath = $Matches[1].Trim()
			continue
		}

		if ($line -match '^Mount Status\s*:\s*(.+)$') {
			$currentImage.MountStatus = $Matches[1].Trim()
		}
	}

	if ($null -ne $currentImage) {
		$mountedImages.Add($currentImage)
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

		throw "Broken or stale mounted image(s) were detected before reading ESD metadata: $($brokenSummary -join '; '). Clean up mounted images and retry."
	}
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
		Write-InfoStatus "Preparing ESD info read. Source: $resolvedEsdPath"

		if (-not (Test-IsAdministrator)) {
			Write-TSxLog -Level 'ERROR' -Message 'Administrator privileges are required to read ESD metadata.'
			throw 'Administrator privileges are required to read ESD metadata. Start PowerShell as Administrator and run the command again.'
		}

		Write-InfoStatus 'Administrator check passed.'
		Write-InfoStatus 'Checking mounted image health...'
		$mountedCheckStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
		try {
			Test-HealthyMountedImages
			$mountedCheckStopwatch.Stop()
			Write-InfoStatus "Mounted image health check passed in $($mountedCheckStopwatch.Elapsed.TotalSeconds.ToString('0.0')) second(s)."
		} catch {
			$mountedCheckStopwatch.Stop()
			Write-TSxLog -Level 'WARN' -Message "Mounted image health check could not be completed: $($_.Exception.Message)"
			Write-InfoStatus "Mounted image health check could not be completed after $($mountedCheckStopwatch.Elapsed.TotalSeconds.ToString('0.0')) second(s). Continuing anyway."
		}
		Write-InfoStatus 'Reading ESD image metadata...'
		$metadataStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

		$images = Get-EsdImageInfo -EsdPath $resolvedEsdPath
		$metadataStopwatch.Stop()
		Write-InfoStatus "ESD metadata loaded in $($metadataStopwatch.Elapsed.TotalSeconds.ToString('0.0')) second(s)."
		Write-InfoStatus "Found $(@($images).Count) image index(es) in ESD."

		foreach ($image in $images | Sort-Object ImageIndex) {
			[PSCustomObject]@{
				EsdPath      = $resolvedEsdPath
				ImageIndex   = [int](Get-OptionalPropertyValue -InputObject $image -PropertyName 'ImageIndex')
				ImageName    = [string](Get-OptionalPropertyValue -InputObject $image -PropertyName 'ImageName')
				ImageDescription = [string](Get-OptionalPropertyValue -InputObject $image -PropertyName 'ImageDescription')
			}
		}
	}
} catch {
	Write-TSxLog -Level 'ERROR' -Message "Unhandled error: $($_.Exception.Message)"
	throw
} finally {
	Write-TSxLog -Message 'Script end.'
}
