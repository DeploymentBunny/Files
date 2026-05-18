<#
.SYNOPSIS
    Get detailed information about one specific image index inside a WIM file.

.DESCRIPTION
    Mounts a single WIM index read-only and returns a PSCustomObject containing:
    - Image metadata (name, version, architecture, edition, etc.)
    - Injected drivers
    - Enabled optional features
    - Installed packages
    - Provisioned AppX packages

    The image is always dismounted (discarded) after the data is collected.
    If no MountFolder is supplied, a temporary folder is created under %TEMP%
    and removed automatically after use.

    Use Get-TSxWimIndexInfo.ps1 first to discover available indexes.

.PARAMETER WIMFile
    Full path to the WIM file to inspect.

.PARAMETER Index
    Index number of the image inside the WIM file to mount. Required.

.PARAMETER MountFolder
    Path to an existing, empty folder used as the mount point.
    If omitted, a temporary folder is created under %TEMP% and deleted afterwards.

.EXAMPLE
    .\Get-TSxWIMInfo.ps1 -WIMFile D:\Sources\install.wim -Index 1

.EXAMPLE
    .\Get-TSxWIMInfo.ps1 -WIMFile D:\Sources\install.wim -Index 2 -Verbose

.EXAMPLE
    $info = .\Get-TSxWIMInfo.ps1 -WIMFile D:\Sources\install.wim -Index 1
    $info.EnabledFeatures

.NOTES
    Version: 1.0.1
    Date: 2026-05-18

.LINK
    https://www.deploymentbunny.com
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$WIMFile,

    [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true, Position = 1)]
    [ValidateRange(1, 999)]
    [int]$Index,

    [Parameter(Mandatory = $false, ValueFromPipelineByPropertyName = $true, Position = 2)]
    [string]$MountFolder = ""

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
    $newProcess.Arguments = "-NoProfile -File `"$($myInvocation.MyCommand.Definition)`" -WIMFile `"$WIMFile`" -Index $Index -MountFolder `"$MountFolder`""
    $newProcess.Verb = "runas"
    [System.Diagnostics.Process]::Start($newProcess) | Out-Null
    exit
}

# Logging
$Script:ToolName = "Get-TSxWIMInfo"
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

Write-TSxLog -Message "$Script:ToolName started"
Write-Verbose -Message ("Tool log: {0}" -f $Script:TSxLogFile)

# Auto-create a temp mount folder if none was supplied
$Script:TempMountFolderCreated = $false
if ([string]::IsNullOrWhiteSpace($MountFolder)) {
    $MountFolder = Join-Path $env:TEMP ("TSxWIMInfo_Mount_{0}" -f [System.IO.Path]::GetRandomFileName().Replace('.',''))
    New-Item -ItemType Directory -Path $MountFolder -Force | Out-Null
    $Script:TempMountFolderCreated = $true
    Write-Verbose -Message ("Auto-created temp mount folder: {0}" -f $MountFolder)
    Write-TSxLog -Message ("Auto-created temp mount folder: {0}" -f $MountFolder)
}

# Input validation
Write-Verbose -Message ("Validating MountFolder: {0}" -f $MountFolder)
if (-not (Test-Path -LiteralPath $MountFolder -PathType Container)) {
    Write-TSxLog -Message ("MountFolder does not exist: {0}" -f $MountFolder)
    Write-Warning "MountFolder does not exist: $MountFolder"
    exit 1
}

if ((Get-ChildItem -LiteralPath $MountFolder).Count -ne 0) {
    Write-TSxLog -Message ("MountFolder is not empty: {0}" -f $MountFolder)
    Write-Warning "MountFolder is not empty: $MountFolder"
    exit 1
}

Write-Verbose -Message ("Validating WIMFile: {0}" -f $WIMFile)
if (-not (Test-Path -LiteralPath $WIMFile -PathType Leaf)) {
    Write-TSxLog -Message ("WIMFile does not exist: {0}" -f $WIMFile)
    Write-Warning "WIMFile does not exist: $WIMFile"
    exit 1
}

# If no index was specified, list available indexes and exit without mounting
if ($Index -eq 0) {
    Write-Verbose -Message "No index specified - listing available images in WIM"
    Write-TSxLog -Message "No index specified - listing WIM contents only"
    try {
        $allImages = Get-WindowsImage -ImagePath $WIMFile -LogPath $Script:TSxLogFile -ErrorAction Stop
        foreach ($img in $allImages) {
            [PSCustomObject]@{
                WIMFile    = $WIMFile
                ImageIndex = $img.ImageIndex
                ImageName  = $img.ImageName
                ImageSize  = $img.ImageSize
            }
        }
    }
    catch {
        Write-TSxLog -Message ("Failed to enumerate WIM contents. Error: {0}" -f $_.Exception.Message)
        Write-Error ("Failed to enumerate WIM contents: {0}" -f $_.Exception.Message)
        exit 1
    }
    Write-TSxLog -Message "$Script:ToolName completed (index listing only)"
    exit 0
}

# Mount image
Write-Verbose -Message ("Mounting WIM index {0} to {1}" -f $Index, $MountFolder)
Write-TSxLog -Message ("Mounting WIM index {0} to {1}" -f $Index, $MountFolder)

try {
    $null = Mount-WindowsImage -ImagePath $WIMFile -Path $MountFolder -Index $Index -ReadOnly -LogPath $Script:TSxLogFile -ErrorAction Stop
    Write-Verbose -Message "Mount succeeded"
    Write-TSxLog -Message "Mount succeeded"
}
catch {
    Write-TSxLog -Message ("Failed to mount WIM. Error: {0}" -f $_.Exception.Message)
    Write-Error ("Failed to mount WIM: {0}" -f $_.Exception.Message)
    exit 1
}

# Collect data
Write-Verbose -Message "Collecting image metadata"
try { $WindowsImage = Get-WindowsImage -ImagePath $WIMFile -Index $Index -LogPath $Script:TSxLogFile -ErrorAction Stop }
catch { Write-Warning ("Could not execute Get-WindowsImage. Error: {0}" -f $_.Exception.Message); Write-TSxLog -Message ("Get-WindowsImage failed: {0}" -f $_.Exception.Message) }

Write-Verbose -Message "Collecting driver list"
try { $WindowsDrivers = Get-WindowsDriver -Path $MountFolder -LogPath $Script:TSxLogFile -ErrorAction Stop }
catch { Write-Warning ("Could not execute Get-WindowsDriver. Error: {0}" -f $_.Exception.Message); Write-TSxLog -Message ("Get-WindowsDriver failed: {0}" -f $_.Exception.Message) }

Write-Verbose -Message "Collecting optional features"
try { $WindowsOptionalFeatures = Get-WindowsOptionalFeature -Path $MountFolder -LogPath $Script:TSxLogFile -ErrorAction Stop }
catch { Write-Warning ("Could not execute Get-WindowsOptionalFeature. Error: {0}" -f $_.Exception.Message); Write-TSxLog -Message ("Get-WindowsOptionalFeature failed: {0}" -f $_.Exception.Message) }

Write-Verbose -Message "Collecting packages"
try { $WindowsPackages = Get-WindowsPackage -Path $MountFolder -LogPath $Script:TSxLogFile -ErrorAction Stop }
catch { Write-Warning ("Could not execute Get-WindowsPackage. Error: {0}" -f $_.Exception.Message); Write-TSxLog -Message ("Get-WindowsPackage failed: {0}" -f $_.Exception.Message) }

Write-Verbose -Message "Collecting AppX provisioned packages"
try { $AppxProvisionedPackages = Get-AppxProvisionedPackage -Path $MountFolder -ErrorAction Stop }
catch { Write-Warning ("Could not execute Get-AppxProvisionedPackage. Error: {0}" -f $_.Exception.Message); Write-TSxLog -Message ("Get-AppxProvisionedPackage failed: {0}" -f $_.Exception.Message) }

# Build driver objects from the already-collected summary (no per-driver DISM calls)
$driverObjects = @()
if ($WindowsDrivers) {
    $driverObjects = @($WindowsDrivers | Select-Object `
        OriginalFileName, Driver, ClassDescription, BootCritical,
        DriverSignature, ProviderName, Date, Version, ManufacturerName)
}

# Build enabled-features list
$enabledFeatures = @()
if ($WindowsOptionalFeatures) {
    $enabledFeatures = @($WindowsOptionalFeatures |
        Where-Object { $_.State -eq 'Enabled' } |
        Sort-Object FeatureName |
        Select-Object -ExpandProperty FeatureName)
}

# Build package objects from the already-collected summary (no per-package DISM calls)
$packageObjects = @()
if ($WindowsPackages) {
    $packageObjects = @($WindowsPackages | Select-Object `
        PackageName, Applicable, Copyright, Company,
        CreationTime, Description, InstallClient,
        InstallPackageName, InstallTime, LastUpdateTime,
        DisplayName, ProductName, ProductVersion, ReleaseType,
        RestartRequired, SupportInformation, PackageState, Visibility)
}

# Build AppX objects
$appxObjects = @()
if ($AppxProvisionedPackages) {
    $appxObjects = @($AppxProvisionedPackages | Select-Object DisplayName, Version)
}

# Store result — emitted after dismount so formatter does not buffer during cleanup
$result = [PSCustomObject]@{
    ImagePath        = $WindowsImage.ImagePath
    ImageIndex       = $WindowsImage.ImageIndex
    ImageName        = $WindowsImage.ImageName
    ImageDescription = $WindowsImage.ImageDescription
    ImageSizeGB      = [math]::Round($WindowsImage.ImageSize / 1024 / 1024 / 1024)
    Architecture     = $WindowsImage.Architecture
    Version          = $WindowsImage.Version
    Build            = $WindowsImage.SPBuild
    ServicePackLevel = $WindowsImage.SPLevel
    Edition          = $WindowsImage.EditionId
    InstallationType = $WindowsImage.InstallationType
    ProductType      = $WindowsImage.ProductType
    ProductSuite     = $WindowsImage.ProductSuite
    Created          = $WindowsImage.CreatedTime
    Modified         = $WindowsImage.ModifiedTime
    Languages        = $WindowsImage.Languages
    Drivers          = $driverObjects
    EnabledFeatures  = $enabledFeatures
    Packages         = $packageObjects
    AppxPackages     = $appxObjects
}

# Dismount
Write-Verbose -Message ("Dismounting {0}" -f $MountFolder)
Write-TSxLog -Message ("Dismounting {0}" -f $MountFolder)

try {
    Dismount-WindowsImage -Path $MountFolder -Discard -LogPath $Script:TSxLogFile -ErrorAction Stop
    Write-Verbose -Message "Dismount succeeded"
    Write-TSxLog -Message "Dismount succeeded"
}
catch {
    Write-TSxLog -Message ("Dismount failed. Error: {0}" -f $_.Exception.Message)
    Write-Warning ("Dismount failed: {0}" -f $_.Exception.Message)
}

# Remove auto-created temp mount folder if we made it
if ($Script:TempMountFolderCreated -and (Test-Path -LiteralPath $MountFolder -PathType Container)) {
    try {
        Remove-Item -LiteralPath $MountFolder -Recurse -Force -ErrorAction Stop
        Write-Verbose -Message ("Removed temp mount folder: {0}" -f $MountFolder)
        Write-TSxLog -Message ("Removed temp mount folder: {0}" -f $MountFolder)
    }
    catch {
        Write-TSxLog -Message ("Failed to remove temp mount folder: {0}. Error: {1}" -f $MountFolder, $_.Exception.Message)
        Write-Warning ("Failed to remove temp mount folder: {0}" -f $MountFolder)
    }
}

Write-TSxLog -Message "$Script:ToolName completed"

# Emit the result object as the very last operation so the formatter
# receives it only after all DISM/cleanup work is done and outputs immediately
Write-Output $result
