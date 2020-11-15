# Install NuGet Provider
Install-PackageProvider -Name NuGet -Force -Verbose

# Install PowerShellGet
Install-Module -Name PowerShellGet -Force -SkipPublisherCheck -Verbose

# Update all modules
Update-Module -Force -Verbose
