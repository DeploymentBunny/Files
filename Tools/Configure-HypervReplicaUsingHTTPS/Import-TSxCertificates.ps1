<#
.SYNOPSIS
    Imports the Hyper-V Replica certificates created by New-TSxCertificates.ps1 on a Hyper-V host.

.DESCRIPTION
    This script imports:
      1. The Root CA certificate (RootCA.cer) into Local Machine\Trusted Root Certification Authorities.
      2. The certificate matching the computer name (<computername>.pfx) into Local Machine\Personal,
         including its private key.

    Run this script on each Hyper-V host that should participate in Hyper-V Replica over HTTPS.

.PARAMETER Path
    Folder containing the certificate files exported by New-TSxCertificates.ps1.

.PARAMETER Password
    Password protecting the .pfx file. Accepts a SecureString or a plain string.

.PARAMETER ComputerName
    Name used to locate the matching .pfx file. Defaults to the local computer name and its FQDN.

.PARAMETER RootCertificateFile
    File name of the Root CA public certificate. Default is "RootCA.cer".

.EXAMPLE
    .\Import-TSxCertificates.ps1 -Path C:\Certs -Password 'zaq123'

.EXAMPLE
    $pwd = Read-Host -AsSecureString -Prompt 'PFX password'
    .\Import-TSxCertificates.ps1 -Path \\server\certs -Password $pwd -ComputerName 'hv01.corp.viamonstra.com' -Verbose

.NOTES
    FileName:    Import-TSxCertificates.ps1
    Version:     1.0.1
    Author:      Mikael Nystrom
    Contact:     deploymentbunny@outlook.com
    Created:     2026-09-10
    Updated:     2026-09-11
    Twitter:     @mikael_nystrom

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author or DeploymentBunny.
.LINK
    https://www.deploymentbunny.com
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
Param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [object]$Password,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ComputerName = $env:COMPUTERNAME,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$RootCertificateFile = 'RootCA.cer'
)

$ErrorActionPreference = 'Stop'

switch ($Password) {
    { $_ -is [System.Security.SecureString] } { $PfxPassword = $_; break }
    { $_ -is [string] } { $PfxPassword = ConvertTo-SecureString -String $_ -AsPlainText -Force; break }
    default { throw 'The -Password parameter must be a SecureString or a string.' }
}

function Write-Log {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Type = 'Info'
    )
    $Stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    switch ($Type) {
        'Warning' { Write-Warning "$Stamp - $Message" }
        'Error' { Write-Error "$Stamp - $Message" }
        default { Write-Verbose "$Stamp - $Message" -Verbose }
    }
}

$CurrentIdentity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $CurrentIdentity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This script must be run elevated (Run as Administrator).'
}

if (-not (Test-Path -Path $Path)) {
    throw "The folder $Path does not exist."
}

# Locate the Root CA certificate
$RootFile = Join-Path -Path $Path -ChildPath $RootCertificateFile
if (-not (Test-Path -Path $RootFile)) {
    throw "Could not find the root certificate $RootFile."
}

# Locate the certificate matching this computer, FQDN first
$Candidates = New-Object -TypeName System.Collections.Generic.List[string]
$Candidates.Add($ComputerName)
if (-not $ComputerName.Contains('.')) {
    if (-not [string]::IsNullOrEmpty($env:USERDNSDOMAIN)) { $Candidates.Add("$ComputerName.$env:USERDNSDOMAIN") }
    $IPProperties = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    if (-not [string]::IsNullOrEmpty($IPProperties.DomainName)) { $Candidates.Add("$ComputerName.$($IPProperties.DomainName)") }
}
else {
    $Candidates.Add($ComputerName.Split('.')[0])
}

$ComputerPfxFile = $null
foreach ($Candidate in $Candidates) {
    $CandidateFile = Join-Path -Path $Path -ChildPath "$Candidate.pfx"
    if (Test-Path -Path $CandidateFile) {
        $ComputerPfxFile = $CandidateFile
        break
    }
}

if ([string]::IsNullOrEmpty($ComputerPfxFile)) {
    throw "Could not find a .pfx file matching this computer in $Path. Looked for: $($Candidates -join ', ')"
}

# Import the Root CA into Trusted Root Certification Authorities (Local Machine)
if ($PSCmdlet.ShouldProcess('Cert:\LocalMachine\Root', "Import $RootFile")) {
    Write-Log -Message "Importing root certificate $RootFile into Cert:\LocalMachine\Root"
    $RootCertificate = Import-Certificate -FilePath $RootFile -CertStoreLocation 'Cert:\LocalMachine\Root'
    Write-Log -Message "Imported root certificate '$($RootCertificate.Subject)' with thumbprint $($RootCertificate.Thumbprint)"
}

# Import the computer certificate into Personal (Local Machine)
if ($PSCmdlet.ShouldProcess('Cert:\LocalMachine\My', "Import $ComputerPfxFile")) {
    Write-Log -Message "Importing computer certificate $ComputerPfxFile into Cert:\LocalMachine\My"
    $ComputerCertificate = Import-PfxCertificate -FilePath $ComputerPfxFile -CertStoreLocation 'Cert:\LocalMachine\My' -Password $PfxPassword -Exportable
    Write-Log -Message "Imported computer certificate '$($ComputerCertificate.Subject)' with thumbprint $($ComputerCertificate.Thumbprint)"

    $ChainOk = Test-Certificate -Cert $ComputerCertificate -AllowUntrustedRoot:$false -ErrorAction SilentlyContinue
    if ($ChainOk) {
        Write-Log -Message 'Certificate chain validation succeeded.'
    }
    else {
        Write-Log -Message 'Certificate chain validation reported issues. This is expected for self-signed certificates without a CRL. Run Set-TSxHyperVReplicaHostConfiguration.ps1 to disable the revocation check.' -Type Warning
    }
}

Write-Log -Message 'Done.'
