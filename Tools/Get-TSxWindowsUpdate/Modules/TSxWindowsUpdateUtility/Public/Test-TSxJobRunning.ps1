function Test-TSxJobRunning {
    [CmdletBinding()]
    param(
        [Parameter()]
        [object]$JobCandidate
    )

    if ($null -eq $JobCandidate) {
        return $false
    }

    if (-not ($JobCandidate -is [System.Management.Automation.Job])) {
        return $false
    }

    try {
        return @('Running', 'NotStarted') -contains [string]$JobCandidate.State
    }
    catch {
        return $false
    }
}
