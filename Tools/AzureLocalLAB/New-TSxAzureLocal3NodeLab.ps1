<#
.SYNOPSIS
Creates a three-node nested Azure Local lab on a Hyper-V host.

.DESCRIPTION
Creates three Generation 2 VMs. Each VM receives:
- 4 vCPU and static memory
- Secure Boot and virtual TPM
- Nested virtualization
- Four virtual NICs: two Management/Compute and two Storage
- One dynamically expanding OS VHDX
- Six dynamically expanding data VHDXs
- Disabled checkpoints and Hyper-V time synchronization

This prepares the virtual hardware only. Azure Local OS installation,
IP addressing, domain/DNS preparation, Azure registration, and deployment
must be completed separately.

Run from an elevated Windows PowerShell session on the Hyper-V host.

.EXAMPLE
.\New-AzureLocal3NodeLab.ps1 -VmRoot 'D:\AzureLocalLab' -IsoPath 'D:\ISO\AzureLocal.iso' -Verbose

.NOTES
    FileName:    New-AzureLocal3NodeLab.ps1
    Version:     1.0.1
    Author:      Mikael Nystrom
    Contact:     @mikael_nystrom
    Created:     2026-10-01
    Updated:     2026-10-01
    Twitter:     @mikael_nystrom

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author.

.LINK
    https://www.deploymentbunny.com

.FUNCTIONALITY
    Creates a nested three-node Azure Local lab with the required Hyper-V objects and VM configuration.
#>

#Requires -RunAsAdministrator
#Requires -Modules Hyper-V

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$VmRoot = 'D:\AzureLocalLab',
    [string]$IsoPath = 'D:\ISO\AzureLocal.iso',

    # This switch must already exist and normally provides upstream access.
    [string]$ManagementSwitchName = 'AzureLocal-Mgmt',

    # Created as a Private switch if it does not already exist.
    [string]$StorageSwitchName = 'AzureLocal-Storage',

    [string[]]$NodeNames = @('AZL-NODE01', 'AZL-NODE02', 'AZL-NODE03'),

    [ValidateRange(4, 256)]
    [int]$ProcessorCount = 8,

    [ValidateRange(32, 1024)]
    [int]$MemoryGB = 32,

    [ValidateRange(127, 2048)]
    [int]$OsDiskGB = 200,

    [ValidateRange(1, 6)]
    [int]$DataDiskCount = 6,

    # Microsoft documents virtual Azure Local S2D VHDXs up to 1024 GB.
    [ValidateRange(500, 1024)]
    [int]$DataDiskGB = 500,

    [ValidateRange(0, 4094)]
    [int]$NativeVlanId = 0,

    [string]$AllowedVlanIdList = '0-1000'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogRootPath = Join-Path -Path $env:TEMP -ChildPath 'AzureLocalLab'
$script:LogFilePath = Join-Path -Path $script:LogRootPath -ChildPath ('{0}.log' -f [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath))

if (-not (Test-Path -Path $script:LogRootPath)) {
    New-Item -Path $script:LogRootPath -ItemType Directory -Force | Out-Null
}

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

Write-TSxLog -Message ('Script started. VmRoot={0}; IsoPath={1}; NodeNames={2}' -f $VmRoot, $IsoPath, ($NodeNames -join ', '))

function Assert-Prerequisite {
    $featureState = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
    $featureEnabled = $false
    if ($featureState) {
        $featureEnabled = ($featureState | Where-Object { $_.State -eq 'Enabled' }).Count -gt 0
    }

    $hyperVCmdletsAvailable = $null -ne (Get-Command -Name New-VM -ErrorAction SilentlyContinue)
    if (-not ($featureEnabled -or $hyperVCmdletsAvailable)) {
        throw 'Hyper-V is not enabled on this host. Enable the Hyper-V role and rerun the script.'
    }

    if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) {
        throw "Azure Local ISO not found: $IsoPath"
    }

    if (-not (Get-VMSwitch -Name $ManagementSwitchName -ErrorAction SilentlyContinue)) {
        throw "Management switch '$ManagementSwitchName' does not exist. Create an External or NAT-connected Internal switch first, then rerun the script."
    }

    if ($NodeNames.Count -ne 3) {
        throw 'This script expects exactly three node names.'
    }

    $existing = Get-VM -Name $NodeNames -ErrorAction SilentlyContinue
    if ($existing) {
        throw "One or more target VMs already exist: $($existing.Name -join ', '). Remove them or change NodeNames."
    }
}

function Get-OrCreateUntrustedGuardian {
    $guardian = Get-HgsGuardian -Name 'AzureLocalLab-UntrustedGuardian' -ErrorAction SilentlyContinue
    if (-not $guardian) {
        if (-not $PSCmdlet.ShouldProcess('AzureLocalLab-UntrustedGuardian', 'Create HGS guardian')) {
            throw 'HGS guardian creation was cancelled.'
        }

        Write-TSxLog -Message 'Creating HGS guardian AzureLocalLab-UntrustedGuardian.'
        $guardian = New-HgsGuardian -Name 'AzureLocalLab-UntrustedGuardian' -GenerateCertificates
    }
    return $guardian
}

Assert-Prerequisite

if (-not (Test-Path -LiteralPath $VmRoot)) {
    Write-Verbose ("Ensuring VM root exists: {0}" -f $VmRoot)
    if ($PSCmdlet.ShouldProcess($VmRoot, 'Create VM root directory')) {
        Write-TSxLog -Message ("Creating VM root directory {0}." -f $VmRoot)
        New-Item -Path $VmRoot -ItemType Directory -Force | Out-Null
    }
}

if (-not (Get-VMSwitch -Name $StorageSwitchName -ErrorAction SilentlyContinue)) {
    Write-Verbose ("Creating storage switch '{0}'." -f $StorageSwitchName)
    if ($PSCmdlet.ShouldProcess($StorageSwitchName, 'Create storage VMSwitch')) {
        Write-TSxLog -Message ("Creating storage switch {0}." -f $StorageSwitchName)
        New-VMSwitch -Name $StorageSwitchName -SwitchType Private | Out-Null
    }
}

$guardian = Get-OrCreateUntrustedGuardian
if ($null -eq $guardian) {
    throw 'Unable to resolve or create the HGS guardian for the lab.'
}

Write-Verbose 'Creating a key protector for the untrusted guardian.'
if (-not $PSCmdlet.ShouldProcess('AzureLocalLab-UntrustedGuardian', 'Create HGS key protector')) {
    throw 'HGS key protector creation was cancelled.'
}

Write-TSxLog -Message 'Creating HGS key protector for the lab guardian.'
$keyProtector = New-HgsKeyProtector -Owner $guardian -AllowUntrustedRoot

foreach ($node in $NodeNames) {
    Write-Host "Creating $node..." -ForegroundColor Cyan
    Write-TSxLog -Message ("Beginning Azure Local node creation for {0}." -f $node)

    if ($PSCmdlet.ShouldProcess($node, 'Create Azure Local lab node')) {
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

        Set-VM -Name $node -CheckpointType Disabled -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
        Set-VMMemory -VMName $node -DynamicMemoryEnabled $false
        Set-VMProcessor -VMName $node -Count $ProcessorCount -ExposeVirtualizationExtensions $true
        Set-VMFirmware -VMName $node -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows

        Write-Verbose ("Applying key protector and TPM configuration to {0}." -f $node)
        Set-VMKeyProtector -VMName $node -KeyProtector $keyProtector.RawData
        Enable-VMTPM -VMName $node

        Disable-VMIntegrationService -VMName $node -Name 'Time Synchronization'

        Get-VMNetworkAdapter -VMName $node | Remove-VMNetworkAdapter

        $managementNicNames = @('NIC01', 'NIC02')
        $storageNicNames = @('NIC03', 'NIC04')

        foreach ($nicName in $managementNicNames) {
            Add-VMNetworkAdapter -VMName $node -Name $nicName -SwitchName $ManagementSwitchName -DeviceNaming On
        }

        foreach ($nicName in $storageNicNames) {
            Add-VMNetworkAdapter -VMName $node -Name $nicName -SwitchName $StorageSwitchName -DeviceNaming On
        }

        Get-VMNetworkAdapter -VMName $node |
            Set-VMNetworkAdapter -MacAddressSpoofing On -AllowTeaming On

        # Required by Microsoft's multi-node virtual deployment guidance.
        Get-VMNetworkAdapter -VMName $node |
            Set-VMNetworkAdapterVlan -Trunk -NativeVlanId $NativeVlanId -AllowedVlanIdList $AllowedVlanIdList

        Add-VMDvdDrive -VMName $node -Path $IsoPath | Out-Null
        $dvd = Get-VMDvdDrive -VMName $node
        Set-VMFirmware -VMName $node -FirstBootDevice $dvd

        for ($diskNumber = 1; $diskNumber -le $DataDiskCount; $diskNumber++) {
            $dataVhd = Join-Path $vhdPath ('{0}-DATA-{1:D2}.vhdx' -f $node, $diskNumber)
            Write-Verbose ("Creating data VHD {0} for {1}." -f $diskNumber, $node)
            New-VHD -Path $dataVhd -Dynamic -SizeBytes ($DataDiskGB * 1GB) | Out-Null
            Add-VMHardDiskDrive -VMName $node -ControllerType SCSI -Path $dataVhd | Out-Null
        }

    }
}

if ($WhatIfPreference) {
    Write-Host ''
    Write-Host 'WhatIf mode is active; no VM changes were made.' -ForegroundColor Yellow
    return
}

if (-not (Get-VM -Name $NodeNames -ErrorAction SilentlyContinue)) {
    Write-Host ''
    Write-Host 'The lab creation workflow was skipped or cancelled; no VMs are present.' -ForegroundColor Yellow
    return
}

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
