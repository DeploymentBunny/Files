Function Wait-VIADedupJob
{
    while ((Get-DedupJob).count -ne 0 )
    {
        Get-DedupJob
        Start-Sleep -Seconds 30
    }
}

foreach($item in Get-DedupVolume){
    Wait-VIADedupJob
    $item | Start-DedupJob -Type Optimization -Priority High -Memory 80
    Wait-VIADedupJob
    $item | Start-DedupJob -Type GarbageCollection -Priority High -Memory 80 -Full
    Wait-VIADedupJob
    $item | Start-DedupJob -Type Scrubbing -Priority High -Memory 80 -Full
    Wait-VIADedupJob
}
Get-DedupStatus
