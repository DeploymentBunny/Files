
# This sample will get all accounts that has been or are a member of some administrtative group with higher priviliges then a domain user

Get-ADUser -Filter {admincount -GT 0} -Properties adminCount,LastLogonDate,PasswordNeverExpires,PwdLastSet | 
Select-Object Name,LastLogonDate,PasswordNeverExpires,@{Name='PwdLastSet';Expression={[DateTime]::FromFileTime($_.PwdLastSet)}} | 
Sort-Object | Format-Table
