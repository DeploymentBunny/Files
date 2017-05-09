$Servers = "Server1","Server2"
$AdminPassword = "P@ssw0rd"
$DomainName = "corp.viamonstra.com"
$DomainAdminPassword = "P@ssw0rd"
$domainCred = New-Object -typename System.Management.Automation.PSCredential -argumentlist "$($domainName)\Administrator", (ConvertTo-SecureString $domainAdminPassword -AsPlainText -Force)
$Session = New-PSSession -VMName $Servers -Credential $domainCred
#$Session = New-PSSession -ComputerName $Servers -Credential $domainCred


$InstallJob = Invoke-Command -ScriptBlock {
    Get-ChildItem -Path c:\
} -Session $Session -AsJob
do{$InstallJob}until($($InstallJob.State) -eq "Completed")

foreach($Job in $InstallJob.ChildJobs){
    Write-Host ""
    Write-Host "Result on: $($Job.Location)"
    Write-Host ""
    Receive-Job -Job $Job -Keep
}
