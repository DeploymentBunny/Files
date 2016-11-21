Function Import-SMSTSENV{
    try
    {
        $tsenv = New-Object -COMObject Microsoft.SMS.TSEnvironment
        Write-Output "$ScriptName - tsenv is $tsenv "
        $MDTIntegration = "YES"
        
        #$tsenv.GetVariables() | % { Write-Output "$ScriptName - $_ = $($tsenv.Value($_))" }
    }
    catch
    {
        Write-Output "$ScriptName - Unable to load Microsoft.SMS.TSEnvironment"
        Write-Output "$ScriptName - Running in standalonemode"
        $MDTIntegration = "NO"
    }
    Finally
    {
    if ($MDTIntegration -eq "YES"){
        $Logpath = $tsenv.Value("LogPath")
        $LogFile = $Logpath + "\" + "$ScriptName.log"

    }
    Else{
        $Logpath = $env:TEMP
        $LogFile = $Logpath + "\" + "$ScriptName.log"
    }
    }
}
Function Start-Logging{
    start-transcript -path $LogFile -Force
}
Function Stop-Logging{
    Stop-Transcript
}
Function Invoke-Exe{
    [CmdletBinding(SupportsShouldProcess=$true)]
 
    param(
        [parameter(mandatory=$true,position=0)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Executable,
 
        [parameter(mandatory=$false,position=1)]
        [string]
        $Arguments
    )
 
    if($Arguments -eq "")
    {
        Write-Verbose "Running $ReturnFromEXE = Start-Process -FilePath $Executable -ArgumentList $Arguments -NoNewWindow -Wait -Passthru"
        $ReturnFromEXE = Start-Process -FilePath $Executable -NoNewWindow -Wait -Passthru
    }else{
        Write-Verbose "Running $ReturnFromEXE = Start-Process -FilePath $Executable -ArgumentList $Arguments -NoNewWindow -Wait -Passthru"
        $ReturnFromEXE = Start-Process -FilePath $Executable -ArgumentList $Arguments -NoNewWindow -Wait -Passthru
    }
    Write-Verbose "Returncode is $($ReturnFromEXE.ExitCode)"
    Return $ReturnFromEXE.ExitCode
}

# Set vars
$SCRIPTDIR = split-path -parent $MyInvocation.MyCommand.Path
$SCRIPTNAME = split-path -leaf $MyInvocation.MyCommand.Path
$SOURCEROOT = "$SCRIPTDIR\Source"
$SettingsFile = $SCRIPTDIR + "\" + $SettingsName
$LANG = (Get-Culture).Name
$OSV = $Null
$ARCHITECTURE = $env:PROCESSOR_ARCHITECTURE

#Try to Import SMSTSEnv
. Import-SMSTSENV

# Set more vars
$Make = $tsenv.Value("Make")
$Model = $tsenv.Value("Model")
$ModelAlias = $tsenv.Value("ModelAlias")
$MakeAlias = $tsenv.Value("MakeAlias")

#Start Transcript Logging
. Start-Logging

#Output base info
Write-Output ""
Write-Output "$ScriptName - ScriptDir: $ScriptDir"
Write-Output "$ScriptName - SourceRoot: $SOURCEROOT"
Write-Output "$ScriptName - ScriptName: $ScriptName"
Write-Output "$ScriptName - Current Culture: $LANG"
Write-Output "$ScriptName - Integration with MDT(LTI/ZTI): $MDTIntegration"
Write-Output "$ScriptName - Log: $LogFile"
Write-Output "$ScriptName - Model (win32_computersystem): $((Get-WmiObject Win32_ComputerSystem).model)"
Write-Output "$ScriptName - Name (Win32_ComputerSystemProduct): $((Get-WmiObject Win32_ComputerSystemProduct).Name)"
Write-Output "$ScriptName - Version (Win32_ComputerSystemProduct): $((Get-WmiObject Win32_ComputerSystemProduct).Version)"
Write-Output "$ScriptName - Model (from TSENV): $Model"
Write-Output "$ScriptName - ModelAlias (from TSENV): $ModelAlias"

#Check Model
if($((Get-WmiObject Win32_ComputerSystem).model) -eq 'HP EliteBook 8560w'){
    Write-Output "Model is $((Get-WmiObject Win32_ComputerSystem).model)"
    Write-Output "Checking BIOS Version"
    Write-Output "Version is $((Get-WmiObject Win32_Bios).SMBIOSBIOSVersion)"
    if($((Get-WmiObject Win32_Bios).SMBIOSBIOSVersion) -ne '68SVD Ver. F.50'){
        Write-Output "Needs upgrade"
        $Exe = 'hpqflash.exe'
        $Location = "$SCRIPTDIR\Source\HP EliteBook 8560w"
        $Executable = $Location + "\" + $exe
        Set-Location -Path $Location
        Invoke-Exe -Executable "$Executable" -Arguments "/s /p LCadmin1.bin" -Verbose
    }
    else
    {
        Write-Output "No Need to upgrade"
    }
}
if($((Get-WmiObject Win32_ComputerSystem).model) -eq 'HP ProBook 6570b'){
    Write-Output "Model is $((Get-WmiObject Win32_ComputerSystem).model)"
    Write-Output "Checking BIOS Version"
    Write-Output "Version is $((Get-WmiObject Win32_Bios).SMBIOSBIOSVersion)"
    if($((Get-WmiObject Win32_Bios).SMBIOSBIOSVersion) -Like '*ICE*'){
        if($((Get-WmiObject Win32_Bios).SMBIOSBIOSVersion) -ne '68ICE Ver. F.62'){
            Write-Output "Needs upgrade"
            $Exe = 'hpqflash.exe'
            $Location = "$SCRIPTDIR\Source\HP ProBook 6570b"
            $Executable = $Location + "\" + $exe
            Set-Location -Path $Location
            Invoke-Exe -Executable "$Executable" -Arguments "/s /f 68ICE.cab" -Verbose
        }
        else
        {
            Write-Output "No Need to upgrade"
        }
    }
    if($((Get-WmiObject Win32_Bios).SMBIOSBIOSVersion) -Like '*ICF*'){
        if($((Get-WmiObject Win32_Bios).SMBIOSBIOSVersion) -ne '68ICF Ver. F.62'){
            Write-Output "Needs upgrade"
            $Exe = 'hpqflash.exe'
            $Location = "$SCRIPTDIR\Source\HP ProBook 6570b"
            $Executable = $Location + "\" + $exe
            Set-Location -Path $Location
            Invoke-Exe -Executable "$Executable" -Arguments "/s /f 68ICF.cab" -Verbose
        }
        else
        {
            Write-Output "No Need to upgrade"
        }
    }
}
if($ModelAlias -eq 'HP EliteBook 8460p'){
    Write-Output "Model is $((Get-WmiObject Win32_ComputerSystem).model)"
    Write-Output "Checking BIOS Version"
    Write-Output "Version is $((Get-WmiObject Win32_Bios).SMBIOSBIOSVersion)"
    if($((Get-WmiObject Win32_Bios).SMBIOSBIOSVersion) -Like '*SCF*'){
        if($((Get-WmiObject Win32_Bios).SMBIOSBIOSVersion) -ne '68SCF Ver. F.63'){
            Write-Output "Needs upgrade"
            $Exe = 'hpqflash.exe'
            $Location = "$SCRIPTDIR\Source\HP EliteBook 8460p"
            $Executable = $Location + "\" + $exe
            Set-Location -Path $Location
            Invoke-Exe -Executable "$Executable" -Arguments "/s /f 68SCF.CAB" -Verbose
            }
        else
            {
            Write-Output "No Need to upgrade"
        }
    }
    if($((Get-WmiObject Win32_Bios).SMBIOSBIOSVersion) -Like '*SCE*'){
        if($((Get-WmiObject Win32_Bios).SMBIOSBIOSVersion) -ne '68SCE Ver. F.63'){
            Write-Output "Needs upgrade"
            $Exe = 'hpqflash.exe'
            $Location = "$SCRIPTDIR\Source\HP EliteBook 8460p"
            $Executable = $Location + "\" + $exe
            Set-Location -Path $Location
            Invoke-Exe -Executable "$Executable" -Arguments "/s /f 68SCE.CAB" -Verbose
            }
        else
            {
            Write-Output "No Need to upgrade"
        }
    }
}
if($((Get-WmiObject Win32_ComputerSystem).model) -eq 'HP Compaq dc7900 Small Form Factor'){
    Write-Output "Model is $((Get-WmiObject Win32_ComputerSystem).model)"
    Write-Output "Checking BIOS Version"
    Write-Output "Version is $((Get-WmiObject Win32_Bios).SMBIOSBIOSVersion)"
    if($((Get-WmiObject Win32_Bios).SMBIOSBIOSVersion) -ne '786G1 v01.27'){
        Write-Output "Needs upgrade"
        $Exe = 'hpqflash.exe'
        $Location = "$SCRIPTDIR\Source\HP Compaq dc7900 Small Form Factor\HPQFlash"
        $Executable = $Location + "\" + $exe
        $SourceFile = $Location + "\" + "Password01.bin"
        $Destination = $env:TEMP
        $DestinationFile = $Destination + "\" + "Password01.bin"
        Copy-Item -Path $SourceFile -Destination $DestinationFile -Force -Verbose 
        Set-Location -Path $Location
        Invoke-Exe -Executable $Executable -Arguments "/s /p $DestinationFile"
    }
    else
    {
        Write-Output "No Need to upgrade"
    }
}

#Stop Logging
. Stop-Logging
