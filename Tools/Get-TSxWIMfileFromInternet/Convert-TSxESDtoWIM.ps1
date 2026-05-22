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
.\Convert-TSxESDtoWIM.ps1 -EsdPath "C:\Temp\ESD\install.esd"

.EXAMPLE
$download | .\Convert-TSxESDtoWIM.ps1 -Verbose

.EXAMPLE
.\Convert-TSxESDtoWIM.ps1 -EsdPath "C:\Temp\ESD\install.esd" -WimPath "C:\Temp\ESD\install.wim" -Index 1,2,3

.NOTES
	FileName:    Convert-TSxESDtoWIM.ps1
	Version:     1.1.20
	Author:      Mikael Nystrom
	Contact:     deploymentbunny@outlook.com
	Created:     2026-04-23
	Updated:     2026-05-22
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
	[object]$InputObject,

	[string]$EsdPath,
	[string]$WimPath,
	[int[]]$Index,
	[switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:LogRootPath = Join-Path $env:TEMP 'Get-TSxWIMfileFromInternet'
$Script:LogFilePath = Join-Path $Script:LogRootPath ("{0}.log" -f [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath))
$Script:DismLogPath = Join-Path $Script:LogRootPath 'dism.log'

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

	if ($WriteVerbose -or $VerbosePreference -eq 'Continue') {
		Write-Verbose $entry
	}
}

if (-not (Test-Path -Path $Script:LogRootPath)) {
	New-Item -Path $Script:LogRootPath -ItemType Directory -Force | Out-Null
}
Write-Verbose "[Convert-TSxESDtoWIM] Log root path: $Script:LogRootPath"
Write-Verbose "[Convert-TSxESDtoWIM] Script log path: $Script:LogFilePath"
Write-Verbose "[Convert-TSxESDtoWIM] DISM log path: $Script:DismLogPath"
Write-TSxLog -Message 'Script start.' -WriteVerbose

function Write-ConversionStatus {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Message
	)

	Write-Verbose "[Convert-TSxESDtoWIM] $Message"
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
		return $EsdPath.Trim()
	}

	if (-not $InputObject) {
		throw 'No ESD path was provided. Pass -EsdPath or pipe an object with an EsdPath property.'
	}

	foreach ($propertyName in @('EsdPath', 'FilePath', 'FullName')) {
		$property = $InputObject.PSObject.Properties[$propertyName]
		if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
			return ([string]$property.Value).Trim()
		}
	}

	if ($InputObject -is [string] -and -not [string]::IsNullOrWhiteSpace($InputObject)) {
		return ([string]$InputObject).Trim()
	}

	throw 'Unable to resolve ESD path from pipeline input. Use -EsdPath or pipe an object with EsdPath, FilePath, or FullName.'
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

function Get-EsdImageInfo {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$EsdPath
	)

	function Invoke-DismCommand {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string[]]$Arguments
		)

		$quotedDismLogPath = '"{0}"' -f $Script:DismLogPath
		$allArguments = @($Arguments + "/LogPath:$quotedDismLogPath")
		$argumentText = ($allArguments | ForEach-Object { $_ -replace "`r", '\\r' -replace "`n", '\\n' }) -join ' '
		Write-TSxLog -Message "Executing DISM command: dism.exe $argumentText" -WriteVerbose

		$stdout = & dism.exe @allArguments 2>&1 | Out-String
		$exitCode = $LASTEXITCODE
		Write-TSxLog -Message "DISM command completed with exit code $exitCode." -WriteVerbose

		[PSCustomObject]@{
			ExitCode = $exitCode
			StdOut = $stdout
			StdErr = ''
		}
	}

	function ConvertFrom-DismWimInfoOutput {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$OutputText
		)

		$results = New-Object System.Collections.Generic.List[object]
		$current = $null
		foreach ($line in ($OutputText -split "`r?`n")) {
			if ($line -match '^\s*Index\s*:\s*(\d+)\s*$') {
				if ($null -ne $current) {
					$results.Add($current)
				}

				$current = [PSCustomObject]@{
					ImageIndex = [int]$Matches[1]
					ImageName = ''
					ImageDescription = ''
				}
				continue
			}

			if ($null -eq $current) {
				continue
			}

			if ($line -match '^\s*Name\s*:\s*(.+?)\s*$') {
				$current.ImageName = $Matches[1].Trim()
				continue
			}

			if ($line -match '^\s*Description\s*:\s*(.+?)\s*$') {
				$current.ImageDescription = $Matches[1].Trim()
			}
		}

		if ($null -ne $current) {
			$results.Add($current)
		}

		return $results
	}

	try {
		if ($EsdPath -match "`r|`n") {
			throw 'ESD path contains invalid newline characters. Provide a clean file path.'
		}

		$quotedPath = '"{0}"' -f $EsdPath
		$dismResult = Invoke-DismCommand -Arguments @('/English', '/Get-WimInfo', "/WimFile:$quotedPath")
		if ($dismResult.ExitCode -ne 0) {
			$failureText = ($dismResult.StdErr, $dismResult.StdOut | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' '
			throw "DISM /Get-WimInfo failed for $EsdPath. $failureText"
		}

		$images = @(ConvertFrom-DismWimInfoOutput -OutputText $dismResult.StdOut)
		Write-TSxLog -Message "DISM /Get-WimInfo parsed for path: $EsdPath. ImageCount=$(@($images).Count)" -WriteVerbose
		return $images
	} catch {
		Write-TSxLog -Level 'ERROR' -Message "DISM image info command failed for path: $EsdPath. $($_.Exception.Message)" -WriteVerbose
		throw "DISM failed while reading ESD metadata from $EsdPath. $($_.Exception.Message)"
	}
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

	if (-not (Get-Command -Name Export-WindowsImage -ErrorAction SilentlyContinue)) {
		throw 'Export-WindowsImage cmdlet is not available. Ensure the DISM PowerShell module is installed and available in this session.'
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
	Write-ConversionStatus "Resolved source ESD path: $([System.IO.Path]::GetFullPath($EsdPath))"
	Write-ConversionStatus "Resolved destination WIM path: $([System.IO.Path]::GetFullPath($WimPath))"

	if (-not (Test-IsAdministrator)) {
		Write-TSxLog -Level 'ERROR' -Message 'Administrator privileges are required for ESD to WIM conversion.'
		throw 'Administrator privileges are required for ESD to WIM conversion. Start PowerShell as Administrator and run the command again.'
	}

	Write-ConversionStatus 'Administrator check passed.'

	$esdFileInfo = Get-Item -Path $EsdPath -ErrorAction Stop
	$dismTempBufferBytes = 10GB
	$wimEstimateBytes = $esdFileInfo.Length * 3
	$totalRequiredBytes = $dismTempBufferBytes + $wimEstimateBytes
	Write-ConversionStatus "Checking disk space. ESD size: $([math]::Round($esdFileInfo.Length / 1GB, 1)) GB, estimated WIM: $([math]::Round($wimEstimateBytes / 1GB, 1)) GB, DISM temp buffer: 10 GB."
	Test-SufficientDiskSpace -TargetPath $WimPath -RequiredBytes $totalRequiredBytes
	Write-ConversionStatus 'Disk space check passed.'

	$wimDirectory = Split-Path -Path $WimPath -Parent
	Write-ConversionStatus "Destination folder path: $wimDirectory"
	if (-not (Test-Path -Path $wimDirectory)) {
		if ($PSCmdlet.ShouldProcess($wimDirectory, 'Create destination directory')) {
			Write-ConversionStatus "Creating destination directory: $wimDirectory"
			New-Item -Path $wimDirectory -ItemType Directory -Force | Out-Null
		} else {
			Write-TSxLog -Message "Skipping destination directory creation due to WhatIf: $wimDirectory" -WriteVerbose
		}
	} else {
		Write-ConversionStatus "Destination directory already exists: $wimDirectory"
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
		if ($PSCmdlet.ShouldProcess($WimPath, 'Remove existing WIM before conversion')) {
			Remove-Item -Path $WimPath -Force
		} else {
			Write-TSxLog -Message "Skipping WIM removal due to WhatIf: $WimPath" -WriteVerbose
		}
	}

	Write-ConversionStatus 'Reading ESD image metadata...'
	$metadataStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
	$images = @(Get-EsdImageInfo -EsdPath $EsdPath)
	$metadataStopwatch.Stop()
	Write-ConversionStatus "ESD metadata loaded in $($metadataStopwatch.Elapsed.TotalSeconds.ToString('0.0')) second(s)."
	foreach ($img in $images) {
		Write-ConversionStatus "Found image index $($img.ImageIndex): Name='$($img.ImageName)' Description='$($img.ImageDescription)'"
	}
	if (@($images).Count -eq 0) {
		throw "No image indexes were found in $EsdPath"
	}

	$imagesToExport = @($images)
	$requestedIndexes = @($Index | Where-Object { $null -ne $_ } | Select-Object -Unique)
	if ($requestedIndexes.Count -gt 0) {
		$availableIndexes = @($images | ForEach-Object { [int]$_.ImageIndex })
		$missingIndexes = @($requestedIndexes | Where-Object { $_ -notin $availableIndexes })
		if ($missingIndexes.Count -gt 0) {
			throw "Requested image index(es) were not found in ${EsdPath}: $($missingIndexes -join ', ')"
		}

		$imagesToExport = @($images | Where-Object { [int]$_.ImageIndex -in $requestedIndexes })
		Write-ConversionStatus "Index filter applied. Exporting index(es): $($requestedIndexes -join ', ')"
	}

	Write-ConversionStatus "Starting conversion of $EsdPath to $WimPath ($($imagesToExport.Count) image index(es))."

	$totalImages = $imagesToExport.Count
	$currentImage = 0
	foreach ($image in $imagesToExport) {
		$currentImage++
		$imageIndex = [uint32]$image.ImageIndex
		$imageLabel = if ([string]::IsNullOrWhiteSpace([string]$image.ImageName)) { "Index $imageIndex" } else { "Index $imageIndex - $($image.ImageName)" }
		Write-ConversionStatus "Exporting $imageLabel ($currentImage/$totalImages)..."
		$percentComplete = [int]((($currentImage - 1) / $totalImages) * 100)
		Write-Progress -Id 1 -Activity 'Converting ESD to WIM' -Status "Starting $imageLabel ($currentImage of $totalImages)" -PercentComplete $percentComplete
		Write-Verbose "Converting $imageLabel to $WimPath ($currentImage of $totalImages)"

		$action = "Export index $imageIndex from $EsdPath"
		if ($PSCmdlet.ShouldProcess($WimPath, $action)) {
			try {
				Write-TSxLog -Message "Executing Export-WindowsImage for index $imageIndex. Source=$EsdPath Destination=$WimPath DismLog=$Script:DismLogPath" -WriteVerbose

				$exportJob = Start-Job -ScriptBlock {
					param(
						[string]$SourceImagePath,
						[uint32]$SourceIndex,
						[string]$DestinationImagePath,
						[string]$LogPath
					)

					Import-Module Dism -ErrorAction Stop
					Export-WindowsImage -SourceImagePath $SourceImagePath -SourceIndex $SourceIndex -DestinationImagePath $DestinationImagePath -CompressionType Max -CheckIntegrity -LogPath $LogPath -ErrorAction Stop | Out-Null
				} -ArgumentList $EsdPath, $imageIndex, $WimPath, $Script:DismLogPath

				$exportStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
				while ($true) {
					$completedJob = Wait-Job -Job $exportJob -Timeout 30
					if ($null -ne $completedJob) {
						break
					}

					$currentWimSizeGBValue = 0
					if (Test-Path -Path $WimPath -PathType Leaf) {
						$currentWimSizeGBValue = [math]::Round(((Get-Item -Path $WimPath -ErrorAction SilentlyContinue).Length / 1GB), 2)
					}

					$elapsedMinutes = [int]$exportStopwatch.Elapsed.TotalMinutes
					$elapsedSeconds = [int]$exportStopwatch.Elapsed.Seconds
					$elapsedText = "{0:00}:{1:00}" -f $elapsedMinutes, $elapsedSeconds
					$currentWimSizeGBText = "{0:00.00}" -f $currentWimSizeGBValue

					Write-ConversionStatus "Still exporting $imageLabel. Elapsed: $elapsedText, current WIM size: ${currentWimSizeGBText} GB"
				}

				$jobOutput = Receive-Job -Job $exportJob -ErrorAction SilentlyContinue
				if ($jobOutput) {
					$null = $jobOutput
				}

				if ($exportJob.State -ne 'Completed') {
					$jobError = $null
					if ($exportJob.ChildJobs -and $exportJob.ChildJobs.Count -gt 0 -and $exportJob.ChildJobs[0].Error.Count -gt 0) {
						$jobError = [string]$exportJob.ChildJobs[0].Error[0]
					}
					if ([string]::IsNullOrWhiteSpace($jobError)) {
						$jobError = "Export job state was $($exportJob.State)."
					}
					throw "Export-WindowsImage failed while exporting index $imageIndex from $EsdPath. $jobError"
				}

				Write-TSxLog -Message "Export-WindowsImage completed for index $imageIndex." -WriteVerbose
				if (Test-Path -Path $WimPath -PathType Leaf) {
					$finalWimSizeGB = [math]::Round(((Get-Item -Path $WimPath).Length / 1GB), 2)
					Write-ConversionStatus "Current output WIM path: $WimPath (size: $finalWimSizeGB GB)"
				}

				$percentComplete = [int](($currentImage / $totalImages) * 100)
				Write-Progress -Id 1 -Activity 'Converting ESD to WIM' -Status "Completed $imageLabel ($currentImage of $totalImages)" -PercentComplete $percentComplete
			} catch {
				Write-Progress -Id 1 -Activity 'Converting ESD to WIM' -Completed
				Write-TSxLog -Level 'ERROR' -Message "Export-WindowsImage failed for index $imageIndex. $($_.Exception.Message)"
				throw "Export-WindowsImage failed while exporting index $imageIndex from $EsdPath. $($_.Exception.Message)"
			} finally {
				if ($null -ne $exportJob) {
					Remove-Job -Job $exportJob -Force -ErrorAction SilentlyContinue
				}
			}
		}
	}

	Write-Progress -Id 1 -Activity 'Converting ESD to WIM' -Completed
	Write-ConversionStatus "Conversion completed: $WimPath"
	if (Test-Path -Path $WimPath -PathType Leaf) {
		$completedSizeGB = [math]::Round(((Get-Item -Path $WimPath).Length / 1GB), 2)
		Write-ConversionStatus "Final output file: $WimPath"
		Write-ConversionStatus "Final output size: $completedSizeGB GB"
	}
	return $WimPath
}

try {
	Test-ExecutionPrerequisites
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
		$resolvedWimPath = if ([string]::IsNullOrWhiteSpace($WimPath)) { [System.IO.Path]::ChangeExtension($resolvedEsdPath, '.wim') } else { $WimPath.Trim() }
		$requestedIndexes = @($Index | Where-Object { $null -ne $_ } | Select-Object -Unique)
		$indexText = if ($requestedIndexes.Count -gt 0) { $requestedIndexes -join ',' } else { 'all' }
		Write-TSxLog -Message "Resolved conversion job. EsdPath=[$resolvedEsdPath]; WimPath=[$resolvedWimPath]; Index=$indexText" -WriteVerbose
		Write-TSxLog -Message "Starting conversion job for source '$resolvedEsdPath' to destination '$resolvedWimPath'." -WriteVerbose
		$finalWimPath = Convert-EsdPathToWim -EsdPath $resolvedEsdPath -WimPath $resolvedWimPath -Index $Index -Force:$Force -WhatIf:$WhatIfPreference

		[PSCustomObject]@{
			EsdPath   = $resolvedEsdPath
			WimPath   = $finalWimPath
			Converted = $true
		}
	}
} catch {
	Write-TSxLog -Level 'ERROR' -Message "Unhandled error: $($_.Exception.Message)" -WriteVerbose
	throw
} finally {
	Write-TSxLog -Message 'Script end.' -WriteVerbose
}