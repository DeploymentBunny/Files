<#
.SYNOPSIS
    Creates a new Hyper-V virtual machine with optional base disk copy, differencing disk, or empty disk.
.DESCRIPTION
    New-HyperVM creates a Generation 1 or 2 virtual machine, configures CPU and networking,
    creates/attaches storage according to the selected disk mode, optionally mounts an ISO,
    and sets boot order for Generation 2 VMs.

    Disk modes:
    - Copy: Copies an existing VHD/VHDX into the VM folder and attaches it.
    - Diff: Creates a differencing VHDX based on an existing parent disk and attaches it.
    - Empty: Creates a new dynamic VHDX and attaches it.

    This script requires local administrator rights and the Hyper-V PowerShell module.
.PARAMETER VMName
    Name of the virtual machine to create.
.PARAMETER VMMem
    Startup memory in bytes. Defaults to 1GB.
.PARAMETER VMvCPU
    Number of virtual processors. Defaults to 1.
.PARAMETER VMLocation
    Root path where the VM folder will be created. Defaults to C:\VMs.
.PARAMETER VHDFile
    Source VHD/VHDX path used by Copy or Diff disk modes.
.PARAMETER DiskMode
    Storage mode for the VM disk: Copy, Diff, or Empty.
.PARAMETER VMSwitchName
    Virtual switch name to connect the VM network adapter to.
.PARAMETER VMNetworkType
    Network adapter type: Standard or Legacy (Legacy only valid for Generation 1).
.PARAMETER VlanID
    Optional access VLAN ID to assign to the VM network adapter.
.PARAMETER VMGeneration
    VM generation: 1 or 2. Defaults to 2.
.PARAMETER ISO
    Optional ISO path to mount in VM DVD drive.
.PARAMETER VHDSizeGB
    Size in GB used when DiskMode is Empty. Defaults to 100.
.NOTES
    FileName:    New-HyperVM.ps1
    Author:      Mikael Nystrom
    Contact:     deploymentbunny@outlook.com
    Created:     2026-04-28
    Updated:     2026-04-28
    Twitter:     @mikael_nystrom

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author.
.LINK
    https://www.deploymentbunny.com
.EXAMPLE
    .\New-HyperVM.ps1 -VMName LAB-CL01 -VMSwitchName vSwitch-Prod -DiskMode Empty
.EXAMPLE
    .\New-HyperVM.ps1 -VMName LAB-APP01 -VMSwitchName vSwitch-Prod -DiskMode Copy -VHDFile C:\BaseImages\Win11.vhdx -ISO C:\ISO\Windows.iso
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

    [Parameter(Mandatory = $false)]
    [ValidateRange(512MB, 64TB)]
    [Int64]$VMMem = 1GB,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 64)]
    [int]$VMvCPU = 1,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$VMLocation = "C:\VMs",

    [Parameter(Mandatory = $false)]
    [string]$VHDFile,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Copy", "Diff", "Empty")]
    [string]$DiskMode = "Copy",

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$VMSwitchName,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Standard", "Legacy")]
    [string]$VMNetworkType = "Standard",

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 4094)]
    [int]$VlanID,

    [Parameter(Mandatory = $false)]
    [ValidateSet(1, 2)]
    [int]$VMGeneration = 2,

    [Parameter(Mandatory = $false)]
    [string]$ISO,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 65536)]
    [int]$VHDSizeGB = 100
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Ensure script runs elevated; Hyper-V create/configure operations require admin rights.
$isAdmin = [bool](([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
if (-not $isAdmin) {
    throw "Administrator privileges are required to create and configure Hyper-V virtual machines."
}

# Validate parameters that depend on selected mode.
if ($DiskMode -in @("Copy", "Diff")) {
    if ([string]::IsNullOrWhiteSpace($VHDFile)) {
        throw "Parameter -VHDFile is required when -DiskMode is '$DiskMode'."
    }
    if (-not (Test-Path -LiteralPath $VHDFile -PathType Leaf)) {
        throw "VHD file not found: $VHDFile"
    }
}

if (-not [string]::IsNullOrWhiteSpace($ISO) -and -not (Test-Path -LiteralPath $ISO -PathType Leaf)) {
    throw "ISO file not found: $ISO"
}

if ($VMNetworkType -eq "Legacy" -and $VMGeneration -ne 1) {
    throw "Legacy network adapter is only supported for Generation 1 VMs."
}

if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    throw "A VM with name '$VMName' already exists."
}

$vmPath = Join-Path -Path $VMLocation -ChildPath $VMName
$vhdFolder = Join-Path -Path $vmPath -ChildPath "Virtual Hard Disks"

if ($PSCmdlet.ShouldProcess($VMName, "Create and configure Hyper-V VM")) {
    if (-not (Test-Path -LiteralPath $vhdFolder -PathType Container)) {
        [void](New-Item -Path $vhdFolder -ItemType Directory -Force)
    }

    # Create VM without disk first, then attach the exact disk built by selected mode.
    $vm = New-VM -Name $VMName -MemoryStartupBytes $VMMem -Path $VMLocation -NoVHD -Generation $VMGeneration

    # Replace default adapter with explicit type/config.
    Get-VMNetworkAdapter -VMName $VMName -ErrorAction SilentlyContinue | Remove-VMNetworkAdapter -Confirm:$false

    if ($VMNetworkType -eq "Legacy") {
        Add-VMNetworkAdapter -VMName $VMName -SwitchName $VMSwitchName -IsLegacy $true | Out-Null
    }
    else {
        Add-VMNetworkAdapter -VMName $VMName -SwitchName $VMSwitchName | Out-Null
    }

    if ($VMvCPU -ne 1) {
        Set-VMProcessor -VMName $VMName -Count $VMvCPU | Out-Null
    }

    if ($PSBoundParameters.ContainsKey("VlanID")) {
        Set-VMNetworkAdapterVlan -VMName $VMName -VlanId $VlanID -Access | Out-Null
    }

    $targetVhdPath = $null
    switch ($DiskMode) {
        "Copy" {
            $leaf = Split-Path -Path $VHDFile -Leaf
            $targetVhdPath = Join-Path -Path $vhdFolder -ChildPath $leaf
            Copy-Item -LiteralPath $VHDFile -Destination $targetVhdPath -Force
        }
        "Diff" {
            $baseLeaf = [System.IO.Path]::GetFileNameWithoutExtension($VHDFile)
            $targetVhdPath = Join-Path -Path $vhdFolder -ChildPath ("{0}-diff.vhdx" -f $baseLeaf)
            New-VHD -Path $targetVhdPath -ParentPath $VHDFile -Differencing | Out-Null
        }
        "Empty" {
            $targetVhdPath = Join-Path -Path $vhdFolder -ChildPath ("{0}.vhdx" -f $VMName)
            New-VHD -Path $targetVhdPath -SizeBytes ($VHDSizeGB * 1GB) -Dynamic | Out-Null
        }
    }

    Add-VMHardDiskDrive -VMName $VMName -Path $targetVhdPath | Out-Null

    # Ensure a DVD drive exists before optional ISO mount.
    $dvdDrive = Get-VMDvdDrive -VMName $VMName -ErrorAction SilentlyContinue
    if (-not $dvdDrive) {
        Add-VMDvdDrive -VMName $VMName | Out-Null
        $dvdDrive = Get-VMDvdDrive -VMName $VMName
    }

    if (-not [string]::IsNullOrWhiteSpace($ISO)) {
        Set-VMDvdDrive -VMName $VMName -Path $ISO | Out-Null
    }

    # Generation 2 boot order handling.
    if ($VMGeneration -eq 2) {
        $hddBoot = Get-VMHardDiskDrive -VMName $VMName | Select-Object -First 1
        $dvdBoot = Get-VMDvdDrive -VMName $VMName | Select-Object -First 1

        if ($DiskMode -eq "Empty" -and -not [string]::IsNullOrWhiteSpace($ISO) -and $null -ne $dvdBoot) {
            Set-VMFirmware -VMName $VMName -BootOrder $dvdBoot, $hddBoot | Out-Null
        }
        elseif ($null -ne $hddBoot) {
            Set-VMFirmware -VMName $VMName -BootOrder $hddBoot, $dvdBoot | Out-Null
        }
    }

    # Return a compact summary object to make automation and troubleshooting easier.
    [PSCustomObject]@{
        VMName        = $VMName
        Generation    = $VMGeneration
        MemoryStartup = $VMMem
        vCPU          = $VMvCPU
        SwitchName    = $VMSwitchName
        NetworkType   = $VMNetworkType
        VlanID        = $(if ($PSBoundParameters.ContainsKey("VlanID")) { $VlanID } else { $null })
        DiskMode      = $DiskMode
        DiskPath      = $targetVhdPath
        ISO           = $(if (-not [string]::IsNullOrWhiteSpace($ISO)) { $ISO } else { $null })
        VMPath        = $vmPath
        Created       = $true
    }
}

