#Disable unneeded services in Windows Server 2016 Desktop Edition
$Services = 'CDPUserSvc','MapsBroker','PcaSvc','ShellHWDetection','OneSyncSvc','WpnService'

foreach($Service in $Services){
    Stop-Service -Name $Service -PassThru -Verbose | Set-Service -StartupType Disabled -Verbose
}

