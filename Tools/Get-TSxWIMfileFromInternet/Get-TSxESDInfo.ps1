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

.PARAMETER NoProgress
Suppresses host progress output.

.EXAMPLE
.\Get-TSxESDInfo.ps1 -EsdPath "C:\Temp\ESD\install.esd"

.EXAMPLE
$download | .\Get-TSxESDInfo.ps1

.NOTES
	FileName:    Get-TSxESDInfo.ps1
	Version:     1.1.8
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
[CmdletBinding()]
param(
	[Parameter(ValueFromPipeline = $true)]
	[object]$InputObject,

	[string]$EsdPath,
	[switch]$NoProgress
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

	if ($WriteVerbose) {
		Write-Verbose $entry
	}
}

if (-not (Test-Path -Path $Script:LogRootPath)) {
	New-Item -Path $Script:LogRootPath -ItemType Directory -Force | Out-Null
}
Write-TSxLog -Message 'Script start.' -WriteVerbose

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

function Write-InfoStatus {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Message
	)

	Write-Verbose "[Get-TSxESDInfo] $Message"
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

	function Invoke-DismCommand {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string[]]$Arguments
		)

		$argumentText = $Arguments -join ' '
		$quotedDismLogPath = '"{0}"' -f $Script:DismLogPath
		$allArguments = @($Arguments + "/LogPath:$quotedDismLogPath")
		$argumentText = $allArguments -join ' '
		Write-TSxLog -Message "Executing DISM command: dism.exe $argumentText" -WriteVerbose

		$startInfo = New-Object System.Diagnostics.ProcessStartInfo
		$startInfo.FileName = 'dism.exe'
		$startInfo.Arguments = $argumentText
		$startInfo.UseShellExecute = $false
		$startInfo.RedirectStandardOutput = $true
		$startInfo.RedirectStandardError = $true
		$startInfo.CreateNoWindow = $true

		$process = New-Object System.Diagnostics.Process
		$process.StartInfo = $startInfo
		if (-not $process.Start()) {
			throw 'Unable to start DISM process.'
		}

		$waitTimeout = [TimeSpan]::FromMinutes(5)
		$waitStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
		while (-not $process.WaitForExit(1000)) {
			if ($waitStopwatch.Elapsed -ge $waitTimeout) {
				try {
					$process.Kill()
				} catch {
				}
				Complete-TSxProgress -Id 1200 -Activity 'Reading ESD metadata'
				throw 'Timed out waiting for DISM command to complete.'
			}

			$elapsedText = '{0:00}:{1:00}' -f [int]$waitStopwatch.Elapsed.TotalMinutes, [int]$waitStopwatch.Elapsed.Seconds
			Write-TSxProgress -Id 1200 -Activity 'Reading ESD metadata' -Status ("DISM is running... {0} elapsed" -f $elapsedText)
		}
		Complete-TSxProgress -Id 1200 -Activity 'Reading ESD metadata'

		$stdout = $process.StandardOutput.ReadToEnd()
		$stderr = $process.StandardError.ReadToEnd()
		Write-TSxLog -Message "DISM command completed with exit code $($process.ExitCode)." -WriteVerbose
		if (-not [string]::IsNullOrWhiteSpace($stderr)) {
			Write-TSxLog -Level 'WARN' -Message "DISM stderr: $($stderr.Trim())" -WriteVerbose
		}

		[PSCustomObject]@{
			ExitCode = $process.ExitCode
			StdOut = $stdout
			StdErr = $stderr
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

	if (-not (Test-Path -Path $EsdPath)) {
		throw "ESD file not found: $EsdPath"
	}

	try {
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

	$totalItems = $items.Count
	$itemIndex = 0
	foreach ($item in $items) {
		$itemIndex++
		$resolvedEsdPath = Resolve-EsdSourcePath -InputObject $item -EsdPath $EsdPath
		$itemPercentComplete = if ($totalItems -gt 0) { [int](($itemIndex / $totalItems) * 100) } else { 0 }
		Write-TSxProgress -Id 1201 -Activity 'Inspecting ESD files' -Status ("Preparing {0} ({1}/{2})" -f [System.IO.Path]::GetFileName($resolvedEsdPath), $itemIndex, $totalItems) -PercentComplete $itemPercentComplete
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
				ImageIndex   = [int](Get-OptionalPropertyValue -InputObject $image -PropertyName 'ImageIndex')
				ImageName    = [string](Get-OptionalPropertyValue -InputObject $image -PropertyName 'ImageName')
				ImageDescription = [string](Get-OptionalPropertyValue -InputObject $image -PropertyName 'ImageDescription')
			}
		}
	}
	Complete-TSxProgress -Id 1201 -Activity 'Inspecting ESD files'
} catch {
	Write-TSxLog -Level 'ERROR' -Message "Unhandled error: $($_.Exception.Message)" -WriteVerbose
	throw
} finally {
	Write-TSxLog -Message 'Script end.' -WriteVerbose
}
