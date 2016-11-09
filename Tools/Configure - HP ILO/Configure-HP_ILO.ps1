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

Function Invoke-VIAExe
{
    [CmdletBinding(SupportsShouldProcess=$true)]

    param(
        [parameter(mandatory=$true,position=0)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Executable,

        [parameter(mandatory=$true,position=1)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Arguments,

        [parameter(mandatory=$false,position=2)]
        [ValidateNotNullOrEmpty()]
        [int]
        $SuccessfulReturnCode = 0
    )

    Write-Verbose "Running $ReturnFromEXE = Start-Process -FilePath $Executable -ArgumentList $Arguments -NoNewWindow -Wait -Passthru"
    $ReturnFromEXE = Start-Process -FilePath $Executable -ArgumentList $Arguments -NoNewWindow -Wait -Passthru

    Write-Verbose "Returncode is $($ReturnFromEXE.ExitCode)"
}

$RIBCLScriptFile = "$env:TEMP\ILOConfig.xml"
$RIBCLTemplate = @'
<RIBCL VERSION="2.1">
 <LOGIN USER_LOGIN="Administrator" PASSWORD="password">
  <RIB_INFO MODE="write">
  <MOD_NETWORK_SETTINGS>
    <SPEED_AUTOSELECT VALUE = "Y"/>
    <DHCP_ENABLE VALUE = "N"/>
    <DHCP_GATEWAY VALUE = "N"/>
    <DHCP_DNS_SERVER VALUE = "N"/>
    <DHCP_STATIC_ROUTE VALUE = "N"/>
    <DHCP_WINS_SERVER VALUE = "N"/>
    <REG_WINS_SERVER VALUE = "N"/>
    <IP_ADDRESS VALUE = "OOBIPAddress"/>
    <SUBNET_MASK VALUE = "OOBSubnet"/>
    <GATEWAY_IP_ADDRESS VALUE = "OOBGateway"/>
    <DNS_NAME VALUE = "OOBHostName"/>
    <DOMAIN_NAME VALUE = "OOBDomainName"/>
    <PRIM_DNS_SERVER value = "OOBPriDNSServer"/>
    <SEC_DNS_SERVER value = "OOBSecDNSServer"/>
  </MOD_NETWORK_SETTINGS>
  </RIB_INFO>
  <USER_INFO MODE="write">
  <ADD_USER
    USER_NAME = "OOBAdmin"
    USER_LOGIN = "OOBAdmin"
    PASSWORD = "OOBPassword">
    <ADMIN_PRIV value = "Y"/>
    <REMOTE_CONS_PRIV value = "Y"/>
    <RESET_SERVER_PRIV value = "Y"/>
    <VIRTUAL_MEDIA_PRIV value = "Y"/>
    <CONFIG_ILO_PRIV value = "Y"/>
  </ADD_USER>
  </USER_INFO>
 </LOGIN>
</RIBCL>
'@

$RIBCLSettings = $RIBCLTemplate `-replace ("OOBIPAddress","$OOBIPAddress") `
-replace ("OOBSubnet","$OOBSubnet") `
-replace ("OOBGateway","$OOBGateway") `
-replace ("OOBHostName","$OOBHostName") `
-replace ("OOBDomainName","$OOBDomainName") `
-replace ("OOBPriDNSServer","$OOBPriDNSServer") `
-replace ("OOBSecDNSServer","$OOBSecDNSServer") `
-replace ("OOBAdmin","$OOBAdmin") `
-replace ("OOBPassword","$OOBPassword")

$RIBCLSettings | Out-File $RIBCLScriptFile -Force ascii

$Executable = '"C:\Program Files\HP\hponcfg\hponcfg.exe"'
Invoke-VIAExe -Executable $Executable -Arguments "/reset" -Verbose
Start-Sleep -Seconds 120

$Executable = '"C:\Program Files\HP\hponcfg\hponcfg.exe"' 
Invoke-VIAExe -Executable $Executable -Arguments "/f $RIBCLScriptFile" -Verbose
Start-Sleep -Seconds 120

