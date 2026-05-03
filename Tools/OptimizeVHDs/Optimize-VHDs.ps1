<#
.SYNOPSIS
    Optimizes VHD/VHDX files attached to Hyper-V virtual machines.
.DESCRIPTION
    Optimize-VHDs evaluates local Hyper-V virtual machines and runs Optimize-VHD -Mode Full
    on every eligible attached disk.

    A VM is eligible only when:
    - VM state is Off
    - VM has no checkpoints

    By default the script writes human-readable text to the output stream and shows a
    Write-Progress bar during Optimize-VHD.

    When called with -EmitStructuredOutput the script emits PSCustomObject event records
    instead, which Optimize-VHDsUI.ps1 uses to stream live progress into the GUI.

.PARAMETER VMnames
    One or more VM names to evaluate.
    If omitted, all local VMs are evaluated.

.PARAMETER EmitStructuredOutput
    Boolean flag used by Optimize-VHDsUI.ps1.
    Causes the script to emit structured PSCustomObject records instead of plain text,
    enabling the GUI to display live progress and results.
    Do not use this parameter when running the script from the command line.

.NOTES
    FileName:    Optimize-VHDs.ps1
    Author:      Mikael Nystrom
    Contact:     deploymentbunny@outlook.com
    Created:     2026-04-28
    Updated:     2026-04-28
    Twitter:     @mikael_nystrom

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author.
.LINK
    https://www.deploymentbunny.com
.EXAMPLE
    .\Optimize-VHDs.ps1
    Optimizes all eligible local VMs.
.EXAMPLE
    .\Optimize-VHDs.ps1 -VMnames "LAB-DC01","LAB-APP01"
    Optimizes only the two named VMs.
#>
[CmdletBinding()]
Param(
    [string[]]$VMnames,
    [bool]$EmitStructuredOutput = $false
)

function Write-TSxOptimizeEvent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Type,

        [string]$VMName = "",
        [string]$DiskPath = "",
        [string]$Status = "",
        [string]$Message = "",
        [double]$SavedGB = 0,
        [int]$Percent = -1
    )

    [PSCustomObject]@{
        Type = $Type
        VMName = $VMName
        DiskPath = $DiskPath
        Status = $Status
        Message = $Message
        SavedGB = [math]::Round($SavedGB, 2)
        Percent = $Percent
    }
}

function Publish-TSxOptimizeEvent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Type,

        [string]$VMName = "",
        [string]$DiskPath = "",
        [string]$Status = "",
        [string]$Message = "",
        [double]$SavedGB = 0,
        [int]$Percent = -1
    )

    $eventItem = Write-TSxOptimizeEvent -Type $Type -VMName $VMName -DiskPath $DiskPath -Status $Status -Message $Message -SavedGB $SavedGB -Percent $Percent

    if ($EmitStructuredOutput) {
        Write-Output $eventItem
        return
    }

    switch ($Type) {
        "Progress" {
            $statusText = if ([string]::IsNullOrWhiteSpace($VMName)) {
                $Message
            }
            else {
                "{0}: {1}" -f $VMName, $Message
            }

            if ($Percent -ge 0 -and $Percent -le 100) {
                Write-Progress -Activity "Optimize VHDs" -Status $statusText -PercentComplete $Percent
            }

            Write-Output $statusText
        }
        "Result" {
            $resultLine = "VM={0}; Disk={1}; Status={2}; SavedGB={3}; Message={4}" -f $VMName, $DiskPath, $Status, ([math]::Round($SavedGB, 2)), $Message
            Write-Output $resultLine
        }
        "Summary" {
            Write-Progress -Activity "Optimize VHDs" -Completed
            Write-Output $Message
        }
    }
}

$isAdmin = [bool](([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
if (-not $isAdmin) {
    Publish-TSxOptimizeEvent -Type "Summary" -Message "Administrator privileges are required to optimize VHDs. Please re-launch using the Elevate (Admin) button." -Percent 100
    return
}

if (-not $VMnames -or $VMnames.Count -eq 0) {
    $VMnames = @(Get-VM | Select-Object -ExpandProperty Name)
}

$VMnames = @($VMnames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$totalVmCount = $VMnames.Count

if (-not $totalVmCount) {
    Publish-TSxOptimizeEvent -Type "Summary" -Message "No VMs to process" -Percent 100
    return
}

$vmCounter = 0
foreach ($VMname in $VMnames) {
    $vmCounter++
    $vmStartPercent = [int][math]::Floor((($vmCounter - 1) / $totalVmCount) * 100)
    Publish-TSxOptimizeEvent -Type "Progress" -VMName $VMname -Message "Checking $VMname" -Percent $vmStartPercent

    $vm = Get-VM -Name $VMname -ErrorAction SilentlyContinue
    if (-not $vm) {
        Publish-TSxOptimizeEvent -Type "Result" -VMName $VMname -Status "Skipped" -Message "VM not found" -Percent $vmStartPercent
        continue
    }

    if ($vm.State -ne "Off" -or $null -ne $vm.ParentCheckpointId) {
        Publish-TSxOptimizeEvent -Type "Result" -VMName $VMname -Status "Skipped" -Message "VM is not turned off or has a snapshot" -Percent $vmStartPercent
        continue
    }

    $diskPaths = @(
        Get-VMHardDiskDrive -VMName $VMname -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.Path) } |
        Select-Object -ExpandProperty Path
    )

    if ($diskPaths.Count -eq 0) {
        Publish-TSxOptimizeEvent -Type "Result" -VMName $VMname -Status "Skipped" -Message "No attached VHD/VHDX paths found" -Percent $vmStartPercent
        continue
    }

    foreach ($VHD in $diskPaths) {
        Publish-TSxOptimizeEvent -Type "Progress" -VMName $VMname -DiskPath $VHD -Message "Working on $VHD, please wait" -Percent $vmStartPercent

        if (-not (Test-Path -Path $VHD)) {
            Publish-TSxOptimizeEvent -Type "Result" -VMName $VMname -DiskPath $VHD -Status "Skipped" -Message "Disk path does not exist" -Percent $vmStartPercent
            continue
        }

        try {
            $beforeSizeGB = [math]::Round(((Get-VHD -Path $VHD -ErrorAction Stop).FileSize / 1GB), 2)
            Publish-TSxOptimizeEvent -Type "Progress" -VMName $VMname -DiskPath $VHD -Message "Current size $beforeSizeGB GB" -Percent $vmStartPercent

            Optimize-VHD -Path $VHD -Mode Full -ErrorAction Stop

            $afterSizeGB = [math]::Round(((Get-VHD -Path $VHD -ErrorAction Stop).FileSize / 1GB), 2)
            $savedGB = [math]::Round(($beforeSizeGB - $afterSizeGB), 2)

            Publish-TSxOptimizeEvent -Type "Result" -VMName $VMname -DiskPath $VHD -Status "Success" -Message "Optimized size $afterSizeGB GB" -SavedGB $savedGB -Percent $vmStartPercent
        }
        catch {
            Publish-TSxOptimizeEvent -Type "Result" -VMName $VMname -DiskPath $VHD -Status "Failed" -Message $_.Exception.Message -Percent $vmStartPercent
        }
    }

    $vmEndPercent = [int][math]::Floor(($vmCounter / $totalVmCount) * 100)
    Publish-TSxOptimizeEvent -Type "Progress" -VMName $VMname -Message "Completed $VMname" -Percent $vmEndPercent
}

Publish-TSxOptimizeEvent -Type "Summary" -Message "Optimization run completed" -Percent 100
