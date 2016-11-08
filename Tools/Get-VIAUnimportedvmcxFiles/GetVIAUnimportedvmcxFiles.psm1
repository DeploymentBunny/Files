Function Get-VIAUnimportedvmcxFiles
{
    <#
    .Synopsis
        Script used find not yet imported Hyper-V Configurations
    .DESCRIPTION
        Created: 2016-11-07
        Version: 1.0
        Author : Mikael Nystrom
        Twitter: @mikael_nystrom
        Blog   : http://deploymentbunny.com
        Disclaimer: This script is provided "AS IS" with no warranties.
    .EXAMPLE
        Get-VIAUnimportedvmcxFiles
    #>    
    [CmdletBinding(SupportsShouldProcess=$true)]
    
    Param(
    [string]$Folder
    )

    if((Test-Path -Path $Folder) -ne $true){
        Write-Warning "I'm sorry, that folder does not exist"
        Break
    }

    $VMsIDs = (Get-VM).VMId
    $VMConfigs = (Get-ChildItem -Path $Folder -Filter *.vmcx -Recurse).BaseName

    $obj = Compare-Object -ReferenceObject $VMsIDs -DifferenceObject $VMConfigs

    $Configs = foreach($Item in ($obj.InputObject)){
        $Items = Get-ChildItem -Path $Folder -Recurse -File -Filter *.vmcx  | Where-Object -Property Basename -Like -Value "*$Item" 
        $Items | Where-Object -Property FullName -NotLike -Value "*Snapshots*"
        }
    Return $Configs.FullName
}