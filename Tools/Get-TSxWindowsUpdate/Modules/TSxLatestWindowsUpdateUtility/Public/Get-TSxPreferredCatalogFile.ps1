function Get-TSxPreferredCatalogFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Files,

        [Parameter()]
        [string]$KB,

        [Parameter(Mandatory = $true)]
        [ValidateSet('x64', 'arm64', 'x86')]
        [string]$Architecture
    )

    $kbToken = $null
    if (-not [string]::IsNullOrWhiteSpace($KB)) {
        $kbToken = $KB.ToLowerInvariant()
    }

    $rankedFiles = @(
        foreach ($file in $Files) {
            if (-not $file) { continue }
            if (-not $file.PSObject.Properties['FileName'] -or [string]::IsNullOrWhiteSpace([string]$file.FileName)) { continue }

            [pscustomobject]@{
                File = $file
                KbScore = if ($kbToken -and $file.FileName -match [regex]::Escape($kbToken)) { 0 } else { 1 }
                ArchitectureScore = if ($file.FileName -match ('(?i){0}' -f [regex]::Escape($Architecture))) { 0 } else { 1 }
                ExtensionScore = if ($file.FileName -match '(?i)\.msu$') { 0 } else { 1 }
                Name = [string]$file.FileName
            }
        }
    )

    if (-not $rankedFiles) {
        throw 'Catalog returned no valid downloadable file entries for this update.'
    }

    $selectedFile = $rankedFiles |
        Sort-Object -Property KbScore, ArchitectureScore, ExtensionScore, Name |
        Select-Object -First 1 -ExpandProperty File

    if (-not $selectedFile) {
        throw 'Catalog did not return any downloadable file entries.'
    }

    return $selectedFile
}
