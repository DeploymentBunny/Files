function Import-TSxUiSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SettingsFile
    )

    if (-not (Test-Path -LiteralPath $SettingsFile -PathType Leaf)) {
        return $null
    }

    try {
        $settings = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
        Write-TSxLog -Message ('Settings loaded: {0}' -f $SettingsFile)
        return $settings
    }
    catch {
        Write-TSxLog -Level 'WARN' -Message ('Failed to load settings. Error: {0}' -f $_.Exception.Message)
        return $null
    }
}
