[CmdletBinding()]
Param(
    $VMnames
)

if($VMnames -eq $null){
    $VMnames = (Get-VM).Name
}

foreach($VMname in $VMnames){
    #Check if VM is running
    Write-Host "Checking $VMname"
    if((Get-VM -Name $VMname).State -eq "off" -and (Get-VM -Name $VMname).ParentCheckpointId -eq $null){
    
    #Find the disks
    foreach($VHD in ((Get-VMHardDiskDrive -VMName $VMname).Path)){
        Write-Host "Working on $VHD, please wait"
        Write-Host "Current size $([math]::truncate($(Get-VHD -Path $VHD).FileSize/ 1GB)) GB"
        Mount-VHD -Path $VHD -NoDriveLetter -ReadOnly
        Optimize-VHD -Path $VHD -Mode Full
        Write-Host "Optimize size $([math]::truncate($(Get-VHD -Path $VHD).FileSize/ 1GB)) GB"
        Dismount-VHD -Path $VHD
        Write-Host ""
        }
    }
    else{Write-Warning "$VMname is not turned off or has a snapshot, will not be fixed"
    Write-Host ""}
}
