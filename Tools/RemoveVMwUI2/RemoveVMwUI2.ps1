<# This form was created using POSHGUI.com  a free online gui designer for PowerShell
.NAME
    Untitled
#>

# Get the ID and security principal of the current user account
$myWindowsID=[System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal=new-object System.Security.Principal.WindowsPrincipal($myWindowsID)

# Get the security principal for the Administrator role
$adminRole=[System.Security.Principal.WindowsBuiltInRole]::Administrator

# Check to see if we are currently running "as Administrator"
if ($myWindowsPrincipal.IsInRole($adminRole))
   {
   # We are running "as Administrator" - so change the title and background color to indicate this
   $Host.UI.RawUI.WindowTitle = $myInvocation.MyCommand.Definition + "(Elevated)"
   $Host.UI.RawUI.BackgroundColor = "DarkBlue"
   clear-host
   }
else
   {
   # We are not running "as Administrator" - so relaunch as administrator
   
   # Create a new process object that starts PowerShell
   $newProcess = new-object System.Diagnostics.ProcessStartInfo "PowerShell";
   
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

Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()

#Get Env:
$RootFolder = $MyInvocation.MyCommand.Path | Split-Path -Parent

$Font = 'Consolas,10'

#region begin GUI{ 

$Form                            = New-Object system.Windows.Forms.Form
$Form.ClientSize                 = '600,400'
$Form.text                       = "Form"
$Form.TopMost                    = $false
$Form.Text                       = "Completly remove virtual machines, for real (2.0)"
$Form.StartPosition              = "CenterScreen"

$Close                           = New-Object system.Windows.Forms.Button
$Close.text                      = "Close"
$Close.width                     = 60
$Close.height                    = 30
$Close.location                  = New-Object System.Drawing.Point(520,350)
$Close.Font                      = $Font

$Connect                         = New-Object system.Windows.Forms.Button
$Connect.text                    = "Connect"
$Connect.width                   = 100
$Connect.height                  = 30
$Connect.location                = New-Object System.Drawing.Point(320,20)
$Connect.Font                    = $Font

$Label1                          = New-Object system.Windows.Forms.Label
$Label1.text                     = "Hyper-V host"
$Label1.AutoSize                 = $true
$Label1.width                    = 25
$Label1.height                   = 10
$Label1.location                 = New-Object System.Drawing.Point(20,25)
$Label1.Font                     = $Font

$Label2                          = New-Object system.Windows.Forms.Label
$Label2.text                     = "Select virtual machine(s)"
$Label2.AutoSize                 = $true
$Label2.width                    = 25
$Label2.height                   = 10
$Label2.location                 = New-Object System.Drawing.Point(20,100)
$Label2.Font                     = $Font

$TextBox1                        = New-Object system.Windows.Forms.TextBox
$TextBox1.multiline              = $false
$TextBox1.width                  = 190
$TextBox1.height                 = 20
$TextBox1.location               = New-Object System.Drawing.Point(120,22)
$TextBox1.Font                   = $Font
$TextBox1.Text                   = $env:COMPUTERNAME

$ListBox1                        = New-Object system.Windows.Forms.ListBox
$ListBox1.text                   = "listBox"
$ListBox1.width                  = 290
$ListBox1.height                 = 200
$ListBox1.location               = New-Object System.Drawing.Point(20,130)
$ListBox1.SelectionMode          = "MultiExtended"

$Delete                          = New-Object system.Windows.Forms.Button
$Delete.text                     = "Delete"
$Delete.width                    = 100
$Delete.height                   = 30
$Delete.location                 = New-Object System.Drawing.Point(320,130)
$Delete.Font                     = $Font

$PictureBox1                     = New-Object system.Windows.Forms.PictureBox
$PictureBox1.width               = 100
$PictureBox1.height              = 100
$PictureBox1.location            = New-Object System.Drawing.Point(462,1)
$PictureBox1.imageLocation       = "$RootFolder\image.png"
$PictureBox1.SizeMode            = [System.Windows.Forms.PictureBoxSizeMode]::zoom
$Form.controls.AddRange(@($Close,$Connect,$Label1,$Label2,$TextBox1,$ListBox1,$Delete,$PictureBox1))

#region gui events {
$Connect.Add_Click({ Connect })
$Close.Add_Click({ Close })
$Delete.Add_Click({ Delete })
#endregion events }

#endregion GUI }

Function Remove-TSxVM{
    [cmdletbinding(SupportsShouldProcess=$True)]
    Param
    (
        [parameter(mandatory=$True,ValueFromPipelineByPropertyName=$true,Position=0)]
        [ValidateNotNullOrEmpty()]
        $Computername,

        [parameter(mandatory=$True,ValueFromPipelineByPropertyName=$true,Position=1)]
        [ValidateNotNullOrEmpty()]
        $VMName
    )

    $ScriptBlock = {
        $Item = Get-VM -Name $using:VMName -ErrorAction SilentlyContinue
        If($Item.count -eq "0"){
            Break
        }
        
        Write-Host "Working on $using:VMName"
        $Item = Get-VM -Name $using:VMName -ErrorAction SilentlyContinue

        if($Item.State -eq "Running"){
            Write-Host "Stopping $using:VMName"
            Get-VM -Id $Item.Id | Stop-VM -Force -TurnOff
        }
            
        If((Get-VM -Name $using:VMName | Get-VMSnapshot).count -ne 0){
            Write-Host "$using:vmname does have snapshots, restoring and removing..."
            Get-VMSnapshot -VMName $using:VMName | Where-Object ParentCheckpointName -EQ $null| Restore-VMSnapshot -Confirm:$false
            Remove-VMSnapshot -VMName $using:VMName
            do{Start-Sleep -Seconds 1}
            until((Get-VM -Name $using:VMName | Get-VMSnapshot).count -eq 0)
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
    Invoke-Command -ComputerName $Computername -ScriptBlock $ScriptBlock
}
Function Connect{
    Write-host "Connecting to $($TextBox1.Text)"
    Write-host "Getting VM's from $($TextBox1.Text)"
    $VMs = Get-VM -ComputerName $($TextBox1.Text) | Sort-Object

    $ListBox1.Items.Clear()
    foreach($VM in $VMs){
        [void] $Listbox1.Items.Add($VM.name)
        
    }

}
Function Close{
    $Form.close()
}
Function Delete{
    $SelectedItems = $ListBox1.SelectedItems
    foreach($SelectedItem in $SelectedItems){
        Write-Host "Deleting $SelectedItem from $($TextBox1.Text)"
        Remove-TSxVM -Computername $($TextBox1.Text) -VMName $SelectedItem
    }
    Connect
}

[void]$Form.ShowDialog()
