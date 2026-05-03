<#
.SYNOPSIS
    Prepares a Hyper-V host for nested virtual machine support.

.DESCRIPTION
    Prepare-NestedHyperVHost validates and configures the host operating system
    to support nested Hyper-V virtualization. It checks that the CPU supports
    hardware virtualization and SLAT (Second Level Address Translation), that
    Microsoft-Hyper-V is installed, disables incompatible security features
    (IsolatedUserMode, HostGuardian), and reports the readiness status.

.PARAMETER Remediate
    When specified, automatically disable incompatible features and enable
    required features. Without this flag, only validation is performed.

.PARAMETER ComputerName
    Name of the remote Hyper-V host to prepare. If omitted, the local computer
    is used. Requires PowerShell remoting to be enabled on the target.

.PARAMETER Credential
    PSCredential object for authentication to the remote host. Required when
    -ComputerName specifies a remote computer.

.EXAMPLE
    .\Prepare-NestedHyperVHost.ps1 -ComputerName "HyperVHost01" -Verbose

    Validates the remote Hyper-V host without making changes.

.EXAMPLE
    .\Prepare-NestedHyperVHost.ps1 -ComputerName "HyperVHost01" -Credential (Get-Credential) -Remediate -Verbose

    Validates and configures the remote host with specified credentials.

.NOTES
    FileName:    Prepare-TSxNestedHyperVHost.ps1
    Author:      Mikael Nystrom
    Contact:     deploymentbunny@outlook.com
    Created:     2026-04-27
    Updated:     2026-04-27
    Version:     1.2
    Web:         https://www.deploymentbunny.com
    Twitter:     @mikael_nystrom

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author.

.LINK
    https://www.deploymentbunny.com
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Remediate,

    [Parameter(Mandatory = $false)]
    [string]$ComputerName = $env:COMPUTERNAME,

    [Parameter(Mandatory = $false)]
    [PSCredential]$Credential
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

function Get-WindowsOptionalFeatureStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FeatureName,
        
        [Parameter(Mandatory = $false)]
        [string]$ComputerName = $env:COMPUTERNAME,
        
        [Parameter(Mandatory = $false)]
        [PSCredential]$Credential
    )
    
    try {
        $invokeParams = @{
            ScriptBlock = {
                param($FeatureName)
                [string](Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction Stop | Select-Object -ExpandProperty State)
            }
            ArgumentList = $FeatureName
            ErrorAction = 'Stop'
        }
        
        if ($ComputerName -ne $env:COMPUTERNAME) {
            $invokeParams['ComputerName'] = $ComputerName
            if ($Credential) {
                $invokeParams['Credential'] = $Credential
            }
            return Invoke-Command @invokeParams
        }
        else {
            return [string](Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction Stop | Select-Object -ExpandProperty State)
        }
    }
    catch {
        Write-TSxLog -Message ("Failed to query feature '{0}' on {1}. Error: {2}" -f $FeatureName, $ComputerName, $_.Exception.Message)
        Write-Error "Failed to query feature '$FeatureName' on $ComputerName : $_"
        return $null
    }
}

function Get-CpuVirtualizationStatus {
    param(
        [Parameter(Mandatory = $false)]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Mandatory = $false)]
        [PSCredential]$Credential
    )

    try {
        $invokeParams = @{
            ScriptBlock = {
                $proc = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
                [PSCustomObject]@{
                    Name                          = $proc.Name
                    Manufacturer                  = $proc.Manufacturer
                    VirtualizationFirmwareEnabled = [bool]$proc.VirtualizationFirmwareEnabled
                    SlatSupported                 = [bool]$proc.SecondLevelAddressTranslationExtensions
                }
            }
            ErrorAction = 'Stop'
        }

        if ($ComputerName -ne $env:COMPUTERNAME) {
            $invokeParams['ComputerName'] = $ComputerName
            if ($Credential) {
                $invokeParams['Credential'] = $Credential
            }
            return Invoke-Command @invokeParams
        }
        else {
            $proc = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
            return [PSCustomObject]@{
                Name                          = $proc.Name
                Manufacturer                  = $proc.Manufacturer
                VirtualizationFirmwareEnabled = [bool]$proc.VirtualizationFirmwareEnabled
                SlatSupported                 = [bool]$proc.SecondLevelAddressTranslationExtensions
            }
        }
    }
    catch {
        Write-TSxLog -Message ("Failed to query CPU virtualization status on {0}. Error: {1}" -f $ComputerName, $_.Exception.Message)
        Write-Error "Failed to query CPU virtualization status on $ComputerName : $_"
        return $null
    }
}

function Set-WindowsOptionalFeatureStatus {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FeatureName,
        
        [Parameter(Mandatory = $true)]
        [ValidateSet('Enable', 'Disable')]
        [string]$Action,
        
        [Parameter(Mandatory = $false)]
        [string]$ComputerName = $env:COMPUTERNAME,
        
        [Parameter(Mandatory = $false)]
        [PSCredential]$Credential
    )
    
    try {
        $invokeParams = @{
            ScriptBlock = {
                param($FeatureName, $Action)
                if ($Action -eq 'Enable') {
                    Enable-WindowsOptionalFeature -Online -FeatureName $FeatureName -All -NoRestart -ErrorAction Stop
                }
                else {
                    Disable-WindowsOptionalFeature -Online -FeatureName $FeatureName -NoRestart -ErrorAction Stop
                }
            }
            ArgumentList = @($FeatureName, $Action)
            ErrorAction = 'Stop'
        }
        
        if ($ComputerName -ne $env:COMPUTERNAME) {
            $invokeParams['ComputerName'] = $ComputerName
            if ($Credential) {
                $invokeParams['Credential'] = $Credential
            }
            if ($PSCmdlet.ShouldProcess("Feature $FeatureName on $ComputerName", "$Action Windows Optional Feature")) {
                Write-Verbose "$Action feature '$FeatureName' on remote host $ComputerName"
                Write-TSxLog -Message ("{0} feature '{1}' on remote host {2}" -f $Action, $FeatureName, $ComputerName)
                Invoke-Command @invokeParams | Out-Null
                return $true
            }
        }
        else {
            if ($PSCmdlet.ShouldProcess("Feature $FeatureName", "$Action Windows Optional Feature")) {
                if ($Action -eq 'Enable') {
                    Write-Verbose "Enabling feature: $FeatureName"
                    Write-TSxLog -Message ("Enabling feature '{0}' on {1}" -f $FeatureName, $ComputerName)
                    Enable-WindowsOptionalFeature -Online -FeatureName $FeatureName -All -NoRestart -ErrorAction Stop | Out-Null
                }
                else {
                    Write-Verbose "Disabling feature: $FeatureName"
                    Write-TSxLog -Message ("Disabling feature '{0}' on {1}" -f $FeatureName, $ComputerName)
                    Disable-WindowsOptionalFeature -Online -FeatureName $FeatureName -NoRestart -ErrorAction Stop | Out-Null
                }
                return $true
            }
        }
        return $false
    }
    catch {
        Write-TSxLog -Message ("Failed to {0} feature '{1}' on {2}. Error: {3}" -f $Action.ToLower(), $FeatureName, $ComputerName, $_.Exception.Message)
        Write-Error "Failed to $($Action.ToLower()) feature '$FeatureName' on $ComputerName : $_"
        return $false
    }
}

Write-Verbose "Checking Hyper-V host readiness for nested virtualization on: $ComputerName"
Write-TSxLog -Message ("{0} started. Target host: {1}. Remediate: {2}" -f $Script:ToolName, $ComputerName, [bool]$Remediate)
Write-Verbose ("Tool log: {0}" -f $Script:TSxLogFile)

$results = [ordered]@{
    ComputerName                  = $ComputerName
    Ready                         = $false
    MicrosoftHyperV               = $null
    CpuVirtualizationEnabled      = 'N/A'
    CpuSlatSupported              = 'N/A'
    IsolatedUserMode              = $null
    HostGuardian                  = $null
}

# Check Microsoft-Hyper-V
$hyperVState = Get-WindowsOptionalFeatureStatus -FeatureName "Microsoft-Hyper-V" -ComputerName $ComputerName -Credential $Credential
$results.MicrosoftHyperV = $hyperVState
Write-TSxLog -Message ("Microsoft-Hyper-V state on {0}: {1}" -f $ComputerName, $hyperVState)

if ($hyperVState -eq 'Enabled') {
    Write-Verbose "[OK] Microsoft-Hyper-V is ENABLED on $ComputerName"
    Write-Verbose "Skipping CPU virtualization check - Hyper-V is already enabled, CPU support is proven"
    $results.CpuVirtualizationEnabled = 'N/A'
    $results.CpuSlatSupported         = 'N/A'
}
elseif ($hyperVState -eq 'Disabled') {
    if ($Remediate) {
        Write-Warning "Microsoft-Hyper-V is disabled on $ComputerName. Enabling..."
        Set-WindowsOptionalFeatureStatus -FeatureName "Microsoft-Hyper-V" -Action "Enable" -ComputerName $ComputerName -Credential $Credential | Out-Null
        Write-Output "Microsoft-Hyper-V has been enabled on $ComputerName (restart may be required)"
    }
    else {
        Write-Warning "Microsoft-Hyper-V is DISABLED on $ComputerName - required for nested Hyper-V"
    }

    # Hyper-V is not enabled - check CPU capabilities before attempting to enable it
    Write-Verbose "Checking CPU virtualization support on $ComputerName"
    $cpuStatus = Get-CpuVirtualizationStatus -ComputerName $ComputerName -Credential $Credential

    if ($null -ne $cpuStatus) {
        $results.CpuVirtualizationEnabled = $cpuStatus.VirtualizationFirmwareEnabled
        $results.CpuSlatSupported         = $cpuStatus.SlatSupported
        Write-TSxLog -Message ("CPU status on {0}. VirtualizationFirmwareEnabled: {1}; SlatSupported: {2}" -f $ComputerName, $results.CpuVirtualizationEnabled, $results.CpuSlatSupported)

        Write-Verbose "CPU: $($cpuStatus.Name)"

        if ($cpuStatus.VirtualizationFirmwareEnabled) {
            Write-Verbose "[OK] Hardware virtualization (VT-x/AMD-V) is ENABLED on $ComputerName"
        }
        else {
            Write-Warning "Hardware virtualization (VT-x/AMD-V) is DISABLED or unsupported on $ComputerName - enable it in BIOS/UEFI"
        }

        if ($cpuStatus.SlatSupported) {
            Write-Verbose "[OK] SLAT (EPT/NPT) is SUPPORTED on $ComputerName"
        }
        else {
            Write-Warning "SLAT (EPT/NPT) is NOT supported by the CPU on $ComputerName - required for Hyper-V"
        }
    }
    else {
        Write-Warning "Unable to determine CPU virtualization status on $ComputerName"
    }
}
else {
    Write-Warning "Unable to determine Microsoft-Hyper-V status on $ComputerName"
}

# Check IsolatedUserMode (not present on Windows Server 2025 and later)
$isolatedUserModeState = Get-WindowsOptionalFeatureStatus -FeatureName "IsolatedUserMode" -ComputerName $ComputerName -Credential $Credential

if ($null -eq $isolatedUserModeState) {
    Write-Verbose "IsolatedUserMode feature not found on $ComputerName - not applicable on this OS version"
    $results.IsolatedUserMode = 'N/A'
}
else {
    $results.IsolatedUserMode = $isolatedUserModeState

    if ($isolatedUserModeState -eq 'Disabled') {
        Write-Verbose "[OK] IsolatedUserMode is DISABLED on $ComputerName (correct for nested Hyper-V)"
    }
    elseif ($isolatedUserModeState -eq 'Enabled') {
        if ($Remediate) {
            Write-Warning "IsolatedUserMode is enabled on $ComputerName. Disabling..."
            Set-WindowsOptionalFeatureStatus -FeatureName "IsolatedUserMode" -Action "Disable" -ComputerName $ComputerName -Credential $Credential | Out-Null
            Write-Output "IsolatedUserMode has been disabled on $ComputerName"
        }
        else {
            Write-Warning "IsolatedUserMode is ENABLED on $ComputerName - blocks nested Hyper-V. Disable it to proceed."
        }
    }
    else {
        Write-Verbose "IsolatedUserMode state on $ComputerName : $isolatedUserModeState"
    }
}

# Check HostGuardian
$hostGuardianState = Get-WindowsOptionalFeatureStatus -FeatureName "HostGuardian" -ComputerName $ComputerName -Credential $Credential
$results.HostGuardian = $hostGuardianState
Write-TSxLog -Message ("IsolatedUserMode state on {0}: {1}" -f $ComputerName, $results.IsolatedUserMode)
Write-TSxLog -Message ("HostGuardian state on {0}: {1}" -f $ComputerName, $hostGuardianState)

if ($hostGuardianState -eq 'Disabled') {
    Write-Verbose "[OK] HostGuardian is DISABLED on $ComputerName (correct for nested Hyper-V)"
}
elseif ($hostGuardianState -eq 'Enabled') {
    if ($Remediate) {
        Write-Warning "HostGuardian is enabled on $ComputerName. Disabling..."
        Set-WindowsOptionalFeatureStatus -FeatureName "HostGuardian" -Action "Disable" -ComputerName $ComputerName -Credential $Credential | Out-Null
        Write-Output "HostGuardian has been disabled on $ComputerName"
    }
    else {
        Write-Warning "HostGuardian is ENABLED on $ComputerName - blocks nested Hyper-V. Disable it to proceed."
    }
}
else {
    Write-Verbose "HostGuardian state on $ComputerName : $hostGuardianState"
}

# Determine overall readiness
$isolatedUserModeOk = ($results.IsolatedUserMode -eq 'N/A') -or ($results.IsolatedUserMode -eq 'Disabled')
$results.Ready = ($results.CpuVirtualizationEnabled -ne $false) -and
                ($results.CpuSlatSupported -ne $false) -and
                ($hyperVState -eq 'Enabled') -and
                $isolatedUserModeOk -and
                ($hostGuardianState -eq 'Disabled')

if ($results.Ready) {
    Write-Output "[OK] Host $ComputerName is ready for nested Hyper-V virtualization"
}
else {
    Write-Output "✗ Host $ComputerName is NOT ready for nested Hyper-V. Review warnings above."
}

Write-TSxLog -Message ("Completed host readiness check on {0}. Ready: {1}" -f $ComputerName, $results.Ready)

return $results
