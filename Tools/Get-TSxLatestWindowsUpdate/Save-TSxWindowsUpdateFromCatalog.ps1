[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
    [ValidateNotNull()]
    [psobject]$InputObject,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Path,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogPath = (Join-Path -Path $env:TEMP -ChildPath 'Get-TSxWindowsUpdates.log')
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

$scriptName = Split-Path -Path $PSCommandPath -Leaf
Start-TSxLog -FilePath $LogPath
Write-TSxLog -Message ('{0} started' -f $scriptName)
Write-TSxLog -Message ('Download path: {0}' -f $Path)
Write-TSxLog -Message ('Log path: {0}' -f $LogPath)

if (-not (Test-Path -Path $Path)) {
    Write-TSxLog -Message ('Creating download directory: {0}' -f $Path)
    $null = New-Item -Path $Path -ItemType Directory -Force
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
    throw 'No input objects were provided. Pipe objects from Get-TSxLatestWindowsUpdateList.ps1 or pass -InputObject.'
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

    if ($PSCmdlet.ShouldProcess($destinationPath, ('Download update {0}' -f $updateId))) {
        Invoke-WebRequest -UseBasicParsing -Uri $selectedFile.Url -OutFile $destinationPath
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
    }
}