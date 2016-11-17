#Add Computer to the MDT Database 1.0
Param(
    [Parameter(Mandatory=$true,ValueFromPipeline=$true)] 
    [ValidateLength(3,16)]
    [ValidatePattern('[A-Z][0-9]')]
    [String]$ComputerName,
 
    [Parameter(Mandatory=$true,ValueFromPipeline=$true)] 
    [ValidateSet('Standard_PC','RnD','Admin_Workstation')] 
    [String]$Role,
 
    [Parameter(Mandatory=$true,ValueFromPipeline=$true)] 
    [ValidatePattern('^([0-9a-fA-F]{2}[:-]{0,1}){5}[0-9a-fA-F]{2}$')]
    [String]$MacAddress,
 
    [Switch]$Force
)
 
#Import the Modules and connect to the database
#Note: You need to have the MDTDB PowerShell module installed as well as the Active Directory module to be able to access the data.
#
Import-Module MDTDB -ErrorAction Stop
Import-Module ActiveDirectory -ErrorAction Stop
Connect-MDTDatabase -sqlServer MDT01 -database MDT01 -instance SQLExpress -ErrorAction stop
 
#Create function for check AD if name exists
Function CheckIfComputerInADExists{
    Param(
        $ComputerName
    )
    try {
        $Null = Get-ADComputer $ComputerName
        Return $True
    }
    Catch {
        Return $False
    }
}
 
#Create function for check MDT DB if name exists
Function CheckIfComputerInMDTExists{
    Param(
        $ComputerName
    )
    $result = Get-MDTComputer | Where-Object -Property OSDComputerName -EQ -Value $ComputerName
    if($result -ne $null){Return $True}else{$False}
}
 
#Create function for check MDT DB if MAC exists
Function CheckIfMacAddressInMDTExists{
    Param(
        $MacAddress
    )
    $result = Get-MDTComputer -macAddress $MacAddress
    if($result -ne $null){Return $True}else{$False}
}
 
#Check if Computer exists in Active Directory
$CheckAD = CheckIfComputerInADExists -ComputerName $ComputerName
if($CheckAD -eq $true){
    Write-Warning "$ComputerName exists in Active Directory"
    if(!($Force)){BREAK}
    }else{Write-Host "AD Name check OK"}
 
#Check if Computer exists in the MDT database
$CheckMDT = CheckIfComputerInMDTExists -ComputerName $ComputerName
if($CheckMDT -eq $true){
    Write-Warning "$ComputerName exists in the MDT database"
    if(!($Force)){BREAK}
    }else{Write-Host "MDT name check OK"}
 
#Check if MacAddress exists in the MDT database
$CheckMAC = CheckIfMacAddressInMDTExists -MacAddress $MacAddress
if($CheckMAC -eq $true){
    Write-Warning "$MacAddress exists in the MDT database"
    if(!($Force)){BREAK}
    }else{Write-Host "MDT macaddress check OK"}
 
#Create array for all settings the computer should have
$Settings = @{
OSInstall='YES';
OSDComputerName="$ComputerName"
}
 
#If computer name exists and we used the -Force switch, remove it
if($CheckMDT -eq $true){
    Get-MDTComputer -description $ComputerName | Remove-MDTComputer
    }
 
#If MacAddress exists and we used the -Force switch, remove it
if($CheckMAC -eq $true){
    Get-MDTComputer -macAddress $MacAddress | Remove-MDTComputer
    }
 
#Create Computer in MDT Database
$NewMDTComputer = New-MDTComputer -macAddress $MacAddress -description $ComputerName -settings $Settings
 
#Add role to Computer in MDT Database
$NewMDTComputer | Set-MDTComputerRole -roles $Role
