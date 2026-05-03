<#
.SYNOPSIS
    Demonstrates running parallel PowerShell jobs against multiple servers.

.DESCRIPTION
    This sample script shows how to use Invoke-Command -AsJob to execute a
    script block simultaneously on multiple servers via existing PS sessions,
    wait for all jobs to finish, and then collect and display the results
    per server. It is intended as a learning template; swap out the
    script block for any remote workload.

.NOTES
    - Sessions can target Hyper-V VMs ($Session via -VMName) or physical/
      network hosts ($Session via -ComputerName). Uncomment the appropriate
      line in the "Create sessions" section.
    - Credentials are prompted at runtime to avoid storing passwords in
      plain text inside the script.
    - Jobs are removed from memory after results are collected.

.EXAMPLE
    .\Running-ParJobs.ps1
#>

#region Configuration
# List of target server names. Add or remove entries as needed.
$Servers    = "Server1", "Server2"

# Domain used when building the credential username (DOMAIN\Administrator).
$DomainName = "corp.viamonstra.com"
#endregion

#region Credentials
# Prompt for credentials at runtime so no password is stored in plain text.
Write-Host "Enter credentials for $DomainName\TheAdmin" -ForegroundColor Cyan
$DomainCred = Get-Credential -UserName "$DomainName\TheAdmin" -Message "Domain administrator credentials"
#endregion

#region Create sessions
# Choose ONE of the two lines below depending on your target environment:
#   -VMName    : connects to local Hyper-V virtual machines by name (no network required)
#   -ComputerName : connects to physical hosts or VMs reachable over the network

Write-Host "Opening PS sessions to: $($Servers -join ', ')" -ForegroundColor Cyan

$Session = New-PSSession -VMName $Servers -Credential $DomainCred
# $Session = New-PSSession -ComputerName $Servers -Credential $DomainCred

Write-Host "Sessions established: $($Session.Count)" -ForegroundColor Green
#endregion

#region Submit parallel jobs
# Invoke-Command with -AsJob submits the script block to all sessions at the
# same time and returns immediately, allowing all servers to run in parallel.
# Replace the script block body with the actual workload you want to execute.

Write-Host "Submitting parallel jobs..." -ForegroundColor Cyan

$ParallelJob = Invoke-Command -Session $Session -AsJob -ScriptBlock {
    # ----- Remote workload start -----
    Get-ChildItem -Path C:\
    # ----- Remote workload end -------
}
#endregion

#region Wait for all jobs to complete
# Poll every 2 seconds to avoid a busy-wait that would consume unnecessary CPU.
Write-Host "Waiting for jobs to complete (state: $($ParallelJob.State))..." -ForegroundColor Cyan

do {
    Start-Sleep -Seconds 2
    Write-Host "  Job state: $($ParallelJob.State)" -ForegroundColor DarkGray
} until ($ParallelJob.State -in 'Completed', 'Failed', 'Stopped')

Write-Host "All jobs finished with state: $($ParallelJob.State)" -ForegroundColor Green
#endregion

#region Collect and display results
# Each child job maps to one session/server. Iterate them individually so
# results are clearly attributed to their source server.
# -Keep retains the output so Receive-Job can be called again if needed.

Write-Host "`nCollecting results..." -ForegroundColor Cyan

foreach ($ChildJob in $ParallelJob.ChildJobs) {
    Write-Host ""
    Write-Host "---- Result from: $($ChildJob.Location) ----" -ForegroundColor Yellow

    if ($ChildJob.State -eq 'Failed') {
        Write-Warning "Job on $($ChildJob.Location) failed: $($ChildJob.JobStateInfo.Reason.Message)"
    }
    else {
        Receive-Job -Job $ChildJob -Keep
    }
}
#endregion

#region Cleanup
# Remove the parent job (and its child jobs) from the current session's
# job table to free memory once you no longer need the results.

Remove-Job -Job $ParallelJob -Force
Write-Host "`nJobs removed. Sessions remain open for reuse." -ForegroundColor Cyan

# Uncomment the next line to also close and remove the PS sessions:
# $Session | Remove-PSSession
#endregion
