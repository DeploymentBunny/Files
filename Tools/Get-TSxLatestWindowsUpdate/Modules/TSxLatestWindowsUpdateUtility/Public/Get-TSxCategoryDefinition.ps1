function Get-TSxCategoryDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Query,

        [Parameter(Mandatory = $true)]
        [string[]]$IncludePatterns,

        [Parameter()]
        [string[]]$ExcludePatterns = @()
    )

    return [pscustomobject]@{
        Name            = $Name
        Query           = $Query
        IncludePatterns = $IncludePatterns
        ExcludePatterns = $ExcludePatterns
    }
}
