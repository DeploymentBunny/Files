$builderPath = Join-Path $PSScriptRoot 'New-TsxAzureLab.ps1'
# Remove only runtime requirements in memory; host commands are all mocked.
$builder = [scriptblock]::Create(((Get-Content -LiteralPath $builderPath -Raw) -replace '(?m)^#Requires.*$', ''))

Describe 'Azure Local lab builder' {
    # Untyped host-command stubs keep these orchestration tests independent of Hyper-V.
    function Get-WindowsOptionalFeature { [CmdletBinding()] param([switch]$Online, $FeatureName) }
    function Get-VM { [CmdletBinding()] param($Name) }
    function Get-VMSwitch { [CmdletBinding()] param($Name) }
    function New-VMSwitch { [CmdletBinding()] param($Name, $SwitchType) }
    function Get-HgsGuardian { [CmdletBinding()] param($Name) }
    function New-HgsGuardian { [CmdletBinding()] param($Name, [switch]$GenerateCertificates) }
    function New-HgsKeyProtector { [CmdletBinding()] param($Owner, [switch]$AllowUntrustedRoot) }
    function New-VHD { [CmdletBinding()] param($Path, [switch]$Dynamic, $SizeBytes) }
    function New-VM { [CmdletBinding()] param($Name, $Generation, $Path, $VHDPath, $MemoryStartupBytes) }
    function Set-VM { [CmdletBinding()] param($Name, $CheckpointType, $AutomaticStartAction, $AutomaticStopAction) }
    function Set-VMMemory { [CmdletBinding()] param($VMName, $DynamicMemoryEnabled) }
    function Set-VMProcessor { [CmdletBinding()] param($VMName, $Count, $ExposeVirtualizationExtensions) }
    function Set-VMFirmware { [CmdletBinding()] param($VMName, $EnableSecureBoot, $SecureBootTemplate, $FirstBootDevice) }
    function Set-VMKeyProtector { [CmdletBinding()] param($VMName, $KeyProtector) }
    function Enable-VMTPM { [CmdletBinding()] param($VMName) }
    function Disable-VMIntegrationService { [CmdletBinding()] param($VMName, $Name) }
    function Get-VMNetworkAdapter { [CmdletBinding()] param($VMName) }
    function Remove-VMNetworkAdapter { [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)]$InputObject) }
    function Add-VMNetworkAdapter { [CmdletBinding()] param($VMName, $Name, $SwitchName, $DeviceNaming) }
    function Set-VMNetworkAdapter { [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)]$InputObject, $MacAddressSpoofing, $AllowTeaming) }
    function Set-VMNetworkAdapterVlan { [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)]$InputObject, [switch]$Trunk, $NativeVlanId, $AllowedVlanIdList) }
    function Add-VMDvdDrive { [CmdletBinding()] param($VMName, $Path) }
    function Get-VMDvdDrive { [CmdletBinding()] param($VMName) }
    function Add-VMHardDiskDrive { [CmdletBinding()] param($VMName, $ControllerType, $Path) }
    function Get-VMHardDiskDrive { [CmdletBinding()] param($VMName) }

    BeforeEach {
        $script:isoExists = $true
        $script:testIsoPath = 'D:\ISO\AzureLocal.iso'
        $script:testManagementSwitch = 'AzureLocal-Mgmt'
        $script:managementSwitchExists = $true
        $script:existingVmNames = @()
        $script:existingNodePath = $null
        Mock Get-WindowsOptionalFeature { [pscustomobject]@{ State = 'Enabled' } }
        Mock Test-Path {
            if ($LiteralPath -eq $script:testIsoPath) { return $script:isoExists }
            return $null -ne $script:existingNodePath -and $LiteralPath -eq $script:existingNodePath
        }
        Mock Get-VM { $script:existingVmNames | ForEach-Object { [pscustomobject]@{ Name = $_ } } }
        Mock Get-VMSwitch {
            if ($Name -eq $script:testManagementSwitch -and $script:managementSwitchExists) {
                [pscustomobject]@{ Name = $Name }
            }
        }
        Mock Get-HgsGuardian {}
        Mock New-HgsGuardian { [pscustomobject]@{ Name = 'guardian' } }
        Mock New-HgsKeyProtector { [pscustomobject]@{ RawData = [byte[]]@(1, 2) } }
        Mock New-Item {}
        Mock Add-Content {}
        Mock New-VMSwitch {}
        Mock New-VHD {}
        Mock New-VM {}
        Mock Set-VM {}
        Mock Set-VMMemory {}
        Mock Set-VMProcessor {}
        Mock Set-VMFirmware {}
        Mock Set-VMKeyProtector {}
        Mock Enable-VMTPM {}
        Mock Disable-VMIntegrationService {}
        Mock Get-VMNetworkAdapter { [pscustomobject]@{ Name = 'NIC01' } }
        Mock Remove-VMNetworkAdapter {}
        Mock Add-VMNetworkAdapter {}
        Mock Set-VMNetworkAdapter {}
        Mock Set-VMNetworkAdapterVlan {}
        Mock Add-VMDvdDrive {}
        Mock Get-VMDvdDrive { [pscustomobject]@{ Name = 'DVD' } }
        Mock Add-VMHardDiskDrive {}
        Mock Get-VMHardDiskDrive {}
        Mock Write-Host {}
    }

    It 'preserves the default three-node hardware configuration' {
        & $builder -Confirm:$false | Out-Null
        Assert-MockCalled New-VM -Times 3 -Exactly -Scope It
        foreach ($expectedName in @('AZL-NODE01', 'AZL-NODE02', 'AZL-NODE03')) {
            Assert-MockCalled New-VM -Times 1 -Exactly -Scope It -ParameterFilter {
                $Name -eq $expectedName -and $Generation -eq 2 -and $MemoryStartupBytes -eq 32GB
            }
        }
        Assert-MockCalled New-VHD -Times 3 -Exactly -Scope It -ParameterFilter { $Path -like '*-OS.vhdx' -and $SizeBytes -eq 200GB -and $Dynamic }
        Assert-MockCalled New-VHD -Times 18 -Exactly -Scope It -ParameterFilter { $Path -like '*-DATA-*.vhdx' -and $SizeBytes -eq 500GB -and $Dynamic }
        Assert-MockCalled Set-VMProcessor -Times 3 -Exactly -Scope It -ParameterFilter { $Count -eq 8 -and $ExposeVirtualizationExtensions }
        Assert-MockCalled Add-VMNetworkAdapter -Times 12 -Exactly -Scope It
        Assert-MockCalled Enable-VMTPM -Times 3 -Exactly -Scope It
        Assert-MockCalled Set-VMMemory -Times 3 -Exactly -Scope It -ParameterFilter { -not $DynamicMemoryEnabled }
        Assert-MockCalled Set-VMFirmware -Times 3 -Exactly -Scope It -ParameterFilter { $EnableSecureBoot -eq 'On' }
        Assert-MockCalled Set-VMNetworkAdapter -Times 3 -Exactly -Scope It -ParameterFilter { $MacAddressSpoofing -eq 'On' -and $AllowTeaming -eq 'On' }
    }

    It 'creates a single node with two 1 TB data disks and no trunk configuration' {
        & $builder -ServerName LAB -NodeCount 1 -ProcessorCount 4 -DataDiskCount 2 -DataDiskGB 1024 -Confirm:$false | Out-Null
        Assert-MockCalled New-VM -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'LAB01' }
        Assert-MockCalled New-VHD -Times 3 -Exactly -Scope It
        Assert-MockCalled Add-VMHardDiskDrive -Times 2 -Exactly -Scope It
        Assert-MockCalled New-VHD -Times 2 -Exactly -Scope It -ParameterFilter { $SizeBytes -eq 1TB }
        Assert-MockCalled Set-VMNetworkAdapterVlan -Times 0 -Exactly -Scope It
    }

    It 'starts at the requested suffix and uses generated names for VM and disk paths' {
        & $builder -ServerNamePrefix FAHOST -Suffix 41 -NodeCount 3 -Confirm:$false | Out-Null
        Assert-MockCalled New-VM -Times 3 -Exactly -Scope It
        foreach ($expectedName in @('FAHOST41', 'FAHOST42', 'FAHOST43')) {
            Assert-MockCalled New-VM -Times 1 -Exactly -Scope It -ParameterFilter {
                $Name -eq $expectedName -and $Path -eq ('D:\AzureLocalLab\{0}' -f $expectedName) -and
                $VHDPath -eq ('D:\AzureLocalLab\{0}\Virtual Hard Disks\{0}-OS.vhdx' -f $expectedName)
            }
            Assert-MockCalled Add-VMHardDiskDrive -Times 6 -Exactly -Scope It -ParameterFilter {
                $VMName -eq $expectedName -and $Path -like ('*\{0}-DATA-*.vhdx' -f $expectedName)
            }
        }
    }

    It 'continues from 99 to 100 without truncating suffixes' {
        & $builder -ServerNamePrefix FAHOST -StartNumber 99 -NodeCount 3 -Confirm:$false | Out-Null
        foreach ($expectedName in @('FAHOST99', 'FAHOST100', 'FAHOST101')) {
            Assert-MockCalled New-VM -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq $expectedName }
        }
    }

    It 'pads small suffixes to two digits' {
        & $builder -ServerNamePrefix LAB -StartNumber 0 -NodeCount 2 -Confirm:$false | Out-Null
        foreach ($expectedName in @('LAB00', 'LAB01')) {
            Assert-MockCalled New-VM -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq $expectedName }
        }
    }

    It 'rejects the whole range when a later name exceeds 15 characters' {
        { & $builder -ServerNamePrefix ABCDEFGHIJKLM -StartNumber 99 -NodeCount 2 -Confirm:$false } |
            Should Throw '15-character'
        Assert-MockCalled New-Item -Times 0 -Exactly -Scope It
        Assert-MockCalled New-VM -Times 0 -Exactly -Scope It
    }

    It 'checks for existing VMs using the requested starting suffix' {
        $script:existingVmNames = @('FAHOST42')
        { & $builder -ServerNamePrefix FAHOST -StartNumber 41 -NodeCount 3 -Confirm:$false } |
            Should Throw 'FAHOST42'
        Assert-MockCalled New-VM -Times 0 -Exactly -Scope It
    }

    It 'creates all 16 nodes with ten 1 TB disks and custom resources and NICs' {
        & $builder -ServerNamePrefix HCI -NodeCount 16 -ProcessorCount 16 -MemoryGB 64 `
            -OsDiskGB 400 -DataDiskCount 10 -DataDiskGB 1024 -ManagementNicCount 3 `
            -StorageNicCount 1 -NativeVlanId 10 -AllowedVlanIdList '10-200' -Confirm:$false | Out-Null
        Assert-MockCalled New-VM -Times 16 -Exactly -Scope It -ParameterFilter { $MemoryStartupBytes -eq 64GB }
        foreach ($number in 1..16) {
            $expectedName = 'HCI{0:D2}' -f $number
            Assert-MockCalled New-VM -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq $expectedName }
        }
        Assert-MockCalled New-VHD -Times 176 -Exactly -Scope It
        Assert-MockCalled New-VHD -Times 16 -Exactly -Scope It -ParameterFilter { $Path -like '*-OS.vhdx' -and $SizeBytes -eq 400GB }
        Assert-MockCalled New-VHD -Times 160 -Exactly -Scope It -ParameterFilter { $Path -like '*-DATA-*.vhdx' -and $SizeBytes -eq 1TB }
        Assert-MockCalled Add-VMHardDiskDrive -Times 160 -Exactly -Scope It -ParameterFilter { $ControllerType -eq 'SCSI' }
        Assert-MockCalled Set-VMProcessor -Times 16 -Exactly -Scope It -ParameterFilter { $Count -eq 16 -and $ExposeVirtualizationExtensions }
        Assert-MockCalled Add-VMNetworkAdapter -Times 48 -Exactly -Scope It -ParameterFilter { $SwitchName -eq 'AzureLocal-Mgmt' -and $Name -in @('NIC01', 'NIC02', 'NIC03') }
        Assert-MockCalled Add-VMNetworkAdapter -Times 16 -Exactly -Scope It -ParameterFilter { $SwitchName -eq 'AzureLocal-Storage' -and $Name -eq 'NIC04' }
        Assert-MockCalled Set-VMNetworkAdapterVlan -Times 16 -Exactly -Scope It -ParameterFilter { $Trunk -and $NativeVlanId -eq 10 -and $AllowedVlanIdList -eq '10-200' }
    }

    It 'previews without creating any lab resources or logs' {
        & $builder -NodeCount 16 -DataDiskCount 10 -WhatIf | Out-Null
        foreach ($command in @('New-Item', 'Add-Content', 'New-VMSwitch', 'New-HgsGuardian',
                'New-HgsKeyProtector', 'New-VHD', 'New-VM', 'Add-VMNetworkAdapter')) {
            Assert-MockCalled $command -Times 0 -Exactly -Scope It
        }
    }

    It 'shows useful per-node progress without requiring verbose output' {
        & $builder -ServerNamePrefix FAHOST -StartNumber 41 -NodeCount 1 -DataDiskCount 2 -Confirm:$false | Out-Null
        Assert-MockCalled Write-Host -Times 1 -Exactly -Scope It -ParameterFilter { ($Object -join ' ') -eq 'Checking prerequisites...' }
        Assert-MockCalled Write-Host -Times 1 -Exactly -Scope It -ParameterFilter { ($Object -join ' ') -like '*FAHOST41: creating OS disk and VM*' }
        Assert-MockCalled Write-Host -Times 2 -Exactly -Scope It -ParameterFilter { ($Object -join ' ') -like '*FAHOST41: creating data disk*' }
        Assert-MockCalled Write-Host -Times 1 -Exactly -Scope It -ParameterFilter { ($Object -join ' ') -like '*FAHOST41: completed;*' }
    }

    It 'shows every planned node and clearly explains preview-only behavior' {
        & $builder -ServerNamePrefix FAHOST -StartNumber 41 -NodeCount 3 -WhatIf | Out-Null
        foreach ($expectedName in @('FAHOST41', 'FAHOST42', 'FAHOST43')) {
            Assert-MockCalled Write-Host -Times 1 -Exactly -Scope It -ParameterFilter { ($Object -join ' ') -like ('Preview {0}:*' -f $expectedName) }
        }
        Assert-MockCalled Write-Host -Times 1 -Exactly -Scope It -ParameterFilter { ($Object -join ' ') -like '*No resources were created. Remove -WhatIf*' }
        Assert-MockCalled New-VM -Times 0 -Exactly -Scope It
    }

    It 'uses custom paths and switches for an intermediate node and disk count' {
        $script:testIsoPath = 'E:\Images\Custom.iso'
        $script:testManagementSwitch = 'External'
        & $builder -VMNamePrefix TEST -NodeCount 4 -DataDiskCount 5 `
            -VmRoot 'E:\Labs' -IsoPath $script:testIsoPath `
            -ManagementSwitchName External -StorageSwitchName Private `
            -ManagementNicCount 1 -StorageNicCount 1 -Confirm:$false | Out-Null
        Assert-MockCalled New-VM -Times 4 -Exactly -Scope It -ParameterFilter {
            $Path -eq ('E:\Labs\{0}' -f $Name) -and
            $VHDPath -eq ('E:\Labs\{0}\Virtual Hard Disks\{0}-OS.vhdx' -f $Name)
        }
        Assert-MockCalled New-VHD -Times 24 -Exactly -Scope It -ParameterFilter { $Path -like 'E:\Labs\TEST*\Virtual Hard Disks\*.vhdx' }
        Assert-MockCalled Add-VMDvdDrive -Times 4 -Exactly -Scope It -ParameterFilter { $Path -eq 'E:\Images\Custom.iso' }
        Assert-MockCalled New-VMSwitch -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'Private' -and $SwitchType -eq 'Private' }
        Assert-MockCalled Add-VMNetworkAdapter -Times 4 -Exactly -Scope It -ParameterFilter { $Name -eq 'NIC01' -and $SwitchName -eq 'External' }
        Assert-MockCalled Add-VMNetworkAdapter -Times 4 -Exactly -Scope It -ParameterFilter { $Name -eq 'NIC02' -and $SwitchName -eq 'Private' }
    }

    It 'rejects out-of-range hardware and invalid computer-name prefixes' {
        foreach ($invalid in @(
                @{ NodeCount = 0 }, @{ NodeCount = 17 },
                @{ StartNumber = -1 },
                @{ DataDiskCount = 1 }, @{ DataDiskCount = 11 },
                @{ DataDiskGB = 499 }, @{ DataDiskGB = 1025 },
                @{ MemoryGB = 31 }, @{ ProcessorCount = 3 }, @{ OsDiskGB = 126 },
                @{ ManagementNicCount = 0 }, @{ StorageNicCount = 9 },
                @{ ServerNamePrefix = 'TOOLONGPREFIXXX' }, @{ ServerNamePrefix = '123' },
                @{ ServerNamePrefix = 'BAD_NAME' }, @{ ServerNamePrefix = '-LAB' })) {
            { & $builder @invalid -Confirm:$false } | Should Throw
        }
        Assert-MockCalled New-VM -Times 0 -Exactly -Scope It
    }

    It 'accepts a 13-character prefix without exceeding 15-character names' {
        & $builder -ServerNamePrefix ABCDEFGHIJKLM -NodeCount 1 -Confirm:$false | Out-Null
        Assert-MockCalled New-VM -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'ABCDEFGHIJKLM01' }
    }

    It 'rejects existing VMs before any provisioning' {
        $script:existingVmNames = @('AZL-NODE02')
        { & $builder -Confirm:$false } | Should Throw 'already exist'
        Assert-MockCalled New-Item -Times 0 -Exactly -Scope It
        Assert-MockCalled New-VM -Times 0 -Exactly -Scope It
    }

    It 'rejects existing node directories before any provisioning' {
        $script:existingNodePath = 'D:\AzureLocalLab\AZL-NODE01'
        { & $builder -Confirm:$false } | Should Throw 'Target node path already exists'
        Assert-MockCalled New-VHD -Times 0 -Exactly -Scope It
    }

    It 'rejects missing ISO files and management switches' {
        $script:isoExists = $false
        { & $builder -Confirm:$false } | Should Throw 'ISO not found'
        $script:isoExists = $true
        $script:managementSwitchExists = $false
        { & $builder -Confirm:$false } | Should Throw 'does not exist'
        Assert-MockCalled New-VM -Times 0 -Exactly -Scope It
    }

    It 'logs provisioning failures and propagates the original error' {
        Mock New-VHD { throw 'Disk creation failed' }
        { & $builder -NodeCount 1 -Confirm:$false } | Should Throw 'Disk creation failed'
        Assert-MockCalled Add-Content -Times 1 -Exactly -Scope It -ParameterFilter { $Value -like '*[[]ERROR]*Disk creation failed*' }
        Assert-MockCalled New-VM -Times 0 -Exactly -Scope It
    }
}
