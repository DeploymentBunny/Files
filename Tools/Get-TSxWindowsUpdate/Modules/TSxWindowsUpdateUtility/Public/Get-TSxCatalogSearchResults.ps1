function Get-TSxCatalogSearchResults {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    $searchUri = 'https://www.catalog.update.microsoft.com/Search.aspx?q={0}' -f [uri]::EscapeDataString($Query)

    if (-not $PSCmdlet.ShouldProcess($searchUri, 'Query Windows Update Catalog')) {
        return
    }

    Write-TSxLog -Message ('Searching Windows Update Catalog: {0}' -f $searchUri)

    $previousProgressPreference = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $searchUri
    }
    finally {
        $ProgressPreference = $previousProgressPreference
    }
    $rowPattern = [regex]::new('<tr id="(?<UpdateId>[0-9a-f-]+)_R\d+"[^>]*>(?<RowHtml>.*?)</tr>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $resultRowMatch = $rowPattern.Match($response.Content)

    while ($resultRowMatch.Success) {
        $rowHtml = $resultRowMatch.Groups['RowHtml'].Value
        $titleMatch = [regex]::Match($rowHtml, '<a id=''.*?_link''[^>]*>(?<Title>.*?)</a>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
        $productMatch = [regex]::Match($rowHtml, '_C2_R\d+">\s*(?<Product>.*?)\s*</td>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
        $classificationMatch = [regex]::Match($rowHtml, '_C3_R\d+">\s*(?<Classification>.*?)\s*</td>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
        $lastUpdatedMatch = [regex]::Match($rowHtml, '_C4_R\d+">\s*(?<LastUpdated>.*?)\s*</td>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
        $sizeMatch = [regex]::Match($rowHtml, '<span id=".*?_size">\s*(?<Size>.*?)\s*</span>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)

        if (-not $titleMatch.Success) { continue }

        $title = ConvertFrom-TSxHtml -Text $titleMatch.Groups['Title'].Value
        $lastUpdated = $null
        if ($lastUpdatedMatch.Success) {
            $lastUpdated = [datetime]::Parse((ConvertFrom-TSxHtml -Text $lastUpdatedMatch.Groups['LastUpdated'].Value), [System.Globalization.CultureInfo]::InvariantCulture)
        }

        $build = [version]'0.0'
        $buildMatch = [regex]::Match($title, '\((?<Build>\d+(?:\.\d+)+)\)\s*$')
        if ($buildMatch.Success) { $build = [version]$buildMatch.Groups['Build'].Value }

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
