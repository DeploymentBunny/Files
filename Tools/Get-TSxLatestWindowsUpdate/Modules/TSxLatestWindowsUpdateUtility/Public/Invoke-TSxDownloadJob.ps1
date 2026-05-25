function Invoke-TSxDownloadJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DownloadScriptPath,

        [Parameter(Mandatory = $true)]
        [psobject]$SelectedUpdate,

        [Parameter(Mandatory = $true)]
        [string]$DownloadPath,

        [Parameter(Mandatory = $true)]
        [bool]$UseWhatIf = $false,

        [Parameter()]
        [bool]$UseForce = $false
    )

    $job = Start-Job -ScriptBlock {
        param(
            [string]$DownloadScriptPath,
            [psobject]$SelectedUpdate,
            [string]$DownloadPath,
            [bool]$UseWhatIf,
            [bool]$UseForce
        )

        $SelectedUpdate | & $DownloadScriptPath -Path $DownloadPath -WhatIf:$UseWhatIf -Force:$UseForce -Verbose 4>&1 6>&1
    } -ArgumentList $DownloadScriptPath, $SelectedUpdate, $DownloadPath, $UseWhatIf, $UseForce

    try {
        while ($job.State -eq 'Running' -or $job.State -eq 'NotStarted') {
            [System.Windows.Forms.Application]::DoEvents()
            [System.Threading.Thread]::Sleep(150)
        }

        if ($job.State -ne 'Completed') {
            $reason = $job.ChildJobs[0].JobStateInfo.Reason
            if ($reason) { throw $reason }
            throw ('Download job finished with unexpected state: {0}' -f $job.State)
        }

        return @(Receive-Job -Job $job -ErrorAction Stop)
    }
    finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}
