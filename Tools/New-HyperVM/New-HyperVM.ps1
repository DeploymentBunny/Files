Param(
    [Parameter(mandatory=$True)]
    [ValidateNotNullOrEmpty()]
    [String]
    $VMName,

    [Parameter(mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    #[Int]
    $VMMem = 1GB,

    [Parameter(mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [int]
    $VMvCPU = 1,
    
    [parameter(mandatory=$True)]
    [ValidateNotNullOrEmpty()]
    [String]
    $VMLocation = "C:\VMs",

    [parameter(mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [String]
    $VHDFile,

    [parameter(mandatory=$True)]
    [ValidateSet("Copy","Diff","Empty")]
    [String]
    $DiskMode = "Copy",

    [parameter(mandatory=$True)]
    [ValidateNotNullOrEmpty()]
    [String]
    $VMSwitchName,

    [parameter(mandatory=$False)]
    [ValidateNotNullOrEmpty()]
    [Int]
    $VlanID,

    [parameter(mandatory=$False)]
    [ValidateSet("1","2")]
    [Int]
    $VMGeneration,

    [parameter(mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [String]
    $ISO
    
)

#Create VM 
$VM = New-VM -Name $VMName -MemoryStartupBytes $VMMem -Path $VMLocation -NoVHD -Generation $VMGeneration
Remove-VMNetworkAdapter -VM $VM

#Add Networkadapter
if($VMNetWorkType -eq "Legacy" -and $VMGeneration -eq "1")
    {
        Add-VMNetworkAdapter -VM $VM -SwitchName $VMSwitchName -IsLegacy $true
    }
else
    {
        Add-VMNetworkAdapter -VM $VM -SwitchName $VMSwitchName
    }

#Set vCPU
if($VMvCPU -ne "1")
    {
        Set-VMProcessor -Count $VMvCPU -VM $VM
    }

#Set VLAN
If($VlanID -ne $NULL){
    Set-VMNetworkAdapterVlan -VlanId $VlanID -Access -VM $VM
}

#Add Virtual Disk
switch ($DiskMode)
{
    Copy {
        New-Item "$VMLocation\$VMName\Virtual Hard Disks" -ItemType directory -Force
        $VHD = $VHDFile | Split-Path -Leaf
        Copy-Item $VHDFile -Destination "$VMLocation\$VMName\Virtual Hard Disks\"
        Add-VMHardDiskDrive -VM $VM -Path "$VMLocation\$VMName\Virtual Hard Disks\$VHD"
    }
    Diff {
        New-Item "$VMLocation\$VMName\Virtual Hard Disks" -ItemType directory -Force
        $VHD = $VHDFile | Split-Path -Leaf
        New-VHD -Path "$VMLocation\$VMName\Virtual Hard Disks\$VHD" -ParentPath $VHDFile -Differencing
        Add-VMHardDiskDrive -VMName $VMName -Path "$VMLocation\$VMName\Virtual Hard Disks\$VHD"
    }
    Empty{
        $VHD = $VMName + ".vhdx"
        New-VHD -Path "$VMLocation\$VMName\Virtual Hard Disks\$VHD" -SizeBytes 100GB -Dynamic
        Add-VMHardDiskDrive -VMName $VMName -Path "$VMLocation\$VMName\Virtual Hard Disks\$VHD"
    }
    Default {Write-Error "Epic Failure";BREAK}
}

#Add DVD for Gen2
#if($VMGeneration -ne "1"){Add-VMDvdDrive -VMName $VM -Path $NULL -ErrorAction SilentlyContinue}

#Mount ISO
if($ISO -ne ''){
    Set-VMDvdDrive -Path $ISO -VMName $VMName
    }

#Set Correct Bootorder when booting from VHD in Gen 2
if($VMGeneration -ne "1" -and $DiskMode -ne "Empty")
    {
        Set-VMFirmware -BootOrder (Get-VMHardDiskDrive -VM $VM) -VM $VM
    }

#Set Correct Bootorder when booting from ISO in Gen 2
if($VMGeneration -ne "1" -and $DiskMode -eq "Empty")
    {
        Set-VMFirmware -BootOrder (Get-VMDvdDrive -VMName $VMName) -VM $VM
    }

