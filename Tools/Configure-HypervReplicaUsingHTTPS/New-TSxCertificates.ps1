<#
.SYNOPSIS
    Creates a self-signed Root CA certificate and one server/client certificate per Hyper-V host,
    exports everything to a folder and cleans up the certificates from the local machine.

.DESCRIPTION
    This script is used to prepare certificates for Hyper-V Replica over HTTPS.

    It will:
      1. Create a self-signed Root Certification Authority certificate.
      2. Create one certificate per computer listed in -Computers, signed by that Root CA,
         with both Server Authentication and Client Authentication EKUs.
      3. Export the Root CA public certificate (.cer), the Root CA key pair (.pfx) and each
         computer certificate (.pfx) to the folder specified in -Path.
      4. Remove all certificates created by this script from the local computer stores.

    Afterwards, import RootCA.cer into "Trusted Root Certification Authorities\Local Computer"
    and the matching <computer>.pfx into "Personal\Local Computer" on each Hyper-V host.

.PARAMETER Computers
    One or more computer names (preferably the FQDN used by Hyper-V Replica) to create certificates for.

.PARAMETER Path
    Folder where the certificate files are exported. The folder is created if it does not exist.

.PARAMETER Password
    Password used to protect the exported .pfx files. Accepts a SecureString or a plain string.
    Using a SecureString is recommended.

.PARAMETER RootCommonName
    Common name of the Root CA certificate, for example "HyperV Replica Root CA".

.PARAMETER ValidYears
    Number of years the certificates are valid. Root CA gets ValidYears + 1. Default is 5.

.EXAMPLE
    $pwd = Read-Host -AsSecureString -Prompt 'PFX password'
    .\New-TSxCertificates.ps1 -Computers 'hv01.corp.viamonstra.com','hv02.corp.viamonstra.com' -Path C:\Certs -Password $pwd -RootCommonName 'HyperV Replica Root CA'

.EXAMPLE
    .\New-TSxCertificates.ps1 -Computers 'hv01.corp.viamonstra.com' -Path C:\Certs -Password $pwd -RootCommonName 'ViaMonstra Replica Root CA' -WhatIf

.EXAMPLE
    .\New-TSxCertificates.ps1 -Computers 'ARTA-HOST96','ARTA-HOST95' -Path C:\Certs -Password 'zaq123' -RootCommonName 'ViaMonstra Replica Root CA'

.NOTES
    FileName:    New-TSxCertificates.ps1
    Version:     1.0.4
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
    [string[]]$Computers,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [object]$Password,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$RootCommonName,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 20)]
    [int]$ValidYears = 5
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

function Remove-CreatedCertificate {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Thumbprint
    )
    foreach ($Store in @('Cert:\LocalMachine\My', 'Cert:\LocalMachine\Root', 'Cert:\LocalMachine\CA')) {
        $Item = Join-Path -Path $Store -ChildPath $Thumbprint
        if (Test-Path -Path $Item) {
            Write-Log -Message "Removing certificate $Thumbprint from $Store"
            Remove-Item -Path $Item -Force -DeleteKey -ErrorAction SilentlyContinue
        }
    }
}

# Requirements
if (-not (Get-Command -Name New-SelfSignedCertificate -ErrorAction SilentlyContinue)) {
    throw 'New-SelfSignedCertificate is not available. Windows 10 / Windows Server 2016 or later is required.'
}

$CurrentIdentity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $CurrentIdentity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This script must be run elevated (Run as Administrator).'
}

if (-not (Test-Path -Path $Path)) {
    if ($PSCmdlet.ShouldProcess($Path, 'Create output folder')) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
        Write-Log -Message "Created output folder $Path"
    }
}
$OutputFolder = (Resolve-Path -Path $Path -ErrorAction SilentlyContinue).Path
if ([string]::IsNullOrEmpty($OutputFolder)) { $OutputFolder = $Path }

$CreatedThumbprints = New-Object -TypeName System.Collections.Generic.List[string]
$RootCertificate = $null

try {
    # Create the Root CA certificate
    $RootFile = Join-Path -Path $OutputFolder -ChildPath 'RootCA.cer'
    $RootPfxFile = Join-Path -Path $OutputFolder -ChildPath 'RootCA.pfx'

    if ($PSCmdlet.ShouldProcess($RootCommonName, 'Create self-signed Root CA certificate')) {
        Write-Log -Message "Creating Root CA certificate '$RootCommonName'"
        $RootCertificate = New-SelfSignedCertificate `
            -Subject "CN=$RootCommonName" `
            -FriendlyName $RootCommonName `
            -CertStoreLocation 'Cert:\LocalMachine\My' `
            -KeyExportPolicy Exportable `
            -KeyLength 4096 `
            -KeyAlgorithm RSA `
            -HashAlgorithm SHA256 `
            -KeyUsage CertSign, CRLSign, DigitalSignature `
            -NotAfter (Get-Date).AddYears($ValidYears + 1) `
            -TextExtension @('2.5.29.19={critical}{text}ca=1&pathlength=1')

        $CreatedThumbprints.Add($RootCertificate.Thumbprint)
        Write-Log -Message "Root CA created with thumbprint $($RootCertificate.Thumbprint)"

        Export-Certificate -Cert $RootCertificate -FilePath $RootFile -Type CERT -Force | Out-Null
        Write-Log -Message "Exported Root CA public certificate to $RootFile"

        Export-PfxCertificate -Cert $RootCertificate -FilePath $RootPfxFile -Password $PfxPassword -Force | Out-Null
        Write-Log -Message "Exported Root CA key pair to $RootPfxFile"
    }

    # Create one certificate per computer, signed by the Root CA
    foreach ($Computer in $Computers) {
        $ComputerName = $Computer.Trim()
        if ([string]::IsNullOrEmpty($ComputerName)) { continue }

        if (-not $PSCmdlet.ShouldProcess($ComputerName, 'Create server/client certificate signed by Root CA')) { continue }

        Write-Log -Message "Creating certificate for $ComputerName"

        $DnsNames = @($ComputerName)
        if ($ComputerName.Contains('.')) {
            $ShortName = $ComputerName.Split('.')[0]
            if ($DnsNames -notcontains $ShortName) { $DnsNames += $ShortName }
        }

        $ComputerCertificate = New-SelfSignedCertificate `
            -Subject "CN=$ComputerName" `
            -FriendlyName "Hyper-V Replica - $ComputerName" `
            -DnsName $DnsNames `
            -Signer $RootCertificate `
            -CertStoreLocation 'Cert:\LocalMachine\My' `
            -KeyExportPolicy Exportable `
            -KeyLength 2048 `
            -KeyAlgorithm RSA `
            -HashAlgorithm SHA256 `
            -KeyUsage DigitalSignature, KeyEncipherment `
            -NotAfter (Get-Date).AddYears($ValidYears) `
            -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.1,1.3.6.1.5.5.7.3.2')

        $CreatedThumbprints.Add($ComputerCertificate.Thumbprint)
        Write-Log -Message "Certificate for $ComputerName created with thumbprint $($ComputerCertificate.Thumbprint)"

        $ComputerPfxFile = Join-Path -Path $OutputFolder -ChildPath "$ComputerName.pfx"
        $ComputerCerFile = Join-Path -Path $OutputFolder -ChildPath "$ComputerName.cer"

        Export-PfxCertificate -Cert $ComputerCertificate -FilePath $ComputerPfxFile -Password $PfxPassword -ChainOption BuildChain -Force | Out-Null
        Write-Log -Message "Exported $ComputerName certificate to $ComputerPfxFile"

        Export-Certificate -Cert $ComputerCertificate -FilePath $ComputerCerFile -Type CERT -Force | Out-Null
        Write-Log -Message "Exported $ComputerName public certificate to $ComputerCerFile"
    }
}
finally {
    # Always clean up the certificates created on this computer
    foreach ($Thumbprint in $CreatedThumbprints) {
        if ($PSCmdlet.ShouldProcess($Thumbprint, 'Remove certificate from local certificate store')) {
            Remove-CreatedCertificate -Thumbprint $Thumbprint
        }
    }
}

Write-Log -Message "Done. Certificate files are located in $OutputFolder"
Write-Log -Message "On each Hyper-V host: import RootCA.cer into Trusted Root Certification Authorities (Local Computer) and <computer>.pfx into Personal (Local Computer)."
