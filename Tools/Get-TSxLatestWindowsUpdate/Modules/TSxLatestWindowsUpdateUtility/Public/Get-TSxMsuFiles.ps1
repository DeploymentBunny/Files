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
