<#
 Install Wrapper 2.0
 Author: Mikael Nystrom
 http://www.deploymentbunny.com 
#>

Param(
    $OOBIPAddress,
    $OOBSubnet,
    $OOBGateway,
    $OOBHostName,
    $OOBDomainName,
    $OOBPriDNSServer,
    $OOBSecDNSServer,
    $OOBAdmin,
    $OOBPassword
)

# Set Vars
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScriptName = Split-Path -Leaf $MyInvocation.MyCommand.Path
#[xml]$Settings = Get-Content "$ScriptDir\Settings.xml"
$SOURCEROOT = "$SCRIPTDIR\Source"
$LANG = (Get-Culture).Name
$OSV = $Null
$ARCHITECTURE = $env:PROCESSOR_ARCHITECTURE

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
            $LogFile = $Logpath + "\" + "$ScriptName.txt"
        }
    Else{
            $Logpath = $env:TEMP
            $LogFile = $Logpath + "\" + "$ScriptName.txt"
        }
    }
    Return $MDTIntegration
}
Function Start-VIALogging{
    Start-Transcript -path $LogFile -Force
}
Function Stop-VIALogging{
    Stop-Transcript
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
Function Invoke-VIAMsi{
    [CmdletBinding(SupportsShouldProcess=$true)]

    param(
        [parameter(mandatory=$true,position=0)]
        [ValidateNotNullOrEmpty()]
        [string]
        $MSI,

        [parameter(mandatory=$false,position=1)]
        [string]
        $Arguments
    )

    #Set MSIArgs
    $MSIArgs = "/i " + $MSI + " " + $Arguments

    if($Arguments -eq "")
    {
        $MSIArgs = "/i " + $MSI

        
    }
    else
    {
        $MSIArgs = "/i " + $MSI + " " + $Arguments
    
    }
    Write-Verbose "Running Start-Process -FilePath msiexec.exe -ArgumentList $MSIArgs -NoNewWindow -Wait -Passthru"
    $ReturnFromEXE = Start-Process -FilePath msiexec.exe -ArgumentList $MSIArgs -NoNewWindow -Wait -Passthru
    Write-Verbose "Returncode is $($ReturnFromEXE.ExitCode)"
    Return $ReturnFromEXE.ExitCode
}
Function Invoke-VIAMsu{
    [CmdletBinding(SupportsShouldProcess=$true)]

    param(
        [parameter(mandatory=$true,position=0)]
        [ValidateNotNullOrEmpty()]
        [string]
        $MSU,

        [parameter(mandatory=$false,position=1)]
        [string]
        $Arguments
    )

        #Set MSIArgs
    $MSUArgs = $MSU + " " + $Arguments

    if($Arguments -eq "")
    {
        $MSUArgs = $MSU

        
    }
    else
    {
        $MSUArgs = $MSU + " " + $Arguments
    
    }

    Write-Verbose "Running Start-Process -FilePath wusa.exe -ArgumentList $MSUArgs -NoNewWindow -Wait -Passthru"
    $ReturnFromEXE = Start-Process -FilePath wusa.exe -ArgumentList $MSUArgs -NoNewWindow -Wait -Passthru
    Write-Verbose "Returncode is $($ReturnFromEXE.ExitCode)"
    Return $ReturnFromEXE.ExitCode
}

#Try to Import SMSTSEnv
. Import-VIASMSTSENV

#Start Transcript Logging
. Start-VIALogging

#Detect current OS Version
. Get-VIAOSVersion -osv ([ref]$osv) 

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

#Generate more info
if($MDTIntegration -eq $true){
    $TSMake = $tsenv.Value("Make")
    $TSModel = $tsenv.Value("Model")
    $TSMakeAlias = $tsenv.Value("MakeAlias")
    $TSModelAlias = $tsenv.Value("ModelAlias")
    $TSOSDComputerName = $tsenv.Value("OSDComputerName")
    Write-Output "$ScriptName - Make:: $TSMake"
    Write-Output "$ScriptName - Model: $TSModel"
    Write-Output "$ScriptName - MakeAlias: $TSMakeAlias"
    Write-Output "$ScriptName - ModelAlias: $TSModelAlias"
    Write-Output "$ScriptName - OSDComputername: $TSOSDComputerName"
}

#Custom Code Starts--------------------------------------

#Generate Custom info
if($MDTIntegration -eq $true){
    $OOBIPAddress = $tsenv.Value("OOBIPAddress")
    $OOBSubnet = $tsenv.Value("OOBSubnet")
    $OOBGateway = $tsenv.Value("OOBGateway")
    $OOBHostName = $tsenv.Value("OOBHostName")
    $OOBDomainName = $tsenv.Value("OOBDomainName")
    $OOBPriDNSServer = $tsenv.Value("OOBPriDNSServer")
    $OOBSecDNSServer = $tsenv.Value("OOBSecDNSServer")
    $OOBAdmin = $tsenv.Value("OOBAdmin")
    $OOBPassword = $tsenv.Value("OOBPassword")

    Write-Output "$ScriptName - OOBIPAddress: $OOBIPAddress"
    Write-Output "$ScriptName - OOBSubnet: $OOBSubnet"
    Write-Output "$ScriptName - OOBGateway: $OOBGateway"
    Write-Output "$ScriptName - OOBHostName: $OOBHostName"
    Write-Output "$ScriptName - OOBDomainName: $OOBDomainName"
    Write-Output "$ScriptName - OOBPriDNSServer: $OOBPriDNSServer"
    Write-Output "$ScriptName - OOBSecDNSServer: $OOBSecDNSServer"
    Write-Output "$ScriptName - OOBAdmin: $OOBAdmin"
    Write-Output "$ScriptName - OOBPassword: $OOBPassword"
}

$RIBCLScriptFile = "c:\Windows\Temp\ILOConfig.xml"
$RIBCLTemplate = @'
<RIBCL VERSION="2.0">
<LOGIN USER_LOGIN="admin" PASSWORD="password">
<RIB_INFO mode="write">
<MOD_NETWORK_SETTINGS>
    <DHCP_ENABLE VALUE="N" />
    <DHCP_GATEWAY VALUE="N" />
    <DHCP_DNS_SERVER VALUE="N" />
    <DHCP_WINS_SERVER VALUE="N" />
    <DHCP_STATIC_ROUTE VALUE="N" />
    <DHCP_DOMAIN_NAME VALUE="N" />
    <DHCP_SNTP_SETTINGS VALUE="N" />
    <REG_WINS_SERVER VALUE="N" />
    <REG_DDNS_SERVER VALUE="N" />
    <PING_GATEWAY VALUE="N" />
    <IP_ADDRESS VALUE="%OOBIPAddress%" />
    <SUBNET_MASK VALUE="%OOBSubnet%" />
    <GATEWAY_IP_ADDRESS VALUE="%OOBGateway%" />
    <DNS_NAME VALUE="%OOBHostName%" />
    <DOMAIN_NAME VALUE="%OOBDomainName%" />
    <PRIM_DNS_SERVER VALUE="%OOBPriDNSServer%" />
    <SEC_DNS_SERVER VALUE="%OOBSecDNSServer%" />
    <TIMEZONE VALUE="Atlantic/Reykjavik" />
</MOD_NETWORK_SETTINGS>
</RIB_INFO>
<USER_INFO mode="write">
<ADD_USER USER_NAME="%OOBAdmin%" USER_LOGIN="%OOBAdmin%" PASSWORD="%OOBPassword%">
<ADMIN_PRIV value="Y" />
<REMOTE_CONS_PRIV value="Y" />
<RESET_SERVER_PRIV value="Y" />
<VIRTUAL_MEDIA_PRIV value="Y" />
<CONFIG_ILO_PRIV value="Y" />
</ADD_USER>
</USER_INFO>
</LOGIN>
</RIBCL>
'@

$RIBCLTemplate | Out-File $RIBCLScriptFile -Force ascii

$Executable = '"C:\Program Files\HP\hponcfg\hponcfg.exe"' 
Invoke-VIAExe -Executable $Executable -Arguments "/f $RIBCLScriptFile /s OOBAdmin=$OOBAdmin,OOBPassword=$OOBPassword,OOBIPAddress=$OOBIPAddress,OOBSubnet=$OOBSubnet,OOBGateway=$OOBGateway,OOBHostName=$OOBHostName,OOBDomainName=$OOBDomainName,OOBPriDNSServer=$OOBPriDNSServer,OOBSecDNSServer=$OOBSecDNSServer" -Verbose

#Custom Code Ends--------------------------------------

. Stop-VIALogging