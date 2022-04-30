Function New-WimReport{
<#
.Synopsis
    Get data from WIM file
.DESCRIPTION
    Created: 2015-11-25
    Version: 1.0

    Author : Mikael Nystrom
    Twitter: @mikael_nystrom
    Blog   : http://deploymentbunny.com

    Disclaimer: This script is provided "AS IS" with no warranties, confers no rights and 
    is not supported by the author.
.EXAMPLE
    New-WimReport -MountFolder C:\mount -WIMFile "E:\MDTBuildLab\Captures\REFWS2012R2-002.wim" -Index 1

.EXAMPLE
    $WimData = New-WimReport -MountFolder C:\mount -WIMFile "E:\MDTBuildLab\Captures\REFWS2012R2-002.wim" -Index 1
    $WimData > C:\test.txt
    Invoke-Item -Path C:\test.txt
#>
    [cmdletbinding()]
    Param(
    [parameter(mandatory=$True,ValueFromPipelineByPropertyName=$true,Position=0)]
    [ValidateNotNullOrEmpty()]
        $MountFolder,

    [parameter(mandatory=$True,ValueFromPipelineByPropertyName=$true,Position=1)]
    [ValidateNotNullOrEmpty()]
        $WIMFile,

    [parameter(mandatory=$False,ValueFromPipelineByPropertyName=$true,Position=2)]
    [ValidateNotNullOrEmpty()]
        $LogFile = "$env:TEMP\DISM.log",

    [parameter(mandatory=$True,ValueFromPipelineByPropertyName=$true,Position=3)]
    [ValidateNotNullOrEmpty()]
        $Index
    )
    #Check stuff
    If(!(Test-Path -Path $MountFolder)){Write-Warning "MountFolder does not exist";BREAK}
    If((Get-ChildItem -path $MountFolder).count -ne 0){Write-Warning "MountFolder is not empty";BREAK}
    If(!(Test-Path -Path $WIMFile)){Write-Warning "WIMfile does not exist";BREAK}

    $null = Mount-WindowsImage -ImagePath $WIMFile -Path $MountFolder -Index $Index -ReadOnly -LogPath $LogFile -ErrorAction Stop
    Try{$WindowsImage = Get-WindowsImage -ImagePath $WIMFile -Index $Index -LogPath $LogFile}catch{Write-Warning "Could execute Get-WindowsImage"}
    Try{$WindowsDrivers = Get-WindowsDriver -Path $MountFolder -LogPath $LogFile}catch{Write-Warning "Could execute Get-WindowsDriver"}
    Try{$WindowsOptionalFeatures = Get-WindowsOptionalFeature -Path $MountFolder -LogPath $LogFile}catch{Write-Warning "Could execute Get-WindowsOptionalFeature"}
    Try{$WindowsPackages = Get-WindowsPackage -Path $MountFolder -LogPath $LogFile}catch{Write-Warning "Could execute Get-WindowsPackage"}
    Try{$AppxProvisionedPackages = Get-AppxProvisionedPackage -Path $MountFolder -LogPath $LogFile}catch{Write-Warning "Could execute Get-AppxProvisionedPackage"}

    Write-Output "Image Info:"
    Write-Output ""
    Write-Output "Image Path        : $($WindowsImage.ImagePath)"
    Write-Output "Index Number      : $($WindowsImage.ImageIndex)"
    Write-Output "Image Name        : $($WindowsImage.ImageName)"
    Write-Output "Image Description : $($WindowsImage.ImageDescription)" 
    Write-Output "Image Size (GB)   : $([math]::Round($WindowsImage.ImageSize/1024/1024/1024))"
    Write-Output "Architechture     : $($WindowsImage.Architecture)"
    Write-Output "Version           : $($WindowsImage.Version)"
    Write-Output "Build             : $($WindowsImage.SPBuild)"
    Write-Output "Service Pack Level: $($WindowsImage.SPLevel)"
    Write-Output "Edition           : $($WindowsImage.EditionId)"
    Write-Output "Installation Type : $($WindowsImage.InstallationType)"
    Write-Output "Product Tyep      : $($WindowsImage.ProductType)"
    Write-Output "Product Suite     : $($WindowsImage.ProductSuite)"
    Write-Output "Created           : $($WindowsImage.CreatedTime)"
    Write-Output "Modified          : $($WindowsImage.ModifiedTime)"
    Write-Output "Languages         : $($WindowsImage.Languages)"
    Write-Output ""

    #Getting Driver Info
    Write-Output "Drivers:"
    Write-Output ""
    Foreach($WindowsDriver in $WindowsDrivers){
        $Drv = Get-WindowsDriver –Path $MountFolder –Driver $WindowsDriver.Driver
        Write-Output "Manufacturer   : $($Drv.ManufacturerName)"
        Write-Output "Description    : $($Drv.HardwareDescription)"
        Write-Output "Version        : $($Drv.version)"
        Write-Output "CompatibleIds  : $($Drv.CompatibleIds)"
        Write-Output "ExcludeIds     : $($Drv.ExcludeIds)"
        Write-Output "Class          : $($Drv.ClassName)"
        Write-Output "Signature      : $($Drv.DriverSignature)"
        Write-Output "Provider       : $($Drv.ProviderName)"
        Write-Output "Date           : $($Drv.Date)"
        Write-Output ""
    }

    #Getting Features
    Write-Output "Features:"
    Write-Output ""
    Foreach($Feature in $WindowsOptionalFeatures | Where-Object -Property State -EQ -Value Enabled | Sort-Object){
        Write-Output "Feature Name   : $($Feature.FeatureName)"
    }
    Write-Output ""

    #Getting Packages
    Write-Output "Packages:"
    Write-Output ""
    Foreach($WindowsPackage in $WindowsPackages){
        $Pkg = Get-WindowsPackage –Path $MountFolder –PackageName $WindowsPackage.PackageName
        $Pkg = $Pkg | Sort-Object
        Write-Output "Product Name    : $($Pkg.ProductName)"
        Write-Output "Release Type    : $($pkg.ReleaseType)"
        Write-Output "Description     : $($pkg.Description)"
        Write-Output "Support         : $($pkg.SupportInformation)"
        Write-Output "Install Time    : $($pkg.InstallTime)"
        Write-Output "Manufacturer    : $($Drv.ManufacturerName)"
        Write-Output ""
    }

    #Getting Appx Provisioned Packages
    Write-Output "AppxPackages:"
    Write-Output ""
    Foreach($AppxProvisionedPackage in $AppxProvisionedPackages){
        Write-Output "Display Name    : $($AppxProvisionedPackage.DisplayName)"
        Write-Output "Version         : $($AppxProvisionedPackage.Version)"
        Write-Output ""
    }
Dismount-WindowsImage -Path $MountFolder -Discard
}