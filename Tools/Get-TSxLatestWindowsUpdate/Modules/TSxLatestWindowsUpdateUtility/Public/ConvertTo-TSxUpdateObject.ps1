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
        [string]$UpdateType,

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
        UpdateType      = $UpdateType
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
