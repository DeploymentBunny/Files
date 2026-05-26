function ConvertFrom-TSxHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    return ([System.Net.WebUtility]::HtmlDecode(($Text -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim()))
}
