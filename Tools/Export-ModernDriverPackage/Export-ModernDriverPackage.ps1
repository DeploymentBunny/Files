<#
 # This script exports drivers from the machine you are running on, stores them in a folder and create a .CSV file that can be used to
 # import custom driver package for the Modern Driver Managment tool. http://www.scconfigmgr.com/modern-driver-management/
#>

Function Export-TSxWindowsDriver {
    Param(
        $Path,
        $Platform,
        $WindowsVersion,
        $Architecture,
        $Version
    )
    #ExportDriver
    $Make = (Get-WmiObject -Class Win32_Computersystem).Manufacturer
    switch ($Make)
    {
        'HP'{
            $MakeAlias='Hewlett-Packard'
            $ModelAlias = (Get-WmiObject -Class Win32_ComputerSystem).model
            $BaseBoard = (Get-CIMInstance -ClassName MS_SystemInformation -NameSpace root\WMI).BaseBoardProduct
        }
    
        'Hewlett-Packard'{
            $MakeAlias=$Make
            $ModelAlias = (Get-WmiObject -Class Win32_ComputerSystem).model
            $BaseBoard = (Get-CIMInstance -ClassName MS_SystemInformation -NameSpace root\WMI).BaseBoardProduct
        }
    
        'LENOVO'{
            $MakeAlias=$Make
            $ModelAlias = (Get-WmiObject -Class Win32_ComputerSystemProduct).version
            $BaseBoard = ((Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty Model).SubString(0, 4)).Trim()
        }

        'Microsoft Corporation'{
            $MakeAlias='Microsoft'
            $ModelAlias = (Get-WmiObject -Class Win32_ComputerSystem).model
            $BaseBoard = (Get-WmiObject -Class Win32_ComputerSystem).model
        }
        Default {}
    }

    New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop
    New-Item -Path $Path\$MakeAlias -ItemType Directory -Force -ErrorAction Stop
    New-Item -Path $Path\$MakeAlias\$ModelAlias -ItemType Directory -Force -ErrorAction Stop
    if((Test-Path -Path $Path) -ne $true){"Unable to access exportpath"}
    
    Export-WindowsDriver -Online -Destination $Path\$MakeAlias\$ModelAlias
    $items = Get-ChildItem -Path $Path\$MakeAlias\$ModelAlias -Filter PRN*
    foreach ($item in $items){
        Remove-Item -Path $item.fullname -Recurse -Force
    }

    $SourceDirectory = "$Path\$MakeAlias\$ModelAlias"
    Set-Content -Path $("$Path\$MakeAlias\$ModelAlias.csv") -Value "Make,Model,Baseboard,Platform,Operating System,Architecture,Version,Source Directory"
    Add-Content -Path $("$Path\$MakeAlias\$ModelAlias.csv") -Value "$MakeAlias,$ModelAlias,$BaseBoard,$Platform,$WindowsVersion,$Architecture,$Version,$SourceDirectory"
}

Export-TSxWindowsDriver -Path \\SCCM\Drivers$\W101709 -Platform ConfigMgr -WindowsVersion "Windows 10" -Version '1.0' -Architecture x64
