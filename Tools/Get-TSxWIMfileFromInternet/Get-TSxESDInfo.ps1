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
Version: 1.0.1
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
		Write-InfoStatus 'Reading ESD image metadata...'
		$metadataStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

		$images = Get-EsdImageInfo -EsdPath $resolvedEsdPath
		$metadataStopwatch.Stop()
		Write-InfoStatus "ESD metadata loaded in $($metadataStopwatch.Elapsed.TotalSeconds.ToString('0.0')) second(s)."
		Write-InfoStatus "Found $(@($images).Count) image index(es) in ESD."

		foreach ($image in $images | Sort-Object ImageIndex) {
			[PSCustomObject]@{
				EsdPath      = $resolvedEsdPath
				ImageIndex   = [int]$image.ImageIndex
				ImageName    = [string]$image.ImageName
				ImageDescription = [string]$image.ImageDescription
				Architecture = [string]$image.Architecture
				EditionId    = [string]$image.EditionId
				Version      = [string]$image.Version
				Build        = [string]$image.Build
				CreatedTime  = $image.CreatedTime
				ModifiedTime = $image.ModifiedTime
				Languages    = if ($image.Languages) { ($image.Languages -join ',') } else { $null }
			}
		}
	}
} catch {
	Write-TSxLog -Level 'ERROR' -Message "Unhandled error: $($_.Exception.Message)"
	throw
} finally {
	Write-TSxLog -Message 'Script end.'
}
