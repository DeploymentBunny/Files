# New-HyperVM

## Overview
`New-HyperVM.ps1` creates a Hyper-V virtual machine with consistent, validated provisioning logic.

It supports:
- Generation 1 or 2 VMs
- Standard or Legacy networking (Legacy only for Gen1)
- Optional VLAN configuration
- Three disk modes: `Copy`, `Diff`, `Empty`
- Optional ISO mounting
- Generation 2 boot order configuration

## Files
- `New-HyperVM.ps1` - VM provisioning script

## Requirements
- Windows host with Hyper-V role and PowerShell module
- Local administrator privileges
- Existing Hyper-V virtual switch (`-VMSwitchName`)

## Parameters
- `VMName` (string, required): Name of the VM to create.
- `VMMem` (Int64, optional, default `1GB`): Startup memory in bytes.
- `VMvCPU` (int, optional, default `1`): Number of virtual processors.
- `VMLocation` (string, optional, default `C:\VMs`): Root path for VM files.
- `VHDFile` (string, optional): Source VHD/VHDX path for `Copy` or `Diff` mode.
- `DiskMode` (string, optional, default `Copy`): `Copy`, `Diff`, or `Empty`.
- `VMSwitchName` (string, required): Hyper-V virtual switch name.
- `VMNetworkType` (string, optional, default `Standard`): `Standard` or `Legacy`.
- `VlanID` (int, optional): Access VLAN ID (1-4094).
- `VMGeneration` (int, optional, default `2`): `1` or `2`.
- `ISO` (string, optional): ISO file path to mount.
- `VHDSizeGB` (int, optional, default `100`): Used when `DiskMode` is `Empty`.

## Disk Modes
- `Copy`: Copies an existing VHD/VHDX into the VM's "Virtual Hard Disks" folder and attaches it.
- `Diff`: Creates a differencing disk based on `-VHDFile` and attaches it.
- `Empty`: Creates a new dynamic VHDX (`<VMName>.vhdx`) and attaches it.

## Examples
```powershell
# Create a Gen2 VM with empty 100GB disk
.\New-HyperVM.ps1 -VMName LAB-CL01 -VMSwitchName vSwitch-Prod -DiskMode Empty
```

```powershell
# Create VM by copying a base image and mounting an ISO
.\New-HyperVM.ps1 -VMName LAB-APP01 -VMSwitchName vSwitch-Prod -DiskMode Copy -VHDFile C:\BaseImages\Win11.vhdx -ISO C:\ISO\Windows.iso
```

```powershell
# Create Gen1 VM with legacy adapter and VLAN
.\New-HyperVM.ps1 -VMName LAB-SRV01 -VMGeneration 1 -VMNetworkType Legacy -VMSwitchName vSwitch-Prod -DiskMode Diff -VHDFile C:\BaseImages\ServerBase.vhdx -VlanID 120
```

## Output
On success, the script emits a summary object with VM name, generation, memory, CPU, network settings, disk details, ISO path, and VM path.

## Notes
- The script throws a clear error if not running elevated.
- It validates mode-dependent parameters (for example, `-VHDFile` is required for `Copy` and `Diff`).
- Existing VMs with the same name are rejected to prevent accidental overwrite.
