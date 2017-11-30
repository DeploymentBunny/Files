#Get and Set the WSUS Server target
$WSUSSrv = Get-WsusServer -Name $env:COMPUTERNAME -PortNumber 8530
Write-Output "Working on $($WSUSSrv.name)"

if (($WSUSSrv.GetDatabaseConfiguration()).IsUsingWindowsInternalDatabase -eq $false){
    $WSUSDBComputerName = $WSUSSrv.GetDatabaseConfiguration().ServerName | Split-Path
    $WSUSDBInstanceName = $WSUSSrv.GetDatabaseConfiguration().ServerName | Split-Path -Leaf
    $WSUSDBDBName = $WSUSSrv.GetDatabaseConfiguration().DatabaseName
    Write-Host "Database Server name: $WSUSDBComputerName"
    Write-Host "Database Server Instance name: $WSUSDBInstanceName"
    Write-Host "Database name: $WSUSDBDBName"
    $WSUSDB = '\\.\pipe\MSSQL$SQLEXPRESS\sql\query'
}else{
    $WSUSDB = "\\.\pipe\MICROSOFT##WID\tsql\query"
}

#Setup
$RunningFromFolder = "E:\Invoke-WSUSMaint"
#$RunningFromFolder = $MyInvocation.MyCommand.Path | Split-Path -Parent 
$WsusDBMaintenanceFile = "$RunningFromFolder\WsusDBMaintenance.sql"
$WsusDBRemoveObsolete = "$RunningFromFolder\RemoveObsoleteUpdates.sql"

if(!(Test-Path $WSUSDB) -eq $true){Write-Warning "Could not access the WID database";BREAK}
if(!(Test-Path $WsusDBMaintenanceFile) -eq $true){Write-Warning "Could not access the WsusDBMaintenance.sql, make sure you have downloaded the file from https://gallery.technet.microsoft.com/scriptcenter/6f8cde49-5c52-4abd-9820-f1d270ddea61#content";BREAK}

Write-Output "Running from: $RunningFromFolder"
Write-Output "Using SQL FIle: $WsusDBMaintenanceFile"
Write-Output "Using DB: $WSUSDB"

#Cleanup the SUDB
Write-Output "Remove Obsolete directly from DB"
$Command = "sqlcmd.exe"
$Arguments = "-E -S $WSUSDB /i $WsusDBRemoveObsolete"
$ReturnFromEXE = Start-Process -FilePath $Command -ArgumentList $Arguments -NoNewWindow -Wait -Passthru

#Cleanup the SUDB
Write-Output "Defrag and Cleanup DB using the supported MSFT script"
$Command = "sqlcmd.exe"
$Arguments = "-E -S $WSUSDB /i $WsusDBMaintenanceFile"
$ReturnFromEXE = Start-Process -FilePath $Command -ArgumentList $Arguments -NoNewWindow -Wait -Passthru

#Decline All Itanium
#$SuperSeededUpdates = Get-WsusUpdate -Approval AnyExceptDeclined -Classification All -Status Any | Where-Object -Property Title -Like -Value *Itanium*
#$ReturnfromSuperSeededUpdates = $SuperSeededUpdates | Deny-WsusUpdate -Verbose

#Decline superseeded updates
Write-Output "Getting all Superseded's"
$SuperSeededUpdates = Get-WsusUpdate -Approval AnyExceptDeclined -Classification All -Status Any | Where-Object -Property UpdatesSupersedingThisUpdate -NE -Value 'None' -Verbose
$ReturnfromSuperSeededUpdates = $SuperSeededUpdates | Deny-WsusUpdate -Verbose

#Cleanup WSUS
Write-Output "Cleanup Obsolete Computers"
$CleanupObsoleteComputers = Invoke-WsusServerCleanup -UpdateServer $WSUSSrv -CleanupObsoleteComputers

Write-Output "Cleanup Obsolete Updates"
$CleanupObsoleteUpdates = Invoke-WsusServerCleanup -UpdateServer $WSUSSrv -CleanupObsoleteUpdates

Write-Output "Cleanup Unneeded Content Files"
$CleanupUnneededContentFiles = Invoke-WsusServerCleanup -UpdateServer $WSUSSrv -CleanupUnneededContentFiles

Write-Output "Compress Updates"
$CompressUpdates = Invoke-WsusServerCleanup -UpdateServer $WSUSSrv -CompressUpdates

Write-Output "Decline Expired Updates"
$DeclineExpiredUpdates = Invoke-WsusServerCleanup -UpdateServer $WSUSSrv -DeclineExpiredUpdates

Write-Output "Decline Superseded Updates"
$DeclineSupersededUpdates = Invoke-WsusServerCleanup -UpdateServer $WSUSSrv -DeclineSupersededUpdates

#Cleanup the SUDB
Write-Output "Defrag and Cleanup DB"
$Command = "sqlcmd.exe"
$Arguments = "-E -S $WSUSDB /i $WsusDBMaintenanceFile"
$ReturnFromEXE = Start-Process -FilePath $Command -ArgumentList $Arguments -NoNewWindow -Wait -Passthru

$SuperSeededUpdates
$CleanupObsoleteComputers
$CleanupObsoleteUpdates
$CleanupUnneededContentFiles
$CompressUpdates
$DeclineExpiredUpdates
$DeclineSupersededUpdates
Write-Output "Done"