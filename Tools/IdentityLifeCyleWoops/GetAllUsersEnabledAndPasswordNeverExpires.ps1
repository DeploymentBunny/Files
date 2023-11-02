
# This will get all users where Password Never Expires is set to true and are enabled

Get-ADUser -filter {passwordNeverExpires -EQ $true -and enabled -EQ $true } -Properties  Name,LastLogonDate,PasswordNeverExpires,PwdLastSet | 
Select-Object Name,LastLogonDate,PasswordNeverExpires,@{Name='PwdLastSet';Expression={[DateTime]::FromFileTime($_.PwdLastSet)}} | 
Sort-Object | Format-Table
