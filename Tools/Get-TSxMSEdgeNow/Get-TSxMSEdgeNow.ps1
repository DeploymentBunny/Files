<#
.SYNOPSIS
  Get-EdgeEnterpriseMSI

.DESCRIPTION
  Imports all device configurations in a folder to a specified tenant

.PARAMETER Channel
  Channel to download, Valid Options are: Dev, Beta, Stable, EdgeUpdate, Policy.

.PARAMETER Platform
  Platform to download, Valid Options are: Windows or MacOS, if using channel "Policy" this should be set to "any"
  Defaults to Windows if not set.

.PARAMETER Architecture
  Architecture to download, Valid Options are: x86, x64, arm64, if using channel "Policy" this should be set to "any"
  Defaults to x64 if not set.

.PARAMETER Version
  If set the script will try and download a specific version. If not set it will download the latest.

.PARAMETER Folder
  Specifies the Download folder

.PARAMETER Force
  Overwrites the file without asking.

.NOTES
  Version:        1.2
  Author:         Mattias Benninge
  Creation Date:  2020-07-01

  Version history:

  1.0 -   Initial script development
  1.1 -   Fixes and improvements by @KarlGrindon
          - Script now handles multiple files for e.g. MacOS Edge files
          - Better error handling and formating
          - URI Validation
  1.2 -   Better compability on servers (force TLS and remove dependency to IE)

  
  https://docs.microsoft.com/en-us/mem/configmgr/apps/deploy-use/deploy-edge

.EXAMPLE
  
  Download the latest version for the Beta channel and overwrite any existing file
  .\Get-EdgeEnterpriseMSI.ps1 -Channel Beta -Folder D:\SourceCode\PowerShell\Div -Force

#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $False, HelpMessage = 'Channel to download, Valid Options are: Dev, Beta, Stable, EdgeUpdate, Policy')]
  [ValidateSet('Dev', 'Beta', 'Stable', 'EdgeUpdate', 'Policy')]
  [string]$Channel = 'Stable',
  
  [Parameter(Mandatory = $False, HelpMessage = 'Folder where the file will be downloaded')]
  [ValidateNotNullOrEmpty()]
  [string]$Folder = $env:TEMP,

  [Parameter(Mandatory = $false, HelpMessage = 'Platform to download, Valid Options are: Windows or MacOS')]
  [ValidateSet('Windows', 'MacOS', 'any')]
  [string]$Platform = "Windows",

  [Parameter(Mandatory = $false, HelpMessage = "Architecture to download, Valid Options are: x86, x64, arm64, any")]
  [ValidateSet('x86', 'x64', 'arm64', 'any')]
  [string]$Architecture = "x64",

  [parameter(Mandatory = $false, HelpMessage = "Specifies which version to download")]
  [ValidateNotNullOrEmpty()]
  [string]$ProductVersion,

  [parameter(Mandatory = $false, HelpMessage = "Overwrites the file without asking")]
  [Switch]$Force,

  [parameter(Mandatory = $false, HelpMessage = "Overwrites the file without asking")]
  [Switch]$Install

)

$ErrorActionPreference = "Stop"

$edgeEnterpriseMSIUri = 'https://edgeupdates.microsoft.com/api/products?view=enterprise'

# Validating parameters to reduce user errors
if ($Channel -eq "Policy" -and ($Architecture -ne "Any" -or $Platform -ne "Any")) {
  Write-Warning ("Channel 'Policy' requested, but either 'Architecture' and/or 'Platform' is not set to 'Any'. 
                  Setting Architecture and Platform to 'Any'")

  $Architecture = "Any"
  $Platform = "Any"
} 
elseif ($Channel -ne "Policy" -and ($Architecture -eq "Any" -or $Platform -eq "Any")) {
  throw "If Channel isn't set to policy, architecture and/or platform can't be set to 'Any'"
}
elseif ($Channel -eq "EdgeUpdate" -and ($Architecture -ne "x86" -or $Platform -eq "Windows")) {
  Write-Warning ("Channel 'EdgeUpdate' requested, but either 'Architecture' is not set to x86 and/or 'Platform' 
                  is not set to 'Windows'. Setting Architecture to 'x86' and Platform to 'Windows'")

  $Architecture = "x86"
  $Platform = "Windows"
}

Write-Host "Enabling connection over TLS for better compability on servers" -ForegroundColor Green
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls12

# Test if HTTP status code 200 is returned from URI
try {
  Invoke-WebRequest $edgeEnterpriseMSIUri -UseBasicParsing | Where-Object StatusCode -match 200 | Out-Null
}
catch {
  throw "Unable to get HTTP status code 200 from $edgeEnterpriseMSIUri. Does the URL still exist?"
}

Write-Host "Getting available files from $edgeEnterpriseMSIUri" -ForegroundColor Green

# Try to get JSON data from Microsoft
try {
  $response = Invoke-WebRequest -Uri $edgeEnterpriseMSIUri -Method Get -ContentType "application/json" -UseBasicParsing -ErrorVariable InvokeWebRequestError
  $jsonObj = ConvertFrom-Json $([String]::new($response.Content))
  Write-Host "Succefully retrived data" -ForegroundColor Green
}
catch {
  throw "Could not get MSI data: $InvokeWebRequestError"
}

# Alternative is to use Invoke-RestMethod to get a Json object directly
# $jsonObj = Invoke-RestMethod -Uri "https://edgeupdates.microsoft.com/api/products?view=enterprise" -UseBasicParsing

$selectedIndex = [array]::indexof($jsonObj.Product, "$Channel")

if (-not $ProductVersion) {
  try {
    Write-host "No version specified, getting the latest for $Channel" -ForegroundColor Green
    $selectedVersion = (([Version[]](($jsonObj[$selectedIndex].Releases |
            Where-Object { $_.Architecture -eq $Architecture -and $_.Platform -eq $Platform }).ProductVersion) |
        Sort-Object -Descending)[0]).ToString(4)
  
    Write-Host "Latest Version for channel $Channel is $selectedVersion`n" -ForegroundColor Green
    $selectedObject = $jsonObj[$selectedIndex].Releases |
    Where-Object { $_.Architecture -eq $Architecture -and $_.Platform -eq $Platform -and $_.ProductVersion -eq $selectedVersion }
  }
  catch {
    throw "Unable to get object from Microsoft. Check your parameters and refer to script help."
  }
}
else {
  Write-Host "Matching $ProductVersion on channel $Channel" -ForegroundColor Green
  $selectedObject = ($jsonObj[$selectedIndex].Releases |
    Where-Object { $_.Architecture -eq $Architecture -and $_.Platform -eq $Platform -and $_.ProductVersion -eq $ProductVersion })

  if (-not $selectedObject) {
    throw "No version matching $ProductVersion found in $channel channel for $Architecture architecture."
  }
  else {
    Write-Host "Found matching version`n" -ForegroundColor Green
  }
}


if (Test-Path $Folder) {
  foreach ($artifacts in $selectedObject.Artifacts) {
    # Not showing the progress bar in Invoke-WebRequest is quite a bit faster than default
    $ProgressPreference = 'SilentlyContinue'
    
    Write-host "Starting download of: $($artifacts.Location)" -ForegroundColor Green
    # Work out file name
    $fileName = Split-Path $artifacts.Location -Leaf

    if (Test-Path "$Folder\$fileName" -ErrorAction SilentlyContinue) {
      if ($Force) {
        Write-Host "Force specified. Will attempt to download and overwrite existing file." -ForegroundColor Green
        try {
          Invoke-WebRequest -Uri $artifacts.Location -OutFile "$Folder\$fileName" -UseBasicParsing
        }
        catch {
          throw "Attempted to download file, but failed: $error[0]"
        }    
      }
      else {
        # CR-someday: There should be an evaluation of the file version, if possible. Currently the function only
        # checks if a file of the same name exists, not if the versions differ
        Write-Host "$Folder\$fileName already exists!" -ForegroundColor Yellow

        do {
          $overWrite = Read-Host -Prompt "Press Y to overwrite or N to quit."
        }
        # -notmatch is case insensitive
        while ($overWrite -notmatch '^y$|^n$')
        
        if ($overWrite -match '^y$') {
          Write-Host "Starting Download" -ForegroundColor Green
          try {
            Invoke-WebRequest -Uri $artifacts.Location -OutFile "$Folder\$fileName" -UseBasicParsing
          }
          catch {
            throw "Attempted to download file, but failed: $error[0]"
          }
        }
        else {
          Write-Host "File already exists and user chose not to overwrite, exiting script." -ForegroundColor Red
          exit
        }
      }
    }
    else {
      Write-Host "Starting Download" -ForegroundColor Green
      try {
        Invoke-WebRequest -Uri $artifacts.Location -OutFile "$Folder\$fileName" -UseBasicParsing
      }
      catch {
        throw "Attempted to download file, but failed: $error[0]"
      }
    }
    if (((Get-FileHash -Algorithm $artifacts.HashAlgorithm -Path "$Folder\$fileName").Hash) -eq $artifacts.Hash) {
      Write-Host "Calculated checksum matches known checksum`n" -ForegroundColor Green
    }
    else {
      Write-Warning "Checksum mismatch!"
      Write-Warning "Expected Hash: $($artifacts.Hash)"
      Write-Warning "Downloaded file Hash: $((Get-FileHash -Algorithm $($artifacts.HashAlgorithm) -Path "$Folder\$fileName").Hash)`n"
    }
  }
}
else {
  throw "Folder $Folder does not exist"
}
Write-Host "-- Script Completed: File Downloaded $Folder\MicrosoftEdgeEnterpriseX64.msi " -ForegroundColor Green

if($Install){
    & msiexec /i "$Folder\MicrosoftEdgeEnterpriseX64.msi" /qb
    Write-Host "-- Script Completed: MS Edge is installed Downloaded -- " -ForegroundColor Green
}