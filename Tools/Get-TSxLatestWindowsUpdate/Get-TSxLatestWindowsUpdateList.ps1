[CmdletBinding()]
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
	[ValidateNotNullOrEmpty()]
	[string]$LogPath = (Join-Path -Path $env:TEMP -ChildPath 'Get-TSxWindowsUpdates.log')
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

		[Parameter(Mandatory = $true)]
		[string]$OperatingSystem
	)

	$normalizedTitle = ConvertTo-TSxNormalizedText -Text $Title
	$tokens = (ConvertTo-TSxNormalizedText -Text $OperatingSystem).Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
	foreach ($token in $tokens) {
		if ($normalizedTitle -notmatch ('\b{0}\b' -f [regex]::Escape($token))) {
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
		[string]$LogPath
	)

	$kbMatch = [regex]::Match($Update.Title, '(KB\d+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
	$kb = if ($kbMatch.Success) { $kbMatch.Groups[1].Value.ToUpperInvariant() } else { $null }

	[pscustomobject]@{
		PSTypeName      = 'TSx.WindowsUpdate.CatalogEntry'
		OperatingSystem = $OperatingSystem
		Architecture    = $Architecture
		SearchQuery     = $SearchQuery
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
Write-TSxLog -Message ('Log path: {0}' -f $LogPath)

$searchQuery = '{0} {1} cumulative update' -f $OperatingSystem, $Architecture
$searchResults = @(Get-TSxCatalogSearchResults -Query $searchQuery)
Write-TSxLog -Message ('Catalog returned {0} result(s)' -f $searchResults.Count)

$candidateUpdates = $searchResults | Where-Object {
	$_.Title -match '(?i)Cumulative Update for' -and
	$_.Title -notmatch '(?i)Preview' -and
	$_.Title -notmatch '(?i)\.NET Framework' -and
	$_.Title -notmatch '(?i)Dynamic Cumulative Update' -and
	$_.Title -notmatch '(?i)Setup Dynamic Update' -and
	$_.Title -notmatch '(?i)Adobe' -and
	(Test-TSxOperatingSystemMatch -Title $_.Title -OperatingSystem $OperatingSystem) -and
	$_.Title -match ('(?i){0}' -f [regex]::Escape($Architecture))
}

if (-not $candidateUpdates) {
	Write-TSxLog -Level 'WARN' -Message 'No non-preview cumulative update matched. Trying preview updates.'
	$candidateUpdates = $searchResults | Where-Object {
		$_.Title -match '(?i)Cumulative Update' -and
		$_.Title -notmatch '(?i)\.NET Framework' -and
		$_.Title -notmatch '(?i)Dynamic Cumulative Update' -and
		$_.Title -notmatch '(?i)Setup Dynamic Update' -and
		(Test-TSxOperatingSystemMatch -Title $_.Title -OperatingSystem $OperatingSystem) -and
		$_.Title -match ('(?i){0}' -f [regex]::Escape($Architecture))
	}
}

if (-not $candidateUpdates) {
	throw ('No cumulative update was found for operating system "{0}" and architecture "{1}".' -f $OperatingSystem, $Architecture)
}


$sortedCandidateUpdates = @(
	$candidateUpdates |
	Sort-Object -Property @{ Expression = { $_.LastUpdated }; Descending = $true }, @{ Expression = { $_.Build }; Descending = $true }, @{ Expression = { $_.Title }; Descending = $true }
)

Write-TSxLog -Message ('Returning {0} candidate update(s).' -f $(if ($LatestOnly) { 1 } else { $sortedCandidateUpdates.Count }))

if ($LatestOnly) {
	$sortedCandidateUpdates |
		Select-Object -First 1 |
		ForEach-Object {
			ConvertTo-TSxUpdateObject -Update $_ -OperatingSystem $OperatingSystem -Architecture $Architecture -SearchQuery $searchQuery -LogPath $LogPath
		}
}
else {
	$sortedCandidateUpdates |
		ForEach-Object {
			ConvertTo-TSxUpdateObject -Update $_ -OperatingSystem $OperatingSystem -Architecture $Architecture -SearchQuery $searchQuery -LogPath $LogPath
		}
}
