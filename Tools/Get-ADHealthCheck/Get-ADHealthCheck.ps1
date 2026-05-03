<#
.Synopsis
    Active Directory health check.
.DESCRIPTION
    Checks Active Directory health by testing network connectivity to all domain controllers
    in the current forest, verifying that automatic services are running, reviewing debug logs
    (PASSWD.LOG, netlogon.log), and running DCDiag diagnostic tests against each domain controller.
.NOTES
    Author - Mikael Nystrom
    Twitter: @mikael_nystrom
    Blog   : https://www.deploymentbunny.com
    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and 
    is not supported by the authors or Deployment Artist.
.LINK
    https://www.deploymentbunny.com
#>
$getForest = [system.directoryservices.activedirectory.Forest]::GetCurrentForest()
$DCServers = $getForest.Domains.DomainControllers.name

foreach ($DCServer in $DCServers){
    Write-Host "Checking netaccess to $DCServer" -ForegroundColor Green
    Test-NetConnection -ComputerName $DCServer

    Write-Host "Checking Services that should be running on $DCServer" -ForegroundColor Green
    Invoke-Command -ComputerName $DCServer -ScriptBlock {
        $Services = Get-Service
        Foreach($Service in $Services | Where-Object -Property StartType -EQ Automatic){
            $Service | Where-Object -Property Status -NE -Value Running
            }
    }

    Write-Host "Getting debug logs on $DCServer" -ForegroundColor Green
    Invoke-Command -ComputerName $DCServer -ScriptBlock {
        Write-Host "C:\Windows\debug\PASSWD.LOG on $DCServer says:" -ForegroundColor Green
        Get-Content C:\Windows\debug\PASSWD.LOG
    }

    Write-Host "Getting debug logs on $DCServer" -ForegroundColor Green
    Invoke-Command -ComputerName $DCServer -ScriptBlock {
        Write-Host "C:\Windows\debug\netlogon.log on $DCServer says:" -ForegroundColor Green
        Get-Content C:\Windows\debug\netlogon.log
    }

    Write-Host "Running DCDiag on $DCServer" -ForegroundColor Green
    Invoke-Command -ComputerName $DCServer -ScriptBlock {
        dcdiag.exe /test:netlogons /Q
        dcdiag.exe /test:Services /Q
        dcdiag.exe /test:Advertising /Q
        dcdiag.exe /test:FSMOCheck /Q
    }

    Write-Host "Checking access to SYSVOL on $DCServer" -ForegroundColor Green
    Test-Path -Path \\$DCServer\sysvol

    Write-Host "Get 20 last errors/warning on $DCServer" -ForegroundColor Green
    Invoke-Command -ComputerName $DCServer -ScriptBlock {
        Get-EventLog -LogName Application -Newest 20 -EntryType Error,Warning | Select-Object Source,Message,TimeGenerated
    }

    Write-Host "Running BPA on $DCServer" -ForegroundColor Green
    Invoke-Command -ComputerName $DCServer -ScriptBlock {
        $BPA = "Microsoft/Windows/DirectoryServices"
        Invoke-BpaModel -BestPracticesModelId $BPA
        Get-BpaResult -ModelID $BPA -Filter Noncompliant | Select-Object ResultNumber,Severity,Category,Title,Problem,Impact,Resolution
    }
}
