$MDTServer='DEMOHOST03:9800'
$MessageID = '41015'

$i = 1000$ary = 1000..1010do {$ary[$i]$i++Write-Host "PC0$i"$mac = $i.ToString()$mac$mac = $mac.Substring(0,2)+":"+$mac.Substring(2,2)$mac$MacAddress = "00:15:5D:00:$mac"
$MacAddress
$ComputerName = "PC0$i" 
$guid = [guid]::NewGuid()
$guid

Invoke-WebRequest "http://$MDTServer/MDTMonitorEvent/PostEvent?uniqueID=&computerName=$ComputerName&messageID=$messageID&severity=1&stepName=&currentStep=10&totalSteps=10&id=$guid,$macaddress&message=Deployment Completed.&dartIP=&dartPort=&dartTicket=&vmHost=WIN-QJG36OC866D&vmName=CM2012SP1STDDEP-PC0003" | Out-Null# Start-Sleep 10} while ($i -lt 1010)
