Function Get-NestedHyperVRediness{
    $WindowsOptionalFeature = Get-WindowsOptionalFeature -Online
    if(($WindowsOptionalFeature | Where-Object -Property FeatureName -EQ -Value IsolatedUserMode).State -ne 'Disabled'){
        Write-Warning "Nested Hyper-V does not work if IsoLatedUserMode is Enabled"
        }
        Else
        {Write-Output "IsoLatedUserMode is set correct"}

    if(($WindowsOptionalFeature | Where-Object -Property FeatureName -EQ -Value HostGuardian).State -ne 'Disabled'){
        Write-Warning "Nested Hyper-v does not work if HostGuardian is Enabled"
        }
        Else
        {Write-Output "HostGuardian is set correct"}

    if(($WindowsOptionalFeature | Where-Object -Property FeatureName -EQ -Value Microsoft-Hyper-V).State -ne 'Enabled'){
        Write-Warning "Nested Hyper-v does not work if Microsoft-Hyper-V is Disabled"
        }
        Else
        {Write-Output "Microsoft-Hyper-V is installed"}
}