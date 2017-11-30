<#
    Created:     2017-06-02
    Version:     1.1

    Author :     Peter Lofgren
    Twitter:     @LofgrenPeter
    Blog   :     http://syscenramblings.wordpress.com

    Author :     Mikael Nystrom
    Twitter:     @mikael_nystrom
    Blog   :     http://www.deploymentbunny.com

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and 
    is not supported by the author
 
    Release notes
    1.0 - Initial release (Peter Lofgren)
    1.1 - Change from netsh.exe to native Powershell (Mikael Nystrom)
    1.2 - Change from blocking the machine, to block AppxSvc
#>
 
param (
  [Parameter(Mandatory=$False,Position=0)]
  [Switch]$Disable
)
 
If (!$Disable) {
  Write-Output "Adding internet block for AppXSvc"
  New-NetFirewallRule -DisplayName "Block Outgoing 80, 443 for AppXSvc" -Enabled True -Direction Outbound -Profile Any -Action Block -Protocol TCP -RemotePort 80,443 -Service AppXSvc
}
 
if ($Disable) {
  Write-Output "Adding internet block for AppXSvc"
  Get-NetFirewallRule -DisplayName "Block Outgoing 80, 443 AppXSvc" | Remove-NetFirewallRule
}