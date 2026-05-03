<#
.SYNOPSIS
    Resume all Hyper-V virtual machines that were saved by Save-TSxAllRunningVMs.ps1.
.DESCRIPTION
    Reads the list of VM names from a host-specific list file and starts each VM
    one by one using Start-VM. The target can be local or remote via PowerShell
    remoting. VMs that are already running or that cannot be found are skipped
    with a warning. The list file is removed after processing.

    Use -ListFolder to specify the folder containing host-specific
    SavedVMs_<host>.txt files. The folder must already exist. When called from
    Invoke-TSxVMSaveResumeUI.ps1 the list folder is set to %TEMP% automatically.
    If -ListFolder is not specified the script looks in the same folder as
    the script.
.PARAMETER ListFolder
    Path to an existing folder that contains host-specific SavedVMs files.
    Defaults to the folder containing this script.
.PARAMETER ComputerName
    Target computer running Hyper-V. Defaults to the local computer.
.PARAMETER Credential
    Optional credential for remote PowerShell remoting.
.EXAMPLE
    .\Resume-TSxAllRunningVMs.ps1
    Reads SavedVMs_<local-host>.txt from the script folder and starts each listed VM.
.EXAMPLE
    .\Resume-TSxAllRunningVMs.ps1 -ListFolder $env:TEMP
    Reads SavedVMs_<local-host>.txt from %TEMP% and starts each listed VM.
.EXAMPLE
    .\Resume-TSxAllRunningVMs.ps1 -ComputerName HVHOST01
    Reads SavedVMs_hvhost01.txt and resumes listed VMs on HVHOST01 over PowerShell remoting.
.NOTES
    FileName:    Resume-TSxAllRunningVMs.ps1
    Author:      Mikael Nystrom
    Contact:     deploymentbunny@outlook.com
    Twitter:     @mikael_nystrom
    Updated:     2026-04-28

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author.
.LINK
    https://www.deploymentbunny.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ListFolder = $PSScriptRoot,

    [Parameter(Mandatory = $false)]
    [string]$ComputerName = $env:COMPUTERNAME,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential
)

function Resolve-TSxTargetComputer {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $normalized = $Name.Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $env:COMPUTERNAME
    }
    if ($normalized -eq '.') {
        return $env:COMPUTERNAME
    }
    return $normalized
}

function Test-TSxLocalTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($Name -ieq $env:COMPUTERNAME -or $Name -ieq 'localhost') {
        return $true
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERDNSDOMAIN)) {
        $fqdn = "{0}.{1}" -f $env:COMPUTERNAME, $env:USERDNSDOMAIN
        if ($Name -ieq $fqdn) {
            return $true
        }
    }
    return $false
}

function Get-TSxListFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Folder,
        [Parameter(Mandatory = $true)]
        [string]$TargetComputer
    )

    $safeTarget = $TargetComputer.ToLowerInvariant() -replace '[^a-z0-9._-]', '_'
    return (Join-Path $Folder ("SavedVMs_{0}.txt" -f $safeTarget))
}

# Logging setup
$LogFile = Join-Path $env:TEMP ("Resume-TSxAllRunningVMs_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$RunUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

function Write-TSxLog {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogFile -Value ("[{0}] [User: {1}] {2}" -f $timestamp, $RunUser, $Message)
}

Write-TSxLog -Message "Resume-TSxAllRunningVMs started"

$TargetComputer = Resolve-TSxTargetComputer -Name $ComputerName
$IsLocalTarget = Test-TSxLocalTarget -Name $TargetComputer
Write-TSxLog -Message ("Target computer: {0}; LocalTarget={1}" -f $TargetComputer, $IsLocalTarget)

# Validate list folder
if (-not (Test-Path -Path $ListFolder -PathType Container)) {
    Write-TSxLog -Message "ListFolder '$ListFolder' does not exist"
    Write-Error "ListFolder '$ListFolder' does not exist. Please create the folder or specify a different path."
    exit 1
}

$ListFile = Get-TSxListFilePath -Folder $ListFolder -TargetComputer $TargetComputer

if (-not (Test-Path $ListFile)) {
    Write-TSxLog -Message "No saved VM list found at: $ListFile"
    Write-Warning "No saved VM list found at: $ListFile"
    Write-Warning "Run Save-TSxAllRunningVMs.ps1 first."
    exit
}

$VMNames = Get-Content -Path $ListFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith('#') }

if ($VMNames.Count -eq 0) {
    Write-TSxLog -Message "Saved VM list at '$ListFile' is empty - removing and exiting"
    Write-Warning "The saved VM list at '$ListFile' is empty. Nothing to resume."
    Remove-Item -Path $ListFile -Force
    Write-Host "List file removed: $ListFile" -ForegroundColor Cyan
    exit
}

Write-TSxLog -Message "Resuming $($VMNames.Count) VM(s) from list: $ListFile"
Write-Host "Resuming $($VMNames.Count) VM(s) from list: $ListFile" -ForegroundColor Cyan
Write-Host ""

$AllSucceeded = $true

if ($IsLocalTarget) {
    foreach ($Name in $VMNames) {
        $VM = Get-VM -Name $Name -ErrorAction SilentlyContinue
        if (-not $VM) {
            Write-TSxLog -Message "VM '$Name' not found on this host - skipping"
            Write-Warning "VM '$Name' not found on this host - skipping."
            $AllSucceeded = $false
            continue
        }
        if ($VM.State -eq 'Running') {
            Write-TSxLog -Message "VM '$Name' is already running - skipping"
            Write-Host "Already running: $Name" -ForegroundColor Yellow
            continue
        }
        try {
            Write-Verbose "Starting VM: $Name"
            Write-TSxLog -Message "Starting VM: $Name"
            Start-VM -Name $Name -ErrorAction Stop
            Write-Host "Started: $Name" -ForegroundColor Green
            Write-TSxLog -Message "Started: $Name"
        }
        catch {
            Write-Warning "Failed to start VM '$Name': $_"
            Write-TSxLog -Message "Failed to start VM '$Name': $_"
            $AllSucceeded = $false
        }
    }
}
else {
    $remoteScript = {
        param([string[]]$Names, [bool]$VerboseEnabled)

        if ($VerboseEnabled) { $VerbosePreference = 'Continue' }
        else { $VerbosePreference = 'SilentlyContinue' }

        foreach ($name in $Names) {
            $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
            if (-not $vm) {
                [PSCustomObject]@{
                    Name    = $name
                    Status  = 'NotFound'
                    Message = 'VM not found on target host'
                }
                continue
            }
            if ($vm.State -eq 'Running') {
                [PSCustomObject]@{
                    Name    = $name
                    Status  = 'AlreadyRunning'
                    Message = 'VM already running'
                }
                continue
            }
            try {
                Start-VM -Name $name -ErrorAction Stop | Out-Null
                [PSCustomObject]@{
                    Name    = $name
                    Status  = 'Started'
                    Message = 'VM started'
                }
            }
            catch {
                [PSCustomObject]@{
                    Name    = $name
                    Status  = 'Failed'
                    Message = $_.Exception.Message
                }
            }
        }
    }

    $invokeParams = @{
        ComputerName = $TargetComputer
        ScriptBlock  = $remoteScript
        ArgumentList = @($VMNames, ($VerbosePreference -eq 'Continue'))
        ErrorAction  = 'Stop'
    }
    if ($Credential) {
        $invokeParams.Credential = $Credential
    }

    try {
        $results = Invoke-Command @invokeParams
    }
    catch {
        Write-TSxLog -Message ("Remote resume failed on '{0}': {1}" -f $TargetComputer, $_.Exception.Message)
        Write-Error ("Failed to run resume operation remotely on '{0}'. {1}" -f $TargetComputer, $_.Exception.Message)
        exit 1
    }

    foreach ($result in $results) {
        switch ($result.Status) {
            'Started' {
                Write-Host ("Started: {0}" -f $result.Name) -ForegroundColor Green
                Write-TSxLog -Message ("Started: {0}" -f $result.Name)
            }
            'AlreadyRunning' {
                Write-Host ("Already running: {0}" -f $result.Name) -ForegroundColor Yellow
                Write-TSxLog -Message ("Already running: {0}" -f $result.Name)
            }
            'NotFound' {
                Write-Warning ("VM '{0}' not found on target host - skipping." -f $result.Name)
                Write-TSxLog -Message ("VM '{0}' not found on target host" -f $result.Name)
                $AllSucceeded = $false
            }
            default {
                Write-Warning ("Failed to start VM '{0}': {1}" -f $result.Name, $result.Message)
                Write-TSxLog -Message ("Failed to start VM '{0}': {1}" -f $result.Name, $result.Message)
                $AllSucceeded = $false
            }
        }
    }
}

# Always remove the list file
Remove-Item -Path $ListFile -Force
Write-Host ""
if ($AllSucceeded) {
    Write-Host "All VMs resumed. List file removed." -ForegroundColor Cyan
    Write-TSxLog -Message "Resume-TSxAllRunningVMs completed successfully. List file removed. Log: $LogFile"
}
else {
    Write-Warning "One or more VMs could not be started. List file removed."
    Write-TSxLog -Message "Resume-TSxAllRunningVMs completed with errors. List file removed. Log: $LogFile"
}
