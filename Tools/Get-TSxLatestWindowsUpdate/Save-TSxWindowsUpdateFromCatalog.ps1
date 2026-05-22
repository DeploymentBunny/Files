<#
.SYNOPSIS
Downloads one or more Windows updates from Microsoft Update Catalog.

.DESCRIPTION
Accepts update objects from the catalog list script, resolves downloadable files for each UpdateId,
selects the best file for requested architecture, and downloads to a target folder.

.PARAMETER InputObject
Pipeline input object containing at least UpdateId, and optionally KB, Architecture, and Title.

.PARAMETER Path
Destination folder for downloaded updates.

.PARAMETER Force
Overwrites existing destination files and recreates the log file content for the current execution.

.PARAMETER LogPath
Path to log file. Defaults to %TEMP%\Get-TSxLatestWindowsUpdate\Save-TSxWindowsUpdateFromCatalog.log.

.EXAMPLE
Get-TSxWindowsUpdateList.ps1 -OperatingSystem 'Windows 11 24H2' -LatestOnly |
    .\Save-TSxWindowsUpdateFromCatalog.ps1 -Path 'C:\Temp\Updates' -Verbose -WhatIf

.NOTES
FileName   : Save-TSxWindowsUpdateFromCatalog.ps1
Version    : 1.2.5
Author     : Mikael Nystrom
Contact    : @mikael_nystrom
Created    : 2026-05-22
Updated    : 2026-05-22
Twitter    : @mikael_nystrom
Disclaimer : This script is provided "AS IS" with no warranties.

.LINK
https://www.deploymentbunny.com
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
    [switch]$Force,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogPath = (Join-Path -Path (Join-Path -Path $env:TEMP -ChildPath 'Get-TSxLatestWindowsUpdate') -ChildPath 'Save-TSxWindowsUpdateFromCatalog.log')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Start-TSxLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $parentPath = Split-Path -Path $FilePath -Parent
    if (-not (Test-Path -Path $parentPath)) {
        $null = New-Item -Path $parentPath -ItemType Directory -Force
    }

    if (-not (Test-Path -Path $FilePath)) {
        $null = New-Item -Path $FilePath -ItemType File -Force
    }

    if ($Force) {
        Clear-Content -Path $FilePath -Force
    }

    $script:ScriptLogFilePath = $FilePath
}

function Write-TSxLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = '[{0}] [{1}] {2}' -f $timestamp, $Level, $Message
    Add-Content -Path $script:ScriptLogFilePath -Value $entry
    Write-Verbose $Message
}

function Get-TSxDefaultArchitecture {
    [CmdletBinding()]
    param()

    switch -Regex ($env:PROCESSOR_ARCHITECTURE) {
        'ARM64' { return 'arm64' }
        '64' { return 'x64' }
        default { return 'x86' }
    }
}

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
    $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' -Body $requestBody
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

function Get-TSxPreferredCatalogFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Files,

        [Parameter()]
        [string]$KB,

        [Parameter(Mandatory = $true)]
        [ValidateSet('x64', 'arm64', 'x86')]
        [string]$Architecture
    )

    $kbToken = $null
    if (-not [string]::IsNullOrWhiteSpace($KB)) {
        $kbToken = $KB.ToLowerInvariant()
    }

    $rankedFiles = @(
        foreach ($file in $Files) {
            if (-not $file) {
                continue
            }

            if (-not $file.PSObject.Properties['FileName'] -or [string]::IsNullOrWhiteSpace([string]$file.FileName)) {
                continue
            }

            [pscustomobject]@{
                File = $file
                KbScore = if ($kbToken -and $file.FileName -match [regex]::Escape($kbToken)) { 0 } else { 1 }
                ArchitectureScore = if ($file.FileName -match ('(?i){0}' -f [regex]::Escape($Architecture))) { 0 } else { 1 }
                ExtensionScore = if ($file.FileName -match '(?i)\.msu$') { 0 } else { 1 }
                Name = [string]$file.FileName
            }
        }
    )

    if (-not $rankedFiles) {
        throw 'Catalog returned no valid downloadable file entries for this update.'
    }

    $selectedFile = $rankedFiles |
        Sort-Object -Property KbScore, ArchitectureScore, ExtensionScore, Name |
        Select-Object -First 1 -ExpandProperty File

    if (-not $selectedFile) {
        throw 'Catalog did not return any downloadable file entries.'
    }

    return $selectedFile
}

function Invoke-TSxFileDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$UpdateId
    )

    $progressId = [Math]::Abs($DestinationPath.GetHashCode())
    if ($progressId -eq 0) {
        $progressId = 1
    }

    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = 'GET'

    $response = $null
    $responseStream = $null
    $fileStream = $null

    $originalProgressPreference = $ProgressPreference
    $lastPercentPrinted = -1
    $lastIsePercentPrinted = -10
    $printedInlineProgress = $false
    $isIseHost = $Host.Name -match '(?i)ISE'
    $useInlineConsoleProgress = -not $isIseHost

    try {
        $ProgressPreference = 'Continue'
        if ($useInlineConsoleProgress) {
            Write-Host ('Starting download for update {0}' -f $UpdateId)
        }
        $response = $request.GetResponse()
        $responseStream = $response.GetResponseStream()
        $fileStream = [System.IO.File]::Open($DestinationPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

        $buffer = New-Object byte[] 81920
        $totalBytes = [int64]$response.ContentLength
        $totalRead = [int64]0

        while (($bytesRead = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $bytesRead)
            $totalRead += $bytesRead

            if ($totalBytes -gt 0) {
                $percentComplete = [int](($totalRead * 100) / $totalBytes)
                $status = '{0:N1} MB / {1:N1} MB' -f ($totalRead / 1MB), ($totalBytes / 1MB)
                Write-Progress -Id $progressId -Activity ('Downloading update {0}' -f $UpdateId) -Status $status -PercentComplete $percentComplete

                if ($useInlineConsoleProgress -and $percentComplete -ne $lastPercentPrinted) {
                    Write-Host -NoNewline ("`rDownloading update {0}: {1,3}% ({2})" -f $UpdateId, $percentComplete, $status)
                    $lastPercentPrinted = $percentComplete
                    $printedInlineProgress = $true
                }

                if ($isIseHost -and ($percentComplete -ge ($lastIsePercentPrinted + 10) -or $percentComplete -eq 100)) {
                    Write-Host ('Downloading update {0}: {1,3}% ({2})' -f $UpdateId, $percentComplete, $status)
                    $lastIsePercentPrinted = $percentComplete
                }
            }
            else {
                $status = '{0:N1} MB downloaded' -f ($totalRead / 1MB)
                Write-Progress -Id $progressId -Activity ('Downloading update {0}' -f $UpdateId) -Status $status

                if ($useInlineConsoleProgress) {
                    Write-Host -NoNewline ("`rDownloading update {0}: {1}" -f $UpdateId, $status)
                    $printedInlineProgress = $true
                }
                elseif ($isIseHost) {
                    Write-Host ('Downloading update {0}: {1}' -f $UpdateId, $status)
                }
            }
        }

        if ($printedInlineProgress) {
            Write-Host ''
        }
        if ($useInlineConsoleProgress) {
            Write-Host ('Completed download for update {0}' -f $UpdateId)
        }
    }
    finally {
        if ($fileStream) {
            $fileStream.Dispose()
        }

        if ($responseStream) {
            $responseStream.Dispose()
        }

        if ($response) {
            $response.Dispose()
        }

        Write-Progress -Id $progressId -Activity ('Downloading update {0}' -f $UpdateId) -Completed
        $ProgressPreference = $originalProgressPreference
    }
}

$scriptName = Split-Path -Path $PSCommandPath -Leaf
Start-TSxLog -FilePath $LogPath
Write-TSxLog -Message ('{0} started' -f $scriptName)
Write-TSxLog -Message ('Download path: {0}' -f $Path)
Write-TSxLog -Message ('Force: {0}' -f $Force.IsPresent)
Write-TSxLog -Message ('Log path: {0}' -f $LogPath)

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
            SourceTitle     = if ($currentInputObject.PSObject.Properties['Title']) { [string]$currentInputObject.Title } else { $null }
            FileName        = $selectedFile.FileName
            DownloadUrl     = $selectedFile.Url
            DestinationPath = $destinationPath
            LogPath         = $LogPath
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

    if ($PSCmdlet.ShouldProcess($destinationPath, ('Download update {0}' -f $updateId))) {
        Invoke-TSxFileDownload -Url $selectedFile.Url -DestinationPath $destinationPath -UpdateId $updateId
        Write-TSxLog -Message ('Download completed: {0}' -f $destinationPath)
    }

    [pscustomobject]@{
        PSTypeName      = 'TSx.WindowsUpdate.DownloadResult'
        UpdateId        = $updateId
        KB              = $kb
        Architecture    = $architecture
        SourceTitle     = if ($currentInputObject.PSObject.Properties['Title']) { [string]$currentInputObject.Title } else { $null }
        FileName        = $selectedFile.FileName
        DownloadUrl     = $selectedFile.Url
        DestinationPath = $destinationPath
        LogPath         = $LogPath
        WasDownloaded   = [bool](-not $WhatIfPreference)
        WasSkipped      = $false
        Forced          = [bool]$Force
    }
}
