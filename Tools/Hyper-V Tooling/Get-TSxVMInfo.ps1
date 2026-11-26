#requires -Version 5.1

<#
.SYNOPSIS
    Displays a read-only inventory of Hyper-V virtual machines.

.DESCRIPTION
    Displays a compact summary and optionally exports one CSV row per VM.
    Results from all hosts are combined and sorted by VM name, with host
    name as the tie-breaker, for display, CSV export and PassThru output.
    Collects status, CPU, memory, network adapters, VLANs, virtual disk paths,
    checkpoints, configuration locations and automatic start/stop settings.
    The summary includes IP and MAC addresses. ReplicationMode, ReplicationState
    and ReplicationHealth are displayed only with -ReplicaInfo.
    Without -ReplicaInfo, powered-off Replica, ExtendedReplica and TestReplica
    VMs are excluded from display, CSV export and PassThru output.
    Running secondary replicas and powered-off primary/nonreplicated VMs remain
    included. Mode None means replication is not configured;
    Primary is the source and Replica is the secondary copy. ExtendedReplica
    and TestReplica retain their Hyper-V role names. Health Normal means
    healthy; Warning and Critical require attention. NotApplicable is not
    a healthy replication result.
    Duplicate IP and MAC values on distinct VMs across the selected hosts
    are highlighted in yellow. Replica, ExtendedReplica and TestReplica
    roles are excluded from both duplicate detection and highlighting.
    DuplicateIPAddresses and DuplicateMacAddresses contain the conflicts
    in CSV and PassThru output (without color codes).
    Comparisons normalize IPv6 notation and MAC separators/case, ignore
    empty and unspecified addresses, and count each VM only once per address.
    These are reported address matches, not proof of a live network conflict;
    VLANs/subnets are not considered and guest-reported IPs may be stale.
    All sizes are in GiB (PowerShell's 1GB). Disk paths describe attachments,
    not guest free space or virtual disk capacity. IP addresses are reported
    by Hyper-V integration services and may be empty or stale.

    Requires the Hyper-V PowerShell module and permission to query each host.
    Remote hosts use the Hyper-V cmdlets' ComputerName connection mechanism.
    A failed query terminates collection before displaying or exporting a
    partial inventory. No VM configuration is changed.

.PARAMETER ComputerName
    Hyper-V hosts to query. Accepts -Computer as an alias and multiple
    server names in one invocation. Defaults to the local computer.

.PARAMETER Name
    VM name patterns to include, matched on each host. Defaults to all names.
    Powered-off secondary replicas require -ReplicaInfo to be included.

.PARAMETER ExportCsv
    Exports the full inventory to CsvPath as UTF-8 CSV.

.PARAMETER CsvPath
    Export destination. Specifying this parameter also enables export.
    Defaults to VMInfo.csv in the current directory. The parent directory
    must exist. Existing files are not overwritten.

.PARAMETER PassThru
    Returns full inventory objects instead of displaying the summary.
    Can be combined with CSV export. Use Format-List * to view all details.

.PARAMETER ReplicaInfo
    Queries and displays detailed replication relationships, including primary
    and replica servers, role, state, health, frequency, last replication time,
    authentication and recovery settings. Adds ReplicationDetails to CSV and
    PassThru output. Adds role, state and health columns to the summary and
    includes powered-off secondary replicas in all outputs.
    Multiple relationships are kept separate. Basic replication properties
    remain available in CSV and PassThru output without this switch.

.PARAMETER LocationInfo
    Displays VM root, configuration, checkpoint and smart-paging folders,
    plus attached disk folders and file paths, below the summary. These
    locations are also included in CSV and PassThru output without this switch.
    Paths belong to the queried host; no local filesystem access is attempted.

.EXAMPLE
    .\Get-TSxVMInfo.ps1

.EXAMPLE
    .\Get-TSxVMInfo.ps1 -Computer HV01,HV02 -Name 'LAB-*' -Verbose

.EXAMPLE
    .\Get-TSxVMInfo.ps1 -ExportCsv -CsvPath 'C:\Reports\VMInfo.csv'

.EXAMPLE
    .\Get-TSxVMInfo.ps1 -Name 'SQL*' -PassThru | Format-List *

.EXAMPLE
    .\Get-TSxVMInfo.ps1 -Computer HV01,HV02 -ReplicaInfo -LocationInfo

.NOTES
    Network and disk collections are flattened into strings for CSV.
    NetworkAdapters preserves the association between adapter, switch, MAC,
    addresses and VLAN configuration; entries are separated by " | ".
    Verbose output reports collection progress and per-VM details.

.LINK
    https://www.deploymentbunny.com
#>

[CmdletBinding()]
param(
    [Parameter()]
    [Alias('Computer')]
    [ValidateNotNullOrEmpty()]
    [string[]]$ComputerName = @('.'),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$Name = @('*'),

    [Parameter()]
    [switch]$ExportCsv,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath = '.\VMInfo.csv',

    [Parameter()]
    [switch]$PassThru,

    [Parameter()]
    [switch]$ReplicaInfo,

    [Parameter()]
    [switch]$LocationInfo
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-TSxAddressKey {
    param(
        [string]$Address,
        [string]$Property
    )

    if ([string]::IsNullOrWhiteSpace($Address)) { return }
    if ($Property -eq 'MacAddresses') {
        $key = ($Address -replace '[-:.\s]', '').ToUpperInvariant()
        if ($key -ne '000000000000') { $key }
    }
    else {
        $key = [System.Net.IPAddress]::Parse($Address.Trim()).ToString()
        if ($key -notin @('0.0.0.0', '::')) { $key }
    }
}

Import-Module Hyper-V -ErrorAction Stop

$inventory = @(
    foreach ($computer in ($ComputerName | Select-Object -Unique)) {
        Write-Verbose "Querying virtual machines on '$computer'."
        try {
            $vms = @(Get-VM -ComputerName $computer -ErrorAction Stop | Where-Object {
                if (-not $ReplicaInfo -and [string]$_.State -eq 'Off' -and
                    [string]$_.ReplicationMode -in @('Replica', 'ExtendedReplica', 'TestReplica')) {
                    Write-Verbose "Skipping powered-off secondary replica '$($_.Name)' on '$computer'. Use -ReplicaInfo to include it."
                    return $false
                }
                foreach ($pattern in $Name) {
                    if ($_.Name -like $pattern) { return $true }
                }
                return $false
            })
        }
        catch {
            throw "Cannot query Hyper-V host '$computer': $($_.Exception.Message)"
        }

        Write-Verbose "Found $($vms.Count) matching VM(s) on '$computer'."
        foreach ($vm in $vms) {
            Write-Verbose "Collecting '$($vm.Name)' on '$computer' (state: $($vm.State))."
            try {
                $memory = Get-VMMemory -VM $vm -ErrorAction Stop
                $processor = Get-VMProcessor -VM $vm -ErrorAction Stop
                $adapters = @(Get-VMNetworkAdapter -VM $vm -ErrorAction Stop)
                $disks = @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop)
                $checkpoints = @(Get-VMSnapshot -VM $vm -ErrorAction Stop)
                $networkDetails = @(
                    foreach ($adapter in $adapters) {
                        $vlan = Get-VMNetworkAdapterVlan -VMNetworkAdapter $adapter -ErrorAction Stop
                        $vlanDescription = switch ([string]$vlan.OperationMode) {
                            'Access' { "Access:$($vlan.AccessVlanId)" }
                            'Trunk' { "Trunk:Native=$($vlan.NativeVlanId),Allowed=$($vlan.AllowedVlanIdListString)" }
                            'Private' {
                                if ([string]$vlan.PrivateVlanMode -eq 'Promiscuous') {
                                    "Promiscuous:Primary=$($vlan.PrimaryVlanId),Secondary=$($vlan.SecondaryVlanIdListString)"
                                }
                                else {
                                    "$($vlan.PrivateVlanMode):Primary=$($vlan.PrimaryVlanId),Secondary=$($vlan.SecondaryVlanId)"
                                }
                            }
                            default { [string]$vlan.OperationMode }
                        }
                        '{0} [Switch={1}; MAC={2}; IP={3}; Status={4}; VLAN={5}]' -f
                            $adapter.Name, $adapter.SwitchName, $adapter.MacAddress,
                            ($adapter.IPAddresses -join ', '), ($adapter.Status -join ', '), $vlanDescription
                    }
                )

                $record = [pscustomobject][ordered]@{
                    ComputerName = $vm.ComputerName
                    Name = $vm.Name
                    VMId = $vm.Id
                    State = [string]$vm.State
                    Status = $vm.Status -join '; '
                    Heartbeat = [string]$vm.Heartbeat
                    IntegrationServicesState = [string]$vm.IntegrationServicesState
                    IsClustered = $vm.IsClustered
                    Generation = $vm.Generation
                    Version = $vm.Version
                    Uptime = [string]$vm.Uptime
                    CreationTime = $vm.CreationTime
                    CPUCount = $processor.Count
                    CPUUsagePercent = $vm.CPUUsage
                    ProcessorMigrationCompatibility = $processor.CompatibilityForMigrationEnabled
                    DynamicMemoryEnabled = $memory.DynamicMemoryEnabled
                    MemoryStatus = $vm.MemoryStatus
                    MemoryAssignedGB = [math]::Round($vm.MemoryAssigned / 1GB, 3)
                    MemoryDemandGB = [math]::Round($vm.MemoryDemand / 1GB, 3)
                    MemoryStartupGB = [math]::Round($memory.Startup / 1GB, 3)
                    MemoryMinimumGB = [math]::Round($memory.Minimum / 1GB, 3)
                    MemoryMaximumGB = [math]::Round($memory.Maximum / 1GB, 3)
                    MemoryBufferPercent = $memory.Buffer
                    MemoryPriority = $memory.Priority
                    NetworkAdapterCount = $adapters.Count
                    SwitchNames = ($adapters | ForEach-Object { $_.SwitchName } | Sort-Object -Unique) -join '; '
                    IPAddresses = @($adapters | ForEach-Object { $_.IPAddresses }) -join '; '
                    MacAddresses = @($adapters | ForEach-Object { $_.MacAddress }) -join '; '
                    NetworkAdapters = $networkDetails -join ' | '
                    DiskCount = $disks.Count
                    DiskPaths = @($disks | ForEach-Object { $_.Path }) -join '; '
                    DiskFolders = @($disks | ForEach-Object {
                        if (-not [string]::IsNullOrWhiteSpace($_.Path)) {
                            [System.IO.Path]::GetDirectoryName($_.Path)
                        }
                    } | Sort-Object -Unique) -join '; '
                    DiskAttachments = @($disks | ForEach-Object {
                        '{0} {1}:{2}={3}' -f $_.ControllerType, $_.ControllerNumber, $_.ControllerLocation, $_.Path
                    }) -join ' | '
                    CheckpointCount = $checkpoints.Count
                    CheckpointNames = @($checkpoints | ForEach-Object { $_.Name }) -join '; '
                    CheckpointType = [string]$vm.CheckpointType
                    Path = $vm.Path
                    ConfigurationLocation = $vm.ConfigurationLocation
                    SnapshotFileLocation = $vm.SnapshotFileLocation
                    SmartPagingFilePath = $vm.SmartPagingFilePath
                    AutomaticStartAction = [string]$vm.AutomaticStartAction
                    AutomaticStartDelaySeconds = $vm.AutomaticStartDelay
                    AutomaticStopAction = [string]$vm.AutomaticStopAction
                    ReplicationMode = [string]$vm.ReplicationMode
                    ReplicationState = [string]$vm.ReplicationState
                    ReplicationHealth = [string]$vm.ReplicationHealth
                    Notes = $vm.Notes
                }
                if ($ReplicaInfo) {
                    $relationships = @()
                    if ([string]$vm.ReplicationMode -notin @('None', 'TestReplica')) {
                        Write-Verbose "Collecting replication relationships for '$($vm.Name)' on '$computer'."
                        $relationships = @(Get-VMReplication -VM $vm -ErrorAction Stop)
                        if ($relationships.Count -eq 0) {
                            throw 'Replication is configured but no replication relationships were returned.'
                        }
                    }
                    $details = @(
                        foreach ($relationship in $relationships) {
                            $fields = [ordered]@{
                                Relationship = $relationship.ReplicationRelationshipType
                                Mode = $relationship.ReplicationMode
                                State = $relationship.ReplicationState
                                Health = $relationship.ReplicationHealth
                                PrimaryServer = $relationship.PrimaryServerName
                                ReplicaServer = $relationship.ReplicaServerName
                                CurrentReplicaServer = $relationship.CurrentReplicaServerName
                                ReplicaServerPort = $relationship.ReplicaServerPort
                                Authentication = $relationship.AuthenticationType
                                FrequencySeconds = $relationship.ReplicationFrequencySec
                                LastReplicationTime = $relationship.LastReplicationTime
                                LastAppliedLogTime = $relationship.LastAppliedLogTime
                                RecoveryHistory = $relationship.RecoveryHistory
                                VSSSnapshotFrequencyHours = $relationship.VSSSnapshotFrequencyHour
                                CompressionEnabled = $relationship.CompressionEnabled
                                AutoResynchronizeEnabled = $relationship.AutoResynchronizeEnabled
                                ReplicatedDisks = @($relationship.ReplicatedDisks | ForEach-Object { $_.Path }) -join '; '
                                ExcludedDisks = @($relationship.ExcludedDisks | ForEach-Object { $_.Path }) -join '; '
                            }
                            ($fields.GetEnumerator() | ForEach-Object {
                                $value = if ($_.Value -is [datetime]) { $_.Value.ToString('o') } else { [string]$_.Value }
                                '{0}: {1}' -f $_.Key, $value
                            }) -join [Environment]::NewLine
                        }
                    )
                    $description = if ($details.Count -gt 0) {
                        $details -join ([Environment]::NewLine + [Environment]::NewLine)
                    }
                    elseif ([string]$vm.ReplicationMode -eq 'TestReplica') {
                        'Test replica VM; no active replication relationship.'
                    }
                    else { 'Replication is not configured.' }
                    $record | Add-Member -NotePropertyName ReplicationDetails -NotePropertyValue $description
                }
                $record
                Write-Verbose ("'{0}': {1} vCPU(s), {2:N2} GiB assigned, {3} NIC(s), {4} disk(s), {5} checkpoint(s). Configuration: {6}" -f
                    $vm.Name, $processor.Count, ($vm.MemoryAssigned / 1GB), $adapters.Count,
                    $disks.Count, $checkpoints.Count, $vm.ConfigurationLocation)
            }
            catch {
                throw "Cannot collect VM '$($vm.Name)' on '$computer': $($_.Exception.Message)"
            }
        }
    }
)

if ($inventory.Count -eq 0) {
    Write-Warning 'No virtual machines matched the requested hosts, name patterns and replica filter. Use -ReplicaInfo to include powered-off secondary replicas. No CSV was written.'
    return
}

$inventory = @($inventory | Sort-Object Name, ComputerName)

$addressProperties = [ordered]@{
    IPAddresses = 'DuplicateIPAddresses'
    MacAddresses = 'DuplicateMacAddresses'
}
foreach ($property in $addressProperties.Keys) {
    $owners = @{}
    foreach ($item in $inventory) {
        if ($item.ReplicationMode -in @('Replica', 'ExtendedReplica', 'TestReplica')) { continue }
        $owner = '{0}|{1}' -f $item.ComputerName, $item.VMId
        foreach ($address in ($item.$property -split '; ')) {
            $key = ConvertTo-TSxAddressKey -Address $address -Property $property
            if ([string]::IsNullOrEmpty($key)) { continue }
            if (-not $owners.ContainsKey($key)) { $owners[$key] = @{} }
            $owners[$key][$owner] = $true
        }
    }
    foreach ($item in $inventory) {
        $duplicates = @(
            if ($item.ReplicationMode -notin @('Replica', 'ExtendedReplica', 'TestReplica')) {
                foreach ($address in ($item.$property -split '; ')) {
                    $key = ConvertTo-TSxAddressKey -Address $address -Property $property
                    if (-not [string]::IsNullOrEmpty($key) -and $owners[$key].Count -gt 1) { $address }
                }
            }
        )
        $item | Add-Member -NotePropertyName $addressProperties[$property] -NotePropertyValue (($duplicates | Select-Object -Unique) -join '; ')
    }
}

if ($ExportCsv -or $PSBoundParameters.ContainsKey('CsvPath')) {
    $inventory | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8 -NoClobber -ErrorAction Stop
    Write-Verbose "Exported $($inventory.Count) VM(s) to '$CsvPath'."
}

if ($PassThru) {
    $inventory
}
else {
    # Write cells separately to support color in Windows PowerShell without ANSI escapes.
    $columns = @('ComputerName', 'Name', 'State', 'CPUCount', 'MemoryAssignedGB',
        'IPAddresses', 'MacAddresses')
    if ($ReplicaInfo) {
        $columns += @('ReplicationMode', 'ReplicationState', 'ReplicationHealth')
    }
    $widths = @{}
    foreach ($column in $columns) {
        $widths[$column] = $column.Length
        foreach ($item in $inventory) {
            foreach ($value in ([string]$item.$column -split '; |\r?\n')) {
                $widths[$column] = [math]::Max($widths[$column], $value.Length)
            }
        }
    }
    Write-Host ''
    Write-Host (($columns | ForEach-Object { $_.PadRight($widths[$_]) }) -join ' ')
    Write-Host (($columns | ForEach-Object { ('-' * $_.Length).PadRight($widths[$_]) }) -join ' ')
    foreach ($item in $inventory) {
        $cells = @{}
        $lineCount = 1
        foreach ($column in $columns) {
            $cells[$column] = @([string]$item.$column -split '; |\r?\n')
            $lineCount = [math]::Max($lineCount, $cells[$column].Count)
        }
        for ($line = 0; $line -lt $lineCount; $line++) {
            foreach ($column in $columns) {
                $value = if ($line -lt $cells[$column].Count) { $cells[$column][$line] } else { '' }
                $highlight = $false
                if ($addressProperties.Contains($column) -and $value.Length -gt 0) {
                    $highlight = $value -in ($item.($addressProperties[$column]) -split '; ')
                }
                if ($highlight) {
                    Write-Host $value -ForegroundColor Yellow -NoNewline
                    Write-Host (' ' * ($widths[$column] - $value.Length + 1)) -NoNewline
                }
                else {
                    Write-Host ($value.PadRight($widths[$column]) + ' ') -NoNewline
                }
            }
            Write-Host ''
        }
    }
    Write-Host ''
    Write-Host ("{0} virtual machine(s). Use -PassThru | Format-List * for all details." -f $inventory.Count)
    Write-Host 'Yellow IP/MAC values indicate duplicates on non-secondary VMs.'
    if ($ReplicaInfo -or $LocationInfo) {
        foreach ($item in $inventory) {
            Write-Host ''
            Write-Host ("{0} on {1}" -f $item.Name, $item.ComputerName)
            if ($ReplicaInfo) {
                Write-Host 'Replication details:'
                Write-Host $item.ReplicationDetails
            }
            if ($LocationInfo) {
                Write-Host 'Locations:'
                foreach ($property in @('Path', 'ConfigurationLocation', 'SnapshotFileLocation',
                    'SmartPagingFilePath', 'DiskFolders', 'DiskPaths')) {
                    Write-Host ('{0}: {1}' -f $property, $item.$property)
                }
            }
        }
    }
}