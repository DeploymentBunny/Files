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

.LINK
    https://www.deploymentbunny.com
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$WIMFile

)

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
$Script:TSxLogFile = Join-Path $env:TEMP ("{0}_{1}.log" -f $Script:ToolName, (Get-Date -Format "yyyyMMdd_HHmmss"))
$Script:RunUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

function Write-TSxLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $Script:TSxLogFile -Value ("[{0}] [User: {1}] {2}" -f $timestamp, $Script:RunUser, $Message)
}

Write-TSxLog -Message "$Script:ToolName started"
Write-Verbose -Message ("Tool log: {0}" -f $Script:TSxLogFile)

# Validate WIMFile
Write-Verbose -Message ("Validating WIMFile: {0}" -f $WIMFile)
if (-not (Test-Path -LiteralPath $WIMFile -PathType Leaf)) {
    Write-TSxLog -Message ("WIMFile does not exist: {0}" -f $WIMFile)
    Write-Warning "WIMFile does not exist: $WIMFile"
    exit 1
}

# Enumerate indexes
Write-Verbose -Message "Enumerating WIM indexes"
Write-TSxLog -Message ("Enumerating indexes in: {0}" -f $WIMFile)

try {
    $allImages = Get-WindowsImage -ImagePath $WIMFile -ErrorAction Stop
    Write-Verbose -Message ("Found {0} image(s)" -f $allImages.Count)
    Write-TSxLog -Message ("Found {0} image(s)" -f $allImages.Count)

    foreach ($img in $allImages) {
        [PSCustomObject]@{
            WIMFile          = $WIMFile
            ImageIndex       = $img.ImageIndex
            ImageName        = $img.ImageName
            ImageDescription = $img.ImageDescription
            ImageSizeGB      = [math]::Round($img.ImageSize / 1024 / 1024 / 1024)
        }
    }
}
catch {
    Write-TSxLog -Message ("Failed to enumerate WIM contents. Error: {0}" -f $_.Exception.Message)
    Write-Error ("Failed to enumerate WIM contents: {0}" -f $_.Exception.Message)
    exit 1
}

Write-TSxLog -Message "$Script:ToolName completed"
