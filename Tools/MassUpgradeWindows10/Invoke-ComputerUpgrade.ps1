#Install Windows 10

#Clen the screen
Clear-Host

#Import data from CSV
"Import data from CSV"
$Computers = Import-Csv -Path D:\Upgrade2W10\computers.txt
"Working on the following computers"
$Computers.Name
""
#Create batchfile for upgrade on each computer
"Create batchfile for upgrade on each computer"
$ScriptBlock = {
    $CommandFile = "c:\Source\Upgrade.cmd"
    Set-Content -Path $CommandFile -Value "@echo off" -Force
    Add-Content -Path $CommandFile -Value "c:\source\setup.exe /Auto Upgrade /Quiet /NoReboot /DynamicUpdate Disable" -Force
    Add-Content -Path $CommandFile -Value "echo %ERRORLEVEL% > C:\Source\upgrade.txt" -Force
    Get-Content -Path $CommandFile
}
$PrepInstall = foreach($Computer in $Computers){
    Invoke-Command -ComputerName $Computer.Name -ScriptBlock $ScriptBlock -AsJob
}
do{
    Write-Host "Waiting to complete the jobs..."
    Start-Sleep -Seconds 5
    $PrepInstall.ChildJobs
}until($($PrepInstall.State) -eq "Completed")
foreach($Job in $PrepInstall.ChildJobs){
    Write-Host "Result on: $($Job.Location)"
    Receive-Job -Job $Job -Keep
}

foreach($Computer in $Computers){
    Start-Process -Wait `
                 -PSPath "C:\PSTools\PsExec.exe"  `
                 -ArgumentList "\\$($Computer.Name) c:\Source\Upgrade.cmd -h -d" `
                 -RedirectStandardError c:\temp\error.log `
                 -RedirectStandardOutput c:\temp\output.log
    Get-Content -Path c:\temp\error.log
}






BREAK

$result = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
    Get-Content "c:\source\Upgrade.txt"
}

switch ($result)
{
    "0 "{
        Write-Host "No issues found."
        winrs.exe -r:$ComputerName "shutdown -r -t 0"    
    }
    Default{
        Write-Host "Check logfile for errors..."
    }
}