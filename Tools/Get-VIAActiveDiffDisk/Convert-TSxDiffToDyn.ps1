<#
.SYNOPSIS
    Converts active differencing disks for a specific VM to dynamic VHDX files.

.DESCRIPTION
    Processes differencing disks attached to the specified Hyper-V virtual machine,
    converts each differencing disk to a new dynamic VHDX file, replaces the original
    disk file with the converted disk, and restores ACLs.

    The VM must be turned off before running this script.

.PARAMETER VMName
    Name of the Hyper-V virtual machine to process.

.EXAMPLE
    .\Convert-TSxDiffToDyn.ps1 -VMName "LAB-VM01"
    Converts all active differencing disks for LAB-VM01 to dynamic VHDX files.

.NOTES
    FileName:    Convert-TSxDiffToDyn.ps1
    Version:     1.0.0
    Author:      Mikael Nystrom
    Twitter:     @mikael_nystrom
    Contact:     deploymentbunny@outlook.com
    Created:     2019-01-01
    Updated:     2026-05-11

    Disclaimer:
    This script is provided "AS IS" with no warranties.
.LINK
    https://www.deploymentbunny.com
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VMName
)

# Logging setup
$Script:LogFile = Join-Path $env:TEMP ("Convert-TSxDiffToDyn_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$Script:RunUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

function Write-TSxLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $Script:LogFile -Value ("[{0}] [User: {1}] {2}" -f $timestamp, $Script:RunUser, $Message)
}

Write-TSxLog -Message ("Convert-TSxDiffToDyn started. VMName={0}" -f $VMName)
Write-Verbose ("Using log file: {0}" -f $Script:LogFile)

try {
    Write-Verbose ("Looking up VM: {0}" -f $VMName)
    $VM = Get-VM -Name $VMName -ErrorAction Stop
    Write-TSxLog -Message ("VM found: {0} (State={1})" -f $VM.Name, $VM.State)
}
catch {
    Write-TSxLog -Message ("Failed to find VM '{0}'. Error: {1}" -f $VMName, $_.Exception.Message)
    throw "Failed to find VM '$VMName'. $($_.Exception.Message)"
}

if ($VM.State -ne 'Off') {
    Write-TSxLog -Message ("VM '{0}' is not off. Current state: {1}" -f $VMName, $VM.State)
    throw "VM '$VMName' must be in state 'Off' before conversion."
}

try {
    Write-Verbose ("Enumerating differencing disks for VM: {0}" -f $VMName)
    $VMDisks = $VM | Get-VMHardDiskDrive | Get-VHD | Where-Object ParentPath -NE ""
    Write-TSxLog -Message ("Found {0} differencing disk(s)" -f @($VMDisks).Count)
}
catch {
    Write-TSxLog -Message ("Failed while enumerating VM disks. Error: {0}" -f $_.Exception.Message)
    throw "Failed while enumerating VM disks. $($_.Exception.Message)"
}

if (@($VMDisks).Count -eq 0) {
    Write-Verbose "No differencing disks found. Nothing to convert."
    Write-TSxLog -Message "No differencing disks found. Exiting."
    return
}

foreach ($VMDisk in $VMDisks) {
    try {
        $diskPath = $VMDisk.Path
        $diskFolder = Split-Path -Path $diskPath -Parent
        $tempPath = Join-Path -Path $diskFolder -ChildPath "temp.vhdx"
        $oldPath = Join-Path -Path $diskFolder -ChildPath "old.vhdx"

        Write-Verbose ("Converting differencing disk: {0}" -f $diskPath)
        Write-TSxLog -Message ("Starting conversion. DiskPath={0}; TempPath={1}; OldPath={2}" -f $diskPath, $tempPath, $oldPath)

        $Acls = Get-Acl -Path $diskPath -ErrorAction Stop
        Convert-VHD -Path $diskPath -DestinationPath $tempPath -VHDType Dynamic -Verbose -ErrorAction Stop
        Rename-Item -Path $diskPath -NewName $oldPath -ErrorAction Stop
        Rename-Item -Path $tempPath -NewName $diskPath -ErrorAction Stop
        Set-Acl -Path $diskPath -AclObject $Acls -Verbose -ErrorAction Stop

        Write-TSxLog -Message ("Conversion completed successfully for disk: {0}" -f $diskPath)
    }
    catch {
        Write-TSxLog -Message ("Conversion failed for disk '{0}'. Error: {1}" -f $VMDisk.Path, $_.Exception.Message)
        throw "Conversion failed for disk '$($VMDisk.Path)'. $($_.Exception.Message)"
    }
}

Write-TSxLog -Message "Convert-TSxDiffToDyn completed successfully"
Write-Verbose "Conversion workflow completed successfully."