<#
.SYNOPSIS
	Injects MSU updates into an offline WIM or VHDX image.

.DESCRIPTION
	Mounts an image in place and injects one or more update packages (.msu/.cab) into the offline image using DISM.
	Supports WIM servicing through Mount-WindowsImage / Add-WindowsPackage / Dismount-WindowsImage,
	and VHDX servicing through Mount-VHD plus Add-WindowsPackage against the offline Windows volume.

.PARAMETER Image
	Path to the image file (.wim or .vhdx) to service in place.

.PARAMETER UpdatePath
	Path to a folder containing .msu/.cab files, or a direct path to a single .msu/.cab file.

.PARAMETER Index
	WIM index to service. Only used when the image is a .wim file. Default: 1.

.PARAMETER ScratchDirectory
	Optional scratch path used by DISM cmdlets.

.EXAMPLE
	.\Add-TSxUpdatesToImage.ps1 -Image C:\Images\install.wim -UpdatePath C:\Updates -Index 1 -Verbose

.EXAMPLE
	.\Add-TSxUpdatesToImage.ps1 -Image C:\Images\server.vhdx -UpdatePath C:\Updates -Verbose

.NOTES
	FileName:    Add-TSxUpdatesToImage.ps1
	Version:     1.0.7
	Author:      Mikael Nystrom
	Contact:     @mikael_nystrom
	Created:     2026-05-22
	Updated:     2026-05-27
	Twitter:     @mikael_nystrom

	Disclaimer:
	This script is provided "AS IS" with no warranties, confers no rights and
	is not supported by the author.
.LINK
	https://www.deploymentbunny.com

.FUNCTIONALITY
	Serves as an offline image servicing front end for injecting MSU/CAB updates into WIM and VHDX images.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
	[Parameter(Mandatory = $true)]
	[ValidateNotNullOrEmpty()]
	[string]$Image,

	[Parameter(Mandatory = $true)]
	[ValidateNotNullOrEmpty()]
	[string]$UpdatePath,

	[Parameter()]
	[ValidateRange(1, 999)]
	[int]$Index = 1,

	[Parameter()]
	[string]$ScratchDirectory
)

Import-Module -Name (Join-Path $PSScriptRoot 'Modules\TSxWindowsUpdateUtility\TSxWindowsUpdateUtility.psd1') -Force -ErrorAction Stop

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogRootPath = Join-Path $env:TEMP 'Get-TSxWindowsUpdate'
$script:LogFilePath = Join-Path $script:LogRootPath 'Add-TSxUpdatesToImage.log'

if (-not (Test-Path -Path $script:LogRootPath)) {
	$null = New-Item -Path $script:LogRootPath -ItemType Directory -Force
}

if (-not (Test-Path -Path $script:LogFilePath)) {
	$null = New-Item -Path $script:LogFilePath -ItemType File -Force
}

Write-TSxLog -Message ("Script start. Image={0}; UpdatePath={1}; Index={2}; WhatIf={3}" -f $Image, $UpdatePath, $Index, $WhatIfPreference)

Assert-TSxAdministrator

$imageItem = Get-Item -Path $Image -ErrorAction Stop
$imageExtension = $imageItem.Extension.ToLowerInvariant()
if ($imageExtension -notin @('.wim', '.vhdx')) {
	throw "Unsupported image type '$imageExtension'. Only .wim and .vhdx are supported."
}

$packages = Get-TSxMsuFiles -Path $UpdatePath
Write-TSxLog -Message "Discovered $($packages.Count) MSU package(s) to inject."

if ($ScratchDirectory) {
	if (-not (Test-Path -Path $ScratchDirectory)) {
		if ($PSCmdlet.ShouldProcess($ScratchDirectory, 'Create scratch directory')) {
			$null = New-Item -Path $ScratchDirectory -ItemType Directory -Force
		}
	}

	try {
		$resolvedScratchPath = (Resolve-Path -Path $ScratchDirectory -ErrorAction Stop).Path
		$scratchRoot = Split-Path -Path $resolvedScratchPath -Qualifier
		$minimumScratchFreeBytes = [int64]10GB

		if (-not [string]::IsNullOrWhiteSpace($scratchRoot)) {
			$driveName = $scratchRoot.TrimEnd(':', '\\')
			$scratchDrive = Get-PSDrive -Name $driveName -ErrorAction Stop
			$freeBytes = [int64]$scratchDrive.Free

			if ($freeBytes -lt $minimumScratchFreeBytes) {
				$freeGb = [math]::Round(($freeBytes / 1GB), 2)
				$minGb = [math]::Round(($minimumScratchFreeBytes / 1GB), 0)
				$warningMessage = ('ScratchDirectory "{0}" has only {1} GB free. At least {2} GB is recommended for offline servicing. Low free space can cause DISM failures or unstable servicing behavior.' -f $resolvedScratchPath, $freeGb, $minGb)
				Write-Warning $warningMessage
				Write-TSxLog -Level 'WARN' -Message $warningMessage
			}
			else {
				Write-TSxLog -Message ('ScratchDirectory free space check passed: {0} GB available at {1}.' -f [math]::Round(($freeBytes / 1GB), 2), $resolvedScratchPath)
			}
		}
	}
	catch {
		$spaceCheckWarning = ('Unable to validate free space for ScratchDirectory "{0}". Continue with caution. Error: {1}' -f $ScratchDirectory, $_.Exception.Message)
		Write-Warning $spaceCheckWarning
		Write-TSxLog -Level 'WARN' -Message $spaceCheckWarning
	}
}

$resolvedImage = $imageItem.FullName

if ($imageExtension -eq '.vhdx') {
	if (-not (Get-Command -Name Mount-VHD -ErrorAction SilentlyContinue)) {
		throw 'Mount-VHD is not available. Install/enable Hyper-V management tools to service VHDX images.'
	}
}

if ($PSCmdlet.ShouldProcess($resolvedImage, 'Inject MSU packages into image')) {
	if ($imageExtension -eq '.wim') {
		Add-TSxPackagesToWim -ImagePath $resolvedImage -ImageIndex $Index -Packages $packages -ScratchPath $ScratchDirectory
	}
	elseif ($imageExtension -eq '.vhdx') {
		Add-TSxPackagesToVhdx -ImagePath $resolvedImage -Packages $packages -ScratchPath $ScratchDirectory
	}
}

Write-TSxLog -Message "Completed successfully. Patched image: $resolvedImage"
[PSCustomObject]@{
	Image = $resolvedImage
	Type = $imageExtension.TrimStart('.')
	PackagesApplied = $packages.Count
	Timestamp = Get-Date
}
