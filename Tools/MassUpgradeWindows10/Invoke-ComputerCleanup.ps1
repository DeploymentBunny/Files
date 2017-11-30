#Cleanup if something did not work

#Clen the screen
Clear-Host

#Import data from CSV
"Import data from CSV"
$Computers = Import-Csv -Path D:\Upgrade2W10\computers.txt
"Working on the following computers"
$Computers.Name
""

#Remove folders, files and tasks
"Remove folders, files and tasks"
$TaskName = "Download_Source_Files"
$ScriptBlock = {
    &  SCHTASKS /Delete /TN \$Using:TaskName /F
    Get-Process -Name robocopy | Stop-Process -Force
    Get-Process -Name PSEXECV | Stop-Process -Force
    Remove-Item -Path c:\Source -Force -Recurse
}
$Cleanup = foreach($Computer in $Computers){
    Invoke-Command -ComputerName $Computer.Name -ScriptBlock $ScriptBlock -AsJob
}
do{
    Write-Host "Waiting to complete the jobs..."
    Start-Sleep -Seconds 5
    $Cleanup.ChildJobs
}until($($Cleanup.State) -eq "Completed")
foreach($Job in $Cleanup.ChildJobs){
    Write-Host "Result on: $($Job.Location)"
    Receive-Job -Job $Job -Keep
}
