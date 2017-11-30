#Clen the screen
Clear-Host

#Import data from CSV
"Import data from CSV"
$Computers = Import-Csv -Path D:\Upgrade2W10\computers.txt
"Working on the following computers"
$Computers.Name
""

#Create batchfile for Compat Scan on each computer
"Create batchfile for Compat Scan on each computer"
$ScriptBlock = {
    $CommandFile = "c:\Source\Check.cmd"
    Set-Content -Path $CommandFile -Value "@echo off" -Force
    Add-Content -Path $CommandFile -Value "c:\source\setup.exe /Auto Upgrade /Quiet /NoReboot /DynamicUpdate Enable /Compat Scanonly" -Force
    Add-Content -Path $CommandFile -Value "echo %ERRORLEVEL% > C:\Source\check.txt" -Force
    Get-Content -Path $CommandFile
}
$PrepCompatScan = foreach($Computer in $Computers){
    Invoke-Command -ComputerName $Computer.Name -ScriptBlock $ScriptBlock -AsJob
}
do{
    Write-Host "Waiting to complete the jobs..."
    Start-Sleep -Seconds 5
    $PrepCompatScan.ChildJobs
}until($($PrepCompatScan.State) -eq "Completed")
foreach($Job in $PrepCompatScan.ChildJobs){
    Write-Host "Result on: $($Job.Location)"
    Receive-Job -Job $Job -Keep
}

#Run batchfile for Compat Scan
"Run batchfile for Compat Scan"
$ScriptBlock = {
    cmd.exe /c "c:\source\check.cmd"
}
$CompatScan = foreach($Computer in $Computers){
    Invoke-Command -ComputerName $Computer.Name -ScriptBlock $ScriptBlock -AsJob
}
do{
    Write-Host "Waiting to complete the jobs..."
    Start-Sleep -Seconds 20
    $CompatScan.ChildJobs
}until($($CompatScan.State) -eq "Completed")
foreach($Job in $CompatScan.ChildJobs){
    Write-Host "Result on: $($Job.Location)"
    Receive-Job -Job $Job -Keep
}

#Grab the data from each computer and see if we can upgrade
"Grab the data from each computer and see if we can upgrade"
$ScriptBlock = {
    $result = Get-Content "c:\source\check.txt"
    switch ($result){
        "-1047526896 "{Write-Host "$env:COMPUTERNAME : No issues found." -ForegroundColor Green}
        "-1047526904 "{Write-Host "$env:COMPUTERNAME : Compatibility issues found (hard block)." -ForegroundColor Red}
        "-1047526908 "{Write-Host "$env:COMPUTERNAME : Migration choice (auto upgrade) not available (probably the wrong SKU or architecture)·" -ForegroundColor Yellow}
        "-1047526912 "{Write-Host "$env:COMPUTERNAME : Does not meet system requirements for Windows 10." -ForegroundColor Red}
        "-1047526898 "{Write-Host "$env:COMPUTERNAME : Insufficient free disk space." -ForegroundColor Red}
        Default{}
    }
}
$CompatResult = foreach($Computer in $Computers){
    Invoke-Command -ComputerName $Computer.Name -ScriptBlock $ScriptBlock -AsJob
}
do{
    Write-Host "Waiting to complete the jobs..."
    Start-Sleep -Seconds 5
    $CompatResult.ChildJobs
}until($($CompatResult.State) -eq "Completed")
foreach($Job in $CompatResult.ChildJobs){
    Write-Host "Result on: $($Job.Location)"
    Receive-Job -Job $Job -Keep
}
