# Azure Local lab

These scripts prepare and configure nested Azure Local VMs on a Hyper-V host.
They do not perform a complete Azure Local deployment. Virtual deployments are
for evaluation only and are not supported by Microsoft.

## Scripts

- `Sample.ps1`: single-node, three-node, and 16-node builder examples. All use
  `-WhatIf`; edit the environment settings and remove it from the chosen example
  when ready to provision. This is a selection-only sample: an intentional
  `BREAK` guard blocks whole-file execution. In PowerShell ISE, save it beside
  the builder, select the path setup below the guard and run it with F8, then
  select only the desired example and run it with F8.
- `New-TsxAzureLab.ps1` (formerly `New-TSxAzureLocal3NodeLab.ps1`): creates
  configurable, identical virtual hardware for 1-16 hyperconverged lab nodes.
- `Set-TSxPostDeployTSxAzureLocal.ps1`: configures **one installed guest** at a
  time. Renames the guest to its VM name, maps NIC names by MAC address, sets
  static networking, joins the domain, and restarts it.
- `Set-TSxAzureArcRegistration.ps1`: registers **one guest** with Azure Arc.
  Requires the Azure Local initialization cmdlet inside the installed guest.

## Requirements

Run the builder in elevated Windows PowerShell on a host with Hyper-V and HGS
client cmdlets. Supply an existing Azure Local ISO and an existing management
switch with upstream connectivity. A missing storage switch is created as a
private switch. Ensure sufficient host RAM, CPU, and storage for all nodes.

The 16-node limit is for this hyperconverged lab topology, not the separate
64-machine disaggregated topology. Creating VM hardware does not guarantee that
a particular Azure Local version, network configuration, or host can deploy it.
See Microsoft's [virtual deployment guidance](https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-virtual).

## Builder parameters

All hardware quantities are **per node**. All sizes use PowerShell binary GB
(1 GB = 1 GiB); `-DataDiskGB 1024` creates a 1 TiB disk.

| Parameter | Default | Accepted values / purpose |
| --- | --- | --- |
| `ServerNamePrefix` | `AZL-NODE` | 1-13 letters, digits, or hyphens; starts with a letter/digit and cannot be all digits. Aliases: `ServerName`, `VMNamePrefix`. |
| `StartNumber` | `1` | Nonnegative integer for the first numeric suffix; at least two digits. Aliases: `Suffix`, `SuffixStartNumber`. |
| `NodeCount` | `3` | 1-16; suffixes increase consecutively from `StartNumber`. |
| `VmRoot` | `D:\AzureLocalLab` | Root directory for VM configuration and disks. |
| `IsoPath` | `D:\ISO\AzureLocal.iso` | Existing installation ISO. |
| `ProcessorCount` | `8` | 4-256 virtual processors. |
| `MemoryGB` | `32` | 32-1024 GB static memory. |
| `OsDiskGB` | `200` | 127-2048 GB; exactly one dynamically expanding OS VHDX. |
| `DataDiskCount` | `6` | 2-10 dynamically expanding data VHDXs. |
| `DataDiskGB` | `500` | 500-1024 GB for each data disk. |
| `ManagementSwitchName` | `AzureLocal-Mgmt` | Existing management/compute switch. |
| `StorageSwitchName` | `AzureLocal-Storage` | Existing switch or a new private switch. |
| `ManagementNicCount` | `2` | 1-8 management/compute adapters. |
| `StorageNicCount` | `2` | 1-8 storage adapters. |
| `NativeVlanId` | `0` | 0-4094; multi-node trunk configuration only. |
| `AllowedVlanIdList` | `0-1000` | Hyper-V allowed trunk VLAN list; multi-node only. |

NICs are numbered consecutively, management first: the default is management
`NIC01`/`NIC02`, storage `NIC03`/`NIC04`. Single-node labs do not enable trunk
mode. For multi-node labs, all NICs use the supplied trunk settings.

For example, `-ServerNamePrefix FAHOST -StartNumber 41 -NodeCount 3` generates
`FAHOST41`, `FAHOST42`, and `FAHOST43`. Values below 10 are padded (`01`, `02`);
values above 99 continue as `100`, `101`, etc. Every generated name must be at
most 15 characters; the entire range is checked before any resources are created.

The builder retains Generation 2, Secure Boot, vTPM, nested virtualization,
MAC spoofing, teaming, disabled checkpoints and time synchronization, and DVD
boot. VMs remain powered off for you to start and install the OS.

Existing VM names or target node directories are rejected before provisioning.
`-WhatIf` checks prerequisites and previews the whole lab without creating
directories, logs, switches, guardians, disks, or VMs. One confirmation covers
the whole lab; use `-Confirm:$false` for unattended creation.
Console status messages show prerequisite checks, each node's configuration
phases, individual data disks, and completion even without `-Verbose`.
`-Verbose` adds detailed checks and resource paths. Preview output explicitly
states that no resources were created and shows each node's planned hardware.
Failures terminate with an error and are logged under `%TEMP%\AzureLocalLab`.
Partially created resources are retained for inspection, not automatically
deleted.

## Examples

```powershell
# Custom starting suffix: FAHOST41, FAHOST42, FAHOST43.
.\New-TsxAzureLab.ps1 -ServerNamePrefix FAHOST -StartNumber 41 -NodeCount 3 -WhatIf

# Single node: LAB01, one OS disk and two 1 TB data disks.
.\New-TsxAzureLab.ps1 -ServerNamePrefix LAB -NodeCount 1 `
    -ProcessorCount 4 -MemoryGB 32 -OsDiskGB 200 `
    -DataDiskCount 2 -DataDiskGB 1024 `
    -VmRoot 'D:\Labs' -IsoPath 'D:\ISO\AzureLocal.iso' `
    -ManagementSwitchName 'External' -Verbose

# Maximum lab: HCI01 through HCI16, ten 1 TB data disks per node.
# This allocates 1024 GB of VM RAM and 163.125 TiB of maximum disk capacity.
# Dynamic disks grow as data is written; plan physical storage accordingly.
.\New-TsxAzureLab.ps1 -ServerNamePrefix HCI -NodeCount 16 `
    -ProcessorCount 16 -MemoryGB 64 -OsDiskGB 200 `
    -DataDiskCount 10 -DataDiskGB 1024 `
    -ManagementSwitchName 'External' -WhatIf

# After installing the OS, configure each generated VM separately.
$local = Get-Credential
$domain = Get-Credential
.\Set-TSxPostDeployTSxAzureLocal.ps1 -VMName LAB01 `
    -DomainName 'lab.contoso.com' -OUPath 'OU=AzureLocal,DC=lab,DC=contoso,DC=com' `
    -LocalCredentials $local -DomainJoinCredentials $domain `
    -AdapterName NIC01 -IPAddress '192.168.10.21' -SubnetMask '255.255.255.0' `
    -DefaultGateway '192.168.10.1' -DnsServers '192.168.10.10'

.\Set-TSxAzureArcRegistration.ps1 -VMName LAB01 -Credentials $local `
    -Tenant '<tenant-id>' -Subscription '<subscription-id>' `
    -ResourceGroup 'AzureLocalLab' -Region 'eastus'
```

## Tests

`New-TsxAzureLab.Tests.ps1` uses Pester with mocked host commands. It tests
orchestration without creating real VMs or requiring elevation. Actual Hyper-V
provisioning and Azure Local deployment must still be validated on a lab host.

```powershell
Invoke-Pester .\New-TsxAzureLab.Tests.ps1
```
