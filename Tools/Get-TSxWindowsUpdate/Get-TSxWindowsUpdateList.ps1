<#
.SYNOPSIS
	Queries Microsoft Update Catalog for Windows update entries used by the UI and download pipeline.

.DESCRIPTION
	Searches Microsoft Update Catalog for one or more update categories (LCU, .NET CU, SSU,
	Defender, Edge) matching the requested operating system and architecture, then returns
	normalized objects for automation and download workflows.

.PARAMETER OperatingSystem
	Operating system search text, for example "Windows 11 24H2".

.PARAMETER Architecture
	Target architecture. Defaults to the local processor architecture when not specified.

.PARAMETER LatestOnly
	Returns only the highest ranked candidate.

.PARAMETER IncludeCumulative
	Include latest cumulative updates (LCU).

.PARAMETER IncludeDotNet
	Include cumulative updates for .NET Framework.

.PARAMETER IncludeSSU
	Include servicing stack updates when listed separately.

.PARAMETER IncludeDefender
	Include Microsoft Defender related updates.

.PARAMETER IncludeEdge
	Include Microsoft Edge related updates.

.PARAMETER IncludePreview
	Include preview updates. Default behavior excludes previews.

.PARAMETER Force
	Recreates log file content for the current execution.

.PARAMETER NoProgress
	Suppresses progress output.

.PARAMETER UiProgress
	Emits progress updates as information records for UI wrappers.

.EXAMPLE
	.\Get-TSxWindowsUpdateList.ps1 -OperatingSystem 'Windows 11 24H2' -Architecture x64 -LatestOnly -Verbose

.EXAMPLE
	.\Get-TSxWindowsUpdateList.ps1 -OperatingSystem 'Windows 11 24H2' -Architecture x64 -IncludeCumulative -IncludeDotNet -IncludeSSU -LatestOnly -Verbose

.NOTES
	FileName:    Get-TSxWindowsUpdateList.ps1
	Version:     1.2.16
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
	Returns normalized catalog metadata for Windows updates and supports WhatIf-aware catalog searches.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
	[Parameter(Mandatory = $true)]
	[ValidateNotNullOrEmpty()]
	[string]$OperatingSystem,

	[Parameter()]
	[ValidateSet('x64', 'arm64', 'x86')]
	[string]$Architecture,

	[Parameter()]
	[switch]$LatestOnly,

	[Parameter()]
	[switch]$IncludeCumulative,

	[Parameter()]
	[switch]$IncludeDotNet,

	[Parameter()]
	[switch]$IncludeSSU,

	[Parameter()]
	[switch]$IncludeDefender,

	[Parameter()]
	[switch]$IncludeEdge,

	[Parameter()]
	[switch]$IncludePreview,

	[Parameter()]
	[switch]$Force,

	[Parameter()]
	[switch]$NoProgress,

	[Parameter()]
	[switch]$UiProgress
)

Import-Module -Name (Join-Path $PSScriptRoot 'Modules\TSxWindowsUpdateUtility\TSxWindowsUpdateUtility.psd1') -Force -ErrorAction Stop

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogRootPath = Join-Path -Path $env:TEMP -ChildPath 'Get-TSxWindowsUpdate'
$script:LogFilePath = Join-Path -Path $script:LogRootPath -ChildPath ('{0}.log' -f [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath))

if ($PSBoundParameters.ContainsKey('IncludeCumulative')) { $script:IncludeCumulativeEffective = [bool]$IncludeCumulative } else { $script:IncludeCumulativeEffective = $true }
if ($PSBoundParameters.ContainsKey('IncludeDotNet')) { $script:IncludeDotNetEffective = [bool]$IncludeDotNet } else { $script:IncludeDotNetEffective = $true }
if ($PSBoundParameters.ContainsKey('IncludeSSU')) { $script:IncludeSSUEffective = [bool]$IncludeSSU } else { $script:IncludeSSUEffective = $true }
if ($PSBoundParameters.ContainsKey('IncludeDefender')) { $script:IncludeDefenderEffective = [bool]$IncludeDefender } else { $script:IncludeDefenderEffective = $false }
if ($PSBoundParameters.ContainsKey('IncludeEdge')) { $script:IncludeEdgeEffective = [bool]$IncludeEdge } else { $script:IncludeEdgeEffective = $false }
if ($PSBoundParameters.ContainsKey('IncludePreview')) { $script:IncludePreviewEffective = [bool]$IncludePreview } else { $script:IncludePreviewEffective = $false }

$scriptName = Split-Path -Path $PSCommandPath -Leaf
Start-TSxLog -FilePath $script:LogFilePath -Force:$Force
Write-TSxLog -Message ('{0} started' -f $scriptName)

if (-not $PSBoundParameters.ContainsKey('Architecture')) {
	$Architecture = Get-TSxDefaultArchitecture
}

Write-TSxLog -Message ('OperatingSystem: {0}' -f $OperatingSystem)
Write-TSxLog -Message ('Architecture: {0}' -f $Architecture)
Write-TSxLog -Message ('LatestOnly: {0}' -f $LatestOnly.IsPresent)
Write-TSxLog -Message ('IncludeCumulative: {0}' -f $script:IncludeCumulativeEffective)
Write-TSxLog -Message ('IncludeDotNet: {0}' -f $script:IncludeDotNetEffective)
Write-TSxLog -Message ('IncludeSSU: {0}' -f $script:IncludeSSUEffective)
Write-TSxLog -Message ('IncludeDefender: {0}' -f $script:IncludeDefenderEffective)
Write-TSxLog -Message ('IncludeEdge: {0}' -f $script:IncludeEdgeEffective)
Write-TSxLog -Message ('IncludePreview: {0}' -f $script:IncludePreviewEffective)
Write-TSxLog -Message ('Force: {0}' -f $Force.IsPresent)
Write-TSxLog -Message ('NoProgress: {0}' -f $NoProgress.IsPresent)
Write-TSxLog -Message ('UiProgress: {0}' -f $UiProgress.IsPresent)
Write-TSxLog -Message ('Log root path: {0}' -f $script:LogRootPath)
Write-TSxLog -Message ('Log path: {0}' -f $script:LogFilePath)

if (-not ($script:IncludeCumulativeEffective -or $script:IncludeDotNetEffective -or $script:IncludeSSUEffective -or $script:IncludeDefenderEffective -or $script:IncludeEdgeEffective -or $script:IncludePreviewEffective)) {
	throw 'No update categories selected. Enable at least one category switch.'
}

$categoryDefinitions = New-Object System.Collections.Generic.List[object]

if ($script:IncludeCumulativeEffective) {
	$null = $categoryDefinitions.Add((Get-TSxCategoryDefinition -Name 'Cumulative' -Query '{0} {1} cumulative update' -IncludePatterns @('(?i)Cumulative Update for') -ExcludePatterns @('(?i)\.NET Framework', '(?i)Dynamic Cumulative Update', '(?i)Setup Dynamic Update', '(?i)Adobe')))
}

if ($script:IncludeDotNetEffective) {
	$null = $categoryDefinitions.Add((Get-TSxCategoryDefinition -Name 'DotNet' -Query '{0} {1} .NET Framework cumulative update' -IncludePatterns @('(?i)Cumulative Update for .*\.NET Framework')))
}

if ($script:IncludeSSUEffective) {
	$null = $categoryDefinitions.Add((Get-TSxCategoryDefinition -Name 'SSU' -Query '{0} {1} servicing stack update' -IncludePatterns @('(?i)Servicing Stack Update')))
}

if ($script:IncludeDefenderEffective) {
	$null = $categoryDefinitions.Add((Get-TSxCategoryDefinition -Name 'Defender' -Query 'Windows Defender' -IncludePatterns @('(?i)Defender', '(?i)Security Intelligence Update', '(?i)Antimalware Platform Update') -RequiresOperatingSystemMatch:$false -RequiresArchitectureMatch:$false))
}

if ($script:IncludeEdgeEffective) {
	$null = $categoryDefinitions.Add((Get-TSxCategoryDefinition -Name 'Edge' -Query 'Microsoft Edge Stable' -IncludePatterns @('(?i)Edge') -RequiresOperatingSystemMatch:$false))
}

if ($script:IncludePreviewEffective) {
	$null = $categoryDefinitions.Add((Get-TSxCategoryDefinition -Name 'Preview' -Query '{0} {1} preview cumulative update' -IncludePatterns @('(?i)Preview') -ExcludePatterns @('(?i)Windows Insider', '(?i)Insider Pre-Release')))
}

$outputUpdates = New-Object System.Collections.Generic.List[object]
$seenUpdateIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$progressId = 22001
$categoryCount = [Math]::Max(1, $categoryDefinitions.Count)
$categoryIndex = 0
$showProgress = -not $NoProgress
$tsxExecutionContext = Get-TSxExecutionContext
$emitUiProgress = [bool]($UiProgress -or $tsxExecutionContext -eq 'Wrapper')
$isIseHost = $tsxExecutionContext -eq 'ISE'
$previousProgressPreference = $ProgressPreference
$previousInformationPreference = $InformationPreference


if ($showProgress) {
	$ProgressPreference = 'Continue'
}
if ($emitUiProgress) {
	$InformationPreference = 'Continue'
}

Write-TSxLog -Message ('ExecutionContext: {0}' -f $tsxExecutionContext)

try {
	foreach ($categoryDefinition in $categoryDefinitions) {
		$categoryIndex++
		$percentComplete = [int](($categoryIndex * 100) / $categoryCount)
		$progressStatus = ('{0} ({1}/{2})' -f $categoryDefinition.Name, $categoryIndex, $categoryCount)
		if ($showProgress) {
			Write-Progress -Id $progressId -Activity 'Querying Windows Update Catalog' -Status $progressStatus -PercentComplete $percentComplete
		}
		if ($emitUiProgress) {
			Write-Information -MessageData ('Progress: {0}% - {1}' -f $percentComplete, $progressStatus)
		}
		elseif ($showProgress -and $isIseHost) {
			Write-Host ('Progress: {0}% - {1}' -f $percentComplete, $progressStatus)
		}

		$searchQuery = $categoryDefinition.Query -f $OperatingSystem, $Architecture
		Write-TSxLog -Message ('Query for {0}: {1}' -f $categoryDefinition.Name, $searchQuery)
		Write-Verbose ('Query for {0}: {1}' -f $categoryDefinition.Name, $searchQuery)
		if ($PSCmdlet.ShouldProcess($searchQuery, ('Query Windows Update Catalog for {0}' -f $categoryDefinition.Name))) {
			$searchResults = @(Get-TSxCatalogSearchResults -Query $searchQuery)
		}
		else {
			$searchResults = @()
			Write-TSxLog -Level 'WARN' -Message ('WhatIf mode skipped catalog query for {0}' -f $categoryDefinition.Name)
		}
		Write-TSxLog -Message ('Catalog returned {0} result(s) for {1}' -f $searchResults.Count, $categoryDefinition.Name)

		if ($searchResults.Count -eq 0 -and $WhatIfPreference) {
			Write-TSxLog -Level 'WARN' -Message ('WhatIf mode produced no catalog results for {0} because the web request was skipped.' -f $categoryDefinition.Name)
			continue
		}

		$candidateUpdates = $searchResults | Where-Object {
			$matchesCategory = Test-TSxTitlePatternMatch -Title $_.Title -IncludePatterns $categoryDefinition.IncludePatterns -ExcludePatterns $categoryDefinition.ExcludePatterns
			$requiresArchitectureMatch = $true
			if ($categoryDefinition.PSObject.Properties['RequiresArchitectureMatch']) {
				$requiresArchitectureMatch = [bool]$categoryDefinition.RequiresArchitectureMatch
			}
			$matchesArchitecture = (-not $requiresArchitectureMatch) -or ($_.Title -match ('(?i){0}' -f [regex]::Escape($Architecture)))
			$requiresOperatingSystemMatch = $true
			if ($categoryDefinition.PSObject.Properties['RequiresOperatingSystemMatch']) {
				$requiresOperatingSystemMatch = [bool]$categoryDefinition.RequiresOperatingSystemMatch
			}
			$matchesOperatingSystem = (-not $requiresOperatingSystemMatch) -or (Test-TSxOperatingSystemMatch -Title $_.Title -Product $_.Product -OperatingSystem $OperatingSystem)
			$matchesPreviewRule = $script:IncludePreviewEffective -or ($_.Title -notmatch '(?i)Preview')
			$isInsiderUpdate = $_.Title -match '(?i)Windows Insider|Insider Pre-Release' -or $_.Product -match '(?i)Windows Insider|Insider Pre-Release'
			$matchesCategory -and $matchesArchitecture -and $matchesOperatingSystem -and $matchesPreviewRule -and (-not $isInsiderUpdate)
		}

		if (-not $candidateUpdates) {
			Write-TSxLog -Level 'WARN' -Message ('No updates matched category {0}.' -f $categoryDefinition.Name)
			continue
		}

		$sortedCategoryUpdates = @(
			$candidateUpdates |
			Sort-Object -Property @{ Expression = { $_.LastUpdated }; Descending = $true }, @{ Expression = { $_.Build }; Descending = $true }, @{ Expression = { $_.Title }; Descending = $true }
		)

		Write-TSxLog -Message ('Category {0} produced {1} candidate update(s).' -f $categoryDefinition.Name, $sortedCategoryUpdates.Count)

		$categorySelection = if ($LatestOnly) { @($sortedCategoryUpdates | Select-Object -First 1) } else { $sortedCategoryUpdates }
		foreach ($update in $categorySelection) {
			if ($seenUpdateIds.Add([string]$update.UpdateId)) {
				$null = $outputUpdates.Add((ConvertTo-TSxUpdateObject -Update $update -OperatingSystem $OperatingSystem -Architecture $Architecture -SearchQuery $searchQuery -UpdateType $categoryDefinition.Name -LogPath $script:LogFilePath))
			}
			else {
				Write-TSxLog -Message ('Skipping duplicate UpdateId {0} from category {1}' -f $update.UpdateId, $categoryDefinition.Name)
			}
		}
	}
}
finally {
	if ($showProgress) {
		Write-Progress -Id $progressId -Activity 'Querying Windows Update Catalog' -Completed
	}
	$ProgressPreference = $previousProgressPreference
	$InformationPreference = $previousInformationPreference
}

if ($outputUpdates.Count -eq 0 -and $WhatIfPreference) {
	Write-TSxLog -Level 'WARN' -Message 'WhatIf mode produced no updates because web requests were skipped.'
	return
}

if ($outputUpdates.Count -eq 0) {
	throw ('No updates were found for operating system "{0}" and architecture "{1}" with the selected categories.' -f $OperatingSystem, $Architecture)
}

Write-TSxLog -Message ('Returning {0} update(s) across selected categories.' -f $outputUpdates.Count)
$outputUpdates
