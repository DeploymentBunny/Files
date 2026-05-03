<#
.SYNOPSIS
    Enables nested Hyper-V virtualization for one or more virtual machines.

.DESCRIPTION
    Enable-TSxNestedHyperVVM configures virtual machines to support nested
    Hyper-V virtualization. It validates all prerequisites (VM state, snapshots,
    configuration version, memory, etc.) and applies required settings only after
    all checks pass. Supports pipeline input for batch configuration of multiple VMs.
    The script writes execution and result details to a timestamped log file in
    the temporary folder for troubleshooting and auditing.

.PARAMETER VMName
    Name or names of virtual machines to configure for nested virtualization.
    Accepts pipeline input.

.PARAMETER ComputerName
    Name of the Hyper-V host containing the virtual machines. If omitted,
    the local computer is used.

.PARAMETER Credential
    PSCredential object for authentication to the Hyper-V host. Required when
    -ComputerName specifies a remote computer.

.PARAMETER Force
    Skip validation checks and apply settings directly. Use with caution.

.EXAMPLE
    .\Enable-TSxNestedHyperVVM.ps1 -VMName "VM01", "VM02" -Verbose

    Validates and configures two virtual machines.

.EXAMPLE
    .\Enable-TSxNestedHyperVVM.ps1 -ComputerName "HyperVHost01" -VMName "VM01", "VM02" -Credential (Get-Credential) -Verbose

    Validates and configures two virtual machines on a remote Hyper-V host.

.EXAMPLE
    .\Enable-TSxNestedHyperVVM.ps1 -VMName "VM01" -Force -Verbose

    Bypasses all validation checks and applies settings directly.

.NOTES
    FileName:    Enable-TSxNestedHyperVVM.ps1
    Author:      Mikael Nystrom
    Contact:     deploymentbunny@outlook.com
    Created:     2026-04-27
    Updated:     2026-04-27
    Version:     1.3
    Web:         https://www.deploymentbunny.com
    Twitter:     @mikael_nystrom

    LogFile:     %TEMP%\Enable-TSxNestedHyperVVM_yyyyMMdd_HHmmss.log

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author.

.LINK
    https://www.deploymentbunny.com
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
    [Alias('Name')]
    [string[]]$VMName,

    [Parameter(Mandatory = $false)]
    [string]$ComputerName = $env:COMPUTERNAME,

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$Script:ToolName = [IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
$Script:RunUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$Script:TSxLogFile = Join-Path $env:TEMP ("{0}_{1}.log" -f $Script:ToolName, (Get-Date -Format "yyyyMMdd_HHmmss"))

function Write-TSxLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    try {
        Add-Content -Path $Script:TSxLogFile -Value ("[{0}] [User: {1}] {2}" -f $timestamp, $Script:RunUser, $Message) -ErrorAction Stop
    }
    catch {
        Write-Verbose ("Unable to write to log file {0}. Error: {1}" -f $Script:TSxLogFile, $_.Exception.Message)
    }
}

Write-TSxLog -Message ("{0} started. Target host: {1}" -f $Script:ToolName, $ComputerName)
Write-Verbose ("Tool log: {0}" -f $Script:TSxLogFile)

$vmQueue = @()

# Collect VM names
foreach ($name in $VMName) {
    $vmQueue += $name
}

$results = @()
$vmCount = $vmQueue.Count
$vmIndex = 0
$useComputerName = $PSBoundParameters.ContainsKey('ComputerName')
$cimSession = $null

# Hyper-V blocks credentials for local connections. Detect local host so credentials
# are never passed when the target is the current machine.
$isLocalHost = ($ComputerName -eq '.' -or
                $ComputerName -ieq 'localhost' -or
                $ComputerName -ieq $env:COMPUTERNAME)

Write-TSxLog -Message ("Processing {0} VM(s) on host {1} (local: {2})" -f $vmCount, $ComputerName, $isLocalHost)

if ($useComputerName -and -not $isLocalHost) {
    $cimSessionOption = New-CimSessionOption -Protocol Dcom
    $newSessionParams = @{
        ComputerName = $ComputerName
        SessionOption = $cimSessionOption
        ErrorAction = 'Stop'
    }
    if ($Credential) {
        $newSessionParams['Credential'] = $Credential
    }

    try {
        $cimSession = New-CimSession @newSessionParams
        Write-TSxLog -Message ("Created DCOM CIM session to host {0}" -f $ComputerName)
    }
    catch {
        Write-TSxLog -Message ("Failed to create CIM session to host {0}. Exception: {1}" -f $ComputerName, $_.Exception.ToString())
        throw "Unable to connect to Hyper-V host '$ComputerName' using CIM session. $($_.Exception.Message)"
    }
}
elseif ($isLocalHost -and $Credential) {
    Write-TSxLog -Message ("Credential supplied but host is local - credentials will not be used for Hyper-V cmdlets.")
}

try {
    foreach ($vm in $vmQueue) {
        $vmIndex++
        $vmObject = $null
        $validationResult = @{
            ComputerName = $ComputerName
            VMName = $vm
            Status = 'Unknown'
            Message = ''
            Details = @{}
        }

        Write-Verbose "[$vmIndex/$vmCount] Processing VM: $vm on $ComputerName"
        Write-TSxLog -Message ("[{0}/{1}] Processing VM: {2} on {3}" -f $vmIndex, $vmCount, $vm, $ComputerName)

        # Get VM object
        try {
            $vmGetParams = @{
                Name = $vm
                ErrorAction = 'Stop'
            }
            if ($cimSession) {
                $vmGetParams['CimSession'] = $cimSession
            }
            $vmObject = Get-VM @vmGetParams
        }
        catch {
            $validationResult.Status = 'Error'
            $validationResult.Message = "VM not found on $ComputerName : $vm"
            Write-TSxLog -Message ("[{0}/{1}] VM not found: {2} on {3}. Exception: {4}" -f $vmIndex, $vmCount, $vm, $ComputerName, $_.Exception.ToString())
            Write-Error $validationResult.Message
            $results += [PSCustomObject]$validationResult
            continue
        }

        $vmNicParams = @{
            VMName = $vm
            ErrorAction = 'SilentlyContinue'
        }
        if ($cimSession) {
            $vmNicParams['CimSession'] = $cimSession
        }
        $vmNic = Get-VMNetworkAdapter @vmNicParams

        $vmCpuParams = @{
            VMName = $vm
            ErrorAction = 'SilentlyContinue'
        }
        if ($cimSession) {
            $vmCpuParams['CimSession'] = $cimSession
        }
        $vmCPU = Get-VMProcessor @vmCpuParams

        # Validate prerequisites (unless -Force is specified)
        if (-not $Force) {
            $validationPassed = $true
            $issues = @()

            # Check if VM is saved
            if ($vmObject.State -eq 'Saved') {
                $validationPassed = $false
                $issues += "VM is in 'Saved' state - must be powered off"
                $validationResult.Details['State_Saved'] = $true
            }

            # Check if VM has snapshots
            if ($null -ne $vmObject.ParentSnapshotName) {
                $validationPassed = $false
                $issues += "VM has snapshots - must be removed"
                $validationResult.Details['HasSnapshots'] = $true
            }

            # Check if VM is off
            if ($vmObject.State -ne 'Off') {
                $validationPassed = $false
                $issues += "VM is not powered off (State: $($vmObject.State)) - must be off"
                $validationResult.Details['NotPoweredOff'] = $true
            }

            # Check VM configuration version
            $vmVersion = [version]($vmObject.Version.ToString())
            if ($vmVersion -lt [version]'7.0') {
                $validationPassed = $false
                $issues += "VM configuration version ($($vmObject.Version)) is below 7.0 - upgrade required"
                $validationResult.Details['ConfigVersionTooOld'] = $true
            }

            # Check if VM has minimum 4GB RAM
            if ($vmObject.MemoryStartup -lt 4GB) {
                $validationPassed = $false
                $issues += "VM RAM ($([math]::Round($vmObject.MemoryStartup / 1GB)) GB) is below minimum 4GB"
                $validationResult.Details['InsufficientRAM'] = $true
            }

            if (-not $validationPassed) {
                $validationResult.Status = 'ValidationFailed'
                $validationResult.Message = "Validation failed: $(($issues | ForEach-Object { "- $_" }) -join [Environment]::NewLine)"
                Write-TSxLog -Message ("[{0}/{1}] Validation failed for VM {2}. Issues: {3}" -f $vmIndex, $vmCount, $vm, ($issues -join '; '))
                Write-Warning "[$vmIndex/$vmCount] Validation failed for VM: $vm`n$(($issues | ForEach-Object { "  - $_" }) -join [Environment]::NewLine)"
                $results += [PSCustomObject]$validationResult
                continue
            }
        }

        # All validation passed (or Force was specified), apply settings
        if ($PSCmdlet.ShouldProcess($vm, "Enable nested Hyper-V virtualization")) {
            try {
                Write-Verbose "[$vmIndex/$vmCount] Applying nested Hyper-V settings to VM: $vm"

                # Disable snapshots/checkpoints
                if ($vmObject.CheckpointType -ne 'Disabled') {
                    Write-Verbose "  - Disabling checkpoints"
                    $setVMParams = @{
                        VMName = $vm
                        CheckpointType = 'Disabled'
                        ErrorAction = 'Stop'
                    }
                    if ($cimSession) {
                        $setVMParams['CimSession'] = $cimSession
                    }
                    Set-VM @setVMParams
                }

                # Disable dynamic memory
                if ($vmObject.DynamicMemoryEnabled -eq $true) {
                    Write-Verbose "  - Disabling dynamic memory"
                    $setMemParams = @{
                        VMName = $vm
                        DynamicMemoryEnabled = $false
                        ErrorAction = 'Stop'
                    }
                    if ($cimSession) {
                        $setMemParams['CimSession'] = $cimSession
                    }
                    Set-VMMemory @setMemParams
                }

                # Ensure minimum 4GB RAM
                if ($vmObject.MemoryStartup -lt 4GB) {
                    Write-Verbose "  - Setting memory to 4GB"
                    $setMemParams = @{
                        VMName = $vm
                        StartupBytes = 4GB
                        ErrorAction = 'Stop'
                    }
                    if ($cimSession) {
                        $setMemParams['CimSession'] = $cimSession
                    }
                    Set-VMMemory @setMemParams
                }

                # Enable MAC address spoofing
                if ($vmNic -and ($vmNic | Where-Object { $_.MacAddressSpoofing -ne 'On' })) {
                    Write-Verbose "  - Enabling MAC address spoofing"
                    $setNicParams = @{
                        VMName = $vm
                        MacAddressSpoofing = 'On'
                        ErrorAction = 'Stop'
                    }
                    if ($cimSession) {
                        $setNicParams['CimSession'] = $cimSession
                    }
                    Set-VMNetworkAdapter @setNicParams
                }

                # Enable virtualization extensions
                if ($vmCPU -and ($vmCPU.ExposeVirtualizationExtensions -ne $true)) {
                    Write-Verbose "  - Enabling virtualization extensions"
                    $setProcParams = @{
                        VMName = $vm
                        ExposeVirtualizationExtensions = $true
                        ErrorAction = 'Stop'
                    }
                    if ($cimSession) {
                        $setProcParams['CimSession'] = $cimSession
                    }
                    Set-VMProcessor @setProcParams
                }

                $validationResult.Status = 'Success'
                $validationResult.Message = "Nested Hyper-V virtualization enabled for VM: $vm"
                Write-TSxLog -Message ("[{0}/{1}] Success. {2}" -f $vmIndex, $vmCount, $validationResult.Message)
                Write-Output "[$vmIndex/$vmCount] [OK] $($validationResult.Message)"
            }
            catch {
                $validationResult.Status = 'Error'
                $validationResult.Message = "Failed to apply settings: $_"
                Write-TSxLog -Message ("[{0}/{1}] Failed to configure VM {2}. Exception: {3}" -f $vmIndex, $vmCount, $vm, $_.Exception.ToString())
                Write-Error "[$vmIndex/$vmCount] Failed to configure VM $vm : $_"
            }
        }
        else {
            $validationResult.Status = 'Cancelled'
            $validationResult.Message = "Configuration cancelled by user"
            Write-TSxLog -Message ("[{0}/{1}] Cancelled by user for VM {2}" -f $vmIndex, $vmCount, $vm)
        }

        $results += [PSCustomObject]$validationResult
    }
}
finally {
    if ($cimSession) {
        Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue
        Write-TSxLog -Message ("Closed CIM session to host {0}" -f $ComputerName)
    }
}

 # Return summary
Write-TSxLog -Message ("Completed processing {0} VM(s)." -f $vmCount)
Write-Verbose "Completed processing $vmCount VM(s)"
return $results
