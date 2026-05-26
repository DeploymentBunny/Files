$functionFiles = @(
    'Start-TSxLog.ps1',
    'Write-TSxLog.ps1',
    'Add-TSxUiOutput.ps1',
    'Get-TSxExecutionContext.ps1',
    'Save-TSxUiSettings.ps1',
    'Import-TSxUiSettings.ps1',
    'Get-TSxDeploymentBunnyLogoImage.ps1',
    'Get-TSxDefaultArchitecture.ps1',
    'ConvertFrom-TSxHtml.ps1',
    'ConvertTo-TSxNormalizedText.ps1',
    'Test-TSxOperatingSystemMatch.ps1',
    'Get-TSxCategoryDefinition.ps1',
    'Test-TSxTitlePatternMatch.ps1',
    'Get-TSxCatalogSearchResults.ps1',
    'ConvertTo-TSxUpdateObject.ps1',
    'Get-TSxCatalogDownloadFiles.ps1',
    'Get-TSxPreferredCatalogFile.ps1',
    'Invoke-TSxFileDownload.ps1',
    'Assert-TSxAdministrator.ps1',
    'Get-TSxMsuFiles.ps1',
    'Get-TSxOfflineWindowsPath.ps1',
    'Add-TSxPackagesToWim.ps1',
    'Add-TSxPackagesToVhdx.ps1'
)

foreach ($functionFile in $functionFiles) {
    . (Join-Path (Join-Path $PSScriptRoot 'Public') $functionFile)
}
