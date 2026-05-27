function Get-TSxMsuFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        throw "UpdatePath not found: $Path"
    }

    $allowedExtensions = @('.msu', '.cab')
    $item = Get-Item -Path $Path -ErrorAction Stop
    if ($item.PSIsContainer) {
        $files = Get-ChildItem -Path $item.FullName -File -Recurse |
            Where-Object { $_.Extension.ToLowerInvariant() -in $allowedExtensions } |
            Sort-Object FullName
    }
    else {
        if ($item.Extension.ToLowerInvariant() -notin $allowedExtensions) {
            throw "UpdatePath is a file but not a supported package type (.msu or .cab): $($item.FullName)"
        }
        $files = @($item)
    }

    if (-not $files -or $files.Count -eq 0) {
        throw "No .msu or .cab files found in UpdatePath: $Path"
    }

    return $files
}
