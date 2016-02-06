Param(
    [Parameter(mandatory=$True,HelpMessage="Name and path of Sourcefile.")]
    [ValidateNotNullOrEmpty()]
    [String]
    [ValidateScript({Test-Path $_})] 
    $SourceFile,

    [parameter(mandatory=$True,HelpMessage="Name and path of VHD(x) file.")]
    [ValidateNotNullOrEmpty()]
    [String]
    $DestinationFile,

    [parameter(mandatory=$True,HelpMessage="BIOS or UEFI based disk layout")]
    [ValidateSet("BIOS","UEFI","COMBO")]
    [String]
    $Disklayout,

    [parameter(mandatory=$True)]
    [ValidateNotNullOrEmpty()]
    [String]
    $Index = "1",

    [parameter(mandatory=$True)]
    [ValidateNotNullOrEmpty()]
    [String]
    $SizeInMB = "60000",

    [parameter(mandatory=$False)]
    [ValidateNotNullOrEmpty()]
    [Switch]
    $SXSFolderCopy,

    [parameter(mandatory=$False)]
    [ValidateNotNullOrEmpty()]
    [String]
    $PathtoSXSFolder,

    [parameter(mandatory=$False)]
    [ValidateNotNullOrEmpty()]
    [String]
    $PathtoExtraFolder,

    [parameter(mandatory=$False)]
    [ValidateNotNullOrEmpty()]
    [String]
    $PathtoPatchFolder,

    [parameter(mandatory=$False)]
    [ValidateNotNullOrEmpty()]
    [String]
    $PathtoPackagesFolder,

    [Parameter(mandatory=$False)]
    [ValidateNotNullOrEmpty()]
    [Array]
    $Features,

    [parameter(mandatory=$False)]
    [ValidateSet("w7","w2k8r2")]
    [String]
    $OSVersion,

    [parameter(mandatory=$False)]
    [ValidateNotNullOrEmpty()]
    [String]
    $DISMExe = "dism.exe"
)
Function Invoke-Exe{
    [CmdletBinding(SupportsShouldProcess=$true)]

    param(
        [parameter(mandatory=$true,position=0)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Executable,

        [parameter(mandatory=$true,position=1)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Arguments,

        [parameter(mandatory=$false,position=2)]
        [ValidateNotNullOrEmpty()]
        [int]
        $SuccessfulReturnCode = 0
    )

    Write-Verbose "Running $ReturnFromEXE = Start-Process -FilePath $Executable -ArgumentList $Arguments -NoNewWindow -Wait -Passthru"
    $ReturnFromEXE = Start-Process -FilePath $Executable -ArgumentList $Arguments -NoNewWindow -Wait -Passthru

    Write-Verbose "Returncode is $($ReturnFromEXE.ExitCode)"

    if(!($ReturnFromEXE.ExitCode -eq $SuccessfulReturnCode)) {
        throw "$Executable failed with code $($ReturnFromEXE.ExitCode)"
    }
}
Function New-FAVHD{
    [CmdletBinding(SupportsShouldProcess=$true)]

    Param(
    [Parameter(Position=0)]
    [ValidateNotNullOrEmpty()]
    [string]
    $VHDFile,

    [Parameter(Position=1)]
    [ValidateNotNullOrEmpty()]
    [string]
    $VHDSizeinMB,

    [Parameter(Position=2)]
    [ValidateNotNullOrEmpty()]
    [ValidateSet('EXPANDABLE','FIXED')]
    [string]
    $VHDType
    )

    if(!(Test-Path -Path ($VHDFile | Split-Path -Parent))){
        throw "Folder does not exists..."}
    
    #Check if file exists
    if(Test-Path -Path $VHDFile){
        throw "File exists..."}

    $diskpartcmd = New-Item -Path $env:TEMP\diskpartcmd.txt -ItemType File -Force
    Set-Content -Path $diskpartcmd -Value "CREATE VDISK FILE=""$VHDFile"" MAXIMUM=$VHDSizeinMB TYPE=$VHDType"
    $Exe = "DiskPart.exe"
    $Args = "-s $($diskpartcmd.FullName)"
    Invoke-Exe -Executable $Exe -Arguments $Args -SuccessfulReturnCode 0
    Remove-Item $diskpartcmd -Force -ErrorAction SilentlyContinue
}

#Apply WIM to VHD(x)
Switch ($Disklayout){
    BIOS{
        $VHDFile = $DestinationFile
        New-FAVHD -VHDFile $VHDFile -VHDSizeinMB $SizeinMB -VHDType EXPANDABLE
        Mount-DiskImage -ImagePath $VHDFile
        $VHDDisk = Get-DiskImage -ImagePath $VHDFile | Get-Disk
        $VHDDiskNumber = [string]$VHDDisk.Number
        Write-Verbose "Disknumber is now $VHDDiskNumber"

        # Format VHDx
        Initialize-Disk -Number $VHDDiskNumber -PartitionStyle MBR
        Write-Verbose "Initialize disk as MBR"
        $VHDDrive = New-Partition -DiskNumber $VHDDiskNumber -UseMaximumSize -IsActive
        $VHDDrive | Format-Volume -FileSystem NTFS -NewFileSystemLabel OSDisk -Confirm:$false
        Add-PartitionAccessPath -DiskNumber $VHDDiskNumber -PartitionNumber $VHDDrive.PartitionNumber -AssignDriveLetter
        $VHDDrive = Get-Partition -DiskNumber $VHDDiskNumber -PartitionNumber $VHDDrive.PartitionNumber
        $VHDVolume = [string]$VHDDrive.DriveLetter+":"
        Write-Verbose "OSDrive Driveletter is now = $VHDVolume"
        $VHDVolumeBoot = [string]$VHDDrive.DriveLetter+":"
        Write-Verbose "OSBoot Driveletter is now = $VHDVolumeBoot"

        #Apply Image
        sleep 5
        $Exe = $DISMExe
        $Args = " /apply-Image /ImageFile:$SourceFile /index:$Index /ApplyDir:$VHDVolume\"
        Invoke-Exe -Executable $Exe -Arguments $Args -SuccessfulReturnCode 0 -Verbose
    }
    UEFI{
        $VHDFile = $DestinationFile
        New-FAVHD -VHDFile $VHDFile -VHDSizeinMB $SizeinMB -VHDType EXPANDABLE
        Mount-DiskImage -ImagePath $VHDFile
        $VHDDisk = Get-DiskImage -ImagePath $VHDFile | Get-Disk
        $VHDDiskNumber = [string]$VHDDisk.Number
        Write-Verbose "Disknumber is now $VHDDiskNumber"

        # Format VHDx
        Initialize-Disk -Number $VHDDiskNumber –PartitionStyle GPT
        $VHDDrive1 = New-Partition -DiskNumber $VHDDiskNumber -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' -Size 499MB 
        $VHDDrive1 | Format-Volume -FileSystem FAT32 -NewFileSystemLabel System -Confirm:$false -Verbose
        $VHDDrive2 = New-Partition -DiskNumber $VHDDiskNumber -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' -Size 128MB
        $VHDDrive3 = New-Partition -DiskNumber $VHDDiskNumber -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' -UseMaximumSize
        $VHDDrive3 | Format-Volume -FileSystem NTFS -NewFileSystemLabel OSDisk -Confirm:$false
        Add-PartitionAccessPath -DiskNumber $VHDDiskNumber -PartitionNumber $VHDDrive1.PartitionNumber -AssignDriveLetter
        $VHDDrive1 = Get-Partition -DiskNumber $VHDDiskNumber -PartitionNumber $VHDDrive1.PartitionNumber
        Add-PartitionAccessPath -DiskNumber $VHDDiskNumber -PartitionNumber $VHDDrive3.PartitionNumber -AssignDriveLetter
        $VHDDrive3 = Get-Partition -DiskNumber $VHDDiskNumber -PartitionNumber $VHDDrive3.PartitionNumber
        $VHDVolume = [string]$VHDDrive3.DriveLetter+":"
        Write-Verbose "OSDrive Driveletter is now = $VHDVolume"
        $VHDVolumeBoot = [string]$VHDDrive1.DriveLetter+":"
        Write-Verbose "OSBoot Driveletter is now = $VHDVolumeBoot"

        #Apply Image
        sleep 5
        $Exe = $DISMExe
        $Args = " /apply-Image /ImageFile:$SourceFile /index:$Index /ApplyDir:$VHDVolume\"
        Invoke-Exe -Executable $Exe -Arguments $Args -SuccessfulReturnCode 0 -Verbose
    }
    COMBO{
        $VHDFile = $DestinationFile
        New-FAVHD -VHDFile $VHDFile -VHDSizeinMB $SizeinMB -VHDType EXPANDABLE
        Mount-DiskImage -ImagePath $VHDFile
        $VHDDisk = Get-DiskImage -ImagePath $VHDFile | Get-Disk
        $VHDDiskNumber = [string]$VHDDisk.Number
        Write-Verbose "Disknumber is now $VHDDiskNumber"

        # Format VHDx
        Initialize-Disk -Number $VHDDiskNumber -PartitionStyle MBR
        Write-Verbose "Initialize disk as MBR"
        $VHDDrive1 = New-Partition -DiskNumber $VHDDiskNumber -Size 499MB -IsActive
        $VHDDrive1 | Format-Volume -FileSystem FAT32 -NewFileSystemLabel BootDisk -Confirm:$false
        $VHDDrive3 = New-Partition -DiskNumber $VHDDiskNumber -UseMaximumSize
        $VHDDrive3 | Format-Volume -FileSystem NTFS -NewFileSystemLabel OSDisk -Confirm:$false
        Add-PartitionAccessPath -DiskNumber $VHDDiskNumber -PartitionNumber $VHDDrive1.PartitionNumber -AssignDriveLetter
        $VHDDrive1 = Get-Partition -DiskNumber $VHDDiskNumber -PartitionNumber $VHDDrive1.PartitionNumber
        Add-PartitionAccessPath -DiskNumber $VHDDiskNumber -PartitionNumber $VHDDrive3.PartitionNumber -AssignDriveLetter
        $VHDDrive3 = Get-Partition -DiskNumber $VHDDiskNumber -PartitionNumber $VHDDrive3.PartitionNumber
        $VHDVolume = [string]$VHDDrive3.DriveLetter+":"
        $VHDVolumeBoot = [string]$VHDDrive1.DriveLetter+":"
        Write-Verbose "OSDrive Driveletter is now = $VHDVolume"

        #Apply Image
        sleep 5
        $Exe = $DISMExe
        $Args = " /apply-Image /ImageFile:$SourceFile /index:$Index /ApplyDir:$VHDVolume\"
        Invoke-Exe -Executable $Exe -Arguments $Args -SuccessfulReturnCode 0 -Verbose    }
}

#Apply BCD to VHD(x)
Switch ($Disklayout){
    BIOS{
        Switch ($OSVersion){
            W7{
                # Apply BootFiles
                $Exe = "bcdboot"
                $Args = "$VHDVolume\Windows /s $VHDVolume"
                Invoke-Exe -Executable $Exe -Arguments $Args
            }
            WS2K8R2{
                # Apply BootFiles
                $Exe = "bcdboot.exe"
                $Args = "$VHDVolume\Windows /s $VHDVolume"
                Invoke-Exe -Executable $Exe -Arguments $Args
            }
            Default{
                # Apply BootFiles
                Write-Verbose "Creating the BCD"
                $Exe = "bcdboot.exe"
                $Args = "$VHDVolume\Windows /s $VHDVolume /f BIOS"
                Invoke-Exe -Executable $Exe -Arguments $Args

                Write-Verbose "Fixing the BCD store on $($VHDVolumeBoot) for VMM"
                $Exe = "bcdedit.exe"
                $Args = "/store $($VHDVolumeBoot)boot\bcd /set `{bootmgr`} device locate"
                Invoke-Exe -Executable $Exe -Arguments $Args
                
                $Exe = "bcdedit.exe"
                $Args = "/store $($VHDVolumeBoot)boot\bcd /set `{default`} device locate"
                Invoke-Exe -Executable $Exe -Arguments $Args

                $Exe = "bcdedit.exe"
                $Args = "/store $($VHDVolumeBoot)boot\bcd /set `{default`} osdevice locate"
                Invoke-Exe -Executable $Exe -Arguments $Args
            }
        }
    }
    UEFI{
        # Apply BootFiles
        $Exe = "bcdboot"
        $Args = "$VHDVolume\Windows /s $VHDVolumeBoot /f UEFI"
        Invoke-Exe -Executable $Exe -Arguments $Args

        # Change ID on FAT32 Partition, since we cannot assign the correct ID at creationtime depending on a "feature" in Windows
        $DiskPartTextFile = New-Item "diskpart.txt" -type File -Force
        Set-Content $DiskPartTextFile "select disk $VHDDiskNumber"
        Add-Content $DiskPartTextFile "Select Partition 2" -Verbose
        Add-Content $DiskPartTextFile "Set ID=c12a7328-f81f-11d2-ba4b-00a0c93ec93b OVERRIDE"
        Add-Content $DiskPartTextFile "GPT Attributes=0x8000000000000000"
        $DiskPartTextFile
        $Exe = "diskpart.exe"
        $Args = "/s $DiskPartTextFile"
        Invoke-Exe -Executable $Exe -Arguments $Args
    }
    COMBO{
        # Apply BootFiles
        Write-Verbose "Creating the BCD"
        $Exe = "bcdboot.exe"
        $Args = "$VHDVolume\Windows /s $VHDVolumeBoot /f ALL"
        Invoke-Exe -Executable $Exe -Arguments $Args
        
        Write-Verbose "Fixing the BCD store on $($VHDVolumeBoot) for VMM"
        $Exe = "bcdedit.exe"
        $Args = "/store $($VHDVolumeBoot)boot\bcd /set `{bootmgr`} device locate"
        Invoke-Exe -Executable $Exe -Arguments $Args
                
        $Exe = "bcdedit.exe"
        $Args = "/store $($VHDVolumeBoot)boot\bcd /set `{default`} device locate"
        Invoke-Exe -Executable $Exe -Arguments $Args

        $Exe = "bcdedit.exe"
        $Args = "/store $($VHDVolumeBoot)boot\bcd /set `{default`} osdevice locate"
        Invoke-Exe -Executable $Exe -Arguments $Args
    }
}

#Copy SXS Folders to VHD(X) 
If($SXSFolderCopy){
    If ($PathtoSXSFolder -like '') {
        Write-Verbose "No SXS folder specified"
        }
        else
        {
        Write-Verbose "Execute Copy-Item $PathtoSXSFolder $VHDVolume\Sources\SXS -Force -Recurse"
        Copy-Item $PathtoSXSFolder $VHDVolume\Sources\SXS -Force -Recurse
    }
}

#Apply patches to VHD(X) 
#Not Enabled
If ($PathtoPatchFolder -like '')
    {
        Write-Verbose "No Patch folder specified"
    }
    else
    {
        if(Test-Path $PathtoPatchFolder)
        {
            Write-Warning "Not implemented"
        }
        else
        {
            Write-Warning "$PathtoPatchFolder does not exist!"
        }
}

#Copy Extra Folders to VHD(X) 
If ($PathtoExtraFolder -like '')
    {
        Write-Verbose "No Extra folder specified"
    }
    else
    {
        if(Test-Path $PathtoExtraFolder){
            Write-Verbose "Execute Copy-Item $PathtoExtraFolder $VHDVolume\Tools -Force -Recurse"
            Copy-Item $PathtoExtraFolder $VHDVolume\Tools -Force -Recurse
    }
    else
    {
        Write-Warning "$PathtoExtraFolder does not exist!"
    }
}

#Enable features 
If($Features){
    Foreach($Feature in $Features){
        Enable-WindowsOptionalFeature -FeatureName $Feature -Source $PathtoSXSFolder -Path $VHDVolume -All
    }
}

#Apply packges to VHD(X) 
If ($PathtoPackagesFolder -like '')
    {
        Write-Verbose "No Packages folder specified"
    }
    else
    {
        if(Test-Path $PathtoPackagesFolder){
            Write-Verbose "Searching for packages"
            $Packges = Get-Childitem -Path $PathtoPackagesFolder -Filter *.cab
                foreach ($Packge in $Packges)
                {
                    Add-WindowsPackage –Path $VHDVolume –PackagePath $Packge.Fullname

                }

    }
    else
    {
        Write-Warning "$PathtoPatchFolder does not exist!"
    }
}


# Dismount VHDX
Dismount-DiskImage -ImagePath $VHDFile
Return $VHDFile