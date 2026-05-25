<#
.SYNOPSIS
    Downloads one or more Windows updates from Microsoft Update Catalog.

.DESCRIPTION
    Accepts update objects from the catalog list script, resolves downloadable files for each UpdateId,
    selects the best file for the requested architecture, and downloads to a target folder.

.PARAMETER InputObject
    Pipeline input object containing at least UpdateId, and optionally KB, Architecture, and Title.

.PARAMETER Path
    Destination folder for downloaded updates.

.PARAMETER Force
    Overwrites existing destination files and recreates the log file content for the current execution.

.EXAMPLE
    Get-TSxWindowsUpdateList.ps1 -OperatingSystem 'Windows 11 24H2' -LatestOnly |
        .\Save-TSxWindowsUpdateFromCatalog.ps1 -Path 'C:\Temp\Updates' -Verbose -WhatIf

.NOTES
    FileName:    Save-TSxWindowsUpdateFromCatalog.ps1
    Version:     1.2.9
    Author:      Mikael Nystrom
    Contact:     @mikael_nystrom
    Created:     2026-05-22
    Updated:     2026-05-25
    Twitter:     @mikael_nystrom

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author.

.LINK
    https://www.deploymentbunny.com

.FUNCTIONALITY
    Resolves catalog download links and downloads selected update files to disk.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
    [ValidateNotNull()]
    [psobject]$InputObject,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Path,

    [Parameter()]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogRootPath = Join-Path -Path $env:TEMP -ChildPath 'Get-TSxLatestWindowsUpdate'
$script:LogFilePath = Join-Path -Path $script:LogRootPath -ChildPath ('{0}.log' -f [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath))

Import-Module -Name (Join-Path $PSScriptRoot 'Modules\TSxLatestWindowsUpdateUtility\TSxLatestWindowsUpdateUtility.psd1') -Force -ErrorAction Stop

$scriptName = Split-Path -Path $PSCommandPath -Leaf
Start-TSxLog -FilePath $script:LogFilePath -Force:$Force
Write-TSxLog -Message ('{0} started' -f $scriptName)
Write-TSxLog -Message ('Download path: {0}' -f $Path)
Write-TSxLog -Message ('Force: {0}' -f $Force.IsPresent)
Write-TSxLog -Message ('Log root path: {0}' -f $script:LogRootPath)
Write-TSxLog -Message ('Log path: {0}' -f $script:LogFilePath)

if (-not (Test-Path -Path $Path)) {
    Write-TSxLog -Message ('Creating download directory: {0}' -f $Path)
    if ($PSCmdlet.ShouldProcess($Path, 'Create download directory')) {
        $null = New-Item -Path $Path -ItemType Directory -Force
    }
}

$allInputObjects = New-Object System.Collections.Generic.List[object]
$pipelineInputObjects = @($input)
if ($pipelineInputObjects.Count -gt 0) {
    foreach ($pipelineInputObject in $pipelineInputObjects) {
        $allInputObjects.Add($pipelineInputObject)
    }
}
elseif ($PSBoundParameters.ContainsKey('InputObject')) {
    $allInputObjects.Add($InputObject)
}

if ($allInputObjects.Count -eq 0) {
    throw 'No input objects were provided. Pipe objects from Get-TSxWindowsUpdateList.ps1 or pass -InputObject.'
}

foreach ($currentInputObject in $allInputObjects) {
    if (-not $currentInputObject.PSObject.Properties['UpdateId']) {
        throw 'Pipeline object is missing required property: UpdateId.'
    }

    $updateId = [string]$currentInputObject.UpdateId
    if ([string]::IsNullOrWhiteSpace($updateId)) {
        throw 'Pipeline object has an empty UpdateId value.'
    }

    $kb = if ($currentInputObject.PSObject.Properties['KB']) { [string]$currentInputObject.KB } else { $null }
    $architecture = if ($currentInputObject.PSObject.Properties['Architecture'] -and -not [string]::IsNullOrWhiteSpace([string]$currentInputObject.Architecture)) {
        [string]$currentInputObject.Architecture
    }
    else {
        Get-TSxDefaultArchitecture
    }

    if ($architecture -notin @('x64', 'arm64', 'x86')) {
        throw ('Unsupported architecture value "{0}" on pipeline object. Expected x64, arm64 or x86.' -f $architecture)
    }

    Write-TSxLog -Message ('Processing UpdateId {0} (Architecture: {1}, KB: {2})' -f $updateId, $architecture, $kb)

    $downloadFiles = @(Get-TSxCatalogDownloadFiles -UpdateId $updateId)
    if (-not $downloadFiles) {
        throw ('No files returned from catalog for UpdateId {0}.' -f $updateId)
    }

    $selectedFile = Get-TSxPreferredCatalogFile -Files $downloadFiles -KB $kb -Architecture $architecture
    $destinationPath = Join-Path -Path $Path -ChildPath $selectedFile.FileName
    $sourceTitle = if ($currentInputObject.PSObject.Properties['Title']) { [string]$currentInputObject.Title } else { $null }
    $updateDisplayName = if (-not [string]::IsNullOrWhiteSpace($sourceTitle)) { $sourceTitle } else { $selectedFile.FileName }

    Write-TSxLog -Message ('Selected update: {0} (UpdateId: {1})' -f $updateDisplayName, $updateId)
    Write-TSxLog -Message ('Selected file: {0}' -f $selectedFile.FileName)
    Write-TSxLog -Message ('Source URL: {0}' -f $selectedFile.Url)
    Write-TSxLog -Message ('Destination: {0}' -f $destinationPath)

    if ((Test-Path -Path $destinationPath) -and -not $Force) {
        Write-TSxLog -Level 'WARN' -Message ('Skipping existing file (use -Force to overwrite): {0}' -f $destinationPath)
        [pscustomobject]@{
            PSTypeName      = 'TSx.WindowsUpdate.DownloadResult'
            UpdateId        = $updateId
            KB              = $kb
            Architecture    = $architecture
            SourceTitle     = $sourceTitle
            FileName        = $selectedFile.FileName
            DownloadUrl     = $selectedFile.Url
            DestinationPath = $destinationPath
            LogPath         = $script:LogFilePath
            WasDownloaded   = $false
            WasSkipped      = $true
            Forced          = $false
        }
        continue
    }

    if ((Test-Path -Path $destinationPath) -and $Force) {
        Write-TSxLog -Message ('Force enabled, removing existing file: {0}' -f $destinationPath)
        if ($PSCmdlet.ShouldProcess($destinationPath, 'Remove existing destination file')) {
            Remove-Item -Path $destinationPath -Force
        }
    }

    if ($PSCmdlet.ShouldProcess($destinationPath, ('Download {0} (UpdateId: {1})' -f $updateDisplayName, $updateId))) {
        Invoke-TSxFileDownload -Url $selectedFile.Url -DestinationPath $destinationPath -UpdateId $updateId -UpdateName $updateDisplayName
        Write-TSxLog -Message ('Download completed: {0}' -f $destinationPath)
    }

    [pscustomobject]@{
        PSTypeName      = 'TSx.WindowsUpdate.DownloadResult'
        UpdateId        = $updateId
        KB              = $kb
        Architecture    = $architecture
        SourceTitle     = $sourceTitle
        FileName        = $selectedFile.FileName
        DownloadUrl     = $selectedFile.Url
        DestinationPath = $destinationPath
        LogPath         = $script:LogFilePath
        WasDownloaded   = [bool](-not $WhatIfPreference)
        WasSkipped      = $false
        Forced          = [bool]$Force
    }
}
