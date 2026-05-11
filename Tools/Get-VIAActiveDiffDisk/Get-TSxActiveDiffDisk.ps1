<#
.SYNOPSIS
    Finds active parent disks used by differencing VHD/VHDX files connected to local Hyper-V VMs.

.DESCRIPTION
    Scans local Hyper-V virtual machines and inspects their attached VHD/VHDX files
    to find differencing disks that are currently active.

    The script self-elevates to Administrator when needed and writes a per-run log file
    in %TEMP%.

    By default, output is object-based (VMName, DiskPath, ParentPath).
    Use -AsPath to return only unique parent path strings.
    Use -AsList to display output in list format.

.PARAMETER AsPath
    Returns only unique parent path strings instead of detailed objects.

.PARAMETER AsList
    Displays output in list format only.

.EXAMPLE
    .\Get-TSxActiveDiffDisk.ps1
    Returns detailed mappings between VM name, differencing disk path, and parent path.

.EXAMPLE
    .\Get-TSxActiveDiffDisk.ps1 -AsPath
    Returns only unique parent disk paths for active differencing disks.

.EXAMPLE
    .\Get-TSxActiveDiffDisk.ps1 -Verbose -AsList
    Displays detailed object output as a list.

.NOTES
    FileName:    Get-TSxActiveDiffDisk.ps1
    Version:     3.0.0
    Author:      Mikael Nystrom
    Twitter:     @mikael_nystrom
    Contact:     deploymentbunny@outlook.com
    Created:     2016-11-07
    Updated:     2026-05-11

    Disclaimer:
    This script is provided "AS IS" with no warranties.
.LINK
    https://www.deploymentbunny.com
#>

[CmdletBinding()]
param(
    [switch]$AsPath,

    [switch]$AsList
)

# Get the ID and security principal of the current user account
$myWindowsID = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal($myWindowsID)

# Get the security principal for the Administrator role
$adminRole = [System.Security.Principal.WindowsBuiltInRole]::Administrator

# Check to see if we are currently running as Administrator
if ($myWindowsPrincipal.IsInRole($adminRole)) {
    $Host.UI.RawUI.WindowTitle = $myInvocation.MyCommand.Definition + " (Elevated)"
}
else {
    $newProcess = New-Object System.Diagnostics.ProcessStartInfo "PowerShell"
    $newProcess.Arguments = "-NoProfile -File `"$($myInvocation.MyCommand.Definition)`""
    $newProcess.Verb = "runas"

    [System.Diagnostics.Process]::Start($newProcess) | Out-Null
    exit
}

# Logging setup (after elevation check)
$Script:LogFile = Join-Path $env:TEMP ("Get-TSxActiveDiffDisk_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$Script:RunUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

function Write-TSxLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $Script:LogFile -Value ("[{0}] [User: {1}] {2}" -f $timestamp, $Script:RunUser, $Message)
}

Write-TSxLog -Message "Get-TSxActiveDiffDisk started (running as Administrator)"

try {
    Write-Verbose "Querying local Hyper-V virtual machines..."
    $vms = @(Get-VM -ErrorAction Stop)
    Write-TSxLog -Message ("Found {0} virtual machine(s)" -f $vms.Count)
}
catch {
    Write-TSxLog -Message ("Failed to query Hyper-V virtual machines. Error: {0}" -f $_.Exception.Message)
    throw "Failed to query Hyper-V virtual machines. $($_.Exception.Message)"
}

if ($vms.Count -eq 0) {
    Write-TSxLog -Message "No virtual machines were found on this host"
    Write-Verbose "No virtual machines were found on this host."
    return
}

$results = foreach ($vm in $vms) {
    Write-Verbose ("Checking VM: {0}" -f $vm.Name)
    Write-TSxLog -Message ("Checking VM: {0}" -f $vm.Name)

    $vmHardDiskDrives = @(Get-VMHardDiskDrive -VM $vm -ErrorAction SilentlyContinue)
    foreach ($vmHardDiskDrive in $vmHardDiskDrives) {
        if ([string]::IsNullOrWhiteSpace($vmHardDiskDrive.Path)) {
            continue
        }

        $vhd = Get-VHD -Path $vmHardDiskDrive.Path -ErrorAction SilentlyContinue
        if (-not $vhd) {
            continue
        }

        if ($vhd.VhdType -eq 'Differencing' -and -not [string]::IsNullOrWhiteSpace($vhd.ParentPath)) {
            Write-TSxLog -Message ("Active differencing disk found. VM={0}; DiskPath={1}; ParentPath={2}" -f $vm.Name, $vmHardDiskDrive.Path, $vhd.ParentPath)
            [PSCustomObject]@{
                VMName     = $vm.Name
                DiskPath   = $vmHardDiskDrive.Path
                ParentPath = $vhd.ParentPath
            }
        }
    }
}

$resultCount = @($results).Count
Write-TSxLog -Message ("Found {0} active differencing disk mapping(s)" -f $resultCount)

if ($AsPath) {
    $pathResults = $results |
        Select-Object -ExpandProperty ParentPath |
        Sort-Object -Unique

    Write-TSxLog -Message ("Returning unique parent paths. Count={0}" -f @($pathResults).Count)

    if ($AsList) {
        $pathResults |
            Format-List
        return
    }

    $pathResults
    return
}

$objectResults = $results |
    Sort-Object VMName, DiskPath, ParentPath -Unique

Write-TSxLog -Message ("Returning detailed object output. Count={0}" -f @($objectResults).Count)

if ($AsList) {
    $objectResults |
        Select-Object VMName, DiskPath, ParentPath |
        Format-List
    return
}

$objectResults