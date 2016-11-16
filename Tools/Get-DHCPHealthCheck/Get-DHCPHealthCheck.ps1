<#
.Synopsis
    Script from TechDays Sweden 2016
.DESCRIPTION
    Script from TechDays Sweden 2016
.NOTES
    Author - Mikael Nystrom
    Twitter: @mikael_nystrom
    Blog   : http://deploymentbunny.com
    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and 
    is not supported by the authors or Deployment Artist.
.LINK
    http://www.deploymentbunny.com
#>
$DHCPServers = "SRVDC01.network.local"
Foreach($DHCPServer in $DHCPServers){
    Write-Host "Checking netaccess to $DCServer" -ForegroundColor Green
    Test-Connection -ComputerName $DCServer
    

    Invoke-Command -ComputerName $DCServer -ScriptBlock {
        Write-Host "Getting other DCHP/PXE Servers from $env:COMPUTERNAME" -ForegroundColor Green
        $DhcpServerInDCs = Get-DhcpServerInDC
        $DhcpServerInDCs

        Write-Host "Testing access to other DCHP/PXE Servers from $env:COMPUTERNAME" -ForegroundColor Green
        Foreach($DhcpServerInDC in $DhcpServerInDCs){
            Write-Host "Testing access to $($DhcpServerInDC.IPAddress)" -ForegroundColor Green
            Test-NetConnection -ComputerName $DhcpServerInDC.IPAddress
        }
    }

    Invoke-Command -ComputerName $DCServer -ScriptBlock {
        Write-Host "Get all Scopes from $env:COMPUTERNAME" -ForegroundColor Green
        $DhcpServerv4Scopes = Get-DhcpServerv4Scope
        Foreach($DhcpServerv4Scope in $DhcpServerv4Scopes){
            $DhcpServerv4Scope
            Write-Host "Percent free $(($DhcpServerv4Scope | Get-DhcpServerv4ScopeStatistics).PercentageInUse) in $($DhcpServerv4Scope.scopeid)"
        }
    }

    Write-Host "Running BPA on $DHCPServer" -ForegroundColor Green
    Invoke-Command -ComputerName $DHCPServer -ScriptBlock {
        $BPA = "Microsoft/Windows/DHCPServer"
        Invoke-BpaModel -BestPracticesModelId $BPA
        Get-BpaResult -ModelID $BPA -Filter Noncompliant | Select-Object ResultNumber,Severity,Category,Title,Problem,Impact,Resolution
    }        
}
