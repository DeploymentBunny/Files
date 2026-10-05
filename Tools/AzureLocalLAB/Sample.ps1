<#
.SYNOPSIS
Examples for creating nested Azure Local labs with New-TsxAzureLab.ps1.

.DESCRIPTION
Run the desired example in elevated Windows PowerShell on the Hyper-V host.
Update the ISO path, VM root, and switch names for your environment.
The management switch and ISO must already exist, even for -WhatIf.
All examples preview only. Remove -WhatIf from the chosen example to create
that lab; do not run all examples unless you intend to create three labs.
Hardware settings apply to every node. VMs remain powered off.
In PowerShell ISE, save this file beside the builder before running with F5.
For F8, select the path setup below along with the desired example.
#>

$sampleRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($sampleRoot)) {
    $iseVariable = Get-Variable -Name psISE -ErrorAction SilentlyContinue
    if ($null -ne $iseVariable -and $null -ne $iseVariable.Value -and
        $null -ne $iseVariable.Value.CurrentFile) {
        $sampleFilePath = $iseVariable.Value.CurrentFile.FullPath
        if (-not [string]::IsNullOrWhiteSpace($sampleFilePath) -and
            [System.IO.Path]::IsPathRooted($sampleFilePath)) {
            $sampleRoot = Split-Path -Path $sampleFilePath -Parent
        }
    }
}

if ([string]::IsNullOrWhiteSpace($sampleRoot)) {
    throw 'Cannot locate the sample folder. Save Sample.ps1 beside New-TsxAzureLab.ps1 and run the saved file, or include the path setup in your ISE selection.'
}

$builderPath = Join-Path -Path $sampleRoot -ChildPath 'New-TsxAzureLab.ps1'
if (-not (Test-Path -LiteralPath $builderPath -PathType Leaf)) {
    throw "Lab builder not found: $builderPath. Save Sample.ps1 in the same folder as New-TsxAzureLab.ps1."
}

BREAK

# Single node: SINGLE01, one OS disk and two 1 TB data disks.
& $builderPath `
    -ServerNamePrefix 'SINGLE' `
    -StartNumber 1 `
    -NodeCount 1 `
    -ProcessorCount 4 `
    -MemoryGB 32 `
    -OsDiskGB 200 `
    -DataDiskCount 2 `
    -DataDiskGB 1024 `
    -VmRoot 'D:\AzureLocalLab' `
    -IsoPath 'D:\ISO\AzureLocal.iso' `
    -ManagementSwitchName 'AzureLocal-Mgmt' `
    -StorageSwitchName 'AzureLocal-Storage' `
    -WhatIf `
    -Verbose

# Three nodes: FAHOST41, FAHOST42, FAHOST43, with custom NIC and VLAN settings.
$threeNodeLab = @{
    ServerNamePrefix     = 'FAHOST'
    StartNumber          = 41
    NodeCount            = 3
    ProcessorCount       = 8
    MemoryGB             = 64
    OsDiskGB             = 200
    DataDiskCount        = 6
    DataDiskGB           = 1024
    VmRoot               = 'F:\azurelocal04'
    IsoPath              = 'E:\ISO\AzureLocal24H2.26100.32230.LCM.12.2609.0.3009.x64.en-us.iso'
    ManagementSwitchName = 'UplinkSwitchSET'
    StorageSwitchName    = 'AzureLocal04Storage'
    ManagementNicCount   = 2
    StorageNicCount      = 2
    NativeVlanId         = 0
    AllowedVlanIdList    = '0-1024'
}

& $builderPath @threeNodeLab -WhatIf -Verbose

# Maximum hyperconverged lab: HCI01 through HCI16, ten 1 TB data disks each.
# Requires 1024 GB of VM RAM; dynamic disk capacity can grow to 163.125 TiB.
& $builderPath `
    -ServerNamePrefix 'HCI' `
    -StartNumber 1 `
    -NodeCount 16 `
    -ProcessorCount 16 `
    -MemoryGB 64 `
    -OsDiskGB 200 `
    -DataDiskCount 10 `
    -DataDiskGB 1024 `
    -VmRoot 'D:\AzureLocalLab' `
    -IsoPath 'D:\ISO\AzureLocal.iso' `
    -ManagementSwitchName 'AzureLocal-Mgmt' `
    -StorageSwitchName 'AzureLocal-Storage' `
    -WhatIf `
    -Verbose
