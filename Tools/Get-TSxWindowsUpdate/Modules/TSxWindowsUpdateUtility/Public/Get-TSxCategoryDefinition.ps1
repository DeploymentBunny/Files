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
        [string[]]$ExcludePatterns = @(),

        [Parameter()]
        [bool]$RequiresOperatingSystemMatch = $true,

        [Parameter()]
        [bool]$RequiresArchitectureMatch = $true
    )

    return [pscustomobject]@{
        Name                         = $Name
        Query                        = $Query
        IncludePatterns              = $IncludePatterns
        ExcludePatterns              = $ExcludePatterns
        RequiresOperatingSystemMatch = $RequiresOperatingSystemMatch
        RequiresArchitectureMatch    = $RequiresArchitectureMatch
    }
}
