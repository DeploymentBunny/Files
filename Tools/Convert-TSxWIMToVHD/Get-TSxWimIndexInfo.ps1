<#
.SYNOPSIS
    Returns all image indexes and their basic information from a WIM file.

.DESCRIPTION
    Uses Get-WindowsImage to enumerate every index in a WIM file and returns
    a PSCustomObject per index. No image mounting is required.

.PARAMETER WIMFile
    Full path to the WIM file to inspect.

.EXAMPLE
    .\Get-TSxWimIndexInfo.ps1 -WIMFile D:\Sources\install.wim

.EXAMPLE
    .\Get-TSxWimIndexInfo.ps1 -WIMFile D:\Sources\install.wim | Format-Table

.NOTES
    Version: 1.0.3
    Date: 2026-05-18

.LINK
    https://www.deploymentbunny.com
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$WIMFile,

    [Parameter(Mandatory = $false)]
    [ValidateRange(30, 1800)]
    [int]$MetadataTimeoutSeconds = 180

)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Self-elevation
$myWindowsID = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal($myWindowsID)
$adminRole = [System.Security.Principal.WindowsBuiltInRole]::Administrator

if ($myWindowsPrincipal.IsInRole($adminRole)) {
    $Host.UI.RawUI.WindowTitle = $myInvocation.MyCommand.Definition + " (Elevated)"
}
else {
    $newProcess = New-Object System.Diagnostics.ProcessStartInfo "PowerShell"
    $newProcess.Arguments = "-NoProfile -File `"$($myInvocation.MyCommand.Definition)`" -WIMFile `"$WIMFile`""
    $newProcess.Verb = "runas"
    [System.Diagnostics.Process]::Start($newProcess) | Out-Null
    exit
}

# Logging
$Script:ToolName = "Get-TSxWimIndexInfo"
$Script:LogFolder = Join-Path $env:TEMP 'Convert-TSxWIMToVHD'
if (-not (Test-Path -LiteralPath $Script:LogFolder)) {
    New-Item -ItemType Directory -Path $Script:LogFolder -Force | Out-Null
}
$Script:TSxLogFile = Join-Path $Script:LogFolder "$Script:ToolName.log"
$Script:RunUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

function Write-TSxLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $Script:TSxLogFile -Value ("[{0}] [User: {1}] {2}" -f $timestamp, $Script:RunUser, $Message)
}

function Write-TSxStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host "[Get-TSxWimIndexInfo] $Message" -ForegroundColor Green
    Write-TSxLog -Message $Message
}

function Test-HealthyMountedImages {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'dism.exe'
    $startInfo.Arguments = "/English /Get-MountedWimInfo /LogPath:`"$Script:TSxLogFile`""
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Unable to start DISM while checking mounted Windows images.'
    }

    if (-not $process.WaitForExit(15000)) {
        try { $process.Kill() } catch {}
        throw 'Timed out while checking mounted Windows images. DISM may be blocked by a stale mount state.'
    }

    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    if ($process.ExitCode -ne 0) {
        $failureText = ($standardError, $standardOutput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' '
        throw "Unable to query mounted Windows images before WIM index read. $failureText"
    }
}

function Get-WimImageInfoWithTimeout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImagePath,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory = $false)]
        [string]$LogPath = ''
    )

    $job = Start-Job -ScriptBlock {
        param($Path, $LogPath)
        if ($LogPath) {
            Get-WindowsImage -ImagePath $Path -LogPath $LogPath -ErrorAction Stop |
                Select-Object ImageIndex, ImageName, ImageDescription, ImageSize
        }
        else {
            Get-WindowsImage -ImagePath $Path -ErrorAction Stop |
                Select-Object ImageIndex, ImageName, ImageDescription, ImageSize
        }
    } -ArgumentList $ImagePath, $LogPath

    try {
        $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
        if (-not $completed) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
            throw "Timed out after $TimeoutSeconds second(s) while reading WIM metadata using Get-WindowsImage."
        }

        return @(Receive-Job -Job $job -ErrorAction Stop)
    }
    finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

Write-TSxLog -Message "$Script:ToolName started"
Write-Verbose -Message ("Tool log: {0}" -f $Script:TSxLogFile)
Write-TSxStatus -Message 'Starting WIM index inspection.'
Write-TSxStatus -Message "Input file: $WIMFile"
Write-TSxStatus -Message "Metadata timeout: $MetadataTimeoutSeconds second(s)."

# Validate WIMFile
Write-Verbose -Message ("Validating WIMFile: {0}" -f $WIMFile)
if (-not (Test-Path -LiteralPath $WIMFile -PathType Leaf)) {
    Write-TSxLog -Message ("WIMFile does not exist: {0}" -f $WIMFile)
    Write-Warning "WIMFile does not exist: $WIMFile"
    exit 1
}

Write-TSxStatus -Message 'Checking mounted image health...'
$mountedCheckStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
try {
    Test-HealthyMountedImages
    $mountedCheckStopwatch.Stop()
    Write-TSxStatus -Message "Mounted image health check passed in $($mountedCheckStopwatch.Elapsed.TotalSeconds.ToString('0.0')) second(s)."
}
catch {
    $mountedCheckStopwatch.Stop()
    Write-TSxLog -Message ("Mounted image health check warning: {0}" -f $_.Exception.Message)
    Write-TSxStatus -Message "Mounted image health check warning after $($mountedCheckStopwatch.Elapsed.TotalSeconds.ToString('0.0')) second(s). Continuing anyway."
}

# Enumerate indexes
Write-Verbose -Message "Enumerating WIM indexes"
Write-TSxLog -Message ("Enumerating indexes in: {0}" -f $WIMFile)
Write-TSxStatus -Message 'Reading WIM image metadata...'

try {
    $metadataStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $allImages = Get-WimImageInfoWithTimeout -ImagePath $WIMFile -TimeoutSeconds $MetadataTimeoutSeconds -LogPath $Script:TSxLogFile
    $metadataStopwatch.Stop()
    Write-Verbose -Message ("Found {0} image(s)" -f $allImages.Count)
    Write-TSxLog -Message ("Found {0} image(s)" -f $allImages.Count)
    Write-TSxStatus -Message "Found $($allImages.Count) image(s) in $($metadataStopwatch.Elapsed.TotalSeconds.ToString('0.0')) second(s)."

    $results = @($allImages | ForEach-Object {
        [PSCustomObject]@{
            WIMFile          = $WIMFile
            ImageIndex       = $_.ImageIndex
            ImageName        = $_.ImageName
            ImageDescription = $_.ImageDescription
            ImageSizeGB      = [math]::Round($_.ImageSize / 1024 / 1024 / 1024)
        }
    })

    # Display as a clean table on screen
    $tableText = $results |
        Format-Table -Property ImageIndex, ImageName, ImageSizeGB -AutoSize |
        Out-String
    Write-Host $tableText.TrimEnd()

    # Emit objects for pipeline/variable capture
    foreach ($result in $results) {
        Write-Output $result
    }
}
catch {
    Write-TSxLog -Message ("Failed to enumerate WIM contents. Error: {0}" -f $_.Exception.Message)
    Write-TSxStatus -Message ("Failed to enumerate WIM contents. Error: {0}" -f $_.Exception.Message)
    Write-Error ("Failed to enumerate WIM contents: {0}" -f $_.Exception.Message)
    exit 1
}

Write-TSxLog -Message "$Script:ToolName completed"
Write-TSxStatus -Message 'Completed.'
