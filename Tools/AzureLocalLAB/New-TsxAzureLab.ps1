<#
.SYNOPSIS
Creates a configurable nested Azure Local lab on a Hyper-V host.

.DESCRIPTION
Creates 1 to 16 Generation 2 VMs for a hyperconverged lab. Each VM receives:
- Configurable vCPU and static memory (at least 4 vCPU and 32 GB)
- Secure Boot and virtual TPM
- Nested virtualization
- Configurable Management/Compute and Storage NIC counts (two each by default)
- One dynamically expanding OS VHDX
- Two to ten dynamically expanding data VHDXs, up to 1024 GB each
- Disabled checkpoints and Hyper-V time synchronization

This prepares the virtual hardware only. Azure Local OS installation,
IP addressing, domain/DNS preparation, Azure registration, and deployment
must be completed separately.

Run from an elevated Windows PowerShell session on the Hyper-V host.
Virtual deployments are for evaluation only and are not supported by Microsoft.
All nodes receive the same hardware configuration and remain powered off.

.PARAMETER ServerNamePrefix
Prefix for VM and guest computer names. The sequence begins at StartNumber,
with at least two digits. The prefix must be 1 to 13 letters, digits, or
hyphens, must start with a letter or digit, and must contain a letter or hyphen.
Every generated name must fit the 15-character Windows computer-name limit.

.PARAMETER StartNumber
First numeric suffix, a nonnegative integer. Defaults to 1 (formatted as 01).
For example, prefix FAHOST and StartNumber 41 produce FAHOST41, FAHOST42, etc.
Aliases: Suffix, SuffixStartNumber.

.PARAMETER NodeCount
Number of nodes, from 1 to 16. Defaults to 3.

.PARAMETER DataDiskCount
Number of data disks per node, from 2 to 10. Exactly one OS disk is always created.

.PARAMETER DataDiskGB
Size of each dynamically expanding data disk in GB, from 500 to 1024.
Use 1024 for a 1 TB disk.

.EXAMPLE
.\New-TsxAzureLab.ps1 -ServerNamePrefix 'AZL-NODE' -NodeCount 3 -VmRoot 'D:\AzureLocalLab' -IsoPath 'D:\ISO\AzureLocal.iso' -Verbose

.EXAMPLE
.\New-TsxAzureLab.ps1 -ServerNamePrefix 'LAB' -NodeCount 1 -ProcessorCount 4 -MemoryGB 32 -DataDiskCount 2 -DataDiskGB 1024

.EXAMPLE
.\New-TsxAzureLab.ps1 -ServerNamePrefix 'FAHOST' -StartNumber 41 -NodeCount 3 -WhatIf

.EXAMPLE
.\New-TsxAzureLab.ps1 -ServerNamePrefix 'HCI' -NodeCount 16 -ProcessorCount 16 -MemoryGB 64 -OsDiskGB 200 -DataDiskCount 10 -DataDiskGB 1024 -WhatIf

.NOTES
    FileName:    New-TsxAzureLab.ps1
    Version:     1.2.0
    Author:      Mikael Nystrom
    Contact:     @mikael_nystrom
    Created:     2026-10-01
    Updated:     2026-10-05
    Twitter:     @mikael_nystrom

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author.

.LINK
    https://www.deploymentbunny.com

.FUNCTIONALITY
    Creates configurable nested Azure Local lab virtual hardware.
#>

#Requires -RunAsAdministrator
#Requires -Modules Hyper-V

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateNotNullOrEmpty()]
    [string]$VmRoot = 'D:\AzureLocalLab',
    [ValidateNotNullOrEmpty()]
    [string]$IsoPath = 'D:\ISO\AzureLocal.iso',

    # This switch must already exist and normally provides upstream access.
    [ValidateNotNullOrEmpty()]
    [string]$ManagementSwitchName = 'AzureLocal-Mgmt',

    # Created as a Private switch if it does not already exist.
    [ValidateNotNullOrEmpty()]
    [string]$StorageSwitchName = 'AzureLocal-Storage',

    [Alias('ServerName', 'VMNamePrefix')]
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]{0,12}$')]
    [ValidatePattern('[a-zA-Z-]')]
    [string]$ServerNamePrefix = 'AZL-NODE',

    [Alias('Suffix', 'SuffixStartNumber')]
    [ValidateRange(0, 2147483647)]
    [int]$StartNumber = 1,

    [ValidateRange(1, 16)]
    [int]$NodeCount = 3,

    [ValidateRange(4, 256)]
    [int]$ProcessorCount = 8,

    [ValidateRange(32, 1024)]
    [int]$MemoryGB = 32,

    [ValidateRange(127, 2048)]
    [int]$OsDiskGB = 200,

    [ValidateRange(2, 10)]
    [int]$DataDiskCount = 6,

    # Microsoft documents virtual Azure Local S2D VHDXs up to 1024 GB.
    [ValidateRange(500, 1024)]
    [int]$DataDiskGB = 500,

    [ValidateRange(1, 8)]
    [int]$ManagementNicCount = 2,

    [ValidateRange(1, 8)]
    [int]$StorageNicCount = 2,

    [ValidateRange(0, 4094)]
    [int]$NativeVlanId = 0,

    [ValidateNotNullOrEmpty()]
    [string]$AllowedVlanIdList = '0-1000'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$NodeNames = @(0..($NodeCount - 1) | ForEach-Object { '{0}{1:D2}' -f $ServerNamePrefix, ([long]$StartNumber + $_) })
if (@($NodeNames | Where-Object { $_.Length -gt 15 }).Count -gt 0) {
    throw 'Generated server names exceed the 15-character Windows computer-name limit. Shorten ServerNamePrefix or reduce StartNumber or NodeCount.'
}
$script:LogRootPath = Join-Path -Path $env:TEMP -ChildPath 'AzureLocalLab'
$script:LogFilePath = Join-Path -Path $script:LogRootPath -ChildPath ('{0}.log' -f [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath))

function Write-TSxLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $entry = '{0} [{1}] {2}' -f $timestamp, $Level, $Message
    Add-Content -Path $script:LogFilePath -Value $entry
    Write-Verbose $entry
}

function Assert-Prerequisite {
    Write-Verbose 'Checking Hyper-V availability.'
    $featureState = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
    $featureEnabled = $false
    if ($featureState) {
        $featureEnabled = @($featureState | Where-Object { $_.State -eq 'Enabled' }).Count -gt 0
    }

    $hyperVCmdletsAvailable = $null -ne (Get-Command -Name New-VM -ErrorAction SilentlyContinue)
    if (-not ($featureEnabled -or $hyperVCmdletsAvailable)) {
        throw 'Hyper-V is not enabled on this host. Enable the Hyper-V role and rerun the script.'
    }

    Write-Verbose ("Checking installation ISO: {0}" -f $IsoPath)
    if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) {
        throw "Azure Local ISO not found: $IsoPath"
    }

    Write-Verbose ("Checking management switch: {0}" -f $ManagementSwitchName)
    if (-not (Get-VMSwitch -Name $ManagementSwitchName -ErrorAction SilentlyContinue)) {
        throw "Management switch '$ManagementSwitchName' does not exist. Create an External or NAT-connected Internal switch first, then rerun the script."
    }

    if ((Test-Path -LiteralPath $VmRoot) -and -not (Test-Path -LiteralPath $VmRoot -PathType Container)) {
        throw "VM root is not a directory: $VmRoot"
    }

    Write-Verbose ("Checking for existing VMs and node directories: {0}" -f ($NodeNames -join ', '))
    $existing = @(Get-VM | Where-Object { $_.Name -in $NodeNames })
    if ($existing) {
        throw "One or more target VMs already exist: $($existing.Name -join ', '). Choose another ServerNamePrefix or StartNumber, or remove the existing VMs."
    }

    foreach ($node in $NodeNames) {
        $nodePath = Join-Path $VmRoot $node
        if (Test-Path -LiteralPath $nodePath) {
            throw "Target node path already exists: $nodePath. Choose another ServerNamePrefix, StartNumber, or VmRoot."
        }
    }
}

function Get-OrCreateUntrustedGuardian {
    $guardian = Get-HgsGuardian -Name 'AzureLocalLab-UntrustedGuardian' -ErrorAction SilentlyContinue
    if (-not $guardian) {
        Write-TSxLog -Message 'Creating HGS guardian AzureLocalLab-UntrustedGuardian.'
        $guardian = New-HgsGuardian -Name 'AzureLocalLab-UntrustedGuardian' -GenerateCertificates
    }
    return $guardian
}

Write-Host ('Azure Local lab: {0}' -f ($NodeNames -join ', ')) -ForegroundColor Cyan
Write-Host 'Checking prerequisites...' -ForegroundColor Cyan
Assert-Prerequisite
Write-Host 'Prerequisite checks passed.' -ForegroundColor Green

Write-Verbose ('Plan: Nodes={0}; vCPU/node={1}; RAM/node={2} GB; OS/node={3} GB; Data/node={4} x {5} GB; NICs/node={6} management + {7} storage.' -f $NodeCount, $ProcessorCount, $MemoryGB, $OsDiskGB, $DataDiskCount, $DataDiskGB, $ManagementNicCount, $StorageNicCount)
$creationDescription = 'Create {0} Azure Local lab node(s), each with {1} vCPU, {2} GB RAM, one {3} GB OS disk and {4} x {5} GB data disks; create missing VM root, private storage switch and HGS guardian' -f $NodeCount, $ProcessorCount, $MemoryGB, $OsDiskGB, $DataDiskCount, $DataDiskGB
if (-not $PSCmdlet.ShouldProcess(($NodeNames -join ', '), $creationDescription)) {
    if ($WhatIfPreference) {
        foreach ($node in $NodeNames) {
            Write-Host ('Preview {0}: {1} vCPU, {2} GB RAM, one {3} GB OS disk, {4} x {5} GB data disks, {6} management + {7} storage NICs.' -f $node, $ProcessorCount, $MemoryGB, $OsDiskGB, $DataDiskCount, $DataDiskGB, $ManagementNicCount, $StorageNicCount) -ForegroundColor Cyan
        }
        Write-Host 'Preview complete (-WhatIf). No resources were created. Remove -WhatIf to provision this lab.' -ForegroundColor Yellow
    }
    else {
        Write-Host 'Lab creation cancelled. No resources were created.' -ForegroundColor Yellow
    }
    return
}

Write-Host 'Preparing lab directories, storage switch and vTPM guardian...' -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $script:LogRootPath)) {
    New-Item -Path $script:LogRootPath -ItemType Directory -Force | Out-Null
}
Write-TSxLog -Message ('Script started. VmRoot={0}; IsoPath={1}; NodeNames={2}; {3}' -f $VmRoot, $IsoPath, ($NodeNames -join ', '), $creationDescription)

try {
    if (-not (Test-Path -LiteralPath $VmRoot)) {
        Write-Verbose ("Ensuring VM root exists: {0}" -f $VmRoot)
        Write-TSxLog -Message ("Creating VM root directory {0}." -f $VmRoot)
        New-Item -Path $VmRoot -ItemType Directory -Force | Out-Null
    }

    if (-not (Get-VMSwitch -Name $StorageSwitchName -ErrorAction SilentlyContinue)) {
        Write-Verbose ("Creating storage switch '{0}'." -f $StorageSwitchName)
        Write-TSxLog -Message ("Creating storage switch {0}." -f $StorageSwitchName)
        New-VMSwitch -Name $StorageSwitchName -SwitchType Private | Out-Null
    }

    $guardian = Get-OrCreateUntrustedGuardian
    if ($null -eq $guardian) {
        throw 'Unable to resolve or create the HGS guardian for the lab.'
    }

    Write-Verbose 'Creating a key protector for the untrusted guardian.'
    Write-TSxLog -Message 'Creating HGS key protector for the lab guardian.'
    $keyProtector = New-HgsKeyProtector -Owner $guardian -AllowUntrustedRoot

    $nodeIndex = 0
    foreach ($node in $NodeNames) {
        $nodeIndex++
        Write-Host ('[{0}/{1}] {2}: creating OS disk and VM...' -f $nodeIndex, $NodeCount, $node) -ForegroundColor Cyan
        Write-TSxLog -Message ("Beginning Azure Local node creation for {0}." -f $node)

        $nodePath = Join-Path $VmRoot $node
        $vhdPath = Join-Path $nodePath 'Virtual Hard Disks'
        Write-Verbose ("Ensuring VM path exists for {0}: {1}" -f $node, $vhdPath)
        New-Item -Path $vhdPath -ItemType Directory -Force | Out-Null

        $osVhd = Join-Path $vhdPath "$node-OS.vhdx"
        Write-Verbose ("Creating OS VHD for {0}: {1}" -f $node, $osVhd)
        New-VHD -Path $osVhd -Dynamic -SizeBytes ($OsDiskGB * 1GB) | Out-Null

        Write-Verbose ("Creating VM {0}." -f $node)
        New-VM -Name $node `
            -Generation 2 `
            -Path $nodePath `
            -VHDPath $osVhd `
            -MemoryStartupBytes ($MemoryGB * 1GB) | Out-Null

        Write-Host ('[{0}/{1}] {2}: configuring CPU, memory, nested virtualization, Secure Boot and vTPM...' -f $nodeIndex, $NodeCount, $node) -ForegroundColor Cyan
        Set-VM -Name $node -CheckpointType Disabled -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
        Set-VMMemory -VMName $node -DynamicMemoryEnabled $false
        Set-VMProcessor -VMName $node -Count $ProcessorCount -ExposeVirtualizationExtensions $true
        Set-VMFirmware -VMName $node -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows

        Write-Verbose ("Applying key protector and TPM configuration to {0}." -f $node)
        Set-VMKeyProtector -VMName $node -KeyProtector $keyProtector.RawData
        Enable-VMTPM -VMName $node

        Disable-VMIntegrationService -VMName $node -Name 'Time Synchronization'

        Write-Host ('[{0}/{1}] {2}: configuring network adapters and installation media...' -f $nodeIndex, $NodeCount, $node) -ForegroundColor Cyan
        Get-VMNetworkAdapter -VMName $node | Remove-VMNetworkAdapter

        $managementNicNames = @(1..$ManagementNicCount | ForEach-Object { 'NIC{0:D2}' -f $_ })
        $storageNicNames = @(1..$StorageNicCount | ForEach-Object { 'NIC{0:D2}' -f ($_ + $ManagementNicCount) })

        foreach ($nicName in $managementNicNames) {
            Write-Verbose ("Adding {0} to {1} on management switch {2}." -f $nicName, $node, $ManagementSwitchName)
            Add-VMNetworkAdapter -VMName $node -Name $nicName -SwitchName $ManagementSwitchName -DeviceNaming On
        }

        foreach ($nicName in $storageNicNames) {
            Write-Verbose ("Adding {0} to {1} on storage switch {2}." -f $nicName, $node, $StorageSwitchName)
            Add-VMNetworkAdapter -VMName $node -Name $nicName -SwitchName $StorageSwitchName -DeviceNaming On
        }

        Get-VMNetworkAdapter -VMName $node |
            Set-VMNetworkAdapter -MacAddressSpoofing On -AllowTeaming On

        # Required by Microsoft's multi-node virtual deployment guidance.
        if ($NodeCount -gt 1) {
            Get-VMNetworkAdapter -VMName $node |
                Set-VMNetworkAdapterVlan -Trunk -NativeVlanId $NativeVlanId -AllowedVlanIdList $AllowedVlanIdList
        }

        Add-VMDvdDrive -VMName $node -Path $IsoPath | Out-Null
        $dvd = Get-VMDvdDrive -VMName $node
        Set-VMFirmware -VMName $node -FirstBootDevice $dvd

        for ($diskNumber = 1; $diskNumber -le $DataDiskCount; $diskNumber++) {
            Write-Host ('[{0}/{1}] {2}: creating data disk {3}/{4} ({5} GB)...' -f $nodeIndex, $NodeCount, $node, $diskNumber, $DataDiskCount, $DataDiskGB) -ForegroundColor Cyan
            $dataVhd = Join-Path $vhdPath ('{0}-DATA-{1:D2}.vhdx' -f $node, $diskNumber)
            Write-Verbose ("Creating data VHD {0} for {1}." -f $diskNumber, $node)
            New-VHD -Path $dataVhd -Dynamic -SizeBytes ($DataDiskGB * 1GB) | Out-Null
            Add-VMHardDiskDrive -VMName $node -ControllerType SCSI -Path $dataVhd | Out-Null
        }
        Write-TSxLog -Message ("Node {0} completed." -f $node)
        Write-Host ('[{0}/{1}] {2}: completed; VM is powered off and ready for OS installation.' -f $nodeIndex, $NodeCount, $node) -ForegroundColor Green
    }
}
catch {
    Write-TSxLog -Message ("Lab creation failed: {0}. Partially created resources have been retained for inspection." -f $_.Exception.Message) -Level ERROR
    throw
}

Write-TSxLog -Message 'Azure Local lab virtual hardware created successfully.'
Write-Host ''
Write-Host 'Azure Local lab virtual hardware created successfully.' -ForegroundColor Green
Get-VM -Name $NodeNames | Select-Object Name, State, ProcessorCount,
    @{Name='StartupMemoryGB'; Expression={[math]::Round($_.MemoryStartup / 1GB, 0)}} |
    Format-Table -AutoSize

Write-Host 'NIC layout:' -ForegroundColor Cyan
Get-VMNetworkAdapter -VMName $NodeNames |
    Select-Object VMName, Name, SwitchName, MacAddressSpoofing, AllowTeaming |
    Sort-Object VMName, Name |
    Format-Table -AutoSize

Write-Host 'Disk layout:' -ForegroundColor Cyan
Get-VMHardDiskDrive -VMName $NodeNames |
    Select-Object VMName, ControllerType, ControllerNumber, ControllerLocation, Path |
    Sort-Object VMName, ControllerLocation |
    Format-Table -AutoSize
