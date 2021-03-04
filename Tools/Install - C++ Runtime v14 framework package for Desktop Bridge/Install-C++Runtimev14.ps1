<#
.Synopsis
   Short description.
.DESCRIPTION
   Long description
.EXAMPLE

#>

[CmdletBinding(SupportsShouldProcess=$true)]
Param()

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
Function Get-OSVersion{
    $OS = Get-WmiObject -Class Win32_OperatingSystem
    Switch -Regex ($OS.Version)
    {
    "6.1"
        {
        If($OS.ProductType -eq 1)
            {$OSv = "Windows 7 SP1"}
                Else
            {$OSv = "Windows Server 2008 R2"}
        }
    "6.2"
        {If($OS.ProductType -eq 1)
            {$OSv = "Windows 8"}
                Else
            {$OSv = "Windows Server 2012"}
        }
    "6.3"
        {If($OS.ProductType -eq 1)
            {$OSv = "Windows 8.1"}
                Else
            {$OSv = "Windows Server 2012 R2"}
        }
    "10."
        {If($OS.ProductType -eq 1)
            {$OSv = "Windows 10"}
                Else
            {$OSv = "Windows Server 2016"}
        }
    DEFAULT {$OSv = "Unknown"}
    }
    Return $OSV
}
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
        $LogFile = $Logpath + "\" + "$ScriptName.txt"

    }
    Else{
        $Logpath = $env:TEMP
        $LogFile = $Logpath + "\" + "$ScriptName.txt"
    }
    }
}
Function Start-Logging{
    start-transcript -path $LogFile -Force
}
Function Stop-Logging{
    Stop-Transcript
}

# Set Vars
$SCRIPTDIR = split-path -parent $MyInvocation.MyCommand.Path
$SCRIPTNAME = split-path -leaf $MyInvocation.MyCommand.Path
$SOURCEROOT = "$SCRIPTDIR\Source"
$LANG = (Get-Culture).Name
$ARCHITECTURE = $env:PROCESSOR_ARCHITECTURE

#Try to Import SMSTSEnv
. Import-SMSTSENV

#Start Transcript Logging
. Start-Logging

#Detect current OS Version
$OSVersion = Get-OSVersion

#Output base info
Write-Output ""
Write-Output "$ScriptName - ScriptDir: $ScriptDir"
Write-Output "$ScriptName - SourceRoot: $SOURCEROOT"
Write-Output "$ScriptName - ScriptName: $ScriptName"
Write-Output "$ScriptName - OS Name: $OSVersion"
Write-Output "$ScriptName - OS Architecture: $ARCHITECTURE"
Write-Output "$ScriptName - Current Culture: $LANG"
Write-Output "$ScriptName - Integration with MDT(LTI/ZTI): $MDTIntegration"
Write-Output "$ScriptName - Log: $LogFile"

$InstallerFile = Get-ChildItem -Path $SOURCEROOT -Filter *.exe

$Arguments = "/QUIET /NORESTART "
$Exe = $InstallerFile.FullName

Write-Output "$ScriptName - Invoke-Exe -Executable $Exe -Arguments $Arguments"
Invoke-Exe -Executable $Exe -Arguments $Arguments
#Stop Logging
. Stop-Logging