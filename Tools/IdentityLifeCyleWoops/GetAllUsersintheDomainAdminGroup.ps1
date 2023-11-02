
# This will get all users that are member of the Domain Admin group

Get-ADGroupMember -Identity "Domain Admins" -Recursive | 
Get-ADUser -Properties Name,LastLogonDate,PasswordNeverExpires,PwdLastSet | Where-Object {$_.Enabled -eq $true} | 
Select-Object Name,LastLogonDate,PasswordNeverExpires,@{Name='PwdLastSet';Expression={[DateTime]::FromFileTime($_.PwdLastSet)}} | 
Sort-Object | Format-Table