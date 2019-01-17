<#
.SYNOPSIS
    Install RSAT from FOD media, instead of the default "online" way
.DESCRIPTION
    The script will get all RSAT FOD components and install the from media. For this to work, you need to download the FOD media and 
    extract it and store the files in a subfolder where this script is located named Source. The script works standalone, integrateded in MDT or ConfigMgr
.EXAMPLE
    Install-RSATToolsfor1809.ps1
.NOTES
        ScriptName: Install-RSATToolsfor1809.ps1
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

$VerbosePreference = "continue"
$writetoscreen = $true

Function Get-VIAOSVersion([ref]$OSv){
    $OS = Get-WmiObject -Class Win32_OperatingSystem
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
    "10"
        {If($OS.ProductType -eq 1)
            {$OSv.value = "Windows 10"}
                Else
            {$OSv.value = "Windows Server 2016"}
        }
    DEFAULT { "Version not listed" }
    } 
}
Function Import-VIASMSTSENV{
    try{
        $tsenv = New-Object -COMObject Microsoft.SMS.TSEnvironment
        Write-Output "$ScriptName - tsenv is $tsenv "
        $MDTIntegration = $true
        
        #$tsenv.GetVariables() | % { Write-Output "$ScriptName - $_ = $($tsenv.Value($_))" }
    }
    catch{
        Write-Output "$ScriptName - Unable to load Microsoft.SMS.TSEnvironment"
        Write-Output "$ScriptName - Running in standalonemode"
        $MDTIntegration = $false
    }
    Finally{
        if ($MDTIntegration -eq $true){
            $Logpath = $tsenv.Value("LogPath")
            $LogFile = $Logpath + "\" + "$ScriptName.log"
        }
    Else{
            $Logpath = $env:TEMP
            $LogFile = $Logpath + "\" + "$ScriptName.log"
        }
    }
    Return $MDTIntegration
}
Function Invoke-VIAExe{
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
Function Start-Log
{
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
Function Write-Log
{
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

    if($writetolistbox -eq $true){
        $result1.Items.Add("$Message")
    }
}

# Set Vars
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScriptName = Split-Path -Leaf $MyInvocation.MyCommand.Path
#[xml]$Settings = Get-Content "$ScriptDir\Settings.xml"
$ARCHITECTURE = $env:PROCESSOR_ARCHITECTURE

#Try to Import SMSTSEnv
. Import-VIASMSTSENV

#Start logging
Start-Log -FilePath $LogFile

#Output more info
Write-Log "$ScriptName - ScriptDir: $ScriptDir"
Write-Log "$ScriptName - ScriptName: $ScriptName"
Write-Log "$ScriptName - Integration with TaskSequence(LTI/ZTI): $MDTIntegration"
Write-Log "$ScriptName - Log: $LogFile"

#Generate more info
if($MDTIntegration -eq "YES"){
    $TSMake = $tsenv.Value("Make")
    $TSModel = $tsenv.Value("Model")
    Write-Log "$ScriptName - Make:: $TSMake"
    Write-Log "$ScriptName - Model: $TSModel"
}
#Custom Code Starts--------------------------------------

#Get RSAT tools from FOD
$Items = Get-WindowsCapability -Name RSAT* -Online
ForEach($Item in $Items)
{
    Write-Log "$ScriptName - Adding $($Item.displayname)"
    $Item | Add-WindowsCapability -Online -LimitAccess -Source "$ScriptDir\source"
    $Return = Get-WindowsCapability -Name $Item.Name -Online
    Write-Log "$ScriptName - $($Item.displayname) state is now $($Return.State)"
}

#Custom Code Ends--------------------------------------
