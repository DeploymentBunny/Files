<#
.SYNOPSIS
Converts a WIM image to a bootable virtual disk.

.DESCRIPTION
Creates and partitions a new virtual disk (VHD/VHDX), applies a selected image
from a WIM file, and configures boot support based on the selected disk layout
(BIOS, UEFI, or COMBO).

The script can optionally:
- Copy an SxS source folder into the mounted image
- Enable optional Windows features (with SxS source)
- Add CAB packages from a folder
- Copy extra content into the image

The script requires local administrator privileges and the PAWUtility module
located under Functions\PAWUtility relative to this script.

.PARAMETER Sourcefile
Path to the source WIM file.

.PARAMETER DestinationFile
Path to the destination virtual disk file (for example, .vhdx).

.PARAMETER Disklayout
Partition and boot layout: UEFI, BIOS, or COMBO.
COMBO uses a layout that supports both BIOS and UEFI boot.

.PARAMETER Index
WIM image index to apply.

.PARAMETER SizeInMB
Virtual disk size in MB. For example, 120000 is approximately 120 GB.

.PARAMETER SXSFolderCopy
If specified, copies PathtoSXSFolder to the mounted image under Sources\SXS.

.PARAMETER PathtoSXSFolder
Path to a Side-by-Side (SxS) source folder.
Required when Features is specified.

.PARAMETER PathtoExtraFolder
If defined, this folder is copied into the mounted image under Tools.

.PARAMETER PathtoPackagesFolder
If defined, all .cab packages in this folder are added to the mounted image.

.PARAMETER Features
Array of optional Windows features to enable on the mounted image.
When this parameter is used, PathtoSXSFolder must also be specified.

.PARAMETER OSVersion
Used for legacy image handling when building W7 or W2K8R2 images
("w7", "w2k8r2").

.PARAMETER DISMExe
Optional path or command name for DISM.exe.

.PARAMETER VHDType
Virtual disk allocation type: EXPANDABLE or FIXED.

.PARAMETER RemoveOldVHD
If specified, removes an existing destination virtual disk before creating a new one.

.EXAMPLE
.\Convert-TSxWIM2VHD.ps1 -Sourcefile C:\IMF\TS001.WIM -DestinationFile C:\IMF\TS001.vhdx -Disklayout UEFI -Index 1 -SizeInMB 120000

.NOTES
    Requires:  Windows PowerShell 5.1 or later.
               Must be run as a local administrator.
               The PAWUtility module must be present under Functions\PAWUtility
               relative to this script (loaded automatically via Import-Module).
               DISM.exe (or a custom path supplied via -DISMExe) must be available.
               -Features requires -PathtoSXSFolder to be specified and the path must exist.
               -SXSFolderCopy requires -PathtoSXSFolder when the SXS content is needed.

    Author - Mikael Nystrom
    Twitter: @mikael_nystrom

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author.
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]
    $Sourcefile,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]
    $DestinationFile,

    [Parameter(Mandatory = $true)]
    [ValidateSet("BIOS", "UEFI", "COMBO")]
    [string]
    $Disklayout,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 999)]
    [int]
    $Index = 1,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1024, 4194304)]
    [int]
    $SizeInMB = 120000,

    [Parameter(Mandatory = $false)]
    [switch]
    $SXSFolderCopy,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]
    $PathtoSXSFolder,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]
    $PathtoExtraFolder,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]
    $PathtoPackagesFolder,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string[]]
    $Features,

    [Parameter(Mandatory = $false)]
    [ValidateSet("w7", "w2k8r2")]
    [string]
    $OSVersion,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]
    $DISMExe = "dism.exe",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [ValidateSet('EXPANDABLE', 'FIXED')]
    [string]
    $VHDType = 'EXPANDABLE',

    [switch]$RemoveOldVHD
)

if ($PSBoundParameters['Verbose']) {
    $VerbosePreference = "Continue"
}

Import-Module -Global $PSScriptRoot\Functions\PAWUtility -ErrorAction Stop -Force

if ($PSBoundParameters.ContainsKey('Features')) {
    if (-not $PSBoundParameters.ContainsKey('PathtoSXSFolder') -or [string]::IsNullOrWhiteSpace($PathtoSXSFolder)) {
        throw "-Features requires -PathtoSXSFolder to be specified."
    }

    if (-not (Test-Path -Path $PathtoSXSFolder)) {
        throw "-PathtoSXSFolder path '$PathtoSXSFolder' does not exist."
    }
}


if ((Test-Path -Path $Sourcefile) -ne $true) {
    Write-Warning "Unable to access $Sourcefile, exit"
    Return
}

if ((Test-Path -Path $DestinationFile) -eq $True -and ($RemoveOldVHD -eq $false)) {
    Write-Warning "$DestinationFile exists and -RemoveOldVHD is set to $RemoveOldVHD, unable to continute"
    Return
}

if ((Test-Path -Path $DestinationFile) -eq $True -and ($RemoveOldVHD -eq $True)) {
    Write-Warning "$DestinationFile exists and -RemoveOldVHD is set to $RemoveOldVHD, trying to remove"
    Remove-Item -Path $DestinationFile -Force -ErrorAction Stop
}

#Apply WIM to VHD(x)
Switch ($Disklayout) {
    BIOS {
        $VHDFile = $DestinationFile
        $Null = New-PAWVHD -VHDFile $VHDFile -VHDSizeinMB $SizeinMB -VHDType $VHDType
        $Null = Mount-DiskImage -ImagePath $VHDFile
        $VHDDisk = Get-DiskImage -ImagePath $VHDFile | Get-Disk
        $VHDDiskNumber = [string]$VHDDisk.Number
        Write-Verbose "Disknumber is now $VHDDiskNumber"

        # Format VHDx
        $Null = Initialize-Disk -Number $VHDDiskNumber -PartitionStyle MBR
        Write-Verbose "Initialize disk as MBR"
        $VHDDrive = New-Partition -DiskNumber $VHDDiskNumber -UseMaximumSize -IsActive
        $Null = $VHDDrive | Format-Volume -FileSystem NTFS -NewFileSystemLabel OSDisk -Confirm:$false
        $Null = Add-PartitionAccessPath -DiskNumber $VHDDiskNumber -PartitionNumber $VHDDrive.PartitionNumber -AssignDriveLetter
        $VHDDrive = Get-Partition -DiskNumber $VHDDiskNumber -PartitionNumber $VHDDrive.PartitionNumber
        $VHDVolume = [string]$VHDDrive.DriveLetter + ":"
        Write-Verbose "OSDrive Driveletter is now = $VHDVolume"
        $VHDVolumeBoot = [string]$VHDDrive.DriveLetter + ":"
        Write-Verbose "OSBoot Driveletter is now = $VHDVolumeBoot"

        #Apply Image
        Start-Sleep -Seconds 5
        $Exe = $DISMExe
        $Arguments = " /apply-Image /ImageFile:""$SourceFile"" /index:$Index /ApplyDir:$VHDVolume\"
        # Invoke-PAWExe -Executable $Exe -Arguments $Arguments -SuccessfulReturnCode 0
        $Null = Expand-WindowsImage -ImagePath $SourceFile -ApplyPath $VHDVolume -Index $Index
    }
    UEFI {
        $VHDFile = $DestinationFile
        $Null = New-PAWVHD -VHDFile $VHDFile -VHDSizeinMB $SizeinMB -VHDType $VHDType
        $Null = Mount-DiskImage -ImagePath $VHDFile
        $VHDDisk = Get-DiskImage -ImagePath $VHDFile | Get-Disk
        $VHDDiskNumber = [string]$VHDDisk.Number
        Write-Verbose "Disknumber is now $VHDDiskNumber"

        # Format VHDx
        $Null = Initialize-Disk -Number $VHDDiskNumber -PartitionStyle GPT
        $VHDDrive1 = New-Partition -DiskNumber $VHDDiskNumber -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' -Size 499MB
        $Null = $VHDDrive1 | Format-Volume -FileSystem FAT32 -NewFileSystemLabel System -Confirm:$false
        $null = New-Partition -DiskNumber $VHDDiskNumber -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' -Size 128MB
        $VHDDrive3 = New-Partition -DiskNumber $VHDDiskNumber -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' -UseMaximumSize
        $Null = $VHDDrive3 | Format-Volume -FileSystem NTFS -NewFileSystemLabel OSDisk -Confirm:$false
        $Null = Add-PartitionAccessPath -DiskNumber $VHDDiskNumber -PartitionNumber $VHDDrive1.PartitionNumber -AssignDriveLetter
        $Null = $VHDDrive1 = Get-Partition -DiskNumber $VHDDiskNumber -PartitionNumber $VHDDrive1.PartitionNumber
        $Null = Add-PartitionAccessPath -DiskNumber $VHDDiskNumber -PartitionNumber $VHDDrive3.PartitionNumber -AssignDriveLetter
        $VHDDrive3 = Get-Partition -DiskNumber $VHDDiskNumber -PartitionNumber $VHDDrive3.PartitionNumber
        $VHDVolume = [string]$VHDDrive3.DriveLetter + ":"
        Write-Verbose "OSDrive Driveletter is now = $VHDVolume"
        $VHDVolumeBoot = [string]$VHDDrive1.DriveLetter + ":"
        Write-Verbose "OSBoot Driveletter is now = $VHDVolumeBoot"

        #Apply Image
        Start-Sleep -Seconds 5
        $Exe = $DISMExe
        $Arguments = " /apply-Image /ImageFile:""$SourceFile"" /index:$Index /ApplyDir:$VHDVolume\"
        #Invoke-PAWExe -Executable $Exe -Arguments $Arguments -SuccessfulReturnCode 0
        $Null = Expand-WindowsImage -ImagePath $SourceFile -ApplyPath $VHDVolume -Index $Index
    }
    COMBO {
        $VHDFile = $DestinationFile
        $Null = New-PAWVHD -VHDFile $VHDFile -VHDSizeinMB $SizeinMB -VHDType $VHDType
        $Null = Mount-DiskImage -ImagePath $VHDFile
        $VHDDisk = Get-DiskImage -ImagePath $VHDFile | Get-Disk
        $VHDDiskNumber = [string]$VHDDisk.Number
        Write-Verbose "Disknumber is now $VHDDiskNumber"

        # Format VHDx
        $Null = Initialize-Disk -Number $VHDDiskNumber -PartitionStyle MBR
        Write-Verbose "Initialize disk as MBR"
        $VHDDrive1 = New-Partition -DiskNumber $VHDDiskNumber -Size 499MB -IsActive
        $Null = $VHDDrive1 | Format-Volume -FileSystem FAT32 -NewFileSystemLabel BootDisk -Confirm:$false
        $VHDDrive3 = New-Partition -DiskNumber $VHDDiskNumber -UseMaximumSize
        $Null = $VHDDrive3 | Format-Volume -FileSystem NTFS -NewFileSystemLabel OSDisk -Confirm:$false
        $Null = Add-PartitionAccessPath -DiskNumber $VHDDiskNumber -PartitionNumber $VHDDrive1.PartitionNumber -AssignDriveLetter
        $VHDDrive1 = Get-Partition -DiskNumber $VHDDiskNumber -PartitionNumber $VHDDrive1.PartitionNumber
        $Null = Add-PartitionAccessPath -DiskNumber $VHDDiskNumber -PartitionNumber $VHDDrive3.PartitionNumber -AssignDriveLetter
        $VHDDrive3 = Get-Partition -DiskNumber $VHDDiskNumber -PartitionNumber $VHDDrive3.PartitionNumber
        $VHDVolume = [string]$VHDDrive3.DriveLetter + ":"
        $VHDVolumeBoot = [string]$VHDDrive1.DriveLetter + ":"
        Write-Verbose "OSDrive Driveletter is now = $VHDVolume"

        #Apply Image
        Start-Sleep -Seconds 5
        $Exe = $DISMExe
        $Arguments = " /apply-Image /ImageFile:""$SourceFile"" /index:$Index /ApplyDir:$VHDVolume\"
        # Invoke-PAWExe -Executable $Exe -Arguments $Arguments -SuccessfulReturnCode 0
        $Null = Expand-WindowsImage -ImagePath $SourceFile -ApplyPath $VHDVolume -Index $Index
    }
}

#Apply BCD to VHD(x)
Switch ($Disklayout) {
    BIOS {
        Switch ($OSVersion) {
            W7 {
                # Apply BootFiles
                $Exe = "bcdboot"
                $Arguments = "$VHDVolume\Windows /s $VHDVolume"
                $Null = Invoke-PAWExe -Executable $Exe -Arguments $Arguments
            }
            W2K8R2 {
                # Apply BootFiles
                $Exe = "bcdboot.exe"
                $Arguments = "$VHDVolume\Windows /s $VHDVolume"
                $Null = Invoke-PAWExe -Executable $Exe -Arguments $Arguments
            }
            Default {
                # Apply BootFiles
                Write-Verbose "Creating the BCD"
                $Exe = "bcdboot.exe"
                $Arguments = "$VHDVolume\Windows /s $VHDVolume /f BIOS"
                $Null = Invoke-PAWExe -Executable $Exe -Arguments $Arguments

                Write-Verbose "Fixing the BCD store on $($VHDVolumeBoot) for VMM"
                $Exe = "bcdedit.exe"
                $Arguments = "/store $($VHDVolumeBoot)boot\bcd /set `{bootmgr`} device locate"
                $Null = Invoke-PAWExe -Executable $Exe -Arguments $Arguments

                $Exe = "bcdedit.exe"
                $Arguments = "/store $($VHDVolumeBoot)boot\bcd /set `{default`} device locate"
                $Null = Invoke-PAWExe -Executable $Exe -Arguments $Arguments

                $Exe = "bcdedit.exe"
                $Arguments = "/store $($VHDVolumeBoot)boot\bcd /set `{default`} osdevice locate"
                $Null = Invoke-PAWExe -Executable $Exe -Arguments $Arguments
            }
        }
    }
    UEFI {
        # Apply BootFiles
        $Exe = "bcdboot"
        $Arguments = "$VHDVolume\Windows /s $VHDVolumeBoot /f UEFI"
        $Null = Invoke-PAWExe -Executable $Exe -Arguments $Arguments

        # Change ID on FAT32 Partition, since we cannot assign the correct ID at creationtime depending on a "feature" in Windows
        $DiskPartTextFile = New-Item "diskpart.txt" -type File -Force
        $Null = Set-Content $DiskPartTextFile "select disk $VHDDiskNumber"
        $Null = Add-Content $DiskPartTextFile "Select Partition 2" -Verbose
        $Null = Add-Content $DiskPartTextFile "Set ID=c12a7328-f81f-11d2-ba4b-00a0c93ec93b OVERRIDE"
        $Null = Add-Content $DiskPartTextFile "GPT Attributes=0x8000000000000000"
        $Exe = "diskpart.exe"
        $Arguments = "/s $DiskPartTextFile"
        $Null = Invoke-PAWExe -Executable $Exe -Arguments $Arguments
    }
    COMBO {
        # Apply BootFiles
        Write-Verbose "Creating the BCD"
        $Exe = "bcdboot.exe"
        $Arguments = "$VHDVolume\Windows /s $VHDVolumeBoot /f ALL"
        Invoke-PAWExe -Executable $Exe -Arguments $Arguments

        Write-Verbose "Fixing the BCD store on $($VHDVolumeBoot) for VMM"
        $Exe = "bcdedit.exe"
        $Arguments = "/store $($VHDVolumeBoot)boot\bcd /set `{bootmgr`} device locate"
        Invoke-PAWExe -Executable $Exe -Arguments $Arguments

        $Exe = "bcdedit.exe"
        $Arguments = "/store $($VHDVolumeBoot)boot\bcd /set `{default`} device locate"
        Invoke-PAWExe -Executable $Exe -Arguments $Arguments

        $Exe = "bcdedit.exe"
        $Arguments = "/store $($VHDVolumeBoot)boot\bcd /set `{default`} osdevice locate"
        Invoke-PAWExe -Executable $Exe -Arguments $Arguments
    }
}

#Copy SXS Folders to VHD(X)
If ($SXSFolderCopy) {
    If ($PathtoSXSFolder -like '') {
        Write-Verbose "No SXS folder specified"
    }
    elseif (-not (Test-Path -Path $PathtoSXSFolder)) {
        Write-Warning "$PathtoSXSFolder does not exist!"
    }
    else {
        Write-Verbose "Execute Copy-Item $PathtoSXSFolder $VHDVolume\Sources\SXS -Force -Recurse"
        $Null = Copy-Item $PathtoSXSFolder $VHDVolume\Sources\SXS -Force -Recurse
    }
}

#Copy Extra Folders to VHD(X)
If ($PathtoExtraFolder -like '') {
    Write-Verbose "No Extra folder specified"
}
else {
    if (Test-Path $PathtoExtraFolder) {
        Write-Verbose "Execute Copy-Item $PathtoExtraFolder $VHDVolume\Tools -Force -Recurse"
        $Null = Copy-Item $PathtoExtraFolder $VHDVolume\Tools -Force -Recurse
    }
    else {
        Write-Warning "$PathtoExtraFolder does not exist!"
    }
}

#Enable features
If ($Features) {
    Foreach ($Feature in $Features) {
        # $Null = Enable-WindowsOptionalFeature -FeatureName $Feature -Source $PathtoSXSFolder -Path $VHDVolume -All -LimitAccess
        $Exe = $DISMExe
        $Arguments = "/Image:$VHDVolume /Enable-Feature /FeatureName:$Feature /All /Source:$PathtoSXSFolder /LimitAccess"
        $Null = Invoke-PAWExe -Executable $Exe -Arguments $Arguments
    }
}

#Apply packges to VHD(X)
If ($PathtoPackagesFolder -like '') {
    Write-Verbose "No Packages folder specified"
}
else {
    if (Test-Path $PathtoPackagesFolder) {
        Write-Verbose "Searching for packages"
        $Packges = Get-Childitem -Path $PathtoPackagesFolder -Filter *.cab
        foreach ($Packge in $Packges) {
            $Null = Add-WindowsPackage -Path $VHDVolume -PackagePath $Packge.Fullname
        }
    }
    else {
        Write-Warning "$PathtoPackagesFolder does not exist!"
    }
}

# Dismount VHDX
$Null = Dismount-DiskImage -ImagePath $VHDFile
Return $VHDFile
