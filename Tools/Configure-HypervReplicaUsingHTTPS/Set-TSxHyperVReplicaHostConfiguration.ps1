<#
.SYNOPSIS
    Configures a Hyper-V host for Hyper-V Replica over HTTPS with self-signed certificates.

.DESCRIPTION
    Hyper-V Replica performs a certificate revocation check on the certificate used for HTTPS replication.
    Self-signed certificates have no CRL distribution point, so the check fails and replication is blocked.

    This script sets the following registry value on one or more Hyper-V hosts:

        HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\Replication
        DisableCertRevocationCheck (REG_DWORD) = 1

    It also enables the built-in inbound firewall rules for the Hyper-V Replica listeners:

        Hyper-V Replica HTTP Listener (TCP-In)    TCP 80
        Hyper-V Replica HTTPS Listener (TCP-In)   TCP 443

    Use -Disable to revert: revocation check enabled (0) and the firewall rules disabled.

    Finally it enables the host as a Hyper-V Replica server using certificate based authentication,
    selecting the certificate in Local Machine\Personal whose subject matches the host name.

.PARAMETER ComputerName
    One or more Hyper-V hosts to configure. Default is the local computer.

.PARAMETER Credential
    Credential used when connecting to remote hosts.

.PARAMETER Disable
    Sets DisableCertRevocationCheck to 0, disables the Hyper-V Replica listener firewall rules and
    disables the host as a Hyper-V Replica server.

.PARAMETER HttpsPort
    Port used for certificate based replication. Default is 443.

.PARAMETER ReplicationStorageLocation
    Default storage location for replica virtual machines. If omitted the current default storage location
    of the host is reused (or the host VirtualHardDiskPath if none is set).

.PARAMETER SkipReplicationServerConfiguration
    Only configures the registry value and the firewall rules, without enabling the replica server.

.EXAMPLE
    .\Set-TSxHyperVReplicaHostConfiguration.ps1

.EXAMPLE
    .\Set-TSxHyperVReplicaHostConfiguration.ps1 -ComputerName 'hv01.corp.viamonstra.com','hv02.corp.viamonstra.com' -Verbose

.EXAMPLE
    .\Set-TSxHyperVReplicaHostConfiguration.ps1 -ComputerName 'hv01.corp.viamonstra.com' -Disable -WhatIf

.NOTES
    FileName:    Set-TSxHyperVReplicaHostConfiguration.ps1
    Version:     1.2.2
    Author:      Mikael Nystrom
    Contact:     deploymentbunny@outlook.com
    Created:     2026-09-10
    Updated:     2026-09-11
    Twitter:     @mikael_nystrom

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author or DeploymentBunny.
.LINK
    https://www.deploymentbunny.com
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
Param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string[]]$ComputerName = $env:COMPUTERNAME,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [Parameter(Mandatory = $false)]
    [switch]$Disable,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 65535)]
    [int]$HttpsPort = 443,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ReplicationStorageLocation,

    [Parameter(Mandatory = $false)]
    [switch]$SkipReplicationServerConfiguration
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Type = 'Info'
    )
    $Stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    switch ($Type) {
        'Warning' { Write-Warning "$Stamp - $Message" }
        'Error' { Write-Error "$Stamp - $Message" }
        default { Write-Verbose "$Stamp - $Message" -Verbose }
    }
}

$RegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\Replication'
$ValueName = 'DisableCertRevocationCheck'
$ValueData = if ($Disable) { 0 } else { 1 }

$ScriptBlock = {
    Param($RegistryPath, $ValueName, $ValueData, $Disable, $HttpsPort, $ReplicationStorageLocation, $SkipReplicationServerConfiguration)

    if (-not (Test-Path -Path $RegistryPath)) {
        New-Item -Path $RegistryPath -Force | Out-Null
    }

    New-ItemProperty -Path $RegistryPath -Name $ValueName -Value $ValueData -PropertyType DWord -Force | Out-Null

    # Built-in inbound rules for the Hyper-V Replica listeners (TCP 80 and TCP 443)
    $FirewallRuleNames = @('Hyper-V Replica HTTP Listener (TCP-In)', 'Hyper-V Replica HTTPS Listener (TCP-In)')
    $FirewallState = New-Object -TypeName System.Collections.Generic.List[string]

    foreach ($RuleName in $FirewallRuleNames) {
        $Rule = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
        if ($null -eq $Rule) {
            $FirewallState.Add("$RuleName = not found")
            continue
        }

        if ($Disable) {
            $Rule | Disable-NetFirewallRule
        }
        else {
            $Rule | Enable-NetFirewallRule
        }

        $Rule = Get-NetFirewallRule -DisplayName $RuleName
        $FirewallState.Add("$RuleName = $($Rule.Enabled)")
    }

    # Enable the host as a replica server using the imported certificate that matches the host name
    $ReplicationState = 'Skipped'
    $Thumbprint = $null

    if (-not $SkipReplicationServerConfiguration) {
        if ($Disable) {
            Set-VMReplicationServer -ReplicationEnabled $false
            $ReplicationState = 'Disabled'
        }
        else {
            $HostNames = @($env:COMPUTERNAME)
            $DomainName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName
            if (-not [string]::IsNullOrEmpty($DomainName)) { $HostNames += "$env:COMPUTERNAME.$DomainName" }

            $Certificate = Get-ChildItem -Path 'Cert:\LocalMachine\My' |
                Where-Object { $_.HasPrivateKey -and ($_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.1') } |
                Where-Object {
                    $Subject = ($_.Subject -replace '^CN=', '').Split(',')[0].Trim()
                    $HostNames -contains $Subject -or ($_.DnsNameList.Unicode | Where-Object { $HostNames -contains $_ })
                } |
                Sort-Object -Property NotAfter -Descending |
                Select-Object -First 1

            if ($null -eq $Certificate) {
                $ReplicationState = "No matching certificate found in Cert:\LocalMachine\My for $($HostNames -join ', ')"
            }
            else {
                $Thumbprint = $Certificate.Thumbprint
                $Parameters = @{
                    ReplicationEnabled              = $true
                    AllowedAuthenticationType       = 'Certificate'
                    CertificateAuthenticationPort   = $HttpsPort
                    CertificateThumbprint           = $Thumbprint
                    ReplicationAllowedFromAnyServer = $true
                }
                if (-not [string]::IsNullOrEmpty($ReplicationStorageLocation)) {
                    if (-not (Test-Path -Path $ReplicationStorageLocation)) {
                        New-Item -Path $ReplicationStorageLocation -ItemType Directory -Force | Out-Null
                    }
                    $Parameters.Add('DefaultStorageLocation', $ReplicationStorageLocation)
                }
                else {
                    # ReplicationAllowedFromAnyServer always requires DefaultStorageLocation to be passed in the same call
                    $StorageLocation = (Get-VMReplicationServer).DefaultStorageLocation
                    if ([string]::IsNullOrEmpty($StorageLocation)) {
                        $StorageLocation = (Get-VMHost).VirtualHardDiskPath
                    }
                    $Parameters.Add('DefaultStorageLocation', $StorageLocation)
                }

                Set-VMReplicationServer @Parameters
                $ReplicationState = "Enabled on port $HttpsPort using $($Certificate.Subject)"
            }
        }
    }

    [PSCustomObject]@{
        ComputerName          = $env:COMPUTERNAME
        Setting               = $ValueName
        Value                 = (Get-ItemProperty -Path $RegistryPath -Name $ValueName).$ValueName
        FirewallRules         = $FirewallState.ToArray()
        Replication           = $ReplicationState
        CertificateThumbprint = $Thumbprint
    }
}

foreach ($Computer in $ComputerName) {
    $Target = $Computer.Trim()
    if ([string]::IsNullOrEmpty($Target)) { continue }

    $Action = "Set $ValueName to $ValueData, $(if ($Disable) { 'disable' } else { 'enable' }) the Hyper-V Replica firewall rules and replica server"
    if (-not $PSCmdlet.ShouldProcess($Target, $Action)) { continue }

    try {
        Write-Log -Message "Configuring $Target : $ValueName = $ValueData"

        $IsLocal = ($Target -eq $env:COMPUTERNAME) -or ($Target -eq 'localhost') -or ($Target -eq '.') -or ($Target -eq "$env:COMPUTERNAME.$env:USERDNSDOMAIN")

        if ($IsLocal) {
            $Result = & $ScriptBlock $RegistryPath $ValueName $ValueData $Disable.IsPresent $HttpsPort $ReplicationStorageLocation $SkipReplicationServerConfiguration.IsPresent
        }
        else {
            $Parameters = @{
                ComputerName = $Target
                ScriptBlock  = $ScriptBlock
                ArgumentList = @($RegistryPath, $ValueName, $ValueData, $Disable.IsPresent, $HttpsPort, $ReplicationStorageLocation, $SkipReplicationServerConfiguration.IsPresent)
            }
            if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) {
                $Parameters.Add('Credential', $Credential)
            }
            $Result = Invoke-Command @Parameters
        }

        Write-Log -Message "$($Result.ComputerName): $($Result.Setting) = $($Result.Value)"
        foreach ($RuleState in $Result.FirewallRules) {
            Write-Log -Message "$($Result.ComputerName): $RuleState"
        }
        Write-Log -Message "$($Result.ComputerName): Replication = $($Result.Replication)"
        $Result
    }
    catch {
        Write-Log -Message "Failed to configure $Target. $($_.Exception.Message)" -Type Warning
    }
}

Write-Log -Message 'Done. Restart of the Hyper-V Virtual Machine Management service (vmms) is recommended for the setting to take effect.'
