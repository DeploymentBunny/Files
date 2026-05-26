function Get-TSxOfflineWindowsPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$DiskNumber
    )

    $existingDriveLetter = $null
    $temporaryDriveLetter = $null
    $selectedPartition = $null
    $offlinePath = $null

    $partitions = Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop | Sort-Object PartitionNumber
    foreach ($partition in $partitions) {
        if ($partition.DriveLetter) {
            $candidate = '{0}:\' -f $partition.DriveLetter
            if (Test-Path -Path (Join-Path $candidate 'Windows')) {
                $existingDriveLetter = $partition.DriveLetter
                $selectedPartition = $partition
                $offlinePath = $candidate
                break
            }
            continue
        }

        $lettersInUse = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | ForEach-Object { $_.DriveLetter }
        $lettersInUseSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($ltr in $lettersInUse) { [void]$lettersInUseSet.Add([string]$ltr) }

        $freeLetter = $null
        foreach ($candidateLetter in ('Z','Y','X','W','V','U','T','S','R','Q','P','O','N','M')) {
            if (-not $lettersInUseSet.Contains($candidateLetter)) {
                $freeLetter = $candidateLetter
                break
            }
        }

        if (-not $freeLetter) {
            throw 'Unable to assign temporary drive letter to mounted VHDX partition.'
        }

        Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber -DriveLetter $freeLetter -ErrorAction Stop
        $candidatePath = '{0}:\' -f $freeLetter
        if (Test-Path -Path (Join-Path $candidatePath 'Windows')) {
            $temporaryDriveLetter = $freeLetter
            $selectedPartition = $partition
            $offlinePath = $candidatePath
            break
        }

        Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber -DriveLetter $freeLetter -ErrorAction SilentlyContinue
    }

    if (-not $offlinePath) {
        throw 'Unable to locate offline Windows folder inside mounted VHDX.'
    }

    [PSCustomObject]@{
        Path = $offlinePath
        PartitionNumber = $selectedPartition.PartitionNumber
        ExistingDriveLetter = $existingDriveLetter
        TemporaryDriveLetter = $temporaryDriveLetter
    }
}
