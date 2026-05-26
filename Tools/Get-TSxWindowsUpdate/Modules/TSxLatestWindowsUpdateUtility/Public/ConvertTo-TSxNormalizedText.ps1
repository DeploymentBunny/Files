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
