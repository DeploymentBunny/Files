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

    if (-not $matchesInclude) { return $false }

    foreach ($excludePattern in $ExcludePatterns) {
        if ($Title -match $excludePattern) { return $false }
    }

    return $true
}
