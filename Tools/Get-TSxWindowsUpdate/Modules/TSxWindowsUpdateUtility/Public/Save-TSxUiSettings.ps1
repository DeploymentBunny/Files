function Save-TSxUiSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SettingsDirectory,

        [Parameter(Mandatory = $true)]
        [string]$SettingsFile,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Settings
    )

    try {
        if (-not (Test-Path -LiteralPath $SettingsDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $SettingsDirectory -Force | Out-Null
        }

        $Settings | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $SettingsFile -Encoding UTF8
        Write-TSxLog -Message ('Settings saved: {0}' -f $SettingsFile)
    }
    catch {
        Write-TSxLog -Level 'WARN' -Message ('Failed to save settings. Error: {0}' -f $_.Exception.Message)
    }
}
