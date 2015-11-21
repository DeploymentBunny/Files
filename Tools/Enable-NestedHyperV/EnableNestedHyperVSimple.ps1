Function Enable-NestedHyperV{
    Param(
        $VMName
        )
    $VM = Get-VM -Name $VMName
    $VM | Set-VMProcessor -ExposeVirtualizationExtensions:$true
    $VM | Set-VMMemory -DynamicMemoryEnabled:$false
    $vm | Set-VM -CheckpointType Disabled
    Set-VMNetworkAdapter -VMName $VMName -MacAddressSpoofing on
}