<#
.SYNOPSIS
    Baseconfig for WS2016/2019
.DESCRIPTION
    Baseconfig for WS2016/2019
.EXAMPLE
    Baseconfig for WS2016/2019
.NOTES
        ScriptName: Configure-WindowsServer.ps1
        Author:     Mikael Nystrom
        Twitter:    @mikael_nystrom
        Email:      mikael.nystrom@truesec.se
        Blog:       https://deploymentbunny.com

    Version History
    1.0.0 - Script created [01/16/2019 13:12:16]

Copyright (c) 2019 Mikael Nystrom

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
#>

[cmdletbinding(SupportsShouldProcess=$True)]
Param(
)

Function Get-TSxTest {
    Return "OK"
}
Function Get-TSxOSVersion([ref]$OSv) {
    $OS = Get-WmiObject -Class Win32_OperatingSystem | Select *
    Switch -Regex ($OS.Version)
    {
    "6.1"
        {If($OS.ProductType -eq 1)
            {$OSv.value = "Windows 7 SP1"}
                Else
            {$OSv.value = "Windows Server 2008 R2"}
        }
    "6.2"
        {If($OS.ProductType -eq 1)
            {$OSv.value = "Windows 8"}
                Else
            {$OSv.value = "Windows Server 2012"}
        }
    "6.3"
        {If($OS.ProductType -eq 1)
            {$OSv.value = "Windows 8.1"}
                Else
            {$OSv.value = "Windows Server 2012 R2"}
        }
    "10.0.14"
        {If($OS.ProductType -eq 1)
            {$OSv.value = "Windows 10 1607"}
                Else
            {$OSv.value = "Windows Server 2016"}
        }
    "10.0.17"
        {If($OS.ProductType -eq 1)
            {$OSv.value = "Windows 10 1809"}
                Else
            {$OSv.value = "Windows Server 2019"}
        }
    DEFAULT { "Version not listed" }
    } 
}
Function Get-TSxOSSKU {
    $Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Server\ServerLevels\'
    if(Test-Path -Path $Path)
    {
        $Test = Get-ItemProperty -Path $Path
        if(($Test.'ServerCore' -eq 1) -and ($Test.'Server-Gui-Shell' -eq 1)){$OSSKU = "DesktopExperience"}
        if(($Test.'ServerCore' -eq 1) -and ($Test.'Server-Gui-Shell' -ne 1)){$OSSKU = "Core"}
        Return $OSSKU
    }
    else
    {
        Return "Unknown"
    }
}
Function Invoke-TSxExe {
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
        Write-Verbose "Running Start-Process -FilePath $Executable -ArgumentList $Arguments -NoNewWindow -Wait -Passthru"
        $ReturnFromEXE = Start-Process -FilePath $Executable -NoNewWindow -Wait -Passthru
    }else{
        Write-Verbose "Running Start-Process -FilePath $Executable -ArgumentList $Arguments -NoNewWindow -Wait -Passthru"
        $ReturnFromEXE = Start-Process -FilePath $Executable -ArgumentList $Arguments -NoNewWindow -Wait -Passthru
    }
    Write-Verbose "Returncode is $($ReturnFromEXE.ExitCode)"
    Return $ReturnFromEXE.ExitCode
}
Function Start-TSxLog {
[CmdletBinding()]
    param (
    [ValidateScript({ Split-Path $_ -Parent | Test-Path })]
               [string]$FilePath
    )
               
    try
    {
        if (!(Test-Path $FilePath))
               {
                   ## Create the log file
                   New-Item $FilePath -Type File | Out-Null
               }
                              
               ## Set the global variable to be used as the FilePath for all subsequent Write-Log
               ## calls in this session
               $global:ScriptLogFilePath = $FilePath
    }
    catch
    {
        Write-Error $_.Exception.Message
    }
}
Function Write-TSxLog {
               param (
                              [Parameter(Mandatory = $true)]
                              [string]$Message,
                                             
                              [Parameter()]
                              [ValidateSet(1, 2, 3)]
                              [string]$LogLevel = 1
               )

    $TimeGenerated = "$(Get-Date -Format HH:mm:ss).$((Get-Date).Millisecond)+000"
    $Line = '<![LOG[{0}]LOG]!><time="{1}" date="{2}" component="{3}" context="" type="{4}" thread="" file="">'
    $LineFormat = $Message, $TimeGenerated, (Get-Date -Format MM-dd-yyyy), "$($MyInvocation.ScriptName | Split-Path -Leaf):$($MyInvocation.ScriptLineNumber)", $LogLevel
    #$LineFormat = $Message, $TimeGenerated, (Get-Date -Format MM-dd-yyyy), "$($MyInvocation.ScriptName | Split-Path -Leaf)", $LogLevel
    $Line = $Line -f $LineFormat
    Add-Content -Value $Line -Path $ScriptLogFilePath

    if($writetoscreen -eq $true){
        switch ($LogLevel)
        {
            '1'{
                Write-Host $Message -ForegroundColor Gray
                }
            '2'{
                Write-Host $Message -ForegroundColor Yellow
                }
            '3'{
                Write-Host $Message -ForegroundColor Red
                }
            Default {}
        }
    }
}
Function Get-TSxISVM {
    $Win32_computersystem  = Get-WmiObject -Class Win32_computersystem 
    switch ($Win32_computersystem.Model)
    {
        'VMware Virtual Platform' {$IsVM = "True"}
        'VMware7,1' {$IsVM = "True"}
        'Virtual Machine' {$IsVM = "True"}
        'Virtual Box' {$IsVM = "True"}
        Default {$IsVM = "True"}
    }
    Return $IsVM
}
Function Get-TSxISCoreServer {
    (Get-ItemProperty -Path "HKLM:\software\microsoft\windows nt\CurrentVersion").InstallationType -eq "Server Core"
}

# Set Vars
$VerbosePreference = "continue"
$writetoscreen = $true
$osv = ''
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScriptName = Split-Path -Leaf $MyInvocation.MyCommand.Path
$ARCHITECTURE = $env:PROCESSOR_ARCHITECTURE

# Import Microsoft.SMS.TSEnvironment
$tsenv = New-Object -COMObject Microsoft.SMS.TSEnvironment
$Logpath = $tsenv.Value("LogPath")
$LogFile = $Logpath + "\" + "$ScriptName.log"
$DeployRoot = $tsenv.Value("DeployRoot")

#Start logging
Start-TSxLog -FilePath $LogFile
Write-TSxLog "$ScriptName - Logging to $LogFile"

# Generate Vars
$OSSKU = Get-TSxOSSKU
$TSMake = $tsenv.Value("Make")
$TSModel = $tsenv.Value("Model")

Write-TSxLog "$ScriptName - Get-TSxOSVersion"
Get-TSxOSVersion -osv ([ref]$osv)  

Write-TSxLog "$ScriptName - Check if we are IsServerCoreOS"
$IsServerCoreOS = Get-TSxISCoreServer
Write-TSxLog "$ScriptName - IsServerCoreOS is now $IsServerCoreOS"

#Output more info
Write-TSxLog "$ScriptName - ScriptDir: $ScriptDir"
Write-TSxLog "$ScriptName - ScriptName: $ScriptName"
Write-TSxLog "$ScriptName - Log: $LogFile"
Write-TSxLog "$ScriptName - OSSKU: $OSSKU"
Write-TSxLog "$ScriptName - OSVersion: $osv"
Write-TSxLog "$ScriptName - Make:: $TSMake"
Write-TSxLog "$ScriptName - Model: $TSModel"

#Custom Code Starts--------------------------------------

Write-TSxLog "$ScriptName - [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12,[Net.SecurityProtocolType]::Tls11"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12,[Net.SecurityProtocolType]::Tls11

$CreateFolderStructure = $False
$DoNotOpenServerManagerAtLogon = $False
$EnableRemoteDesktop = $False
$ConfigureServerManagerPerformanceMonitor = $true
$DisableShowWelcomeTileforallusers = $true
$EnableSmartScreen = $true
$SetCrashControl = $False
$ConfigureFirewallRules = $False
$ConfigureEventlogs = $False
$SetPowerSchemaSettingsHighPerformance = $False
$SetConfirmDeleteQuestion = $False
$AddingShortCutForNotepadToSendTofolder = $False
$ConfigureScreenSaver = $False
$ShowTaskbarSmallIcons = $False
$ShowFileExt = $True
$ShowHiddenFiles = $True
$ShowSuperHiddenFiles = $True
$AlwaysShowMenus = $True
$AlwaysShowFullPath = $True
$HideMergeConflicts = $True
$HideDrivesWithNoMedia = $True
$LaunchSeparateProcess = $True
$ShowIconsOnlyNoThumbnails = $False
$DontShowInfoTip = $True
$ShowComputerOnDesktop = $True
$ShowAllTaskbarIconsAndNotifcations = $True
$SetControlPanelToSmallIconsView = $True
$DisableVolumeIcon = $False
$DisableAutosearch = $False
$SetAutoDetectProxySettingsEmpty = $False
$DisableServices = $True
$DisableAdminCenterPopup = $True
#Action

Write-TSxLog "$ScriptName - $Action - Loading C:\Users\Default\NTUSER.DAT"
REG LOAD HKEY_LOCAL_MACHINE\defuser  "C:\Users\Default\NTUSER.DAT"


if($DisableAdminCenterPopup -eq $True){
    switch ($osv){
        'Windows Server 2019'{
            #Action
            $Action = "Configure NoWindowsAdminPopup"
            Write-TSxLog "$ScriptName - $Action"
            try{
                $Name = "DoNotPopWACConsoleAtSMLaunch"
                $Path = "HKLM:\SOFTWARE\Microsoft\ServerManager"
                $PropertyType = "DWORD"
                $Value = 1
                $Result = New-ItemProperty -Path $Path -Name $Name -PropertyType $PropertyType -Value $Value -Force
                Write-TSxLog "$ScriptName - $Path\$Name is now: $($Result.$Name)"
            }
            catch{
                Write-TSxLog "$ScriptName - $Action - Fail"
            }
        }
        Default {
        }
    }
}
if($DisableServices -eq $true -and $IsServerCoreOS -eq $false){
    switch ($osv){
        'Windows Server 2016'{
            #Disable unneeded services in Windows Server 2016 Desktop Edition
            $Services = 'CDPUserSvc','MapsBroker','PcaSvc','ShellHWDetection','OneSyncSvc','WpnService'

            foreach($Service in $Services){
                Set-Service -StartupType Disabled -Name $Service
            }
        }
        Default {
        }
    }
}
if($CreateFolderStructure -eq $True){
    $Action = "Create folder structure"
    Write-TSxLog "$ScriptName - $Action"
    try
    {
        $Folders = "C:\Temp"
        foreach ($folder in $Folders){
            $result = New-Item -Path  -ItemType Directory -Force
            Write-TSxLog "$ScriptName - Created: $($Result.FullName)"
        }
    }
    catch{
        Write-TSxLog "$ScriptName - $Action - Fail"
    }
}
if($DoNotOpenServerManagerAtLogon -eq $True){
    #Action
    $Action = "Configure DoNotOpenServerManagerAtLogon"
    Write-TSxLog "$ScriptName - $Action"
    try
    {
        $Name = "DoNotOpenServerManagerAtLogon"
        $Path = "HKLM:\SOFTWARE\Microsoft\ServerManager"
        $PropertyType = "DWORD"
        $Value = 1
        $Result = New-ItemProperty -Path $Path -Name $Name -PropertyType $PropertyType -Value $Value -Force
        Write-TSxLog "$ScriptName - $Path\$Name is now: $($Result.$Name)"
    }
    catch{
        Write-TSxLog "$ScriptName - $Action - Fail"
    }
}
if($EnableRemoteDesktop -eq $True){
    #Action
    $Action = "Configure Remote Desktop"
    Write-TSxLog "$ScriptName - $Action"
    try
    {
        cscript.exe /nologo C:\windows\system32\SCregEdit.wsf /AR 0
    }
    catch{
        Write-TSxLog "$ScriptName - $Action - Fail"
    }

    #Action
    $Action = "Configure Remote Destop Security"
    Write-TSxLog "$ScriptName - $Action"
    try
    {
        cscript.exe /nologo C:\windows\system32\SCregEdit.wsf /CS 1
    }
    catch{
        Write-TSxLog "$ScriptName - $Action - Fail"
    }
}
if($ConfigureServerManagerPerformanceMonitor -eq $true){
    #Server Manager Performance Monitor
    $Action = "Configure Server Manager Performance Monitor"
    Write-TSxLog "$ScriptName - $Action"
    try{
        Start-SMPerformanceCollector -CollectorName 'Server Manager Performance Monitor'
    }catch{
        Write-TSxLog "$ScriptName - $Action - Fail"
    }
}
if($DisableShowWelcomeTileforallusers -eq $true){
    #Disable Show Welcome Tile for all users
    $Action = "Configure Show Welcome Tile"
    Write-TSxLog "$ScriptName - $Action"
    try{
    $XMLBlock = @(
    '<?xml version="1.0" encoding="utf-8"?>
      <configuration>
       <configSections>
        <sectionGroup name="userSettings" type="System.Configuration.UserSettingsGroup, System, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089">
        <section name="Microsoft.Windows.ServerManager.Common.Properties.Settings" type="System.Configuration.ClientSettingsSection, System, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089" allowExeDefinition="MachineToLocalUser" requirePermission="false" />
        </sectionGroup>
       </configSections>
       <userSettings>
        <Microsoft.Windows.ServerManager.Common.Properties.Settings>
         <setting name="WelcomeTileVisibility" serializeAs="String">
          <value>Collapsed</value>
         </setting>
        </Microsoft.Windows.ServerManager.Common.Properties.Settings>
       </userSettings>
      </configuration>'
      )
    $XMLBlock | Out-File -FilePath C:\Windows\System32\ServerManager.exe.config -Encoding ascii -Force
    }catch{
        Write-TSxLog "$ScriptName - $Action - Fail"
    }
}
if($EnableSmartScreen -eq $true){
    # Enable SmartScreen
    $Action = "Configure SmartScreen"
    Write-TSxLog "$ScriptName - $Action"
    try{
        $OptionType = 2
        $KeyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
        New-ItemProperty -Path $KeyPath -Name EnableSmartScreen -Value $OptionType -PropertyType DWord -Force
    }catch{
        Write-TSxLog "$ScriptName - $Action - Fail"
    }
}
if($SetCrashControl -eq $true){
    # Set CrashControl
    $Action = "Set CrashControl"
    Write-TSxLog "$ScriptName - $Action"
    try{
        $Path = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"
        $Name = "AutoReboot"
        $Value = 00000001
        $PropertyType = "DWORD"
        $Result = New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $PropertyType -Force
        Write-TSxLog "$ScriptName - $Path\$Name is now: $($Result.$Name)"

        $Path = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"
        $Name = "CrashDumpEnabled"
        $Value = 00000001
        $PropertyType = "DWORD"
        $Result = New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $PropertyType -Force
        Write-TSxLog "$ScriptName - $Path\$Name is now: $($Result.$Name)"

        $Path = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"
        $Name = "LogEvent"
        $Value = 00000001
        $PropertyType = "DWORD"
        $Result = New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $PropertyType -Force
        Write-TSxLog "$ScriptName - $Path\$Name is now: $($Result.$Name)"

        $Path = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"
        $Name = "MinidumpsCount"
        $Value = 00000005
        $PropertyType = "DWORD"
        $Result = New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $PropertyType -Force
        Write-TSxLog "$ScriptName - $Path\$Name is now: $($Result.$Name)"

        $Path = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"
        $Name = "Overwrite"
        $Value = 00000001
        $PropertyType = "DWORD"
        $Result = New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $PropertyType -Force
        Write-TSxLog "$ScriptName - $Path\$Name is now: $($Result.$Name)"

        $Path = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"
        $Name = "AlwaysKeepMemoryDump"
        $Value = 00000000
        $PropertyType = "DWORD"
        $Result = New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $PropertyType -Force
        Write-TSxLog "$ScriptName - $Path\$Name is now: $($Result.$Name)"

        $Path = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"
        $Name = "FilterPages"
        $Value = 00000001
        $PropertyType = "DWORD"
        $Result = New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $PropertyType -Force
        Write-TSxLog "$ScriptName - $Path\$Name is now: $($Result.$Name)"
    }
    catch{
        Write-TSxLog "$ScriptName - $Action - Fail"
    }
}
if($ConfigureFirewallRules -eq $true){
    # Configure firewall rules
    $Action = "Configure firewall rules"
    Write-TSxLog "$ScriptName - $Action"
    try{
        $RuleSet = Get-NetFirewallRule -Group "@FirewallAPI.dll,-28752"
        $RuleSet | Enable-NetFirewallRule -Verbose

        foreach ($Rule in $RuleSet){
            Write-TSxLog "$ScriptName - $Action - $($Rule.Description) is now Enabled:$($Rule.Enabled)"
        }
    }catch{
        Write-TSxLog "$ScriptName - $Action - Fail"
    }
}
if($ConfigureEventlogs -eq $True){
    # Configure Eventlogs
    $Action = "Configure Eventlogs"
    Write-TSxLog "$ScriptName - $Action"
    $EventLogs = "Application","Security","System"
    $MaxSize = 2GB
    foreach($EventLog in $EventLogs){
        try{
            Limit-EventLog -LogName $EventLog -MaximumSize $MaxSize
        }
        catch{
            Write-TSxLog "$ScriptName - $Action Could not set $EventLog to $MaxSize, sorry"
        }
        $EventLogData = Get-EventLog -List | Where-Object Log -EQ $EventLog
        Write-TSxLog "$ScriptName - $Action $($EventLogData.Log) log is now set to now $($EventLogData.MaximumKilobytes)"
    }
}
if($SetPowerSchemaSettingsHighPerformance -eq $True){
    # Set PowerSchemaSettings to High Performance
    $Action = "Set PowerSchemaSettings to High Performance"
    Write-TSxLog "$ScriptName - $Action"
    try{
        Invoke-TSxExe -Executable powercfg.exe -Arguments "/SETACTIVE 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c" -Verbose
    }
    catch{
        Write-TSxLog "$ScriptName - $Action - Fail"
    }
    $PowerCfgConfig = powercfg.exe /GETACTIVESCHEME
    Write-TSxLog "$ScriptName - $PowerCfgConfig"
}
if($SetConfirmDeleteQuestion -eq $true -and $IsServerCoreOS -eq $false){
        # Set ConfirmDeleteQuestion to ask before deletion
        $Action = "Set ConfirmDeleteQuestion to ask before deletion"

        Write-TSxLog "$ScriptName - $Action"
        $RegistryPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
        $Result = New-ItemProperty -Path $RegistryPath -Name "ScreenSaverIsSecure" -PropertyType DWORD -Value "0000001" -Force
        Write-TSxLog "$ScriptName - TaskbarSmallIcons is now: $($result.ScreenSaverIsSecure)"
    }
if($AddingShortCutForNotepadToSendTofolder -eq $true -and $IsServerCoreOS -eq $false){
        try{
            $Action = "Adding ShortCut for Notepad in the SendTo folder"
            Write-TSxLog "$ScriptName - $Action"

            $Folder = "C:\Users\Default\AppData\Roaming\Microsoft\Windows\SendTo\"
            $linkPath = "$Folder\Notepad.lnk"
            $wshShell = New-Object -comObject WScript.Shell
            $shortcut = $WshShell.CreateShortcut($linkPath)
            $shortcut.Description = "Notepad"
            $shortcut.HotKey = ""
            $shortcut.IconLocation = "C:\Windows\System32\Notepad.exe,0"
            $shortcut.TargetPath = "C:\Windows\System32\Notepad.exe"
            $shortcut.WindowStyle = 3
            $shortcut.WorkingDirectory = "C:\Windows\System32"
            $shortcut.Save()

        }
        catch{
            Write-TSxLog "$ScriptName - $Action - Fail"
        }
    }
if($ConfigureScreenSaver -eq $true){
    $Action = "Configure Screen Saver"
    Write-TSxLog "$ScriptName - $Action"

    $Path = "HKCU:\Control Panel\Desktop"
    $Name = "ScreenSaverIsSecure"
    $Result = New-ItemProperty -Path $Path -Name $Name -Value 1 -PropertyType String -Force
    Write-TSxLog "$ScriptName - $Path\$Name is now: $($result.$Name)"

    $Path = "HKCU:\Control Panel\Desktop"
    $Name = "ScreenSaveActive"
    $Result = New-ItemProperty -Path $Path -Name $Name -Value 1 -PropertyType String -Force
    Write-TSxLog "$ScriptName - TaskbarSmallIcons is now: $($result.$Name)"

    $Path = "HKCU:\Control Panel\Desktop"
    $Name = "ScreenSaveTimeOut"
    $Result = New-ItemProperty -Path $Path -Name ScreenSaveTimeOut -Value 900 -PropertyType String -Force
    Write-TSxLog "$ScriptName - TaskbarSmallIcons is now: $($result.$Name)"

    $Path = "HKCU:\defuser\Control Panel\Desktop"
    $Name = "ScreenSaverIsSecure"
    $Result = New-ItemProperty -Path $Path -Name $Name -Value 1 -PropertyType String -Force
    Write-TSxLog "$ScriptName - $Path\$Name is now: $($result.$Name)"

    $Path = "HKCU:\defuser\Control Panel\Desktop"
    $Name = "ScreenSaveActive"
    $Result = New-ItemProperty -Path $Path -Name $Name -Value 1 -PropertyType String -Force
    Write-TSxLog "$ScriptName - $Path\$Name is now: $($result.$Name)"

    $Path = "HKCU:\defuser\Control Panel\Desktop"
    $Name = "ScreenSaveTimeOut"
    $Result = New-ItemProperty -Path $Path -Name $Name -Value 900 -PropertyType String -Force
    Write-TSxLog "$ScriptName - $Path\$Name is now: $($result.$Name)"


}
if($ShowTaskbarSmallIcons -eq $true -and $IsServerCoreOS -eq $false){
    # Show small icons on taskbar
    $result = New-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name TaskbarSmallIcons -Value 1 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - TaskbarSmallIcons is now: $($result.TaskbarSmallIcons)"	

    # Show small icons on taskbar
    $result = New-ItemProperty -Path 'HKLM:\defuser\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name TaskbarSmallIcons -Value 1 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - TaskbarSmallIcons is now: $($result.TaskbarSmallIcons)"	
}
if($ShowFileExt -eq $true -and $IsServerCoreOS -eq $false){
    # Folderoptions Show file extensions	
    $result = New-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name HideFileExt -Value 0 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - HideFileExt is now: $($result.HideFileExt)"	

    # Folderoptions Show file extensions	
    $result = New-ItemProperty -Path 'HKLM:\defuser\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name HideFileExt -Value 0 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - HideFileExt is now: $($result.HideFileExt)"	
}
if($ShowHiddenFiles -eq $true -and $IsServerCoreOS -eq $false){
    # Folderoptions Show hidden files, show hidden systemfiles file
    $result = New-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name Hidden -Value 1 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - Hidden is now: $($result.Hidden)"
    
    # Folderoptions Show hidden files, show hidden systemfiles file
    $result = New-ItemProperty -Path 'HKLM:\defuser\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name Hidden -Value 1 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - Hidden is now: $($result.Hidden)"	
}
if($ShowSuperHiddenFiles -eq $true -and $IsServerCoreOS -eq $false){
    $result = New-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name ShowSuperHidden -Value 1 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - SuperHidden is now: $($result.ShowSuperHidden)"	

    $result = New-ItemProperty -Path 'HKLM:\defuser\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name ShowSuperHidden -Value 1 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - SuperHidden is now: $($result.ShowSuperHidden)"	
}
if($AlwaysShowMenus -eq $true -and $IsServerCoreOS -eq $false){
    # Folderoptions Always shows Menus
    $result = New-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name AlwaysShowMenus -Value 1 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - AlwaysShowMenus is now: $($result.AlwaysShowMenus)"	

    # Folderoptions Always shows Menus
    $result = New-ItemProperty -Path 'HKLM:\defuser\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name AlwaysShowMenus -Value 1 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - AlwaysShowMenus is now: $($result.AlwaysShowMenus)"	
}
if($AlwaysShowFullPath -eq $true -and $IsServerCoreOS -eq $false){
    # Folderoptions Display the full path in the title bar
    $result = New-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name FullPath -Value 1 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - FullPath is now: $($result.FullPath)"

    # Folderoptions Display the full path in the title bar
    $result = New-ItemProperty -Path 'HKLM:\defuser\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name FullPath -Value 1 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - FullPath is now: $($result.FullPath)"	
}
if($HideMergeConflicts -eq $true -and $IsServerCoreOS -eq $false){
    # Folderoptions HideMerge Conflicts
    $result = New-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name HideMergeConflicts -Value 0 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - HideMergeConflicts is now: $($result.HideMergeConflicts)"

    # Folderoptions HideMerge Conflicts
    $result = New-ItemProperty -Path 'HKLM:\defuser\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name HideMergeConflicts -Value 0 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - HideMergeConflicts is now: $($result.HideMergeConflicts)"	
}
if($HideDrivesWithNoMedia -eq $true -and $IsServerCoreOS -eq $false){
    # Folderoptions Hide empty drives in the computer folder	
    $result = New-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name HideDrivesWithNoMedia -Value 0 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - HideDrivesWithNoMedia is now: $($result.HideDrivesWithNoMedia)"

    # Folderoptions Hide empty drives in the computer folder	
    $result = New-ItemProperty -Path 'HKLM:\defuser\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name HideDrivesWithNoMedia -Value 0 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - HideDrivesWithNoMedia is now: $($result.HideDrivesWithNoMedia)"	
}
if($LaunchSeparateProcess -eq $true -and $IsServerCoreOS -eq $false){
    # Folderoptions launch folder windows in separate process
    $result = New-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name SeparateProcess -Value 1 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - SeparateProcess is now: $($result.SeparateProcess)"

   # Folderoptions launch folder windows in separate process
    $result = New-ItemProperty -Path 'HKLM:\defuser\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name SeparateProcess -Value 1 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - SeparateProcess is now: $($result.SeparateProcess)"	
}
if($ShowIconsOnlyNoThumbnails -eq $true -and $IsServerCoreOS -eq $false){
    # Folderoptions Always show icons never thumbnails
    $result = New-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name IconsOnly -Value 1 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - IconsOnly is now: $($result.IconsOnly)"

    # Folderoptions Always show icons never thumbnails
    $result = New-ItemProperty -Path 'HKLM:\defuser\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name IconsOnly -Value 1 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - IconsOnly is now: $($result.IconsOnly)"	
}
if($DontShowInfoTip -eq $true -and $IsServerCoreOS -eq $false){
    # Dont show tooltip	
    $result = New-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name ShowInfoTip -Value 0 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - ShowInfoTip is now: $($result.ShowInfoTip)"

    # Dont show tooltip	
    $result = New-ItemProperty -Path 'HKLM:\defuser\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name ShowInfoTip -Value 0 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - ShowInfoTip is now: $($result.ShowInfoTip)"	
}
if($ShowComputerOnDesktop -eq $true -and $IsServerCoreOS -eq $false){
    # Show computer on desktop
    $null = New-Item -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons' -Force
    $null = New-Item -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel' -Force
    $result = New-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel' -Name '{20D04FE0-3AEA-1069-A2D8-08002B30309D}' -Value 0 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - TaskbarSmallIcons is now: $($result.'{20D04FE0-3AEA-1069-A2D8-08002B30309D}')"

    # Show computer on desktop
    $null = New-Item -Path 'HKLM:\defuser\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons' -Force
    $null = New-Item -Path 'HKLM:\defuser\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel' -Force
    $result = New-ItemProperty -Path 'HKLM:\defuser\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel' -Name '{20D04FE0-3AEA-1069-A2D8-08002B30309D}' -Value 0 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - TaskbarSmallIcons is now: $($result.'{20D04FE0-3AEA-1069-A2D8-08002B30309D}')"	
}
if($ShowAllTaskbarIconsAndNotifcations -eq $true -and $IsServerCoreOS -eq $false){
    # Always show all taskbar icons and notifcations
    $result = New-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -Name EnableAutoTray -Value 0 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - EnableAutoTray is now: $($result.EnableAutoTray)"

    # Always show all taskbar icons and notifcations
    $result = New-ItemProperty -Path 'HKLM:\defuser\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -Name EnableAutoTray -Value 0 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - EnableAutoTray is now: $($result.EnableAutoTray)"
}
if($SetControlPanelToSmallIconsView  -eq $true -and $IsServerCoreOS -eq $false){
    # Set control panel to small icons view 
    $null = New-Item -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel' -Force
    $result = New-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel' -Name AllItemsIconView -Value 1 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - AllItemsIconView is now: $($result.AllItemsIconView)"	
    $result = New-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel' -Name StartupPage -Value 1 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - StartupPage is now: $($result.StartupPage)"

    # Set control panel to small icons view 
    $null = New-Item -Path 'HKLM:\defuser\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel' -Force
    $result = New-ItemProperty -Path 'HKLM:\defuser\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel' -Name AllItemsIconView -Value 1 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - AllItemsIconView is now: $($result.AllItemsIconView)"	
    $result = New-ItemProperty -Path 'HKLM:\defuser\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel' -Name StartupPage -Value 1 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - StartupPage is now: $($result.StartupPage)"
}
if($DisableVolumeIcon -eq $true -and $IsServerCoreOS -eq $false){
    # Disable the Volume Icon in system icons
    $null = New-Item -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies' -Force
    $null = New-Item -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Force
    $result = New-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Name HideSCAVolume -Value 1 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - HideSCAVolume is now: $($result.HideSCAVolume)"	
	
    # Disable the Volume Icon in system icons
    $null = New-Item -Path 'HKLM:\defuser\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies' -Force
    $null = New-Item -Path 'HKLM:\defuser\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Force
    $result = New-ItemProperty -Path 'HKLM:\defuser\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Name HideSCAVolume -Value 1 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - HideSCAVolume is now: $($result.HideSCAVolume)"
}
if($DisableAutosearch -eq $true -and $IsServerCoreOS -eq $false){
    # Disable Search in the address bar and the search box on the new tab page
    $result = New-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Internet Explorer\Main' -Name Autosearch -Value 0 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - Autosearch is now: $($result.Autosearch)"

    # Disable Search in the address bar and the search box on the new tab page
    $result = New-ItemProperty -Path 'HKLM:\defuser\SOFTWARE\Microsoft\Internet Explorer\Main' -Name Autosearch -Value 0 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - Autosearch is now: $($result.Autosearch)"	
}
if($SetAutoDetectProxySettingsEmpty -eq $true -and $IsServerCoreOS -eq $false){
    # Set AutoDetectProxySettings Empty 
    $result = New-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings' -Name AutoDetect -Value 0 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - AutoDetect is now: $($result.AutoDetect)"

    # Set AutoDetectProxySettings Empty 
    $result = New-ItemProperty -Path 'HKLM:\defuser\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings' -Name AutoDetect -Value 0 -PropertyType DWORD -Force
    Write-TSxLog "$ScriptName - AutoDetect is now: $($result.AutoDetect)"	
}

[gc]::collect()
Write-TSxLog "$ScriptName - $Action - UnLoading C:\Users\Default\NTUSER.DAT"
REG UNLOAD HKEY_LOCAL_MACHINE\defuser

Write-TSxLog "$ScriptName - Done"
#Custom Code Ends--------------------------------------
