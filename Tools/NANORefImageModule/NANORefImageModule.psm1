Function New-VIARefImageNANO
{
    #Create Ref Image for NANO
    [CmdletBinding(SupportsShouldProcess=$true)]
    Param(
        $ISOImageFile = 'C:\Setup\ISO\WS2016_EVAL.iso',
        $WimIndex = '2',
        $PackagesFolder = "C:\Setup\Packages\WS2016",
        $WimFileSource = 'C:\Setup\WIM\NanoServer.wim',
        $WimFileDestination = 'C:\Setup\WIM\NanoServerU.wim',
        $WIMMountFolder = 'C:\Mount'
    )

    #Mount the ISO and get the driveletter
    $MountDiskImageResult = Mount-DiskImage -ImagePath $ISOImageFile -PassThru
    $ISODrive = ($MountDiskImageResult | Get-Volume).DriveLetter
    Write-Verbose "ISO is mounted on $ISODrive"

    #Get the WimFile and dismount ISO
    $Wimfile = "$($ISODrive):\NanoServer\NanoServer.wim"
    Write-Verbose "WIMFile is $Wimfile"
    if((Test-Path $Wimfile) -eq $false){Write-Warning "Could not access $Wimfile, will break";BREAK}
    Copy-Item -Path $Wimfile -Destination $WimFileSource -Force
    Set-ItemProperty -Path $WimFileSource -Name IsReadOnly -Value $false
    Copy-Item -Path $WimFileSource -Destination $WimFileDestination -Force
    #Get-WindowsImage -ImagePath $Wimfile
    Dismount-DiskImage -ImagePath $MountDiskImageResult.ImagePath

    #Patch the image
    Mount-WindowsImage -ImagePath $WimFileDestination -Path $WIMMountFolder -Index $WimIndex
    $Packages = Get-ChildItem -Path $PackagesFolder -Verbose
    foreach($Item in $Packages){
        Add-WindowsPackage -PackagePath $Item.fullname -Path $WIMMountFolder -Verbose
    }
    Dismount-WindowsImage -Path $WIMMountFolder -Save
}
Function Add-VIARefImageNANOFeatures
{
    #Create Ref Image for NANO
    [CmdletBinding(SupportsShouldProcess=$true)]
    Param(
        $ISOImageFile = 'C:\Setup\ISO\WS2016_EVAL.iso',
        $WimFile = 'C:\Setup\WIM\NanoServerU.wim',
        $WIMMountFolder = 'C:\Mount',
        $NanoPackages = 'C:\Setup\Packages\NANO',
        $FeatureSet,
        [switch]$VM
    )

    #Mount the ISO and get the driveletter
    $MountDiskImageResult = Mount-DiskImage -ImagePath $ISOImageFile -PassThru
    $ISODrive = ($MountDiskImageResult | Get-Volume).DriveLetter
    Write-Verbose "ISO is mounted on $ISODrive"

    #Get the WimFile and dismount ISO
    $NanoPackageFolder = "$($ISODrive):\NanoServer\Packages"
    if((Test-Path $NanoPackageFolder) -eq $false){Write-Warning "Could not access $NanoPackageFolder, will break";BREAK}
    Copy-Item -Path $NanoPackageFolder -Destination $NanoPackages -Force -Recurse
    Dismount-DiskImage -ImagePath $MountDiskImageResult.ImagePath

    #Add features
    Mount-WindowsImage -ImagePath $WimFile -Path $WIMMountFolder -Index 1
    switch ($FeatureSet)
    {
        'Compute' {
            Add-WindowsPackage -PackagePath $NanoPackages\Packages\Microsoft-NanoServer-Compute-Package.cab -Path $WIMMountFolder -Verbose
            Add-WindowsPackage -PackagePath $NanoPackages\Packages\en-us\Microsoft-NanoServer-Compute-Package_en-US.cab -Path $WIMMountFolder -Verbose
            Add-WindowsPackage -PackagePath $NanoPackages\Packages\Microsoft-NanoServer-Storage-Package.cab -Path $WIMMountFolder -Verbose
            Add-WindowsPackage -PackagePath $NanoPackages\Packages\en-us\Microsoft-NanoServer-Storage-Package_en-US.cab -Path $WIMMountFolder -Verbose
        }
        'Storage' {
            Add-WindowsPackage -PackagePath $NanoPackages\Packages\Microsoft-NanoServer-Compute-Package.cab -Path $WIMMountFolder -Verbose
            Add-WindowsPackage -PackagePath $NanoPackages\Packages\en-us\Microsoft-NanoServer-Compute-Package_en-US.cab -Path $WIMMountFolder -Verbose
            Add-WindowsPackage -PackagePath $NanoPackages\Packages\Microsoft-NanoServer-Storage-Package.cab -Path $WIMMountFolder -Verbose
            Add-WindowsPackage -PackagePath $NanoPackages\Packages\en-us\Microsoft-NanoServer-Storage-Package_en-US.cab -Path $WIMMountFolder -Verbose
        }
        Default {}
    }

    if($VM -eq $true){
        Write-Verbose "Adding support for running on Hyper-V"
        Add-WindowsPackage -PackagePath $NanoPackages\Packages\Microsoft-NanoServer-Guest-Package.cab -Path $WIMMountFolder -Verbose
        Add-WindowsPackage -PackagePath $NanoPackages\Packages\en-us\Microsoft-NanoServer-Guest-Package_en-US.cab -Path $WIMMountFolder -Verbose
    }
    Dismount-WindowsImage -Path $WIMMountFolder -Save
}
