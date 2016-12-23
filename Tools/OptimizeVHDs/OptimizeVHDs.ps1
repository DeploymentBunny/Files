[CmdletBinding()]
Param(
    $VMnames
)

foreach($VMname in $VMnames){
    #Check if VM is running
    Write-Verbose "Checking $VMname"
    if((Get-VM -Name $VMname).State -eq "off" -and (Get-VM -Name $VMname).ParentCheckpointId -eq $null){
    
    #Find the disks
    foreach($VHD in ((Get-VMHardDiskDrive -VMName $VMname).Path)){
        Write-Verbose "Working on $VHD, please wait"
        Write-Verbose "Current size $([math]::truncate($(Get-VHD -Path $VHD).FileSize/ 1GB)) GB"
        Mount-VHD -Path $VHD -NoDriveLetter -ReadOnly
        Optimize-VHD -Path $VHD -Mode Full
        Write-Verbose "Optimize size $([math]::truncate($(Get-VHD -Path $VHD).FileSize/ 1GB)) GB"
        Dismount-VHD -Path $VHD
        Write-Verbose ""
        }
    }
    else{Write-Warning "$VMname is not turned off or has a snapshot, will not be fixed"
    Write-Verbose ""}
}
