# Make RestPS a Service
$NSSMPath = (Get-Command "C:\ProgramData\chocolatey\bin\nssm.exe").Source
$PoShPath = (Get-Command powershell).Source

$NewServiceName = “RestPS”
$PoShScriptPath = "C:\RestPSService\StartRestPS.ps1"
$args = '-ExecutionPolicy Bypass -NoProfile -File "{0}"' -f $PoShScriptPath

& $NSSMPath install $NewServiceName $PoShPath $args
& $NSSMPath status $NewServiceName

# Change the name of the Services
& $NSSMPath set $NewServiceName description "RestFul API Services"

# Check the Services
Get-Service -Name RestPS

# Start the Services
Get-Service -Name RestPS | Start-Service