<#
.SYNOPSIS
Gets Windows update entries from Microsoft Update Catalog for offline image servicing.

.DESCRIPTION
Searches Microsoft Update Catalog for one or more update categories (LCU, .NET CU, SSU, Defender, Edge)
matching operating system and architecture, then returns normalized objects for automation and download workflows.

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

.PARAMETER IncludeInsider
Include Windows Insider pre-release updates. Default behavior excludes Insider updates.

.PARAMETER Force
Recreates log file content for the current execution.

.PARAMETER LogPath
Path to log file. Defaults to %TEMP%\Get-TSxLatestWindowsUpdate\Get-TSxWindowsUpdateList.log.

.EXAMPLE
.\Get-TSxWindowsUpdateList.ps1 -OperatingSystem 'Windows 11 24H2' -Architecture x64 -LatestOnly -Verbose

.EXAMPLE
.\Get-TSxWindowsUpdateList.ps1 -OperatingSystem 'Windows 11 24H2' -Architecture x64 -IncludeCumulative -IncludeDotNet -IncludeSSU -LatestOnly -Verbose

.NOTES
FileName   : Get-TSxWindowsUpdateList.ps1
Version    : 1.2.2
Author     : Mikael Nystrom
Contact    : @mikael_nystrom
Created    : 2026-05-22
Updated    : 2026-05-22
Twitter    : @mikael_nystrom
Disclaimer : This script is provided "AS IS" with no warranties.

.LINK
https://www.deploymentbunny.com
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
	[switch]$IncludeCumulative = $true,

	[Parameter()]
	[switch]$IncludeDotNet = $true,

	[Parameter()]
	[switch]$IncludeSSU = $true,

	[Parameter()]
	[switch]$IncludeDefender,

	[Parameter()]
	[switch]$IncludeEdge,

	[Parameter()]
	[switch]$IncludePreview,

	[Parameter()]
	[switch]$IncludeInsider,

	[Parameter()]
	[switch]$Force,

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string]$LogPath = (Join-Path -Path (Join-Path -Path $env:TEMP -ChildPath 'Get-TSxLatestWindowsUpdate') -ChildPath 'Get-TSxWindowsUpdateList.log')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Start-TSxLog {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$FilePath
	)

	$parentPath = Split-Path -Path $FilePath -Parent
	if (-not (Test-Path -Path $parentPath)) {
		$null = New-Item -Path $parentPath -ItemType Directory -Force
	}

	if (-not (Test-Path -Path $FilePath)) {
		$null = New-Item -Path $FilePath -ItemType File -Force
	}

	if ($Force) {
		Clear-Content -Path $FilePath -Force
	}

	$script:ScriptLogFilePath = $FilePath
}

function Write-TSxLog {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Message,

		[Parameter()]
		[ValidateSet('INFO', 'WARN', 'ERROR')]
		[string]$Level = 'INFO'
	)

	$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
	$entry = '[{0}] [{1}] {2}' -f $timestamp, $Level, $Message
	Add-Content -Path $script:ScriptLogFilePath -Value $entry

	switch ($Level) {
		'WARN' { Write-Verbose $Message }
		'ERROR' { Write-Verbose $Message }
		default { Write-Verbose $Message }
	}
}

function Get-TSxDefaultArchitecture {
	[CmdletBinding()]
	param()

	switch -Regex ($env:PROCESSOR_ARCHITECTURE) {
		'ARM64' { return 'arm64' }
		'64' { return 'x64' }
		default { return 'x86' }
	}
}

function ConvertFrom-TSxHtml {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Text
	)

	return ([System.Net.WebUtility]::HtmlDecode(($Text -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim()))
}

function ConvertTo-TSxNormalizedText {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Text
	)

	$normalized = $Text.ToLowerInvariant()
	$normalized = $normalized -replace '[,()]', ' '
	$normalized = $normalized -replace '\bversion\b', ' '
	$normalized = $normalized -replace '\s+', ' '
	return $normalized.Trim()
}

function Test-TSxOperatingSystemMatch {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Title,

		[Parameter()]
		[string]$Product,

		[Parameter(Mandatory = $true)]
		[string]$OperatingSystem
	)

	$normalizedTitle = ConvertTo-TSxNormalizedText -Text $Title
	$normalizedProduct = if ([string]::IsNullOrWhiteSpace($Product)) { '' } else { ConvertTo-TSxNormalizedText -Text $Product }
	$normalizedOperatingSystem = ConvertTo-TSxNormalizedText -Text $OperatingSystem
	$matchText = ('{0} {1}' -f $normalizedTitle, $normalizedProduct).Trim()

	# Avoid cross-family matches (client vs server).
	$requiresServer = $normalizedOperatingSystem -match '\bserver\b'
	$isServerEntry = $matchText -match '\bserver\b'
	if ($requiresServer -and -not $isServerEntry) {
		return $false
	}

	if (-not $requiresServer -and $isServerEntry) {
		return $false
	}

	# Enforce explicit client family phrases to avoid date-token false positives like "2025-11".
	if ($normalizedOperatingSystem -match '\bwindows 11\b' -and $matchText -notmatch '\bwindows 11\b') {
		return $false
	}

	if ($normalizedOperatingSystem -match '\bwindows 10\b' -and $matchText -notmatch '\bwindows 10\b') {
		return $false
	}

	$tokens = $normalizedOperatingSystem.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
	foreach ($token in $tokens) {
		if ($token -eq 'windows') {
			continue
		}

		# Ignore 1-2 digit numeric tokens because dates in titles (e.g. 2025-11) create false positives.
		if ($token -match '^\d{1,2}$') {
			continue
		}

		if ($matchText -notmatch ('\b{0}\b' -f [regex]::Escape($token))) {
			return $false
		}
	}

	return $true
}

function Get-TSxCategoryDefinition {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Name,

		[Parameter(Mandatory = $true)]
		[string]$Query,

		[Parameter(Mandatory = $true)]
		[string[]]$IncludePatterns,

		[Parameter()]
		[string[]]$ExcludePatterns = @()
	)

	return [pscustomobject]@{
		Name            = $Name
		Query           = $Query
		IncludePatterns = $IncludePatterns
		ExcludePatterns = $ExcludePatterns
	}
}

function Test-TSxTitlePatternMatch {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Title,

		[Parameter(Mandatory = $true)]
		[string[]]$IncludePatterns,

		[Parameter()]
		[string[]]$ExcludePatterns = @()
	)

	$matchesInclude = $false
	foreach ($includePattern in $IncludePatterns) {
		if ($Title -match $includePattern) {
			$matchesInclude = $true
			break
		}
	}

	if (-not $matchesInclude) {
		return $false
	}

	foreach ($excludePattern in $ExcludePatterns) {
		if ($Title -match $excludePattern) {
			return $false
		}
	}

	return $true
}

function Get-TSxCatalogSearchResults {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Query
	)

	$searchUri = 'https://www.catalog.update.microsoft.com/Search.aspx?q={0}' -f [uri]::EscapeDataString($Query)
	Write-TSxLog -Message ('Searching Windows Update Catalog: {0}' -f $searchUri)
	if (-not $PSCmdlet.ShouldProcess($searchUri, 'Query Windows Update Catalog')) {
		Write-TSxLog -Level 'WARN' -Message 'WhatIf: Catalog query skipped by ShouldProcess.'
		return @()
	}
	$response = Invoke-WebRequest -UseBasicParsing -Uri $searchUri
	$rowPattern = [regex]::new('<tr id="(?<UpdateId>[0-9a-f-]+)_R\d+"[^>]*>(?<RowHtml>.*?)</tr>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
	$resultRowMatch = $rowPattern.Match($response.Content)

	while ($resultRowMatch.Success) {
		$rowHtml = $resultRowMatch.Groups['RowHtml'].Value
		$titleMatch = [regex]::Match($rowHtml, '<a id=''.*?_link''[^>]*>(?<Title>.*?)</a>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
		$productMatch = [regex]::Match($rowHtml, '_C2_R\d+">\s*(?<Product>.*?)\s*</td>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
		$classificationMatch = [regex]::Match($rowHtml, '_C3_R\d+">\s*(?<Classification>.*?)\s*</td>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
		$lastUpdatedMatch = [regex]::Match($rowHtml, '_C4_R\d+">\s*(?<LastUpdated>.*?)\s*</td>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
		$sizeMatch = [regex]::Match($rowHtml, '<span id=".*?_size">\s*(?<Size>.*?)\s*</span>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)

		if (-not $titleMatch.Success) {
			continue
		}

		$title = ConvertFrom-TSxHtml -Text $titleMatch.Groups['Title'].Value
		$lastUpdated = $null
		if ($lastUpdatedMatch.Success) {
			$lastUpdated = [datetime]::Parse((ConvertFrom-TSxHtml -Text $lastUpdatedMatch.Groups['LastUpdated'].Value), [System.Globalization.CultureInfo]::InvariantCulture)
		}

		$build = [version]'0.0'
		$buildMatch = [regex]::Match($title, '\((?<Build>\d+(?:\.\d+)+)\)\s*$')
		if ($buildMatch.Success) {
			$build = [version]$buildMatch.Groups['Build'].Value
		}

		[pscustomobject]@{
			UpdateId       = $resultRowMatch.Groups['UpdateId'].Value
			Title          = $title
			Product        = if ($productMatch.Success) { ConvertFrom-TSxHtml -Text $productMatch.Groups['Product'].Value } else { '' }
			Classification = if ($classificationMatch.Success) { ConvertFrom-TSxHtml -Text $classificationMatch.Groups['Classification'].Value } else { '' }
			LastUpdated    = $lastUpdated
			Size           = if ($sizeMatch.Success) { ConvertFrom-TSxHtml -Text $sizeMatch.Groups['Size'].Value } else { '' }
			Build          = $build
		}

		$resultRowMatch = $resultRowMatch.NextMatch()
	}
}

function ConvertTo-TSxUpdateObject {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[pscustomobject]$Update,

		[Parameter(Mandatory = $true)]
		[string]$OperatingSystem,

		[Parameter(Mandatory = $true)]
		[string]$Architecture,

		[Parameter(Mandatory = $true)]
		[string]$SearchQuery,

		[Parameter(Mandatory = $true)]
		[string]$UpdateType,

		[Parameter(Mandatory = $true)]
		[string]$LogPath
	)

	$kbMatch = [regex]::Match($Update.Title, '(KB\d+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
	$kb = if ($kbMatch.Success) { $kbMatch.Groups[1].Value.ToUpperInvariant() } else { $null }

	[pscustomobject]@{
		PSTypeName      = 'TSx.WindowsUpdate.CatalogEntry'
		OperatingSystem = $OperatingSystem
		Architecture    = $Architecture
		SearchQuery     = $SearchQuery
		UpdateType      = $UpdateType
		UpdateId        = $Update.UpdateId
		KB              = $kb
		Title           = $Update.Title
		Product         = $Update.Product
		Classification  = $Update.Classification
		LastUpdated     = $Update.LastUpdated
		Size            = $Update.Size
		Build           = $Update.Build
		CatalogUrl      = ('https://www.catalog.update.microsoft.com/ScopedViewInline.aspx?updateid={0}' -f $Update.UpdateId)
		LogPath         = $LogPath
	}
}

$scriptName = Split-Path -Path $PSCommandPath -Leaf
Start-TSxLog -FilePath $LogPath
Write-TSxLog -Message ('{0} started' -f $scriptName)

if (-not $PSBoundParameters.ContainsKey('Architecture')) {
	$Architecture = Get-TSxDefaultArchitecture
}

Write-TSxLog -Message ('OperatingSystem: {0}' -f $OperatingSystem)
Write-TSxLog -Message ('Architecture: {0}' -f $Architecture)
Write-TSxLog -Message ('LatestOnly: {0}' -f $LatestOnly.IsPresent)
Write-TSxLog -Message ('IncludeCumulative: {0}' -f $IncludeCumulative.IsPresent)
Write-TSxLog -Message ('IncludeDotNet: {0}' -f $IncludeDotNet.IsPresent)
Write-TSxLog -Message ('IncludeSSU: {0}' -f $IncludeSSU.IsPresent)
Write-TSxLog -Message ('IncludeDefender: {0}' -f $IncludeDefender.IsPresent)
Write-TSxLog -Message ('IncludeEdge: {0}' -f $IncludeEdge.IsPresent)
Write-TSxLog -Message ('IncludePreview: {0}' -f $IncludePreview.IsPresent)
Write-TSxLog -Message ('IncludeInsider: {0}' -f $IncludeInsider.IsPresent)
Write-TSxLog -Message ('Force: {0}' -f $Force.IsPresent)
Write-TSxLog -Message ('Log path: {0}' -f $LogPath)

if (-not ($IncludeCumulative -or $IncludeDotNet -or $IncludeSSU -or $IncludeDefender -or $IncludeEdge)) {
	throw 'No update categories selected. Enable at least one category switch.'
}

$categoryDefinitions = New-Object System.Collections.Generic.List[object]

if ($IncludeCumulative) {
	$null = $categoryDefinitions.Add((Get-TSxCategoryDefinition -Name 'Cumulative' -Query '{0} {1} cumulative update' -IncludePatterns @('(?i)Cumulative Update for') -ExcludePatterns @('(?i)\.NET Framework', '(?i)Dynamic Cumulative Update', '(?i)Setup Dynamic Update', '(?i)Adobe')))
}

if ($IncludeDotNet) {
	$null = $categoryDefinitions.Add((Get-TSxCategoryDefinition -Name 'DotNet' -Query '{0} {1} .NET Framework cumulative update' -IncludePatterns @('(?i)Cumulative Update for .*\.NET Framework')))
}

if ($IncludeSSU) {
	$null = $categoryDefinitions.Add((Get-TSxCategoryDefinition -Name 'SSU' -Query '{0} {1} servicing stack update' -IncludePatterns @('(?i)Servicing Stack Update')))
}

if ($IncludeDefender) {
	$null = $categoryDefinitions.Add((Get-TSxCategoryDefinition -Name 'Defender' -Query '{0} {1} defender update' -IncludePatterns @('(?i)Defender', '(?i)Security Intelligence Update')))
}

if ($IncludeEdge) {
	$null = $categoryDefinitions.Add((Get-TSxCategoryDefinition -Name 'Edge' -Query '{0} {1} Edge Stable' -IncludePatterns @('(?i)Edge')))
}

$outputUpdates = New-Object System.Collections.Generic.List[object]
$seenUpdateIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

foreach ($categoryDefinition in $categoryDefinitions) {
	$searchQuery = $categoryDefinition.Query -f $OperatingSystem, $Architecture
	$searchResults = @(Get-TSxCatalogSearchResults -Query $searchQuery)
	Write-TSxLog -Message ('Catalog returned {0} result(s) for {1}' -f $searchResults.Count, $categoryDefinition.Name)

	if ($searchResults.Count -eq 0 -and $WhatIfPreference) {
		Write-TSxLog -Level 'WARN' -Message ('WhatIf mode produced no catalog results for {0} because the web request was skipped.' -f $categoryDefinition.Name)
		continue
	}

	$candidateUpdates = $searchResults | Where-Object {
		$matchesCategory = Test-TSxTitlePatternMatch -Title $_.Title -IncludePatterns $categoryDefinition.IncludePatterns -ExcludePatterns $categoryDefinition.ExcludePatterns
		$matchesArchitecture = $_.Title -match ('(?i){0}' -f [regex]::Escape($Architecture))
		$matchesOperatingSystem = Test-TSxOperatingSystemMatch -Title $_.Title -Product $_.Product -OperatingSystem $OperatingSystem
		$matchesPreviewRule = $IncludePreview -or ($_.Title -notmatch '(?i)Preview')
		$isInsiderUpdate = $_.Title -match '(?i)Windows Insider|Insider Pre-Release' -or $_.Product -match '(?i)Windows Insider|Insider Pre-Release'
		$matchesInsiderRule = $IncludeInsider -or (-not $isInsiderUpdate)
		$matchesCategory -and $matchesArchitecture -and $matchesOperatingSystem -and $matchesPreviewRule -and $matchesInsiderRule
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
			$null = $outputUpdates.Add((ConvertTo-TSxUpdateObject -Update $update -OperatingSystem $OperatingSystem -Architecture $Architecture -SearchQuery $searchQuery -UpdateType $categoryDefinition.Name -LogPath $LogPath))
		}
		else {
			Write-TSxLog -Message ('Skipping duplicate UpdateId {0} from category {1}' -f $update.UpdateId, $categoryDefinition.Name)
		}
	}
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
