<#
 # This script will give you the option to change the SKU.
 # The script detects the Server OS version and present a list of other SKU's that the current version can be converted into
 # Version 2.0
 # Added Selfelevating : Script "borrowed" from Ben Armstrong - https://blogs.msdn.microsoft.com/virtual_pc_guy/2010/09/23/a-self-elevating-powershell-script/
 # Added support for Windows Server 2016
#>


# Get the ID and security principal of the current user account
 $myWindowsID=[System.Security.Principal.WindowsIdentity]::GetCurrent()
 $myWindowsPrincipal=new-object System.Security.Principal.WindowsPrincipal($myWindowsID)
  
 # Get the security principal for the Administrator role
 $adminRole=[System.Security.Principal.WindowsBuiltInRole]::Administrator
  
 # Check to see if we are currently running "as Administrator"
if ($myWindowsPrincipal.IsInRole($adminRole)){
    # We are running "as Administrator" - so change the title and background color to indicate this
    $Host.UI.RawUI.WindowTitle = $myInvocation.MyCommand.Definition + "(Elevated)"
    $Host.UI.RawUI.BackgroundColor = "DarkBlue"
    clear-host
}
else{
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

Function Show-BoxSelection{
[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms")
[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Drawing") 

$objForm = New-Object System.Windows.Forms.Form 
$objForm.Text = "Select SKU Upgrade"
$objForm.Size = New-Object System.Drawing.Size(600,200) 
$objForm.StartPosition = "CenterScreen"

$objForm.KeyPreview = $True
$objForm.Add_KeyDown({if ($_.KeyCode -eq "Enter") 
    {$x=$objListBox.SelectedItem;$objForm.Close()}})
$objForm.Add_KeyDown({if ($_.KeyCode -eq "Escape") 
    {$objForm.Close()}})

$OKButton = New-Object System.Windows.Forms.Button
$OKButton.Location = New-Object System.Drawing.Size(200,133)
$OKButton.Size = New-Object System.Drawing.Size(75,25)
$OKButton.Text = "OK"
$OKButton.Add_Click({$objListBox.SelectedItem;$objForm.Close()})
$objForm.Controls.Add($OKButton)

$CancelButton = New-Object System.Windows.Forms.Button
$CancelButton.Location = New-Object System.Drawing.Size(300,133)
$CancelButton.Size = New-Object System.Drawing.Size(75,25)
$CancelButton.Text = "Cancel"
$CancelButton.Add_Click({[environment]::exit(0);$objForm.Close()})
$objForm.Controls.Add($CancelButton)

$objLabel = New-Object System.Windows.Forms.Label
$objLabel.Location = New-Object System.Drawing.Size(10,20) 
$objLabel.Size = New-Object System.Drawing.Size(400,20) 
$objLabel.Text = "Current SKU: " + [String]$CurrentWinCaption.Caption
$objForm.Controls.Add($objLabel) 

$objLabel2 = New-Object System.Windows.Forms.Label
$objLabel2.Location = New-Object System.Drawing.Size(10,40) 
$objLabel2.Size = New-Object System.Drawing.Size(400,20) 
$objLabel2.Text = "Select SKU Upgrade: "
$objForm.Controls.Add($objLabel2) 

$objListBox = New-Object System.Windows.Forms.ListBox 
$objListBox.Location = New-Object System.Drawing.Size(10,60) 
$objListBox.Size = New-Object System.Drawing.Size(560,40) 
$objListBox.Height = 80

If($UpgradeSelection01 -ne "NA"){[void] $objListBox.Items.Add($UpgradeSelection01)}
If($UpgradeSelection02 -ne "NA"){[void] $objListBox.Items.Add($UpgradeSelection02)}

$objForm.Controls.Add($objListBox) 

$objForm.Topmost = $True

$objForm.Add_Shown({$objForm.Activate()})
[void] $objForm.ShowDialog()
}
Function Show-BoxResult{
[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms")
[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Drawing") 

$objForm = New-Object System.Windows.Forms.Form 
$objForm.Text = "Select SKU Upgrade"
$objForm.Size = New-Object System.Drawing.Size(600,200) 
$objForm.StartPosition = "CenterScreen"

$objForm.KeyPreview = $True
$objForm.Add_KeyDown({if ($_.KeyCode -eq "Enter") 
    {$x=$objListBox.SelectedItem;$objForm.Close()}})
$objForm.Add_KeyDown({if ($_.KeyCode -eq "Escape") 
    {$objForm.Close()}})

$OKButton = New-Object System.Windows.Forms.Button
$OKButton.Location = New-Object System.Drawing.Size(200,133)
$OKButton.Size = New-Object System.Drawing.Size(75,25)
$OKButton.Text = "OK"
$OKButton.Add_Click({$objListBox.SelectedItem;$objForm.Close()})
$objForm.Controls.Add($OKButton)

$CancelButton = New-Object System.Windows.Forms.Button
$CancelButton.Location = New-Object System.Drawing.Size(300,133)
$CancelButton.Size = New-Object System.Drawing.Size(75,25)
$CancelButton.Text = "Cancel"
$CancelButton.Add_Click({[environment]::exit(0);$objForm.Close()})
$objForm.Controls.Add($CancelButton)

$objLabel = New-Object System.Windows.Forms.Label
$objLabel.Location = New-Object System.Drawing.Size(10,20) 
$objLabel.Size = New-Object System.Drawing.Size(400,20) 
$objLabel.Text = "Current SKU: " + [String]$CurrentWinCaption.Caption
$objForm.Controls.Add($objLabel) 

$objLabel2 = New-Object System.Windows.Forms.Label
$objLabel2.Location = New-Object System.Drawing.Size(10,40) 
$objLabel2.Size = New-Object System.Drawing.Size(400,20) 
$objLabel2.Text = "Selected SKU: $X"
$objForm.Controls.Add($objLabel2)

$objLabel3 = New-Object System.Windows.Forms.Label
$objLabel3.Location = New-Object System.Drawing.Size(10,60) 
$objLabel3.Size = New-Object System.Drawing.Size(600,40) 
$objLabel3.Text = "Command to run: $CMD"
$objForm.Controls.Add($objLabel3) 

$objForm.Add_Shown({$objForm.Activate()})
[void] $objForm.ShowDialog()
}
Function Show-BoxReboot{
[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms")
[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Drawing") 

$objForm = New-Object System.Windows.Forms.Form 
$objForm.Text = "Select SKU Upgrade"
$objForm.Size = New-Object System.Drawing.Size(600,200) 
$objForm.StartPosition = "CenterScreen"

$objForm.KeyPreview = $True
$objForm.Add_KeyDown({if ($_.KeyCode -eq "Enter") 
    {$x=$objListBox.SelectedItem;$objForm.Close()}})
$objForm.Add_KeyDown({if ($_.KeyCode -eq "Escape") 
    {$objForm.Close()}})

$OKButton = New-Object System.Windows.Forms.Button
$OKButton.Location = New-Object System.Drawing.Size(200,133)
$OKButton.Size = New-Object System.Drawing.Size(75,25)
$OKButton.Text = "OK"
$OKButton.Add_Click({Restart-Computer -Force;$objForm.Close()})
$objForm.Controls.Add($OKButton)

$CancelButton = New-Object System.Windows.Forms.Button
$CancelButton.Location = New-Object System.Drawing.Size(300,133)
$CancelButton.Size = New-Object System.Drawing.Size(75,25)
$CancelButton.Text = "Cancel"
$CancelButton.Add_Click({[environment]::exit(0);$objForm.Close()})
$objForm.Controls.Add($CancelButton)

$objLabel = New-Object System.Windows.Forms.Label
$objLabel.Location = New-Object System.Drawing.Size(10,20) 
$objLabel.Size = New-Object System.Drawing.Size(400,20) 
$objLabel.Text = "You need to reboot the server"
$objForm.Controls.Add($objLabel) 

$objForm.Add_Shown({$objForm.Activate()})
[void] $objForm.ShowDialog()
}
Function Inventory-Computer{
    $CurrentWinCaption = Get-WmiObject -Class Win32_OperatingSystem
    #Write-Output $CurrentWinCaption.Caption
    Switch ($CurrentWinCaption.Caption){
        'Microsoft Windows Server 2008 R2 Standard '{
            Write-Verbose [String]$CurrentWinCaption.Caption
            $UpgradeSelection01 = "Microsoft Windows Server 2008 R2 Enterprise"
            $UpgradeSelection02 = "Microsoft Windows Server 2008 R2 Datacenter"
            }
        'Microsoft Windows Server 2008 R2 Enterprise '{
            Write-Verbose $CurrentWinCaption.Caption
            $UpgradeSelection01 = "Microsoft Windows Server 2008 R2 Datacenter"
            $UpgradeSelection02 = "NA"
            }
        'Microsoft Windows Server 2008 R2 Datacenter '{
            Write-Verbose $CurrentWinCaption.Caption
            $UpgradeSelection01 = "Unable to upgrade current edition"
            $UpgradeSelection02 = "NA"
            }
        'Microsoft Windows Server 2012 Standard'{
            Write-Verbose $CurrentWinCaption.Caption
            $UpgradeSelection01 = "Microsoft Windows Server 2012 Datacenter"
            $UpgradeSelection02 = "NA"
            }
        'Microsoft Windows Server 2012 Standard Evaluation'{
            Write-Verbose $CurrentWinCaption.Caption
            $UpgradeSelection01 = "Microsoft Windows Server 2012 Standard"
            $UpgradeSelection02 = "Microsoft Windows Server 2012 Datacenter"
            }
        'Microsoft Windows Server 2012 Datacenter Evaluation'{
            Write-Verbose $CurrentWinCaption.Caption
            $UpgradeSelection01 = "Microsoft Windows Server 2012 Datacenter"
            $UpgradeSelection02 = "NA"
            }
        'Microsoft Windows Server 2012 Datacenter'{
            Write-Verbose $CurrentWinCaption.Caption
            $UpgradeSelection01 = "Unable to upgrade current edition"
            $UpgradeSelection02 = "NA"
            }
        'Microsoft Windows Server 2012 R2 Standard'{
            Write-Verbose $CurrentWinCaption.Caption
            $UpgradeSelection01 = "Microsoft Windows Server 2012 R2 Datacenter"
            $UpgradeSelection02 = "NA"
            }
        'Microsoft Windows Server 2012 R2 Standard Evaluation'{
            Write-Verbose $CurrentWinCaption.Caption
            $UpgradeSelection01 = "Microsoft Windows Server 2012 R2 Standard"
            $UpgradeSelection02 = "Microsoft Windows Server 2012 R2 Datacenter"
            }
        'Microsoft Windows Server 2012 R2 Datacenter Evaluation'{
            Write-Verbose $CurrentWinCaption.Caption
            $UpgradeSelection01 = "Upgrade to Microsoft Windows Server 2012 R2 Datacenter"
            $UpgradeSelection02 = "NA"
            }
        'Microsoft Windows Server 2012 R2 Datacenter'{
            Write-Verbose $CurrentWinCaption.Caption
            $UpgradeSelection01 = "Unable to upgrade current edition"
            $UpgradeSelection02 = "NA"
            }
        'Microsoft Windows Server 2016 Standard'{
            Write-Verbose $CurrentWinCaption.Caption
            $UpgradeSelection01 = "Microsoft Windows Server 2016 Datacenter"
            $UpgradeSelection02 = "NA"
            }
        'Microsoft Windows Server 2016 Standard Evaluation'{
            Write-Verbose $CurrentWinCaption.Caption
            $UpgradeSelection01 = "Microsoft Windows Server 2016 Standard"
            $UpgradeSelection02 = "Microsoft Windows Server 2016 Datacenter"
            }
        'Microsoft Windows Server 2016 Datacenter Evaluation'{
            Write-Verbose $CurrentWinCaption.Caption
            $UpgradeSelection01 = "Upgrade to Microsoft Windows Server 2016 Datacenter"
            $UpgradeSelection02 = "NA"
            }
        'Microsoft Windows Server 2016 Datacenter'{
            Write-Verbose $CurrentWinCaption.Caption
            $UpgradeSelection01 = "Unable to upgrade current edition"
            $UpgradeSelection02 = "NA"
            }
        Default{
            Write-Verbose "Unable to upgrade"
            $UpgradeSelection01 = "Unable To Upgrade"
            $UpgradeSelection02 = "NA"
            }
        }
}
Function Upgrade-SKU{
    #$CurrentWindowsEdition = [String]$CurrentWinCaption.Caption
    Switch ($CurrentWinCaption.Caption){
        'Microsoft Windows Server 2008 R2 Standard '{
            Write-Verbose [String]$CurrentWinCaption.Caption
            if ($x -eq 'Microsoft Windows Server 2008 R2 Enterprise'){
                $UpgradeToWinEditionPID = "489J6-VHDMP-X63PK-3K798-CPX3Y"
				$CMD = "DISM.exe /Online /Set-Edition:ServerEnterprise /ProductKey:$UpgradeToWinEditionPID /AcceptEula /NoRestart"
                }
            if ($x -eq 'Microsoft Windows Server 2008 R2 Datacenter'){
                $UpgradeToWinEditionPID = "74YFP-3QFB3-KQT8W-PMXWJ-7M648"
				$CMD = "DISM.exe /Online /Set-Edition:ServerDataCenter /ProductKey:$UpgradeToWinEditionPID /AcceptEula /NoRestart"
                }
            }
        'Microsoft Windows Server 2008 R2 Enterprise '{
            Write-Verbose $CurrentWinCaption.Caption
            if ($x -eq 'Microsoft Windows Server 2008 R2 Datacenter'){
                $UpgradeToWinEditionPID = "74YFP-3QFB3-KQT8W-PMXWJ-7M648"
				$CMD = "DISM.exe /Online /Set-Edition:ServerDataCenter /ProductKey:$UpgradeToWinEditionPID /AcceptEula /NoRestart"
                }
            }
        'Microsoft Windows Server 2008 R2 Datacenter '{
            Write-Verbose $CurrentWinCaption.Caption
            }
        'Microsoft Windows Server 2012 Standard'{
            Write-Verbose $CurrentWinCaption.Caption
            if ($x -eq 'Microsoft Windows Server 2012 Datacenter'){
				$UpgradeToWinEditionPID = "48HP8-DN98B-MYWDG-T2DCC-8W83P"
				$CMD = "DISM.exe /Online /Set-Edition:ServerDataCenter /ProductKey:$UpgradeToWinEditionPID /AcceptEula /NoRestart"
                }
            }
        'Microsoft Windows Server 2012 Standard Evaluation'{
            Write-Verbose $CurrentWinCaption.Caption
            if ($x -eq 'Microsoft Windows Server 2012 Standard'){
				$UpgradeToWinEditionPID = "XC9B7-NBPP2-83J2H-RHMBY-92BT4"
				$CMD = "DISM.exe /Online /Set-Edition:ServerStandard /ProductKey:$UpgradeToWinEditionPID /AcceptEula /NoRestart"
                }
            if ($x -eq 'Microsoft Windows Server 2012 Datacenter'){
				$UpgradeToWinEditionPID = "48HP8-DN98B-MYWDG-T2DCC-8W83P"
				$CMD = "DISM.exe /Online /Set-Edition:ServerDataCenter /ProductKey:$UpgradeToWinEditionPID /AcceptEula /NoRestart"
                }
            }
        'Microsoft Windows Server 2012 Datacenter Evaluation'{
            Write-Verbose $CurrentWinCaption.Caption
            if ($x -eq 'Microsoft Windows Server 2012 Datacenter'){
				$UpgradeToWinEditionPID = "48HP8-DN98B-MYWDG-T2DCC-8W83P"
				$CMD = "DISM.exe /Online /Set-Edition:ServerDataCenter /ProductKey:$UpgradeToWinEditionPID /AcceptEula /NoRestart"
                }
            }
        'Microsoft Windows Server 2012 Datacenter'{
            Write-Verbose $CurrentWinCaption.Caption
            }
        'Microsoft Windows Server 2012 R2 Standard'{
            Write-Verbose $CurrentWinCaption.Caption
            if ($x -eq 'Microsoft Windows Server 2012 R2 Datacenter'){
				$UpgradeToWinEditionPID = "W3GGN-FT8W3-Y4M27-J84CP-Q3VJ9"
				$CMD = "DISM.exe /Online /Set-Edition:ServerDataCenter /ProductKey:$UpgradeToWinEditionPID /AcceptEula /NoRestart"
                }
            }
        'Microsoft Windows Server 2012 R2 Standard Evaluation'{
            Write-Verbose $CurrentWinCaption.Caption
            if ($x -eq 'Microsoft Windows Server 2012 R2 Standard'){
				$UpgradeToWinEditionPID = "D2N9P-3P6X9-2R39C-7RTCD-MDVJX"
				$CMD = "DISM.exe /Online /Set-Edition:ServerStandard /ProductKey:$UpgradeToWinEditionPID /AcceptEula /NoRestart"
                }
            if ($x -eq 'Microsoft Windows Server 2012 R2 Datacenter'){
				$UpgradeToWinEditionPID = "W3GGN-FT8W3-Y4M27-J84CP-Q3VJ9"
				$CMD = "DISM.exe /Online /Set-Edition:ServerDataCenter /ProductKey:$UpgradeToWinEditionPID /AcceptEula /NoRestart"
                }
            }
        'Microsoft Windows Server 2012 R2 Datacenter Evaluation'{
            Write-Verbose $CurrentWinCaption.Caption
            if ($x -eq 'Microsoft Windows Server 2012 R2 Datacenter'){
				$UpgradeToWinEditionPID = "W3GGN-FT8W3-Y4M27-J84CP-Q3VJ9"
				$CMD = "DISM.exe /Online /Set-Edition:ServerDataCenter /ProductKey:$UpgradeToWinEditionPID /AcceptEula /NoRestart"
                }
            }
        'Microsoft Windows Server 2012 R2 Datacenter'{
            Write-Verbose $CurrentWinCaption.Caption
            }
        'Microsoft Windows Server 2016 Standard'{
            Write-Verbose $CurrentWinCaption.Caption
            if ($x -eq 'Microsoft Windows Server 2016 Datacenter'){
				$UpgradeToWinEditionPID = "CB7KF-BWN84-R7R2Y-793K2-8XDDG"
				$CMD = "DISM.exe /Online /Set-Edition:ServerDataCenter /ProductKey:$UpgradeToWinEditionPID /AcceptEula /NoRestart"
                }
            }
        'Microsoft Windows Server 2016 Standard Evaluation'{
            Write-Verbose $CurrentWinCaption.Caption
            if ($x -eq 'Microsoft Windows Server 2016 Standard'){
				$UpgradeToWinEditionPID = "WC2BQ-8NRM3-FDDYY-2BFGV-KHKQY"
				$CMD = "DISM.exe /Online /Set-Edition:ServerStandard /ProductKey:$UpgradeToWinEditionPID /AcceptEula /NoRestart"
                }
            if ($x -eq 'Microsoft Windows Server 2016 Datacenter'){
				$UpgradeToWinEditionPID = "CB7KF-BWN84-R7R2Y-793K2-8XDDG"
				$CMD = "DISM.exe /Online /Set-Edition:ServerDataCenter /ProductKey:$UpgradeToWinEditionPID /AcceptEula /NoRestart"
                }
            }
        'Microsoft Windows Server 2016 Datacenter Evaluation'{
            Write-Verbose $CurrentWinCaption.Caption
            if ($x -eq 'Microsoft Windows Server 2016 Datacenter'){
				$UpgradeToWinEditionPID = "CB7KF-BWN84-R7R2Y-793K2-8XDDG"
				$CMD = "DISM.exe /Online /Set-Edition:ServerDataCenter /ProductKey:$UpgradeToWinEditionPID /AcceptEula /NoRestart"
                }
            }
        'Microsoft Windows Server 2016 Datacenter'{
            Write-Verbose $CurrentWinCaption.Caption
            }
        Default {
            Write-Verbose "Unable to upgrade."
            }
        }
}

#Set retunr from forms to Zero
$x = ""
$CMD = ""

# Get a grip of reality
. Inventory-Computer

#Show the options
. Show-BoxSelection

#Set the return value to $X
$X = $objListBox.SelectedItem

#Find out what actully is being done here
. Upgrade-SKU

#Show the result of the selection and the command that will run
. Show-BoxResult

#Execute Upgrade
If($CMD -ne ""){
    cmd.exe /c $CMD
}


#Hold it for a sec...
if ($LastExitCode -eq '3010'){
    Write-Output "Reboot nedeed"
    . Show-BoxReboot
    }
Start-Sleep 5

Write-Host -NoNewLine "Press any key to continue..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
