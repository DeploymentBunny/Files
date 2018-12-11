<#
.Synopsis
    Start-TSxDedup
.DESCRIPTION
    Start-TSxDedup will find all dedup drivs and process them
.EXAMPLE
    Start-TSxDedup
.NOTES
    This script will give you the option to remove virtual machines running on Hyper-V, including all data files, even if they are running
    Selfelevating Script "borrowed" from Ben Armstrong - https://blogs.msdn.microsoft.com/virtual_pc_guy/2010/09/23/a-self-elevating-powershell-script/
    FileName:    Start-TSxDedup.ps1 
    Author:      Mikael Nystrom
    Contact:     mikael.nystrom@truesec.se
    Created:     2017-01-01
    Updated:     2018-09-27
                 Added code to self elevate to admin
    web:         http://www.deploymentbunny.com
.FUNCTIONALITY
    The script will check if you are elevated or not, if not it will elevate you and then find all dedup drivs and process them.
#>

# Get the ID and security principal of the current user account
 $myWindowsID=[System.Security.Principal.WindowsIdentity]::GetCurrent()
 $myWindowsPrincipal=New-Object System.Security.Principal.WindowsPrincipal($myWindowsID)
  
 # Get the security principal for the Administrator role
 $adminRole=[System.Security.Principal.WindowsBuiltInRole]::Administrator
  
 # Check to see if we are currently running "as Administrator"
if ($myWindowsPrincipal.IsInRole($adminRole)){
    # We are running "as Administrator" - so change the title and background color to indicate this
    $Host.UI.RawUI.WindowTitle = $myInvocation.MyCommand.Definition + "(Bootstrap)"
    $Host.UI.RawUI.BackgroundColor = "DarkBlue"
    Clear-Host
}
else{
    # We are not running "as Administrator" - so relaunch as administrator
    
    # Create a new process object that starts PowerShell
    $newProcess = New-Object System.Diagnostics.ProcessStartInfo "PowerShell";
    
    # Specify the current script path and name as a parameter
    $newProcess.Arguments = $myInvocation.MyCommand.Definition;
    
    # Indicate that the process should be elevated
    $newProcess.Verb = "runas";
    
    # Start the new process
    [System.Diagnostics.Process]::Start($newProcess);
    
    # Exit from the current, unelevated, process
    exit
}

Function Wait-TSxDedupJob
{
    while ((Get-DedupJob).count -ne 0 )
    {
        Get-DedupJob
        Start-Sleep -Seconds 30
    }
}

foreach($item in Get-DedupVolume){
    Wait-TSxDedupJob
    $item | Start-DedupJob -Type Optimization -Priority High -Memory 80
    Wait-TSxDedupJob
    $item | Start-DedupJob -Type GarbageCollection -Priority High -Memory 80 -Full
    Wait-TSxDedupJob
    $item | Start-DedupJob -Type Scrubbing -Priority High -Memory 80 -Full
    Wait-TSxDedupJob
}
Get-DedupStatus
