Function Get-VIAActiveDiffDisk{
    <#
    .Synopsis
        Script used to Deploy and Configure Fabric
    .DESCRIPTION
        Created: 2016-11-07
        Version: 1.0
        Author : Mikael Nystrom
        Twitter: @mikael_nystrom
        Blog   : http://deploymentbunny.com
        Disclaimer: This script is provided "AS IS" with no warranties.
    .EXAMPLE
        Get-VIAActiveDiffDisk
    #>    
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
    )

    $VMHardDiskDrives = Get-VMHardDiskDrive -VM (Get-VM)
    $ActiveDisks = foreach($VMHardDiskDrive in $VMHardDiskDrives){
        $Diffs = Get-VHD -Path $VMHardDiskDrive.Path | Where-Object -Property VhdType -EQ -Value Differencing
        $Diffs.ParentPath
    }
    $ActiveDisks | Sort-Object | Select-Object -Unique
}