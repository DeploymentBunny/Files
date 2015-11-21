Function Enable-NestedHyperV{
    Param(
        $VMname
        )

    $VM = Get-VM -Name $VMname
    $VMNic = Get-VMNetworkAdapter -VM $VM
    $VMCPU = Get-VMProcessor -VM $VM

    #Check if VM is saved
    if($VM.State -eq 'Saved'){Write-Warning "$VMname is saved, needs to be off";BREAK}

    #Check if VM has Snapshots
    if($VM.ParentSnapshotName -ne $null){Write-Warning "$VMname has snapshots, remove them";BREAK}
   
    #Check if VM is off
    if($VM.State -ne 'Off'){Write-Warning "$VMname is is not turned off, needs to be off";BREAK}

    #Check VM Configuration Version
    if($VM.Version -lt 7.0){Write-Warning "$VMname is not upgraded, needs to run VM Configuration 7.0";BREAK}

    #Check if VM allows Snapshot
    if($VM.CheckpointType -ne 'Disabled'){Write-Warning "$VMname allow Snapshot, Modifying";Set-VM -VM $VM -CheckpointType Disabled}
    
    #Check if VM has Dynamic Memory Enabled
    if($VM.DynamicMemoryEnabled -eq $true){Write-Warning "$VMname is set for Dynamic Memory, Modifying";Set-VMMemory -VM $VM -DynamicMemoryEnabled $false}

    #Check if VM has more then 4GB of RAM
    if($VM.MemoryStartup -lt 4GB){Write-Warning "$VMname has less then 4 GB of ram assigned, Modifying";Set-VMMemory -VM $VM -StartupBytes 4GB}

    #Check if VM has Mac Spoofing Enabled
    if(($VMNic).MacAddressSpoofing -ne 'On'){Write-Warning "$VMname does not have Mac Address Spoofing enabled, Modifying";Set-VMNetworkAdapter -VM $VM -MacAddressSpoofing on}

    #Check if VM has Expose Virtualization Extensions Enabled
    if(($VMCPU).ExposeVirtualizationExtensions -ne $true){Write-Warning "$VMname is not set to Expose Virtualization Extensions, Modifying";Set-VMProcessor -VM $VM -ExposeVirtualizationExtensions $true}
}