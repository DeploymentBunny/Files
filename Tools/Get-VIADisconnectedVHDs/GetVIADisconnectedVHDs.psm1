Function Get-VIADisconnectedVHDs
{
    <#
    .Synopsis
        Script used find .VHD files that are not connected to VM's
    .DESCRIPTION
        Created: 2016-11-07
        Version: 1.0
        Author : Mikael Nystrom
        Twitter: @mikael_nystrom
        Blog   : http://deploymentbunny.com
        Disclaimer: This script is provided "AS IS" with no warranties.
    .EXAMPLE
        Get-Get-VIADisconnectedVHDs
    #>    
    [CmdletBinding(SupportsShouldProcess=$true)]
    
    Param(
    [string]$Folder
    )

    if((Test-Path -Path $Folder) -ne $true){
        Write-Warning "I'm sorry, that folder does not exist"
        Break
    }

    #Get the disk used by a VM
    $VMs = (Get-VM | Where-Object -Property ParentSnapshotName -EQ -Value $null).VMId

    if(($VMs.count) -eq '0'){
        Write-Information "Sorry, could not find any VM's"
        Break
    }
    $VHDsActive = foreach($VMsID in $VMs){
        Get-VMHardDiskDrive -VM (Get-VM -Id $VMsID)
    }

    #Get the disk in the folder
    $VHDsAll = Get-ChildItem -Path $Folder -Filter *.vhd* -Recurse
    if(($VHDsAll.count) -eq '0'){
        Write-Information "Sorry, could not find any VHD's in $folder"
        Break
    }

    $obj = Compare-Object -ReferenceObject $VHDsActive.Path -DifferenceObject $VHDsAll.FullName

    #Compare and give back the list of .vhd's that are not connected
    Return ($obj | Where-Object -Property SideIndicator -EQ -Value =>).InputObject
}