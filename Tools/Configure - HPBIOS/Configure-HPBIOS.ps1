<#
 Install Wrapper 1.0
 Author: Mikael Nystrom
 http://www.deploymentbunny.com 
#>
param($Username,$Password,$mode)
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
Function Get-OSVersion([ref]$OSv){
    $OS = Get-WmiObject -class Win32_OperatingSystem
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

# Set Vars
$SCRIPTDIR = split-path -parent $MyInvocation.MyCommand.Path
$SCRIPTNAME = split-path -leaf $MyInvocation.MyCommand.Path
$SOURCEROOT = "$SCRIPTDIR\Source"
$LANG = (Get-Culture).Name
$OSV = $Null
$ARCHITECTURE = $env:PROCESSOR_ARCHITECTURE

#Try to Import SMSTSEnv
. Import-SMSTSENV

#Start Transcript Logging
. Start-Logging

#Detect current OS Version
. Get-OSVersion -osv ([ref]$osv) 

#Output base info
Write-Output ""
Write-Output "$ScriptName - ScriptDir: $ScriptDir"
Write-Output "$ScriptName - SourceRoot: $SOURCEROOT"
Write-Output "$ScriptName - ScriptName: $ScriptName"
Write-Output "$ScriptName - OS Name: $osv"
Write-Output "$ScriptName - OS Architecture: $ARCHITECTURE"
Write-Output "$ScriptName - Current Culture: $LANG"
Write-Output "$ScriptName - Integration with MDT(LTI/ZTI): $MDTIntegration"
Write-Output "$ScriptName - Log: $LogFile"

$Credentials = New-Object System.Management.Automation.PSCredential -ArgumentList "$env:COMPUTERNAM\$UserName", ($Password | ConvertTo-SecureString -AsPlainText -Force)
$Con = Connect-HPBIOS -IP $env:COMPUTERNAME -Credential $Credentials -ErrorAction Stop

Write-Output "$ScriptName -  Selected Mode: $Mode"

if($mode -eq "FullPower"){
    Set-HPBIOSPowerProfile -Profile Maximum_Performance -Connection $Con
    Set-HPBIOSPowerRegulator -Regulator Static_High_Performance -Connection $Con
    Write-Output "$ScriptName - HP PowerProfile is set to $((Get-HPBIOSPowerProfile -Connection $Con).HPPowerProfile)"
    Write-Output "$ScriptName - HP PowerRegulator is set to $((Get-HPBIOSPowerRegulator -Connection $Con).HPPowerRegulator)"
}

if($mode -eq "TreeHugging"){
    Set-HPBIOSPowerProfile -Profile Minimum_Power -Connection $Con
    Set-HPBIOSPowerRegulator -Regulator Dynamic_Power_Savings -Connection $Con
    Write-Output "$ScriptName - HP PowerProfile is set to $((Get-HPBIOSPowerProfile -Connection $Con).HPPowerProfile)"
    Write-Output "$ScriptName - HP PowerRegulator is set to $((Get-HPBIOSPowerRegulator -Connection $Con).HPPowerRegulator)"
}

. Stop-Logging
