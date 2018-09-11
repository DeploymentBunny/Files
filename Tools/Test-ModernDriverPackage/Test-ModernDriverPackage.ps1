<#
 # This script will get driver packages using the Modern Driver Managment WebServices on the machine you run it on
 # (http://www.scconfigmgr.com/modern-driver-management)
#>

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

    'Dell'{
        $MakeAlias=$Make
        $ModelAlias = (Get-WmiObject -Class Win32_ComputerSystem).model
        $BaseBoard = (Get-CIMInstance -ClassName MS_SystemInformation -NameSpace root\WMI).SystemSku
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

$MakeAlias
$ModelAlias
$BaseBoard

$SecrectKey = "329b3c28-1b52-4cd7-abe1-81d93d1e1dda" 
$URI = "http://cm01.corp.viamonstra.com/ConfigMgrWebService/ConfigMgr.asmx" 
$Web = New-WebServiceProxy -Uri $URI
$Web.
$result = $Web.GetCMPackage($SecrectKey,'Driver')
$result | Where-Object PackageDescription -Like *$BaseBoard*