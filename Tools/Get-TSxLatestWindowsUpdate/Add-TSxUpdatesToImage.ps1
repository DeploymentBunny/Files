<#
.SYNOPSIS
	Injects MSU updates into an offline WIM or VHDX image.

.DESCRIPTION
	Mounts an image in place and injects one or more .msu packages into the offline image using DISM.
	Supports WIM servicing through Mount-WindowsImage / Add-WindowsPackage / Dismount-WindowsImage,
	and VHDX servicing through Mount-VHD plus Add-WindowsPackage against the offline Windows volume.

.PARAMETER Image
	Path to the image file (.wim or .vhdx) to service in place.

.PARAMETER UpdatePath
	Path to a folder containing .msu files, or a direct path to a single .msu file.

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
	Version:     1.0.3
	Author:      Mikael Nystrom
	Contact:     @mikael_nystrom
	Created:     2026-05-22
	Updated:     2026-05-25
	Twitter:     @mikael_nystrom

	Disclaimer:
	This script is provided "AS IS" with no warranties, confers no rights and
	is not supported by the author.
.LINK
	https://www.deploymentbunny.com

.FUNCTIONALITY
	Serves as an offline image servicing front end for injecting MSU updates into WIM and VHDX images.
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

Import-Module -Name (Join-Path $PSScriptRoot 'Modules\TSxLatestWindowsUpdateUtility\TSxLatestWindowsUpdateUtility.psd1') -Force -ErrorAction Stop

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogRootPath = Join-Path $env:TEMP 'Get-TSxLatestWindowsUpdate'
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
