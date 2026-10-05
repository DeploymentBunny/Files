<#
.SYNOPSIS
Configures an Azure Local VM from the Hyper-V host.

.DESCRIPTION
Runs remote configuration inside the target VM using Invoke-Command from the host.
The script renames the guest to match the VM name, joins it to the specified domain,
sets a static IP on the named adapter, and disables DHCP on all other adapters.
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [string]$DomainName,

    [Parameter(Mandatory = $true)]
    [string]$OUPath,

    [Parameter(Mandatory = $true)]
    [System.Management.Automation.PSCredential]$LocalCredentials,

    [Parameter(Mandatory = $true)]
    [System.Management.Automation.PSCredential]$DomainJoinCredentials,

    [Parameter(Mandatory = $true)]
    [string]$AdapterName,

    [Parameter(Mandatory = $true)]
    [string]$IPAddress,

    [Parameter(Mandatory = $true)]
    [string]$SubnetMask,

    [Parameter(Mandatory = $true)]
    [string]$DefaultGateway,

    [Parameter(Mandatory = $true)]
    [string[]]$DnsServers
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-PrefixLength {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubnetMask
    )

    $maskBytes = [System.Net.IPAddress]::Parse($SubnetMask).GetAddressBytes()
    $maskString = ($maskBytes | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join ''
    $firstZero = $maskString.IndexOf('0')

    if ($firstZero -eq -1) {
        return 32
    }

    return $firstZero
}

$vm = Get-VM -Name $VMName -ErrorAction Stop
if (-not $vm) {
    throw "VM '$VMName' was not found."
}

Write-Verbose "Found VM '$VMName'."

$prefixLength = ConvertTo-PrefixLength -SubnetMask $SubnetMask
Write-Verbose "Using prefix length $prefixLength for subnet mask '$SubnetMask'."

$adapterMap = @(
    Get-VMNetworkAdapter -VMName $VMName |
        ForEach-Object {
            [PSCustomObject]@{
                HostName = $_.Name
                MacAddress = ($_.MacAddress -replace '[-: ]', '').ToUpperInvariant()
            }
        }
)

Write-Verbose "Mapped $($adapterMap.Count) host network adapter(s) to MAC addresses."
$remoteVerbosePreference = $VerbosePreference

try {
    $renameRequired = Invoke-Command -VMId $vm.Id -Credential $LocalCredentials -ScriptBlock {
        $VerbosePreference = $using:remoteVerbosePreference
        Write-Verbose "Connected to VM '$using:VMName'."

        $targetName = $using:VMName
        $adapterMap = @($using:adapterMap)
        $currentName = $env:COMPUTERNAME
        $renameRequired = $false

        if ($currentName -ieq $targetName) {
            Write-Verbose "Computer name is already '$targetName'. No rename or restart is required."
        }
        else {
            Write-Verbose "Changing computer name from '$currentName' to '$targetName'."
            Rename-Computer -NewName $targetName -Force -ErrorAction Stop
            $renameRequired = $true
        }

        foreach ($adapterEntry in $adapterMap) {
            $guestAdapter = Get-NetAdapter -Physical |
                Where-Object { (($_.MacAddress -replace '[-: ]', '').ToUpperInvariant()) -eq $adapterEntry.MacAddress } |
                Select-Object -First 1

            if ($guestAdapter) {
                Write-Verbose "Renaming guest adapter with MAC '$($adapterEntry.MacAddress)' to '$($adapterEntry.HostName)'."
                Rename-NetAdapter -InputObject $guestAdapter -NewName $adapterEntry.HostName -ErrorAction Stop
            }
        }

        return $renameRequired
    }
}
catch {
    throw "Failed to check or rename VM '$VMName': $($_.Exception.Message)"
}

if ($renameRequired) {
    Write-Verbose "Restarting VM to apply the new computer name."
    try {
        Invoke-Command -VMId $vm.Id -Credential $LocalCredentials -ScriptBlock {
            Restart-Computer -Force -ErrorAction Stop
        }
    }
    catch {
        Write-Verbose "The VM connection closed during restart, as expected: $($_.Exception.Message)"
    }

    $vmRunning = $false
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        try {
            $currentVm = Get-VM -Id $vm.Id -ErrorAction Stop
            Write-Verbose "Waiting for VM '$VMName' to be running (attempt $attempt of 60, state: $($currentVm.State))."
            $vmRunning = $currentVm.State -eq 'Running'
        }
        catch {
            $vmRunning = $false
        }

        if ($vmRunning) {
            break
        }

        Start-Sleep -Seconds 5
    }

    if (-not $vmRunning) {
        throw "VM '$VMName' did not reach the Running state after the rename restart."
    }

    $hasIpAddress = $false
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        try {
            $ipAddresses = @(
                Get-VMNetworkAdapter -VMName $VMName -ErrorAction Stop |
                    ForEach-Object { $_.IPAddresses } |
                    Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' }
            )
            $hasIpAddress = $ipAddresses.Count -gt 0
        }
        catch {
            $hasIpAddress = $false
        }

        if ($hasIpAddress) {
            Write-Verbose "VM '$VMName' reported IP address '$($ipAddresses[0])'."
            break
        }

        Write-Verbose "Waiting for VM '$VMName' to report an IP address (attempt $attempt of 60)."
        Start-Sleep -Seconds 5
    }

    if (-not $hasIpAddress) {
        throw "VM '$VMName' did not report an IP address after the rename restart."
    }

    $kvpReady = $false
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        try {
            $kvpService = Get-VMIntegrationService -VMName $VMName -ErrorAction Stop |
                Where-Object { $_.Name -eq 'Key-Value Pair Exchange' }
            $kvpReady = @($kvpService | Where-Object {
                $_.Enabled -and $_.PrimaryStatusDescription -like 'OK*'
            }).Count -gt 0
        }
        catch {
            $kvpReady = $false
        }

        if ($kvpReady) {
            break
        }

        Write-Verbose "Waiting for KVP exchange on VM '$VMName' (attempt $attempt of 60)."
        Start-Sleep -Seconds 5
    }

    if (-not $kvpReady) {
        throw "KVP exchange did not become ready for VM '$VMName' after the rename restart."
    }

    $powerShellDirectReady = $false
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        try {
            $directTest = Invoke-Command -VMId $vm.Id -Credential $LocalCredentials -ScriptBlock {
                'PowerShell Direct ready'
            } -ErrorAction Stop
            $powerShellDirectReady = $directTest -contains 'PowerShell Direct ready'
        }
        catch {
            $powerShellDirectReady = $false
        }

        if ($powerShellDirectReady) {
            break
        }

        Write-Verbose "Waiting for PowerShell Direct on VM '$VMName' (attempt $attempt of 60)."
        Start-Sleep -Seconds 5
    }

    if (-not $powerShellDirectReady) {
        throw "PowerShell Direct did not become available for VM '$VMName' after the rename restart."
    }

    Write-Verbose "VM '$VMName' is running, has an IP address, KVP is ready, and PowerShell Direct is available. Continuing network configuration."
}
else {
    Write-Verbose "No rename restart was needed. Continuing network configuration."
}

Invoke-Command -VMId $vm.Id -Credential $LocalCredentials -ScriptBlock {
    $VerbosePreference = $using:remoteVerbosePreference
    $adapterName = $using:AdapterName
    $ipAddress = $using:IPAddress
    $gateway = $using:DefaultGateway
    $dnsServers = @($using:DnsServers)
    $prefixLength = $using:prefixLength

    Write-Verbose "Configuring static IP '$ipAddress' on adapter '$adapterName'."
    $adapter = Get-NetAdapter -Name $adapterName -ErrorAction Stop
    New-NetIPAddress -InterfaceAlias $adapter.Name -IPAddress $ipAddress -PrefixLength $prefixLength -DefaultGateway $gateway -ErrorAction Stop
    Set-DnsClientServerAddress -InterfaceAlias $adapter.Name -ServerAddresses $dnsServers -ErrorAction Stop

    Get-NetAdapter |
        Where-Object { $_.Name -ne $adapter.Name } |
        ForEach-Object {
            Write-Verbose "Disabling DHCP on adapter '$($_.Name)'."
            Set-NetIPInterface -InterfaceAlias $_.Name -Dhcp Disabled -ErrorAction SilentlyContinue
        }
}

Write-Verbose "Joining VM '$VMName' to domain '$DomainName' in OU '$OUPath' as the final configuration step."
Invoke-Command -VMId $vm.Id -Credential $LocalCredentials -ScriptBlock {
    $VerbosePreference = $using:remoteVerbosePreference
    Add-Computer -DomainName $using:DomainName -OUPath $using:OUPath -Credential $using:DomainJoinCredentials -Force -ErrorAction Stop
}

Write-Verbose "Restarting VM to complete domain membership."
try {
    Invoke-Command -VMId $vm.Id -Credential $LocalCredentials -ScriptBlock {
        Restart-Computer -Force -ErrorAction Stop
    }
}
catch {
    Write-Verbose "The VM connection closed during the final domain-join restart: $($_.Exception.Message)"
}
