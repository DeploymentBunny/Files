function Add-TSxPackagesToVhdx {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImagePath,

        [Parameter(Mandatory = $true)]
        [object[]]$Packages,

        [Parameter()]
        [string]$ScratchPath
    )

    $mountedDisk = $null
    $offlineInfo = $null

    try {
        Write-TSxLog -Message "Mounting VHDX image: $ImagePath"
        $mountedDisk = Mount-VHD -Path $ImagePath -Passthru -ErrorAction Stop
        Start-Sleep -Milliseconds 500

        $offlineInfo = Get-TSxOfflineWindowsPath -DiskNumber $mountedDisk.DiskNumber
        Write-TSxLog -Message "Offline Windows path detected: $($offlineInfo.Path)"

        foreach ($package in $Packages) {
            Write-TSxLog -Message "Injecting package into VHDX: $($package.FullName)"
            $packageParams = @{ Path = $offlineInfo.Path; PackagePath = $package.FullName; ErrorAction = 'Stop' }
            if ($ScratchPath) { $packageParams['ScratchDirectory'] = $ScratchPath }
            Add-WindowsPackage @packageParams | Out-Null
        }
    }
    finally {
        if ($offlineInfo -and $offlineInfo.TemporaryDriveLetter) {
            Remove-PartitionAccessPath -DiskNumber $mountedDisk.DiskNumber -PartitionNumber $offlineInfo.PartitionNumber -DriveLetter $offlineInfo.TemporaryDriveLetter -ErrorAction SilentlyContinue
        }

        if ($mountedDisk) {
            Write-TSxLog -Message 'Dismounting VHDX image.'
            Dismount-VHD -Path $ImagePath -ErrorAction SilentlyContinue
        }
    }
}
