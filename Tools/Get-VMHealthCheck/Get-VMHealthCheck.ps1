<#
.Synopsis
    Script from TechDays Sweden 2016
.DESCRIPTION
    Script from TechDays Sweden 2016
.NOTES
    Author - Mikael Nystrom
    Twitter: @mikael_nystrom
    Blog   : http://deploymentbunny.com
    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and 
    is not supported by the authors or Deployment Artist.
.LINK
    http://www.deploymentbunny.com
#>
$HyperVHosts = "demohost03.network.local"

Foreach($HyperVHost in $HyperVHosts){
    Write-Host "Checking netaccess to $HyperVHost" -ForegroundColor Green
    Test-Connection -ComputerName $HyperVHost

    Invoke-Command -ComputerName $HyperVHost -ScriptBlock {
        Write-Host "Base info:" -ForegroundColor Green
        $Win32_computersystem = Get-WmiObject -Class Win32_computersystem
        Write-Host "$($Win32_computersystem.Name), $($Win32_computersystem.Model), $("{0:N0}" -f ($Win32_computersystem.TotalPhysicalMemory/1GB)) GB"
        Get-Volume | FT
        Get-WmiObject -Class Win32_Processor | Select-Object Name | FT
    }

    Invoke-Command -ComputerName $HyperVHost -ScriptBlock {
        $VM = Get-VM

        Write-Host "The total number of VM's on this host is: ": -ForegroundColor Green
        $VM.Count

        Write-Host "The following VM's are running": -ForegroundColor Green
        $VM | Where-Object -Property State -EQ -Value Running | FT -AutoSize

        Write-Host "The following VM's have DiffDisks": -ForegroundColor Green
        $VMHardDiskDrives = $VM | Get-VMHardDiskDrive 
        $VMsWithDiff = foreach($VMHardDiskDrive in $VMHardDiskDrives){
            if($VMHardDiskDrive.Path | Get-VHD | Where-Object -Property VhdType -EQ -Value Differencing){
            $VMHardDiskDrive.VMName
            }
        }
        $VMsWithDiff | FT -AutoSize

        Write-Host "The following DiffDisks are in use": -ForegroundColor Green
        $VMHardDiskDrives = $VM | Get-VMHardDiskDrive 
        $DiffDisks = foreach($VMHardDiskDrive in $VMHardDiskDrives){
            if($VMHardDiskDrive.Path | Get-VHD | Where-Object -Property VhdType -EQ -Value Differencing){
                $VMHardDiskDrive.Path
            }
        }
        $DiffDisks | FT -AutoSize

        Write-Host "The following VM's have SnapShots": -ForegroundColor Green
        $VM | Get-VMSnapshot | FT -AutoSize

        Write-Host "Checking for NetAdapter issues": -ForegroundColor Green
        $VMNetworkAdapters = $VM | Get-VMNetworkAdapter
        $VMNetworkAdapters | Select-Object VMName,MacAddress,DynamicMacAddressEnabled,IsLegacy,SwitchName,Status,IPAddresses | FT -AutoSize

        Write-Host "Checking for CPU issues:" -ForegroundColor Green
        $VMProcessor = $VM | Get-VMProcessor
        $VMProcessor | Select-Object VMName,Count,CompatibilityForMigrationEnabled,CompatibilityForOlderOperatingSystemsEnabled,ExposeVirtualizationExtensions,OperationalStatus | FT -AutoSize

        Write-Host "Checking for Memory issues:" -ForegroundColor Green
        $VMMemory = $VM | Get-VMMemory
        $VMMemory | Select-Object VMName,DynamicMemoryEnabled,Startup, Minimum,Maximum | FT -AutoSize
    }
}
