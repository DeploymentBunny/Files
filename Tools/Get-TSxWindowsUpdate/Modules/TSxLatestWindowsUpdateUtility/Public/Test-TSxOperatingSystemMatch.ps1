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

    $requiresServer = $normalizedOperatingSystem -match '\bserver\b'
    $isServerEntry = $matchText -match '\bserver\b'
    if ($requiresServer -and -not $isServerEntry) { return $false }
    if (-not $requiresServer -and $isServerEntry) { return $false }

    if ($normalizedOperatingSystem -match '\bwindows 11\b' -and $matchText -notmatch '\bwindows 11\b') { return $false }
    if ($normalizedOperatingSystem -match '\bwindows 10\b' -and $matchText -notmatch '\bwindows 10\b') { return $false }

    $tokens = $normalizedOperatingSystem.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
    foreach ($token in $tokens) {
        if ($token -eq 'windows') { continue }
        if ($token -match '^\d{1,2}$') { continue }
        if ($matchText -notmatch ('\b{0}\b' -f [regex]::Escape($token))) { return $false }
    }

    return $true
}
