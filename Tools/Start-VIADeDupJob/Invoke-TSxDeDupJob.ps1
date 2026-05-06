<#
.SYNOPSIS
    Run Data Deduplication jobs on all dedup-enabled volumes.
.DESCRIPTION
    Invoke-TSxDeDupJob validates prerequisites, self-elevates when required,
    and discovers all volumes with Data Deduplication enabled. It runs
    Optimization, Garbage Collection (Full), and Scrubbing (Full) sequentially
    per volume, waiting for each job to complete before continuing. Final
    deduplication status is collected via Get-DedupStatus.
    When -Report is specified, the script only reports actively running dedup
    jobs and exits without starting new jobs.
.EXAMPLE
    .\Invoke-TSxDeDupJob.ps1
.EXAMPLE
    .\Invoke-TSxDeDupJob.ps1 -Report
.NOTES
    FileName:    Invoke-TSxDeDupJob.ps1
    Version:     1.1.0
    Author:      Mikael Nystrom
    Contact:     deploymentbunny@outlook.com
    Created:     2017-01-01
    Updated:     2026-05-06
    Web:         https://www.deploymentbunny.com
    Twitter:     @mikael_nystrom

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author.
.FUNCTIONALITY
    The script verifies administrative privileges and self-elevates when required.
    It validates that the Data Deduplication feature and cmdlets are available and
    that at least one volume has Data Deduplication enabled before any jobs are
    started. It then enumerates all dedup-enabled volumes and runs Optimization,
    Garbage Collection (Full), and Scrubbing (Full) jobs sequentially, waiting for
    each job to complete before starting the next. Active job progress is reported
    on every poll. Final dedup status is collected via Get-DedupStatus.
    In -Report mode, the script returns only currently running dedup jobs.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Report
)

# Get the ID and security principal of the current user account
 $myWindowsID=[System.Security.Principal.WindowsIdentity]::GetCurrent()
 $myWindowsPrincipal=New-Object System.Security.Principal.WindowsPrincipal($myWindowsID)
  
 # Get the security principal for the Administrator role
 $adminRole=[System.Security.Principal.WindowsBuiltInRole]::Administrator
  
 # Check to see if we are currently running "as Administrator"
if ($myWindowsPrincipal.IsInRole($adminRole)){
    # We are running "as Administrator". Console styling is only safe in interactive console hosts.
    try {
        if ($Host.Name -eq 'ConsoleHost') {
            $Host.UI.RawUI.WindowTitle = $myInvocation.MyCommand.Definition + "(Bootstrap)"
        }
    }
    catch {
        # Ignore non-interactive host UI operations.
    }
}
else{
    # We are not running "as Administrator" - so relaunch as administrator
    
    # Create a new process object that starts PowerShell
    $newProcess = New-Object System.Diagnostics.ProcessStartInfo "PowerShell";
    $verboseArg = if ($VerbosePreference -ne 'SilentlyContinue') { ' -Verbose' } else { '' }
    
    # Specify the current script path and name as a parameter
    $reportArg = if ($Report) { ' -Report' } else { '' }
    $newProcess.Arguments = "-NoProfile -File `"$($myInvocation.MyCommand.Definition)`"$reportArg$verboseArg";
    
    # Indicate that the process should be elevated
    $newProcess.Verb = "runas";
    
    # Start the new process
    [System.Diagnostics.Process]::Start($newProcess);
    
    # Exit from the current, unelevated, process
    exit
}

# Logging setup (after elevation check)
$Script:LogFile = Join-Path $env:TEMP ("Invoke-TSxDeDupJob_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$Script:RunUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

function Write-TSxLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $Script:LogFile -Value ("[{0}] [User: {1}] {2}" -f $timestamp, $Script:RunUser, $Message)
}

function Write-TSxStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-TSxLog -Message $Message
    Write-Verbose ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message)
    if ($VerbosePreference -ne 'Continue') {
        Write-Output ("STATUS: [{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message)
    }
}

Write-TSxStatus -Message "Invoke-TSxDeDupJob started (running as Administrator)"

function Test-TSxDedupJobIsRunning {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Job
    )

    $stateValue = $null
    foreach ($stateProperty in @('JobState', 'State', 'Status')) {
        if ($Job.PSObject.Properties.Name -contains $stateProperty) {
            $stateValue = [string]$Job.$stateProperty
            break
        }
    }

    return ($stateValue -match '^Running$')
}

# Validate that Data Deduplication is available on this operating system
if (-not (Get-Command -Name Get-DedupVolume -ErrorAction SilentlyContinue)) {
    Write-Warning "Data Deduplication cmdlets are not available. Ensure Data Deduplication is enabled in the operating system."
    Write-TSxStatus -Message "Validation failed: Get-DedupVolume cmdlet not available"
    exit 1
}

if ($Report) {
    Write-TSxStatus -Message "Report mode requested: collecting actively running dedup jobs only"
    $runningJobs = @(
        Get-DedupJob -ErrorAction SilentlyContinue |
        Where-Object { Test-TSxDedupJobIsRunning -Job $_ }
    )

    if ($runningJobs.Count -eq 0) {
        Write-TSxStatus -Message "No actively running dedup jobs found"
    }
    else {
        Write-TSxStatus -Message ("Found {0} actively running dedup job(s)" -f $runningJobs.Count)
        $runningJobs | Format-Table -AutoSize | Out-String -Width 240 | Write-Output
        $runningJobs
    }

    Write-TSxStatus -Message "Invoke-TSxDeDupJob report completed"
    exit 0
}

# If available, validate the optional feature state explicitly
if (Get-Command -Name Get-WindowsFeature -ErrorAction SilentlyContinue) {
    $DedupFeature = Get-WindowsFeature -Name FS-Data-Deduplication -ErrorAction SilentlyContinue
    if ($DedupFeature -and -not $DedupFeature.Installed) {
        Write-Warning "Data Deduplication feature is not installed. Enable FS-Data-Deduplication before running this script."
        Write-TSxStatus -Message "Validation failed: FS-Data-Deduplication feature is not installed"
        exit 1
    }
}

$DedupVolumes = Get-DedupVolume -ErrorAction SilentlyContinue
if (-not $DedupVolumes) {
    Write-Warning "Data Deduplication is not enabled on any volumes. Enable Data Deduplication and try again."
    Write-TSxStatus -Message "Validation failed: No dedup-enabled volumes found"
    exit 1
}

Write-TSxStatus -Message ("Validation passed: Found {0} dedup-enabled volume(s)" -f @($DedupVolumes).Count)

Function Wait-TSxDedupJob
{
    $activeJobs = @(Get-DedupJob -ErrorAction SilentlyContinue)
    while ($activeJobs.Count -ne 0)
    {
        Write-TSxStatus -Message ("Waiting for active dedup jobs to complete (active jobs: {0})" -f $activeJobs.Count)
        $activeJobs | Format-Table -AutoSize | Out-String -Width 240 | Write-Output
        Start-Sleep -Seconds 30
        $activeJobs = @(Get-DedupJob -ErrorAction SilentlyContinue)
    }
}

try {
    foreach($item in $DedupVolumes){
        $volumeName = if ($item.Volume -and [string]::IsNullOrWhiteSpace([string]$item.Volume) -eq $false) { [string]$item.Volume } else { [string]$item }
        Write-TSxStatus -Message ("Starting dedup cycle for volume: {0}" -f $volumeName)

        Wait-TSxDedupJob
        Write-TSxStatus -Message ("Starting Optimization for volume: {0}" -f $volumeName)
        $optimizationJob = Start-DedupJob -Volume $volumeName -Type Optimization -Priority High -Memory 80 -ErrorAction Stop
        Write-TSxStatus -Message ("Optimization job started. Volume={0}; JobType={1}; StartTime={2}" -f $volumeName, $optimizationJob.Type, $optimizationJob.StartTime)

        Wait-TSxDedupJob
        Write-TSxStatus -Message ("Starting GarbageCollection (Full) for volume: {0}" -f $volumeName)
        $gcJob = Start-DedupJob -Volume $volumeName -Type GarbageCollection -Priority High -Memory 80 -Full -ErrorAction Stop
        Write-TSxStatus -Message ("GarbageCollection job started. Volume={0}; JobType={1}; StartTime={2}" -f $volumeName, $gcJob.Type, $gcJob.StartTime)

        Wait-TSxDedupJob
        Write-TSxStatus -Message ("Starting Scrubbing (Full) for volume: {0}" -f $volumeName)
        $scrubJob = Start-DedupJob -Volume $volumeName -Type Scrubbing -Priority High -Memory 80 -Full -ErrorAction Stop
        Write-TSxStatus -Message ("Scrubbing job started. Volume={0}; JobType={1}; StartTime={2}" -f $volumeName, $scrubJob.Type, $scrubJob.StartTime)

        Wait-TSxDedupJob
        Write-TSxStatus -Message ("Completed dedup cycle for volume: {0}" -f $volumeName)
    }

    Write-TSxStatus -Message "Collecting final dedup status"
    $dedupStatus = @(Get-DedupStatus -ErrorAction Stop)
    Write-TSxStatus -Message ("Collected final dedup status row(s): {0}" -f $dedupStatus.Count)
    $dedupStatus
    Write-TSxStatus -Message "Invoke-TSxDeDupJob completed successfully"
}
catch {
    Write-TSxStatus -Message ("Invoke-TSxDeDupJob failed. Error: {0}" -f $_.Exception.Message)
    throw
}
