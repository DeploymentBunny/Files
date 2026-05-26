function Add-TSxPackagesToWim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImagePath,

        [Parameter(Mandatory = $true)]
        [int]$ImageIndex,

        [Parameter(Mandatory = $true)]
        [object[]]$Packages,

        [Parameter()]
        [string]$ScratchPath
    )

    $mountPath = Join-Path $env:TEMP ('TSxMount_{0}' -f ([guid]::NewGuid().Guid))
    $null = New-Item -Path $mountPath -ItemType Directory -Force
    $isMounted = $false

    try {
        Write-TSxLog -Message "Mounting WIM image: $ImagePath (Index: $ImageIndex)"
        $mountParams = @{ ImagePath = $ImagePath; Index = $ImageIndex; Path = $mountPath; ErrorAction = 'Stop' }
        if ($ScratchPath) { $mountParams['ScratchDirectory'] = $ScratchPath }

        Mount-WindowsImage @mountParams
        $isMounted = $true

        foreach ($package in $Packages) {
            Write-TSxLog -Message "Injecting package into WIM: $($package.FullName)"
            $packageParams = @{ Path = $mountPath; PackagePath = $package.FullName; ErrorAction = 'Stop' }
            if ($ScratchPath) { $packageParams['ScratchDirectory'] = $ScratchPath }
            Add-WindowsPackage @packageParams | Out-Null
        }

        Write-TSxLog -Message 'Committing and unmounting WIM image.'
        Dismount-WindowsImage -Path $mountPath -Save -ErrorAction Stop
        $isMounted = $false
    }
    finally {
        if ($isMounted) {
            Write-TSxLog -Level 'WARN' -Message 'WIM still mounted after error. Discarding pending changes.'
            Dismount-WindowsImage -Path $mountPath -Discard -ErrorAction SilentlyContinue
        }
        Remove-Item -Path $mountPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
