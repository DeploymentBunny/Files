# Get the Module
Find-Module -Name RestPS | Install-Module -Verbose -SkipPublisherCheck -Force

# Import Module
Import-Module RestPS -Verbose -Force

# Initual Configuration
Invoke-DeployRestPS -LocalDir 'C:\RestPS' -Verbose


