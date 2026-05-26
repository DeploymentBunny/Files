function Stop-TSxActiveDownloadJob {
    [CmdletBinding()]
    param(
        [Parameter()]
        [object]$JobCandidate
    )

    if ($JobCandidate -is [System.Management.Automation.Job]) {
        Stop-Job -Job $JobCandidate -ErrorAction SilentlyContinue
        Remove-Job -Job $JobCandidate -Force -ErrorAction SilentlyContinue
    }

    return $null
}
