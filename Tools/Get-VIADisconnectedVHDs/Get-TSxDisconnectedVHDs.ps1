<#
.Synopsis
    Finds .VHD files that are not connected to any virtual machines.

.Description
    Scans a folder recursively (default) to identify VHD/VHDX files that are not
    attached to any virtual machines in the local Hyper-V infrastructure.
    The script self-elevates to Administrator when needed, writes a per-run log,
    and provides detailed progress with -Verbose including in-use VHD mapping to
    VM names. The output is a list of disconnected VHD/VHDX file objects that can
    be piped or captured for further processing.

.Parameter Folder
    The root folder path to search for VHD/VHDX files.
    This parameter is required.

.Parameter AsList
    Displays returned disconnected VHD/VHDX objects in list format.
    Objects are still returned on the pipeline for further processing.

.Example
    .\Get-TSxDisconnectedVHDs.ps1 -Folder "C:\VirtualDisks"
    Returns a list of all disconnected VHD/VHDX files in the folder and subfolders.

.Example
    .\Get-TSxDisconnectedVHDs.ps1 -Folder "C:\VirtualDisks" -AsList
    Displays disconnected VHD/VHDX files as a list and still returns object output.

.Notes
    Created: 2016-11-07
    Version: 2.0
    Author : Mikael Nystrom
    Twitter: @mikael_nystrom
    Blog   : https://www.deploymentbunny.com
    Disclaimer: This script is provided "AS IS" with no warranties.
#>

[CmdletBinding()]

param(
    [Parameter(Mandatory = $true, HelpMessage = "Path to the folder containing VHD files")]
    [ValidateScript({ Test-Path -Path $_ })]
    [string]$Folder,

    [switch]$AsList
)

# Get the ID and security principal of the current user account
$myWindowsID = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal($myWindowsID)

# Get the security principal for the Administrator role
$adminRole = [System.Security.Principal.WindowsBuiltInRole]::Administrator

# Check to see if we are currently running as Administrator
if ($myWindowsPrincipal.IsInRole($adminRole))
{
    $Host.UI.RawUI.WindowTitle = $myInvocation.MyCommand.Definition + " (Elevated)"
    $Host.UI.RawUI.BackgroundColor = "DarkBlue"
    Clear-Host
}
else
{
    $newProcess = New-Object System.Diagnostics.ProcessStartInfo "PowerShell"
    $newProcess.Arguments = "-NoProfile -File `"$($myInvocation.MyCommand.Definition)`""
    $newProcess.Verb = "runas"

    [System.Diagnostics.Process]::Start($newProcess) | Out-Null
    exit
}

# Logging setup (after elevation check)
$Script:LogFile = Join-Path $env:TEMP ("Get-TSxDisconnectedVHDs_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$Script:RunUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

function Write-TSxLog
{
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $Script:LogFile -Value ("[{0}] [User: {1}] {2}" -f $timestamp, $Script:RunUser, $Message)
}

Write-TSxLog -Message "Get-TSxDisconnectedVHDs started (running as Administrator)"

# Get all VMs that do not have a parent snapshot (are not snapshots)
Write-Verbose -Message "Searching for virtual machines on this computer..."
Write-TSxLog -Message "Scanning for virtual machines..."
$VMs = @(Get-VM -ErrorAction Continue | Where-Object -Property ParentSnapshotName -EQ -Value $null)
Write-Verbose -Message ("Found {0} virtual machine(s)" -f $VMs.Count)

if ($VMs.Count -eq 0)
{
    $message = "No virtual machines found in the Hyper-V infrastructure"
    Write-TSxLog -Message $message
    Write-Error -Message $message -ErrorAction Stop
}

# Get all active VHD paths from VMs
Write-Verbose -Message "Checking VHD/VHDX files currently in use by virtual machines..."
Write-TSxLog -Message "Retrieving active VHD paths from $($VMs.Count) virtual machine(s)..."
$VHDUsage = foreach ($VM in $VMs)
{
    Get-VMHardDiskDrive -VM $VM -ErrorAction Continue |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.Path) } |
        Select-Object @{ Name = 'VMName'; Expression = { $VM.Name } }, Path
}
$VHDsActive = @($VHDUsage.Path | Sort-Object -Unique)
Write-Verbose -Message ("Found {0} mounted VHD/VHDX file path(s) across virtual machines" -f $VHDsActive.Count)

# Get all VHD files in the specified folder and subfolders
Write-Verbose -Message "Searching recursively for VHD/VHDX files in folder: $Folder"
Write-TSxLog -Message "Scanning folder recursively for VHD/VHDX files: $Folder"
$searchParams = @{
    Path        = $Folder
    Filter      = '*.vhd*'
    Recurse     = $true
    ErrorAction = 'Continue'
}
$VHDsAll = @(Get-ChildItem @searchParams)
Write-Verbose -Message ("Found {0} VHD/VHDX file(s) in the target folder" -f $VHDsAll.Count)

if ($VHDsAll.Count -eq 0)
{
    $message = "No VHD/VHDX files found in folder: $Folder"
    Write-TSxLog -Message $message
    Write-Warning -Message $message
    Write-TSxLog -Message "Get-TSxDisconnectedVHDs completed with warning"
    return
}

# Compare active VHDs with all VHDs to identify disconnected ones
Write-TSxLog -Message "Comparing active VHDs with all VHDs on disk..."
$InUseVHDs = @($VHDsAll | Where-Object {
    $VHDsActive -contains $_.FullName
})
Write-Verbose -Message ("Found {0} VHD/VHDX file(s) in use by virtual machines" -f $InUseVHDs.Count)

if ($InUseVHDs.Count -gt 0)
{
    Write-Verbose -Message "The following VHD/VHDX file(s) are currently in use:"
    foreach ($inUseFile in $InUseVHDs)
    {
        $connectedVMs = @(
            $VHDUsage |
                Where-Object { $_.Path -eq $inUseFile.FullName } |
                Select-Object -ExpandProperty VMName -Unique
        )
        $vmText = if ($connectedVMs.Count -gt 0) { $connectedVMs -join ', ' } else { 'Unknown VM' }
        Write-Verbose -Message ("  {0}  [VM: {1}]" -f $inUseFile.FullName, $vmText)
    }
}

$DisconnectedVHDs = $VHDsAll | Where-Object {
    $VHDsActive -notcontains $_.FullName
}

# Return results and log summary
$disconnectedCount = @($DisconnectedVHDs).Count
Write-TSxLog -Message "Found $disconnectedCount disconnected VHD file(s)"
Write-Verbose -Message ("Found {0} disconnected VHD/VHDX file(s)" -f $disconnectedCount)

if ($disconnectedCount -gt 0)
{
    Write-Verbose -Message "The following VHD/VHDX file(s) are not related to any virtual machines on your computer."
    foreach ($disconnectedFile in $DisconnectedVHDs)
    {
        Write-Verbose -Message ("  {0}" -f $disconnectedFile.FullName)
    }
    Write-TSxLog -Message "Disconnected VHDs: $($DisconnectedVHDs.FullName -join ', ')"
}

Write-TSxLog -Message "Get-TSxDisconnectedVHDs completed successfully"

if ($AsList)
{
    $DisconnectedVHDs |
        Select-Object FullName, Length, LastWriteTime |
        Format-List |
        Out-Host
}

$DisconnectedVHDs