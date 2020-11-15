Start-Transcript -Path C:\RestPSService\Start.log
Import-Module RESTPS -Verbose -Force
Start-RestPSListener -Port 8080 -LogLevel ALL -Logfile C:\RestPSService\RestPS.log -Verbose
Stop-Transcript -Path C:\RestPSService\Start.log