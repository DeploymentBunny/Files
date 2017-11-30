#Clen the screen
Clear-Host

#Import data from CSV
"Import data from CSV"
$Computers = Import-Csv -Path D:\Upgrade2W10\computers.txt
"Working on the following computers"
$Computers.Name

#Connecting to WMI and enable WinRM and PowerShell remote
$PrepJob = foreach($Computer in $Computers){
    Invoke-WmiMethod -ComputerName $Computer.Name -Namespace root\cimv2 -Class Win32_Process -Name Create -ArgumentList "winrm quickconfig -quiet" -AsJob
    Invoke-WmiMethod -ComputerName $Computer.Name -Namespace root\cimv2 -Class Win32_Process -Name Create -ArgumentList "PowerShell -ExecutionPolicy Bypass -Command Enable-PSRemoting -Force -SkipNetworkProfileCheck" -AsJob
}
do{"Waiting to complete";Start-Sleep -Seconds 10}until($($PrepJob.State) -eq "Completed")
foreach($Job in $PrepJob.ChildJobs){
    Write-Host "Result on: $($Job.Location)"
    Receive-Job -Job $Job -Keep
}
