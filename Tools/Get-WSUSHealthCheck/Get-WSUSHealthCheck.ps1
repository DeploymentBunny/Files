$WSUSServers = "SRVWSUS02.network.local"
Foreach($WSUSServer in $WSUSServers){
    Write-Host "Checking netaccess to $WSUSServer" -ForegroundColor Green
    Test-Connection -ComputerName $WSUSServer

    Invoke-Command -ComputerName $WSUSServer -ScriptBlock {
        Write-Host "Base info:" -ForegroundColor Gray
        Get-WsusServer | Select-Object *
    }

    Invoke-Command -ComputerName $WSUSServer -ScriptBlock {
        $enus = 'en-US' -as [Globalization.CultureInfo]
        $TimeToCheck = (get-date).AddDays(-10).ToString("M/d/yyyy hh:mm tt", $enus)  
        $ComputersWNoReport = Get-WsusComputer -All | Where-Object -Property LastReportedStatusTime -LT -Value $TimeToCheck | Select-Object FullDomainName,Make,Model,LastSyncTime | FT
        Write-Host "The following computers have not reported to WSUS in 10 days..." -ForegroundColor Green
        $ComputersWNoReport
    }

    Invoke-Command -ComputerName $WSUSServer -ScriptBlock {
        Write-Host "The following updates are unapproved but needed" -ForegroundColor Green
        Get-WsusUpdate -Approval Unapproved -Status Needed
    }
}
