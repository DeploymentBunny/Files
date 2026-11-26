$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-TSxVMInfo.ps1'

Describe 'Hyper-V VM inventory' {
    function Get-VM {
        [CmdletBinding()]
        param([string[]]$ComputerName)
    }

    function Get-VMMemory {
        [CmdletBinding()]
        param([object]$VM)
    }

    function Get-VMProcessor {
        [CmdletBinding()]
        param([object]$VM)
    }

    function Get-VMNetworkAdapter {
        [CmdletBinding()]
        param([object]$VM)
    }

    function Get-VMNetworkAdapterVlan {
        [CmdletBinding()]
        param([object]$VMNetworkAdapter)
    }

    function Get-VMHardDiskDrive {
        [CmdletBinding()]
        param([object]$VM)
    }

    function Get-VMSnapshot {
        [CmdletBinding()]
        param([object]$VM)
    }

    function Get-VMReplication {
        [CmdletBinding()]
        param([object]$VM)
    }

    BeforeEach {
        $script:vm = [pscustomobject]@{
            ComputerName = 'HV01'; Name = 'TestVM'; Id = [guid]::NewGuid()
            State = 'Running'; Status = 'Operating normally'; Generation = 2
            Heartbeat = 'OkApplicationsHealthy'; IntegrationServicesState = 'Up to date'
            IsClustered = $false; MemoryStatus = 'OK'
            Version = '12.0'; Uptime = [timespan]::FromHours(2)
            CreationTime = [datetime]'2026-01-01'; CPUUsage = 5
            MemoryAssigned = 4GB; MemoryDemand = 3GB
            CheckpointType = 'Production'; Path = 'D:\VMs\TestVM'
            ConfigurationLocation = 'D:\VMs\TestVM'
            SnapshotFileLocation = 'E:\Checkpoints'; SmartPagingFilePath = 'D:\Paging'
            AutomaticStartAction = 'StartIfRunning'; AutomaticStartDelay = 30
            AutomaticStopAction = 'Save'; ReplicationMode = 'None'; ReplicationState = 'Disabled'
            ReplicationHealth = 'NotApplicable'; Notes = "Test, with`nmultiline notes"
        }
        $script:adapters = @(
            [pscustomobject]@{
                Name = 'LAN'; SwitchName = 'External'; MacAddress = '001122334455'
                IPAddresses = @('192.0.2.10', '2001:db8::10'); Status = @('Ok')
            },
            [pscustomobject]@{
                Name = 'Backup'; SwitchName = ''; MacAddress = '001122334466'
                IPAddresses = @(); Status = @('Disconnected')
            }
        )
        $script:disks = @([pscustomobject]@{
            Path = 'D:\Disks\TestVM.vhdx'; ControllerType = 'SCSI'
            ControllerNumber = 0; ControllerLocation = 1
        })
        $script:checkpoints = @([pscustomobject]@{ Name = 'Before update' })
        Mock Import-Module {} -ParameterFilter { $Name -eq 'Hyper-V' }
        Mock Get-VM { $script:vm }
        Mock Get-VMMemory {
            [pscustomobject]@{
                DynamicMemoryEnabled = $true; Startup = 2GB; Minimum = 1GB
                Maximum = 8GB; Buffer = 20; Priority = 50
            }
        }
        Mock Get-VMProcessor {
            [pscustomobject]@{ Count = 4; CompatibilityForMigrationEnabled = $true }
        }
        Mock Get-VMNetworkAdapter { $script:adapters }
        Mock Get-VMNetworkAdapterVlan {
            [pscustomobject]@{ OperationMode = 'Access'; AccessVlanId = 42 }
        }
        Mock Get-VMHardDiskDrive { $script:disks }
        Mock Get-VMSnapshot { $script:checkpoints }
        $script:relationships = @([pscustomobject]@{
            ReplicationRelationshipType = 'Simple'; ReplicationMode = 'Primary'
            ReplicationState = 'Replicating'; ReplicationHealth = 'Normal'
            PrimaryServerName = 'HV01'; ReplicaServerName = 'HV02'
            CurrentReplicaServerName = 'HV02'; ReplicaServerPort = 80
            AuthenticationType = 'Kerberos'; ReplicationFrequencySec = 300
            LastReplicationTime = [datetime]'2026-10-16T10:00:00'
            LastAppliedLogTime = $null; RecoveryHistory = 24
            VSSSnapshotFrequencyHour = 4; CompressionEnabled = $true
            AutoResynchronizeEnabled = $true; ReplicatedDisks = $script:disks
            ExcludedDisks = @()
        })
        Mock Get-VMReplication { $script:relationships }
        $script:hostWrites = @()
        Mock Write-Host {
            $script:hostWrites += [pscustomobject]@{
                Text = $Object -join ' '
                Color = $ForegroundColor
            }
        }
        Mock Write-Warning {}
    }

    It 'returns full inventory objects with numeric sizes and CSV-safe collections' {
        $result = @(. $scriptPath -PassThru)
        $result.Count | Should Be 1
        $result[0].CPUCount | Should Be 4
        $result[0].Heartbeat | Should Be 'OkApplicationsHealthy'
        $result[0].MemoryStatus | Should Be 'OK'
        $result[0].MemoryAssignedGB | Should Be 4
        $result[0].MemoryStartupGB | Should Be 2
        $result[0].MemoryMinimumGB | Should Be 1
        $result[0].MemoryMaximumGB | Should Be 8
        $result[0].NetworkAdapterCount | Should Be 2
        $result[0].IPAddresses | Should Be '192.0.2.10; 2001:db8::10'
        $result[0].MacAddresses | Should Be '001122334455; 001122334466'
        $result[0].NetworkAdapters | Should Match 'LAN \[Switch=External; MAC=001122334455; IP=192.0.2.10, 2001:db8::10; Status=Ok; VLAN=Access:42\]'
        $result[0].NetworkAdapters | Should Match 'Backup \[Switch=;'
        $result[0].DiskAttachments | Should Be 'SCSI 0:1=D:\Disks\TestVM.vhdx'
        $result[0].CheckpointCount | Should Be 1
        $result[0].ConfigurationLocation | Should Be 'D:\VMs\TestVM'
        $result[0].AutomaticStartDelaySeconds | Should Be 30
        Assert-MockCalled Get-VM -Times 1 -Exactly -Scope It -ParameterFilter { $ComputerName -eq '.' }
    }

    It 'displays a summary without emitting formatting objects by default' {
        $result = @(. $scriptPath)
        $result.Count | Should Be 0
        ($script:hostWrites.Text -join "`n") | Should Match 'TestVM'
    }

    It 'includes MAC addresses but hides replication columns in the default summary' {
        . $scriptPath
        $text = $script:hostWrites.Text -join "`n"
        $text | Should Match 'MacAddresses'
        $text | Should Not Match 'ReplicationMode'
        $text | Should Not Match 'ReplicationState'
        $text | Should Not Match 'ReplicationHealth'
    }

    It 'shows replication columns with ReplicaInfo' {
        . $scriptPath -ReplicaInfo
        $text = $script:hostWrites.Text -join "`n"
        $text | Should Match 'ReplicationMode'
        $text | Should Match 'ReplicationState'
        $text | Should Match 'ReplicationHealth'
    }

    It 'preserves replication roles and health in objects and CSV' {
        foreach ($case in @(
            @{ Mode = 'None'; State = 'Disabled'; Health = 'NotApplicable' },
            @{ Mode = 'Primary'; State = 'Replicating'; Health = 'Normal' },
            @{ Mode = 'Replica'; State = 'Replicating'; Health = 'Warning' },
            @{ Mode = 'ExtendedReplica'; State = 'Suspended'; Health = 'Critical' },
            @{ Mode = 'TestReplica'; State = 'Disabled'; Health = 'NotApplicable' }
        )) {
            $script:vm.ReplicationMode = $case.Mode
            $script:vm.ReplicationState = $case.State
            $script:vm.ReplicationHealth = $case.Health
            $path = Join-Path $TestDrive "$($case.Mode).csv"
            $result = . $scriptPath -PassThru -CsvPath $path
            $result.ReplicationMode | Should Be $case.Mode
            $result.ReplicationState | Should Be $case.State
            $result.ReplicationHealth | Should Be $case.Health
            $row = Import-Csv -LiteralPath $path
            $row.ReplicationMode | Should Be $case.Mode
            $row.ReplicationState | Should Be $case.State
            $row.ReplicationHealth | Should Be $case.Health
        }
    }

    It 'does not query detailed replication or show location sections by default' {
        $script:vm.ReplicationMode = 'Replica'
        . $scriptPath
        $text = $script:hostWrites.Text -join "`n"
        $text | Should Match 'TestVM'
        $text | Should Not Match 'ReplicationHealth'
        $text | Should Not Match 'Replication details:'
        $text | Should Not Match 'Locations:'
        Assert-MockCalled Get-VMReplication -Times 0 -Exactly -Scope It
    }

    It 'filters only powered-off secondary roles across hosts in display objects and CSV' {
        Mock Get-VM {
            foreach ($mode in @('None', 'Primary', 'Replica', 'ExtendedReplica', 'TestReplica')) {
                foreach ($state in @('Off', 'Running', 'Saved', 'Paused')) {
                    $item = $script:vm.PSObject.Copy()
                    $item.Name = "$mode-$state"
                    $item.ReplicationMode = $mode
                    $item.State = $state
                    $item.ComputerName = $ComputerName[0]
                    $item.Id = [guid]::NewGuid()
                    $item
                }
            }
        }
        $path = Join-Path $TestDrive 'filtered-replicas.csv'
        $result = @(. $scriptPath -Computer HV02,HV01 -PassThru -CsvPath $path)
        $result.Count | Should Be 34
        $rows = @(Import-Csv -LiteralPath $path)
        $rows.Count | Should Be 34
        @($result | Where-Object Name -eq 'Primary-Off').Count | Should Be 2
        @($result | Where-Object Name -eq 'None-Off').Count | Should Be 2
        @($result | Where-Object Name -eq 'Replica-Running').Count | Should Be 2
        @($result | Where-Object Name -eq 'Replica-Saved').Count | Should Be 2
        @($result | Where-Object Name -eq 'Replica-Paused').Count | Should Be 2
        foreach ($mode in @('Replica', 'ExtendedReplica', 'TestReplica')) {
            @($result | Where-Object Name -eq "$mode-Off").Count | Should Be 0
            @($rows | Where-Object Name -eq "$mode-Off").Count | Should Be 0
        }
        . $scriptPath -Computer HV01,HV02
        $text = $script:hostWrites.Text -join "`n"
        $text | Should Match 'Primary-Off'
        $text | Should Not Match 'Replica-Off'
        $text | Should Not Match 'ReplicationMode'
        Assert-MockCalled Get-VMMemory -Times 0 -Exactly -Scope It -ParameterFilter {
            $VM.State -eq 'Off' -and $VM.ReplicationMode -in @('Replica', 'ExtendedReplica', 'TestReplica')
        }
    }

    It 'restores powered-off secondary replicas in all outputs with ReplicaInfo' {
        Mock Get-VM {
            foreach ($mode in @('Replica', 'ExtendedReplica', 'TestReplica')) {
                $item = $script:vm.PSObject.Copy()
                $item.Name = "$mode-Off"
                $item.ReplicationMode = $mode
                $item.State = 'Off'
                $item.Id = [guid]::NewGuid()
                $item
            }
        }
        $path = Join-Path $TestDrive 'included-replicas.csv'
        $result = @(. $scriptPath -ReplicaInfo -PassThru -CsvPath $path)
        $result.Count | Should Be 3
        @(Import-Csv -LiteralPath $path).Count | Should Be 3
        . $scriptPath -ReplicaInfo
        $text = $script:hostWrites.Text -join "`n"
        $text | Should Match 'Replica-Off'
        $text | Should Match 'ExtendedReplica-Off'
        $text | Should Match 'TestReplica-Off'
        $text | Should Match 'ReplicationMode'
    }

    It 'warns and skips export when all VMs are hidden powered-off replicas' {
        $script:vm.State = 'Off'
        $script:vm.ReplicationMode = 'Replica'
        $path = Join-Path $TestDrive 'hidden-replicas.csv'
        $result = @(. $scriptPath -Name TestVM -LocationInfo -PassThru -CsvPath $path)
        $result.Count | Should Be 0
        Test-Path -LiteralPath $path | Should Be $false
        Assert-MockCalled Write-Warning -Times 1 -Exactly -Scope It
        Assert-MockCalled Get-VMMemory -Times 0 -Exactly -Scope It
    }

    It 'queries replica details only when requested and exports them without formatting objects' {
        $script:vm.ReplicationMode = 'Primary'
        $path = Join-Path $TestDrive 'replica-details.csv'
        $result = @(. $scriptPath -ReplicaInfo -PassThru -CsvPath $path)
        $result.Count | Should Be 1
        $result[0].ReplicationDetails | Should Match 'PrimaryServer: HV01'
        $result[0].ReplicationDetails | Should Match 'ReplicaServer: HV02'
        $result[0].ReplicationDetails | Should Match 'FrequencySeconds: 300'
        $result[0].ReplicationDetails | Should Match 'LastReplicationTime: 2026-10-16T10:00:00'
        $result[0].ReplicationDetails | Should Match 'ReplicatedDisks: D:\\Disks\\TestVM.vhdx'
        (Import-Csv -LiteralPath $path).ReplicationDetails | Should Be $result[0].ReplicationDetails
        Assert-MockCalled Get-VMReplication -Times 1 -Exactly -Scope It
        $script:hostWrites.Count | Should Be 0
    }

    It 'shows multiple relationships separately for a secondary with extended replication' {
        $script:vm.ReplicationMode = 'Replica'
        $script:relationships[0].ReplicationMode = 'Replica'
        $extended = $script:relationships[0].PSObject.Copy()
        $extended.ReplicationRelationshipType = 'Extended'
        $extended.PrimaryServerName = 'HV02'
        $extended.ReplicaServerName = 'HV03'
        $script:relationships += $extended
        . $scriptPath -ReplicaInfo
        $text = $script:hostWrites.Text -join "`n"
        $text | Should Match 'Relationship: Simple'
        $text | Should Match 'Relationship: Extended'
        $text | Should Match 'ReplicaServer: HV03'
    }

    It 'describes nonreplicated and test VMs without querying nonexistent relationships' {
        . $scriptPath -ReplicaInfo
        ($script:hostWrites.Text -join "`n") | Should Match 'Replication is not configured.'
        $script:vm.ReplicationMode = 'TestReplica'
        . $scriptPath -ReplicaInfo
        ($script:hostWrites.Text -join "`n") | Should Match 'Test replica VM; no active replication relationship.'
        Assert-MockCalled Get-VMReplication -Times 0 -Exactly -Scope It
    }

    It 'fails explicitly on missing relationships or query errors before export' {
        $script:vm.ReplicationMode = 'Primary'
        $script:relationships = @()
        $path = Join-Path $TestDrive 'replica-failure.csv'
        { . $scriptPath -ReplicaInfo -CsvPath $path } | Should Throw
        Test-Path -LiteralPath $path | Should Be $false
        Mock Get-VMReplication { throw 'Replication access denied' }
        { . $scriptPath -ReplicaInfo -CsvPath $path } | Should Throw
        Test-Path -LiteralPath $path | Should Be $false
    }

    It 'shows all configured locations and deduplicated disk folders with both switches' {
        $script:disks += [pscustomobject]@{
            Path = 'D:\Disks\Second.vhdx'; ControllerType = 'SCSI'
            ControllerNumber = 0; ControllerLocation = 2
        }
        $script:disks += [pscustomobject]@{
            Path = '\\Storage\VMs\Third.vhdx'; ControllerType = 'SCSI'
            ControllerNumber = 0; ControllerLocation = 3
        }
        . $scriptPath -LocationInfo -ReplicaInfo
        $text = $script:hostWrites.Text -join "`n"
        $text | Should Match 'Replication details:'
        $text | Should Match 'Locations:'
        $text | Should Match 'Path: D:\\VMs\\TestVM'
        $text | Should Match 'ConfigurationLocation: D:\\VMs\\TestVM'
        $text | Should Match 'SnapshotFileLocation: E:\\Checkpoints'
        $text | Should Match 'SmartPagingFilePath: D:\\Paging'
        $text | Should Match 'DiskFolders: \\\\Storage\\VMs; D:\\Disks'
        $text | Should Match 'DiskPaths: D:\\Disks\\TestVM.vhdx; D:\\Disks\\Second.vhdx; \\\\Storage\\VMs\\Third.vhdx'
    }

    It 'includes disk folders in objects and handles empty attachment paths' {
        $script:disks[0].Path = $null
        $result = . $scriptPath -LocationInfo -PassThru
        $result.DiskFolders | Should Be ''
        $script:hostWrites.Count | Should Be 0
    }

    It 'queries unique hosts and matches overlapping name patterns only once' {
        $result = @(. $scriptPath -ComputerName HV01,HV02,HV01 -Name 'Test*','*VM' -PassThru)
        $result.Count | Should Be 2
        Assert-MockCalled Get-VM -Times 2 -Exactly -Scope It
        Assert-MockCalled Get-VM -Times 1 -Exactly -Scope It -ParameterFilter { $ComputerName -eq 'HV02' }
    }

    It 'warns when no VM matches and does not create an empty export' {
        $path = Join-Path $TestDrive 'empty.csv'
        $result = @(. $scriptPath -Name 'Missing*' -CsvPath $path -PassThru)
        $result.Count | Should Be 0
        Test-Path -LiteralPath $path | Should Be $false
        Assert-MockCalled Write-Warning -Times 1 -Exactly -Scope It
        Assert-MockCalled Get-VMMemory -Times 0 -Exactly -Scope It
    }

    It 'accepts Computer and globally sorts returned objects and CSV by VM name then host' {
        Mock Get-VM {
            foreach ($vmName in $(if ($ComputerName -eq 'HV02') { 'Zulu', 'Shared' } else { 'Shared', 'Alpha' })) {
                $item = $script:vm.PSObject.Copy()
                $item.Name = $vmName
                $item.ComputerName = $ComputerName[0]
                $item
            }
        }
        $path = Join-Path $TestDrive 'sorted.csv'
        $result = @(. $scriptPath -Computer HV02,HV01 -CsvPath $path -PassThru)
        ($result.Name -join ',') | Should Be 'Alpha,Shared,Shared,Zulu'
        ($result.ComputerName -join ',') | Should Be 'HV01,HV01,HV02,HV02'
        $rows = @(Import-Csv -LiteralPath $path)
        ($rows.Name -join ',') | Should Be 'Alpha,Shared,Shared,Zulu'
        ($rows.ComputerName -join ',') | Should Be 'HV01,HV01,HV02,HV02'
        Assert-MockCalled Get-VM -Times 2 -Exactly -Scope It
    }

    It 'displays a single combined summary sorted across hosts by VM name' {
        Mock Get-VM {
            $item = $script:vm.PSObject.Copy()
            $item.Name = if ($ComputerName -eq 'HV01') { 'Zulu' } else { 'Alpha' }
            $item.ComputerName = $ComputerName[0]
            $item
        }
        . $scriptPath -Computer HV01,HV02
        $text = $script:hostWrites.Text -join "`n"
        $text.IndexOf('Alpha') | Should BeLessThan $text.IndexOf('Zulu')
    }

    It 'finds duplicate IP and MAC addresses across hosts and exports plain conflict fields' {
        Mock Get-VM {
            $item = $script:vm.PSObject.Copy()
            $item.ComputerName = $ComputerName[0]
            $item
        }
        $path = Join-Path $TestDrive 'duplicates.csv'
        $result = @(. $scriptPath -Computer HV01,HV02 -CsvPath $path -PassThru)
        foreach ($item in $result) {
            $item.DuplicateIPAddresses | Should Be '192.0.2.10; 2001:db8::10'
            $item.DuplicateMacAddresses | Should Be '001122334455; 001122334466'
        }
        foreach ($row in (Import-Csv -LiteralPath $path)) {
            $row.DuplicateIPAddresses | Should Be '192.0.2.10; 2001:db8::10'
            $row.DuplicateMacAddresses | Should Be '001122334455; 001122334466'
            $row.DuplicateIPAddresses | Should Not Match ([string][char]27)
        }
    }

    It 'excludes secondary roles from both detecting and highlighting duplicates' {
        Mock Get-VM {
            $item = $script:vm.PSObject.Copy()
            $item.ComputerName = $ComputerName[0]
            $item.ReplicationMode = if ($ComputerName -eq 'HV01') { 'Primary' } else { $script:secondaryMode }
            $item
        }
        foreach ($script:secondaryMode in @('Replica', 'ExtendedReplica', 'TestReplica')) {
            $result = @(. $scriptPath -Computer HV01,HV02 -PassThru)
            foreach ($item in $result) {
                $item.DuplicateIPAddresses | Should Be ''
                $item.DuplicateMacAddresses | Should Be ''
            }
            . $scriptPath -Computer HV01,HV02
        }
        @($script:hostWrites | Where-Object Color -eq Yellow).Count | Should Be 0
    }

    It 'highlights only matching address values on primary and ordinary VMs not replicas' {
        Mock Get-VM {
            foreach ($mode in @('Primary', 'None', 'Replica')) {
                $item = $script:vm.PSObject.Copy()
                $item.Name = $mode
                $item.Id = [guid]::NewGuid()
                $item.ReplicationMode = $mode
                $item
            }
        }
        Mock Get-VMNetworkAdapter {
            [pscustomobject]@{
                Name = 'LAN'; SwitchName = 'External'; MacAddress = '001122334455'
                IPAddresses = @('192.0.2.10', $(if ($VM.Name -eq 'None') { '192.0.2.11' } else { '192.0.2.12' }))
                Status = @('Ok')
            }
        }
        . $scriptPath
        $colored = @($script:hostWrites | Where-Object Color -eq Yellow)
        $colored.Count | Should Be 4
        @($colored | Where-Object Text -eq '192.0.2.10').Count | Should Be 2
        @($colored | Where-Object Text -eq '001122334455').Count | Should Be 2
    }

    It 'normalizes IPv6 and MAC spellings and keeps independent VM identities' {
        Mock Get-VM {
            foreach ($label in @('First', 'Second')) {
                $item = $script:vm.PSObject.Copy()
                $item.Name = $label
                $item.Id = [guid]::NewGuid()
                $item
            }
        }
        Mock Get-VMNetworkAdapter {
            [pscustomobject]@{
                Name = 'LAN'; SwitchName = 'External'; Status = @('Ok')
                MacAddress = if ($VM.Name -eq 'First') { '00:AA:BB:CC:DD:EE' } else { '00-aa-bb-cc-dd-ee' }
                IPAddresses = @(if ($VM.Name -eq 'First') { '2001:db8::1' } else { '2001:0db8:0:0:0:0:0:1' })
            }
        }
        $result = @(. $scriptPath -PassThru)
        $result[0].DuplicateIPAddresses | Should Be '2001:db8::1'
        $result[1].DuplicateIPAddresses | Should Be '2001:0db8:0:0:0:0:0:1'
        $result[0].DuplicateMacAddresses | Should Be '00:AA:BB:CC:DD:EE'
        $result[1].DuplicateMacAddresses | Should Be '00-aa-bb-cc-dd-ee'
    }

    It 'does not count repeated addresses within one VM or repeated reports of that VM' {
        $script:adapters += $script:adapters[0]
        $result = @(. $scriptPath -Computer HV01,HV02 -PassThru)
        foreach ($item in $result) {
            $item.DuplicateIPAddresses | Should Be ''
            $item.DuplicateMacAddresses | Should Be ''
        }
    }

    It 'ignores empty and unspecified addresses even across distinct VMs' {
        Mock Get-VM {
            $item = $script:vm.PSObject.Copy()
            $item.ComputerName = $ComputerName[0]
            $item
        }
        $script:adapters[0].IPAddresses = @('', '0.0.0.0', '::')
        $script:adapters[0].MacAddress = '000000000000'
        $script:adapters[1].MacAddress = ''
        $result = @(. $scriptPath -Computer HV01,HV02 -PassThru)
        foreach ($item in $result) {
            $item.DuplicateIPAddresses | Should Be ''
            $item.DuplicateMacAddresses | Should Be ''
        }
    }

    It 'handles an off VM with no adapters disks or checkpoints' {
        $script:vm.State = 'Off'
        $script:vm.MemoryAssigned = 0
        $script:vm.MemoryDemand = 0
        $script:adapters = @()
        $script:disks = @()
        $script:checkpoints = @()
        $result = . $scriptPath -PassThru
        $result.State | Should Be 'Off'
        $result.MemoryAssignedGB | Should Be 0
        $result.NetworkAdapterCount | Should Be 0
        $result.NetworkAdapters | Should Be ''
        $result.SwitchNames | Should Be ''
        $result.DiskCount | Should Be 0
        $result.CheckpointCount | Should Be 0
    }

    It 'preserves trunk VLAN ranges instead of exporting collection type names' {
        Mock Get-VMNetworkAdapterVlan {
            [pscustomobject]@{
                OperationMode = 'Trunk'; NativeVlanId = 10
                AllowedVlanIdListString = '10,20-30'
            }
        }
        $result = . $scriptPath -PassThru
        $result.NetworkAdapters | Should Match 'VLAN=Trunk:Native=10,Allowed=10,20-30'
    }

    It 'reports isolated and promiscuous private VLAN modes' {
        Mock Get-VMNetworkAdapterVlan {
            if ($VMNetworkAdapter.Name -eq 'LAN') {
                [pscustomobject]@{
                    OperationMode = 'Private'; PrivateVlanMode = 'Isolated'
                    PrimaryVlanId = 100; SecondaryVlanId = 101
                }
            }
            else {
                [pscustomobject]@{
                    OperationMode = 'Private'; PrivateVlanMode = 'Promiscuous'
                    PrimaryVlanId = 100; SecondaryVlanIdListString = '101-110'
                }
            }
        }
        $result = . $scriptPath -PassThru
        $result.NetworkAdapters | Should Match 'VLAN=Isolated:Primary=100,Secondary=101'
        $result.NetworkAdapters | Should Match 'VLAN=Promiscuous:Primary=100,Secondary=101-110'
    }

    It 'exports full objects with the export switch and default path' {
        Push-Location $TestDrive
        try {
            . $scriptPath -ExportCsv
            $rows = @(Import-Csv -LiteralPath '.\VMInfo.csv')
            $rows.Count | Should Be 1
            $rows[0].Name | Should Be 'TestVM'
            $rows[0].NetworkAdapters | Should Not Match 'System.Object'
            $rows[0].Notes | Should Be $script:vm.Notes
            $rows[0].DiskPaths | Should Be 'D:\Disks\TestVM.vhdx'
        }
        finally { Pop-Location }
    }

    It 'exports when only CsvPath is supplied and can also return objects' {
        $path = Join-Path $TestDrive 'explicit.csv'
        $result = @(. $scriptPath -CsvPath $path -PassThru)
        $result.Count | Should Be 1
        (Import-Csv -LiteralPath $path).VMId | Should Be ([string]$script:vm.Id)
    }

    It 'does not overwrite existing files or hide export errors' {
        $path = Join-Path $TestDrive 'existing.csv'
        Set-Content -LiteralPath $path -Value 'Keep this'
        { . $scriptPath -CsvPath $path } | Should Throw
        (Get-Content -LiteralPath $path) | Should Be 'Keep this'
        { . $scriptPath -CsvPath (Join-Path $TestDrive 'missing\inventory.csv') } | Should Throw
    }

    It 'stops on host errors without exporting a partial report' {
        $path = Join-Path $TestDrive 'host-failure.csv'
        Mock Get-VM { throw 'Access denied' } -ParameterFilter { $ComputerName -eq 'HV02' }
        { . $scriptPath -ComputerName HV01,HV02 -CsvPath $path } | Should Throw
        Test-Path -LiteralPath $path | Should Be $false
    }

    It 'stops on detail errors without exporting a partial report' {
        $path = Join-Path $TestDrive 'detail-failure.csv'
        Mock Get-VMNetworkAdapterVlan { throw 'VLAN query failed' }
        { . $scriptPath -CsvPath $path } | Should Throw
        Test-Path -LiteralPath $path | Should Be $false
    }

    It 'emits collection details on the verbose stream' {
        $messages = @(. $scriptPath -PassThru -Verbose 4>&1)
        @($messages | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] }).Count | Should BeGreaterThan 2
        @($messages | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] }).Count | Should Be 1
    }
}
