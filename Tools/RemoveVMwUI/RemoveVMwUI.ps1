<#
.Synopsis
    RemoveVMwUI will remove selected virtual machines, including datafiles and folder
.DESCRIPTION
    RemoveVMwUI will remove selected virtual machines, including datafiles and folder, forever, without any questions
.EXAMPLE
    RemoveVMwUI
.NOTES
    This script will give you the option to remove virtual machines running on Hyper-V, including all data files, even if they are running
    Selfelevating Script "borrowed" from Ben Armstrong - https://blogs.msdn.microsoft.com/virtual_pc_guy/2010/09/23/a-self-elevating-powershell-script/
    FileName:    RemoveVMwUI.ps1 
    Author:      Mikael Nystrom
    Contact:     mikael.nystrom@truesec.se
    Created:     2018-09-21
    web:         http://www.deploymentbunny.com
.FUNCTIONALITY
    The script will check if you are elevated or not, if not it will elevate you. It will then use get-vm to get all VMs, present in a dialogbox, where you can select vm's
    it will then find out locations of resources used ny the vm, including the folder and then remove all of it, if the vm is running it will be stopped and then deleted.
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

$DLL = '[DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);'
Add-Type -MemberDefinition $DLL -name NativeMethods -namespace Win32
$Process = (Get-Process PowerShell | Where-Object MainWindowTitle -like '*RemoveVMwUI*').MainWindowHandle
# Minimize window
[Win32.NativeMethods]::ShowWindowAsync($Process, 2)

$VMnames = Get-VM

#First box
[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms")
[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Drawing") 

$objForm = New-Object System.Windows.Forms.Form 
$objForm.Text = "Completly remove virtual machines, for real (1.0)"
$objForm.Size = New-Object System.Drawing.Size(600,250) 
$objForm.StartPosition = "CenterScreen"

$objForm.KeyPreview = $True
$objForm.Add_KeyDown({if ($_.KeyCode -eq "Enter") 
    {$x=$objListBox.SelectedItem;$objForm.Close()}})
$objForm.Add_KeyDown({if ($_.KeyCode -eq "Escape") 
    {$objForm.Close()}})

$OKButton = New-Object System.Windows.Forms.Button
$OKButton.Location = New-Object System.Drawing.Size(200,180)
$OKButton.Size = New-Object System.Drawing.Size(75,25)
$OKButton.Text = "OK"
$OKButton.Add_Click({$objListBox.SelectedItem;$objForm.Close()})
$objForm.Controls.Add($OKButton)

$CancelButton = New-Object System.Windows.Forms.Button
$CancelButton.Location = New-Object System.Drawing.Size(300,180)
$CancelButton.Size = New-Object System.Drawing.Size(75,25)
$CancelButton.Text = "Cancel"
$CancelButton.Add_Click({[environment]::exit(0);$objForm.Close()})
$objForm.Controls.Add($CancelButton)

$objLabel2 = New-Object System.Windows.Forms.Label
$objLabel2.Location = New-Object System.Drawing.Size(10,40) 
$objLabel2.Size = New-Object System.Drawing.Size(400,20) 
$objLabel2.Text = "Select virtual machine(s) to delete: "
$objForm.Controls.Add($objLabel2) 

$objListBox = New-Object System.Windows.Forms.ListBox 
$objListBox.Location = New-Object System.Drawing.Size(10,60) 
$objListBox.Size = New-Object System.Drawing.Size(560,40) 
$objListBox.Height = 120
$objlistBox.SelectionMode = 'MultiExtended'


foreach($item in $VMnames.name){
    [void] $objListBox.Items.Add($item)
}
$objForm.Controls.Add($objListBox) 
$objForm.Topmost = $True
$objForm.Add_Shown({$objForm.Activate()})
[void] $objForm.ShowDialog()

#Set the return value to $X
$Selections = $objListBox.SelectedItems

#Third Box
[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms")
[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Drawing") 

$objForm = New-Object System.Windows.Forms.Form 
$objForm.Text = "Completly remove virtual machines, for real (1.0)"
$objForm.Size = New-Object System.Drawing.Size(600,250) 
$objForm.StartPosition = "CenterScreen"

$objForm.KeyPreview = $True
$objForm.Add_KeyDown({if ($_.KeyCode -eq "Enter") 
    {$x=$objListBox.SelectedItem;$objForm.Close()}})
$objForm.Add_KeyDown({if ($_.KeyCode -eq "Escape") 
    {$objForm.Close()}})

$OKButton = New-Object System.Windows.Forms.Button
$OKButton.Location = New-Object System.Drawing.Size(200,180)
$OKButton.Size = New-Object System.Drawing.Size(75,25)
$OKButton.Text = "OK"
$OKButton.Add_Click({$objListBox.SelectedItem;$objForm.Close()})
$objForm.Controls.Add($OKButton)

$CancelButton = New-Object System.Windows.Forms.Button
$CancelButton.Location = New-Object System.Drawing.Size(300,180)
$CancelButton.Size = New-Object System.Drawing.Size(75,25)
$CancelButton.Text = "Cancel"
$CancelButton.Add_Click({[environment]::exit(0);$objForm.Close()})
$objForm.Controls.Add($CancelButton)

$objLabel = New-Object System.Windows.Forms.Label
$objLabel.Location = New-Object System.Drawing.Size(10,40) 
$objLabel.Size = New-Object System.Drawing.Size(400,20) 
$objLabel.Text = "Selected virtual machine(s) will be delete(d): $Selections"
$objForm.Controls.Add($objLabel) 

$objLabel = New-Object System.Windows.Forms.Label
$objLabel.Location = New-Object System.Drawing.Size(10,80) 
$objLabel.Size = New-Object System.Drawing.Size(400,20) 
$objLabel.Text = "Press ok to delete the virtual machine(s), including all datafiles"
$objForm.Controls.Add($objLabel) 

$objForm.Add_Shown({$objForm.Activate()})
[void] $objForm.ShowDialog()

Function Remove-VIAVM
{
<#
.Synopsis
   Short description
.DESCRIPTION
   Long description
.EXAMPLE
   Example of how to use this cmdlet
.EXAMPLE
   Another example of how to use this cmdlet
#>
    [cmdletbinding(SupportsShouldProcess=$True)]

    Param
    (
        [parameter(mandatory=$True,ValueFromPipelineByPropertyName=$true,Position=0)]
        [ValidateNotNullOrEmpty()]
        $VMName
    )

    foreach($Item in $VMName){
        $Items = Get-VM -Name $Item -ErrorAction SilentlyContinue
        If($Items.count -eq "0"){Break}
        foreach($Item in $Items){
            Write-Verbose "Working on $Item"
            if($((Get-VM -Id $Item.Id).State) -eq "Running"){
                Write-Verbose "Stopping $Item"
                Get-VM -Id $Item.Id | Stop-VM -Force -TurnOff
            }
            $Disks = Get-VMHardDiskDrive -VM $Item
            foreach ($Disk in $Disks){
                Write-Verbose "Removing $($Disk.Path)"
                Remove-Item -Path $Disk.Path -Force -ErrorAction Continue
            }
            $ItemLoc = (Get-VM -Id $Item.id).ConfigurationLocation
            Write-Verbose "Removing $item"
            Get-VM -Id $item.Id | Remove-VM -Force
            Write-Verbose "Removing $ItemLoc"
            Remove-Item -Path $Itemloc -Recurse -Force
        }
    }
}
foreach($Selection in $Selections){
    Remove-VIAVM -VMName $Selection
}
