Function Invoke-Exe{
    [CmdletBinding(SupportsShouldProcess=$true)]

    param(
        [parameter(mandatory=$true,position=0)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Executable,

        [parameter(mandatory=$false,position=1)]
        [string]
        $Arguments
    )

    if($Arguments -eq "")
    {
        Write-Verbose "Running $ReturnFromEXE = Start-Process -FilePath $Executable -ArgumentList $Arguments -NoNewWindow -Wait -Passthru"
        $ReturnFromEXE = Start-Process -FilePath $Executable -NoNewWindow -Wait -Passthru
    }else{
        Write-Verbose "Running $ReturnFromEXE = Start-Process -FilePath $Executable -ArgumentList $Arguments -NoNewWindow -Wait -Passthru"
        $ReturnFromEXE = Start-Process -FilePath $Executable -ArgumentList $Arguments -NoNewWindow -Wait -Passthru
    }
    Write-Verbose "Returncode is $($ReturnFromEXE.ExitCode)"
    Return $ReturnFromEXE.ExitCode
}

#Setup
$RunningFromFolder = $MyInvocation.MyCommand.Path | Split-Path -Parent 
$WsusDBMaintenanceFile = "$RunningFromFolder\WsusDBMaintenance.sql"
#Connect to DB
#For Windows Internal Database, use $WSUSDB = '\\.\pipe\MICROSOFT##WID\tsql\query'
#For SQL Express, use $WSUSDB = '\\.\pipe\MSSQL$SQLEXPRESS\sql\query'
$WSUSDB = '\\.\pipe\MICROSOFT##WID\tsql\query'

if(!(Test-Path $WSUSDB) -eq $true){Write-Warning "Could not access the DB";BREAK}
if(!(Test-Path $WsusDBMaintenanceFile) -eq $true){Write-Warning "Could not access the WsusDBMaintenance.sql, make sure you have downloed the file from https://gallery.technet.microsoft.com/scriptcenter/6f8cde49-5c52-4abd-9820-f1d270ddea61#content";BREAK}

Write-Output "Running from: $RunningFromFolder"
Write-Output "Using SQL FIle: $WsusDBMaintenanceFile"
Write-Output "Using DB: $WSUSDB"

#Get and Set the WSUS Server target
$WSUSSrv = Get-WsusServer -Name $env:COMPUTERNAME -PortNumber 8530
Write-Output "Working on $($WSUSSrv.name)"

$SuperSeededUpdates = Get-WsusUpdate -Approval AnyExceptDeclined -Classification All -Status Any | Where-Object -Property UpdatesSupersedingThisUpdate -NE -Value 'None' -Verbose
$SuperSeededUpdates | Deny-WsusUpdate -Verbose

#Cleanup WSUS
Write-Output "Cleanup Obsolete Computers"
$CleanupObsoleteComputers = Invoke-WsusServerCleanup -UpdateServer $WSUSSrv -CleanupObsoleteComputers
Write-Output $CleanupObsoleteComputers

Write-Output "Cleanup Obsolete Updates"
$CleanupObsoleteUpdates = Invoke-WsusServerCleanup -UpdateServer $WSUSSrv -CleanupObsoleteUpdates
Write-Output $CleanupObsoleteUpdates

Write-Output "Cleanup Unneeded Content Files"
$CleanupUnneededContentFiles = Invoke-WsusServerCleanup -UpdateServer $WSUSSrv -CleanupUnneededContentFiles
Write-Output $CleanupUnneededContentFiles

Write-Output "Compress Updates"
$CompressUpdates = Invoke-WsusServerCleanup -UpdateServer $WSUSSrv -CompressUpdates
Write-Output $CompressUpdates

Write-Output "Decline Expired Updates"
$DeclineExpiredUpdates = Invoke-WsusServerCleanup -UpdateServer $WSUSSrv -DeclineExpiredUpdates
Write-Output $DeclineExpiredUpdates

Write-Output "Decline Superseded Updates"
$DeclineSupersededUpdates = Invoke-WsusServerCleanup -UpdateServer $WSUSSrv -DeclineSupersededUpdates
Write-Output $DeclineSupersededUpdates

#Cleanup the SUDB
Write-Output "Defrag and Cleanup DB"
$Command = "sqlcmd.exe"
$Arguments = "-E -S $WSUSDB /i $WsusDBMaintenanceFile"
Invoke-Exe -Executable $Command -Arguments $Arguments

Write-Output "Done"
