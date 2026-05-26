function Get-TSxDeploymentBunnyLogoImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$UiScriptRoot
    )

    $dedupUiPath = Join-Path -Path (Split-Path -Path $UiScriptRoot -Parent) -ChildPath 'Start-VIADeDupJob\Invoke-TSxDeDupJobUI.ps1'
    if (-not (Test-Path -LiteralPath $dedupUiPath -PathType Leaf)) {
        return $null
    }

    try {
        $dedupUiContent = Get-Content -LiteralPath $dedupUiPath -Raw
        $pictureStringMatch = [regex]::Match($dedupUiContent, '\$PictureString\s*=\s*"(?<data>[^"]+)"')
        if (-not $pictureStringMatch.Success) {
            return $null
        }

        $logoBytes = [Convert]::FromBase64String($pictureStringMatch.Groups['data'].Value)
        $logoStream = New-Object System.IO.MemoryStream(,$logoBytes)
        return [System.Drawing.Image]::FromStream($logoStream)
    }
    catch {
        return $null
    }
}
