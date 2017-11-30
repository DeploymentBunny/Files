#Download the image using a scheduled task and wait until it is done

#Import data from CSV
$Computers = Import-Csv -Path D:\Upgrade2W10\computers.txt
"Working on the following computers"
$Computers.Name

#Setting up credentials and paths for the image to download
$RunAsAccountDomain = "DOMAIN"
$RunAsAccount = "Admin"
$RunAsAccountPassword = "P@ssw0rd"
$SourceFolder = "\\Server\Share"
$TaskName = "Download_Source_Files"
$ScriptBlock =  {
        $Command = """robocopy.exe $Using:SourceFolder c:\source /e"""
        "Running $Command as a scheduled task"
        #& SCHTASKS /Delete /TN $Using:TaskName /F
        & SCHTASKS /Create /RU $Using:RunAsAccountDomain\$Using:RunAsAccount /RP $Using:RunAsAccountPassword /SC WEEKLY /TN $Using:TaskName /TR $Command /RL HIGHEST /F
        }
$PrepJob = foreach($Computer in $Computers){
    Invoke-Command -ComputerName $Computer.Name -ScriptBlock $ScriptBlock -AsJob
}
do{Write-Host "Waiting to complete the jobs...";Start-Sleep -Seconds 10}until($($PrepJob.State) -eq "Completed")
foreach($Job in $PrepJob.ChildJobs){
    Write-Host "Result on: $($Job.Location)"
    Receive-Job -Job $Job -Keep
}

#Check if the job is ready to run, in that case fire it up
foreach($Computer in $Computers){
$ScriptBlock =  {
    do{
        "$env:COMPUTERNAME"
        $result = schtasks.exe /query /fo csv | ConvertFrom-Csv
        ($result | Where-Object TaskName -EQ "\$Using:TaskName").Status
        }
    while(($result | Where-Object TaskName -EQ "\$Using:TaskName").Status -ne "Ready")
    & SCHTASKS /Run /TN \$Using:TaskName
    }
    Invoke-Command -ComputerName $Computer.Name -ScriptBlock $ScriptBlock
}

#Wait until it is done
foreach($Computer in $Computers){
$ScriptBlock =  {
    do{
        "$env:COMPUTERNAME"
        $result = schtasks.exe /query /fo csv | ConvertFrom-Csv
        ($result | Where-Object TaskName -EQ "\$Using:TaskName").Status
        Start-Sleep -Seconds 10
        }
    while(($result | Where-Object TaskName -EQ "\$Using:TaskName").Status -ne "Ready")
    &  SCHTASKS /Delete /TN \$Using:TaskName /F
    }
    Invoke-Command -ComputerName $Computer.Name -ScriptBlock $ScriptBlock
}
