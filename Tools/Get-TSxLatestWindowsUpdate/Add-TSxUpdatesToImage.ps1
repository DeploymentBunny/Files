<#
.SYNOPSIS
Injects MSU updates into an offline WIM or VHDX image.

.DESCRIPTION
Mounts an image in-place and injects one or more .msu packages into the offline image
using DISM cmdlets, then closes the image.
Supports common parameters including -Verbose and -WhatIf.
Supports:
- WIM servicing through Mount-WindowsImage / Add-WindowsPackage / Dismount-WindowsImage
- VHDX servicing through Mount-VHD and Add-WindowsPackage against the offline Windows volume

.PARAMETER Image
Path to the image file (.wim or .vhdx) to service in-place.

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
	Version:     1.0.2
	Author:      Mikael Nystrom
	Contact:     deploymentbunny@outlook.com
	Created:     2026-05-22
	Updated:     2026-05-22
	Twitter:     @mikael_nystrom

	Disclaimer:
	This script is provided "AS IS" with no warranties, confers no rights and
	is not supported by the author.
.LINK
	https://www.deploymentbunny.com
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

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogRootPath = Join-Path $env:TEMP 'Get-TSxLatestWindowsUpdate'
$script:LogFilePath = Join-Path $script:LogRootPath 'Add-TSxUpdatesToImage.log'

function Write-TSxLog {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Message,

		[ValidateSet('INFO', 'WARN', 'ERROR')]
		[string]$Level = 'INFO'
	)

	$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
	$entry = "$timestamp [$Level] $Message"
	Add-Content -Path $script:LogFilePath -Value $entry
	Write-Verbose $entry
}

function Assert-TSxAdministrator {
	[CmdletBinding()]
	param()

	$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
	$principal = New-Object Security.Principal.WindowsPrincipal($identity)
	if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
		throw 'This script must be run in an elevated Windows PowerShell session (Run as Administrator).'
	}
}

function Get-TSxMsuFiles {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Path
	)

	if (-not (Test-Path -Path $Path)) {
		throw "UpdatePath not found: $Path"
	}

	$item = Get-Item -Path $Path -ErrorAction Stop
	if ($item.PSIsContainer) {
		$files = Get-ChildItem -Path $item.FullName -Filter '*.msu' -File -Recurse | Sort-Object FullName
	}
	else {
		if ($item.Extension -notmatch '(?i)\.msu$') {
			throw "UpdatePath is a file but not an .msu package: $($item.FullName)"
		}
		$files = @($item)
	}

	if (-not $files -or $files.Count -eq 0) {
		throw "No .msu files found in UpdatePath: $Path"
	}

	return $files
}

function Get-TSxOfflineWindowsPath {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[int]$DiskNumber
	)

	$existingDriveLetter = $null
	$temporaryDriveLetter = $null
	$selectedPartition = $null
	$offlinePath = $null

	$partitions = Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop | Sort-Object PartitionNumber
	foreach ($partition in $partitions) {
		if ($partition.DriveLetter) {
			$candidate = '{0}:\' -f $partition.DriveLetter
			if (Test-Path -Path (Join-Path $candidate 'Windows')) {
				$existingDriveLetter = $partition.DriveLetter
				$selectedPartition = $partition
				$offlinePath = $candidate
				break
			}
			continue
		}

		$lettersInUse = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | ForEach-Object { $_.DriveLetter }
		$lettersInUseSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
		foreach ($ltr in $lettersInUse) { [void]$lettersInUseSet.Add([string]$ltr) }

		$freeLetter = $null
		foreach ($candidateLetter in ('Z','Y','X','W','V','U','T','S','R','Q','P','O','N','M')) {
			if (-not $lettersInUseSet.Contains($candidateLetter)) {
				$freeLetter = $candidateLetter
				break
			}
		}

		if (-not $freeLetter) {
			throw 'Unable to assign temporary drive letter to mounted VHDX partition.'
		}

		Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber -DriveLetter $freeLetter -ErrorAction Stop
		$candidatePath = '{0}:\' -f $freeLetter
		if (Test-Path -Path (Join-Path $candidatePath 'Windows')) {
			$temporaryDriveLetter = $freeLetter
			$selectedPartition = $partition
			$offlinePath = $candidatePath
			break
		}

		Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber -DriveLetter $freeLetter -ErrorAction SilentlyContinue
	}

	if (-not $offlinePath) {
		throw 'Unable to locate offline Windows folder inside mounted VHDX.'
	}

	[PSCustomObject]@{
		Path = $offlinePath
		PartitionNumber = $selectedPartition.PartitionNumber
		ExistingDriveLetter = $existingDriveLetter
		TemporaryDriveLetter = $temporaryDriveLetter
	}
}

function Add-TSxPackagesToWim {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$ImagePath,

		[Parameter(Mandatory = $true)]
		[int]$ImageIndex,

		[Parameter(Mandatory = $true)]
		[object[]]$Packages,

		[Parameter()]
		[string]$ScratchPath
	)

	$mountPath = Join-Path $env:TEMP ('TSxMount_{0}' -f ([guid]::NewGuid().Guid))
	$null = New-Item -Path $mountPath -ItemType Directory -Force
	$isMounted = $false

	try {
		Write-TSxLog -Message "Mounting WIM image: $ImagePath (Index: $ImageIndex)"
		$mountParams = @{
			ImagePath = $ImagePath
			Index = $ImageIndex
			Path = $mountPath
			ErrorAction = 'Stop'
		}
		if ($ScratchPath) { $mountParams['ScratchDirectory'] = $ScratchPath }

		Mount-WindowsImage @mountParams
		$isMounted = $true

		foreach ($package in $Packages) {
			Write-TSxLog -Message "Injecting package into WIM: $($package.FullName)"
			$packageParams = @{
				Path = $mountPath
				PackagePath = $package.FullName
				ErrorAction = 'Stop'
			}
			if ($ScratchPath) { $packageParams['ScratchDirectory'] = $ScratchPath }
			Add-WindowsPackage @packageParams | Out-Null
		}

		Write-TSxLog -Message 'Committing and unmounting WIM image.'
		Dismount-WindowsImage -Path $mountPath -Save -ErrorAction Stop
		$isMounted = $false
	}
	finally {
		if ($isMounted) {
			Write-TSxLog -Level 'WARN' -Message 'WIM still mounted after error. Discarding pending changes.'
			Dismount-WindowsImage -Path $mountPath -Discard -ErrorAction SilentlyContinue
		}
		Remove-Item -Path $mountPath -Recurse -Force -ErrorAction SilentlyContinue
	}
}

function Add-TSxPackagesToVhdx {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$ImagePath,

		[Parameter(Mandatory = $true)]
		[object[]]$Packages,

		[Parameter()]
		[string]$ScratchPath
	)

	$mountedDisk = $null
	$offlineInfo = $null

	try {
		Write-TSxLog -Message "Mounting VHDX image: $ImagePath"
		$mountedDisk = Mount-VHD -Path $ImagePath -Passthru -ErrorAction Stop
		Start-Sleep -Milliseconds 500

		$offlineInfo = Get-TSxOfflineWindowsPath -DiskNumber $mountedDisk.DiskNumber
		Write-TSxLog -Message "Offline Windows path detected: $($offlineInfo.Path)"

		foreach ($package in $Packages) {
			Write-TSxLog -Message "Injecting package into VHDX: $($package.FullName)"
			$packageParams = @{
				Path = $offlineInfo.Path
				PackagePath = $package.FullName
				ErrorAction = 'Stop'
			}
			if ($ScratchPath) { $packageParams['ScratchDirectory'] = $ScratchPath }
			Add-WindowsPackage @packageParams | Out-Null
		}
	}
	finally {
		if ($offlineInfo -and $offlineInfo.TemporaryDriveLetter) {
			Remove-PartitionAccessPath -DiskNumber $mountedDisk.DiskNumber -PartitionNumber $offlineInfo.PartitionNumber -DriveLetter $offlineInfo.TemporaryDriveLetter -ErrorAction SilentlyContinue
		}

		if ($mountedDisk) {
			Write-TSxLog -Message 'Dismounting VHDX image.'
			Dismount-VHD -Path $ImagePath -ErrorAction SilentlyContinue
		}
	}
}

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
