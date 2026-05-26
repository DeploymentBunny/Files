function Get-TSxCatalogDownloadFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$UpdateId
    )

    $requestBody = @{
        updateIDs = ('[{{"size":0,"languages":"","uidInfo":"{0}","updateID":"{0}"}}]' -f $UpdateId)
    }

    Write-TSxLog -Message ('Resolving files for UpdateId {0}' -f $UpdateId)
    $previousProgressPreference = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' -Body $requestBody
    }
    finally {
        $ProgressPreference = $previousProgressPreference
    }
    $filePattern = [regex]::new("downloadInformation\[0\]\.files\[(?<Index>\d+)\]\.(?<Property>url|fileName|sha256|digest) = '(?<Value>.*?)';", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $fileMatch = $filePattern.Match($response.Content)
    $files = @{}

    while ($fileMatch.Success) {
        $index = [int]$fileMatch.Groups['Index'].Value
        if (-not $files.ContainsKey($index)) {
            $files[$index] = [ordered]@{}
        }

        $files[$index][$fileMatch.Groups['Property'].Value] = [System.Net.WebUtility]::HtmlDecode($fileMatch.Groups['Value'].Value)
        $fileMatch = $fileMatch.NextMatch()
    }

    foreach ($index in ($files.Keys | Sort-Object)) {
        [pscustomobject]@{
            Url      = $files[$index]['url']
            FileName = $files[$index]['fileName']
            Sha256   = $files[$index]['sha256']
            Sha1     = $files[$index]['digest']
        }
    }
}
