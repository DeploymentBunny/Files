Function Get-VIASCVMMDiskInfo{
    <#
    .Synopsis
        Get-VIASCVMMDiskInfo is a function that gets virtual harddisks from SCVMM.
    .DESCRIPTION
        Get-VIASCVMMDiskInfo is a function that gets virtual harddisks from SCVMM.
        It presents:
            VMName
            VMhost
            VMHostVolume
            VHDType
            VHDParentDisk
            VHDFormatType
            VHDLocation
            VHDMaxSize
            VHDCurrentSize
            VHDExpandedInPercent
    .EXAMPLE
        Get-VIASCVMMDiskInfo -VMName SERVER01 | Out-GridView
    .EXAMPLE
        Get-VIASCVMMDiskInfo | Out-GridView
    .NOTES
        Created:	 2016-11-25
        Version:	 1.0

        Author - Mikael Nystrom
        Twitter: @mikael_nystrom
        Blog   : http://deploymentbunny.com

        Disclaimer:
        This script is provided 'AS IS' with no warranties, confers no rights and 
        is not supported by the author.


    .LINK
        http://www.deploymentbunny.com
    #>
    Param(
    $VMName = ''
    )

    if($VMName -eq ''){$VMs = Get-SCVirtualMachine -All}
    if($VMName -ne ''){$VMs = Get-SCVirtualMachine -Name $VMName}

    foreach ($Obj in ($VMs | Select-Object ComputerNameString -ExpandProperty VirtualHardDisks)){
        $Data = [ordered]@{
            VMName = $($Obj.ComputerNameString);
            VMhost = $($Obj.VMHost);
            VMHostVolume = $($Obj.HostVolume);
            VHDType = $($Obj.VHDType);
            VHDParentDisk = $($Obj.ParentDisk);
            VHDFormatType = $($Obj.VHDFormatType);
            VHDLocation = $($Obj.Location);
            VHDMaxSize = "{0:N2}" -f $($Obj.MaximumSize/1GB);
            VHDCurrentSize = "{0:N2}" -f $($Obj.size/1GB);
            VHDExpandedInPercent="{0:P0}" -f $(($Obj.size/1GB)/($Obj.MaximumSize/1GB));
        }
        New-Object -TypeName PSObject -Property $Data
    }
}