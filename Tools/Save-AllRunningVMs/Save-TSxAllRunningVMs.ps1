<#
.SYNOPSIS
    Save all running Hyper-V virtual machines and record which ones were saved.
.DESCRIPTION
    Finds every Hyper-V virtual machine in Running state on the target host and
    saves it one by one. The target can be local or remote via PowerShell
    remoting. The name of each VM that was successfully saved is written to a
    host-specific list file so that Resume-TSxAllRunningVMs.ps1 can start them
    again later.

    Use -ListFolder to specify where host-specific SavedVMs_<host>.txt files are
    written. The folder must already exist. When called from
    Invoke-TSxVMSaveResumeUI.ps1 the list folder is set to %TEMP% automatically.
    If -ListFolder is not specified the file is written to the same folder as
    the script.
.PARAMETER ListFolder
    Path to an existing folder where host-specific list files are written.
    Defaults to the folder containing this script.
.PARAMETER ComputerName
    Target computer running Hyper-V. Defaults to the local computer.
.PARAMETER Credential
    Optional credential for remote PowerShell remoting.
.EXAMPLE
    .\Save-TSxAllRunningVMs.ps1
    Saves all running VMs on the local host and writes SavedVMs_<host>.txt next to the script.
.EXAMPLE
    .\Save-TSxAllRunningVMs.ps1 -ListFolder $env:TEMP
    Saves all running VMs on the local host and writes SavedVMs_<host>.txt to %TEMP%.
.EXAMPLE
    .\Save-TSxAllRunningVMs.ps1 -ComputerName HVHOST01
    Saves all running VMs on HVHOST01 over PowerShell remoting.
.NOTES
    FileName:    Save-TSxAllRunningVMs.ps1
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
$LogFile = Join-Path $env:TEMP ("Save-TSxAllRunningVMs_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$RunUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

function Write-TSxLog {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogFile -Value ("[{0}] [User: {1}] {2}" -f $timestamp, $RunUser, $Message)
}

Write-TSxLog -Message "Save-TSxAllRunningVMs started"

$TargetComputer = Resolve-TSxTargetComputer -Name $ComputerName
$IsLocalTarget = Test-TSxLocalTarget -Name $TargetComputer
Write-TSxLog -Message ("Target computer: {0}; LocalTarget={1}" -f $TargetComputer, $IsLocalTarget)

# Validate list folder
if (-not (Test-Path -Path $ListFolder -PathType Container)) {
    Write-TSxLog -Message "ListFolder '$ListFolder' does not exist"
    Write-Error "ListFolder '$ListFolder' does not exist. Please create the folder or specify a different path."
    exit 1
}

# Prepare host-specific list file
$ListFile = Get-TSxListFilePath -Folder $ListFolder -TargetComputer $TargetComputer
if (Test-Path $ListFile) {
    Write-TSxLog -Message "List file already exists at '$ListFile' - aborting"
    Write-Warning "List file already exists at '$ListFile'. Remove it or run Resume-TSxAllRunningVMs.ps1 first."
    exit 1
}
$null = New-Item -Path $ListFile -ItemType File -Force
Add-Content -Path $ListFile -Value ("# TargetComputer={0}" -f $TargetComputer)

$SavedCount = 0

if ($IsLocalTarget) {
    try {
        $RunningVMs = Get-VM -ErrorAction Stop | Where-Object -Property State -EQ -Value Running
    }
    catch {
        Write-TSxLog -Message ("Failed to enumerate local VMs: {0}" -f $_.Exception.Message)
        Write-Error ("Failed to enumerate local VMs on '{0}'. If access is denied, run elevated and try again. {1}" -f $TargetComputer, $_.Exception.Message)
        exit 1
    }

    Write-TSxLog -Message "Found $($RunningVMs.Count) running VM(s)"
    foreach ($VM in $RunningVMs) {
        Write-Verbose "Saving VM: $($VM.Name)"
        Write-TSxLog -Message "Saving VM: $($VM.Name)"
        try {
            Save-VM -Name $VM.Name -ErrorAction Stop
            Add-Content -Path $ListFile -Value $VM.Name
            $SavedCount++
            Write-Host "Saved: $($VM.Name)" -ForegroundColor Green
            Write-TSxLog -Message "Saved: $($VM.Name)"
        }
        catch {
            Write-Warning "Failed to save VM '$($VM.Name)': $_"
            Write-TSxLog -Message "Failed to save VM '$($VM.Name)': $_"
        }
    }
}
else {
    $remoteScript = {
        param([bool]$VerboseEnabled)

        if ($VerboseEnabled) { $VerbosePreference = 'Continue' }
        else { $VerbosePreference = 'SilentlyContinue' }

        $running = Get-VM | Where-Object -Property State -EQ -Value Running
        foreach ($vm in $running) {
            try {
                Save-VM -Name $vm.Name -ErrorAction Stop
                [PSCustomObject]@{
                    Name    = $vm.Name
                    Success = $true
                    Message = 'Saved'
                }
            }
            catch {
                [PSCustomObject]@{
                    Name    = $vm.Name
                    Success = $false
                    Message = $_.Exception.Message
                }
            }
        }
    }

    $invokeParams = @{
        ComputerName = $TargetComputer
        ScriptBlock  = $remoteScript
        ArgumentList = @($VerbosePreference -eq 'Continue')
        ErrorAction  = 'Stop'
    }
    if ($Credential) {
        $invokeParams.Credential = $Credential
    }

    try {
        $results = Invoke-Command @invokeParams
    }
    catch {
        Write-TSxLog -Message ("Remote save failed on '{0}': {1}" -f $TargetComputer, $_.Exception.Message)
        Write-Error ("Failed to run save operation remotely on '{0}'. {1}" -f $TargetComputer, $_.Exception.Message)
        exit 1
    }

    Write-TSxLog -Message ("Remote operation returned {0} VM result(s)" -f $results.Count)
    foreach ($result in $results) {
        if ($result.Success) {
            Add-Content -Path $ListFile -Value $result.Name
            $SavedCount++
            Write-Host ("Saved: {0}" -f $result.Name) -ForegroundColor Green
            Write-TSxLog -Message ("Saved: {0}" -f $result.Name)
        }
        else {
            Write-Warning ("Failed to save VM '{0}': {1}" -f $result.Name, $result.Message)
            Write-TSxLog -Message ("Failed to save VM '{0}': {1}" -f $result.Name, $result.Message)
        }
    }
}

if ($SavedCount -eq 0) {
    Write-Warning "No running VMs were saved."
    Write-TSxLog -Message "No running VMs were saved"
}

Write-Host ""
Write-Host "Saved VM list written to: $ListFile" -ForegroundColor Cyan
Write-TSxLog -Message "Save-TSxAllRunningVMs completed. List file: $ListFile. Log: $LogFile"


