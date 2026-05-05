<#
.Synopsis
   Install NuGet package provider.
.DESCRIPTION
   Installs the NuGet package provider.
.EXAMPLE
    .\Install-NuGet.ps1
#>

[cmdletbinding(SupportsShouldProcess=$True)]
Param(
)

Function Get-TSxTest {
    Return "OK"
}
Function Get-TSxOSVersion([ref]$OSv) {
    $OS = Get-WmiObject -Class Win32_OperatingSystem
    $Caption = ($OS.Caption -replace '^Microsoft\s+', '').Trim()
    $CurrentVersionPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $CurrentVersion = $null

    if(Test-Path -Path $CurrentVersionPath)
    {
        $CurrentVersion = Get-ItemProperty -Path $CurrentVersionPath
    }

    if($OS.ProductType -eq 1)
    {
        switch -Regex ($Caption)
        {
            '^Windows 7' {
                if($OS.ServicePackMajorVersion -gt 0)
                {
                    $OSv.Value = "Windows 7 SP$($OS.ServicePackMajorVersion)"
                }
                else
                {
                    $OSv.Value = 'Windows 7'
                }
                return
            }
            '^Windows 8\.1' {
                $OSv.Value = 'Windows 8.1'
                return
            }
            '^Windows 8' {
                $OSv.Value = 'Windows 8'
                return
            }
            '^Windows (10|11)' {
                $DisplayVersion = $null
                if($CurrentVersion)
                {
                    if($CurrentVersion.DisplayVersion)
                    {
                        $DisplayVersion = $CurrentVersion.DisplayVersion
                    }
                    elseif($CurrentVersion.ReleaseId)
                    {
                        $DisplayVersion = $CurrentVersion.ReleaseId
                    }
                }

                if($DisplayVersion)
                {
                    $OSv.Value = "$($Matches[0]) $DisplayVersion"
                }
                else
                {
                    $OSv.Value = $Matches[0]
                }
                return
            }
        }
    }
    else
    {
        if($Caption -match '^(Windows Server (?:\d{4}|2008 R2|2012 R2|2003(?: R2)?))')
        {
            $OSv.Value = $Matches[1]
            return
        }
    }

    if(-not [string]::IsNullOrWhiteSpace($Caption))
    {
        $OSv.Value = $Caption
    }
    elseif($CurrentVersion -and $CurrentVersion.ProductName)
    {
        $OSv.Value = ($CurrentVersion.ProductName -replace '^Microsoft\s+', '').Trim()
    }
    else
    {
        $OSv.Value = 'Unknown'
    }
}
Function Get-TSxOSSKU {
    $Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Server\ServerLevels\'
    if(Test-Path -Path $Path)
    {
        $Test = Get-ItemProperty -Path $Path
        if(($Test.'ServerCore' -eq 1) -and ($Test.'Server-Gui-Shell' -eq 1)){$OSSKU = "DesktopExperience"}
        if(($Test.'ServerCore' -eq 1) -and ($Test.'Server-Gui-Shell' -ne 1)){$OSSKU = "Core"}
        Return $OSSKU
    }
    else
    {
        Return "Unknown"
    }
}
Function Invoke-TSxExe {
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
        Write-Verbose "Running Start-Process -FilePath $Executable -ArgumentList $Arguments -NoNewWindow -Wait -Passthru"
        $ReturnFromEXE = Start-Process -FilePath $Executable -NoNewWindow -Wait -Passthru
    }else{
        Write-Verbose "Running Start-Process -FilePath $Executable -ArgumentList $Arguments -NoNewWindow -Wait -Passthru"
        $ReturnFromEXE = Start-Process -FilePath $Executable -ArgumentList $Arguments -NoNewWindow -Wait -Passthru
    }
    Write-Verbose "Returncode is $($ReturnFromEXE.ExitCode)"
    Return $ReturnFromEXE.ExitCode
}
Function Start-TSxLog {
[CmdletBinding()]
    param (
    [ValidateScript({ Split-Path $_ -Parent | Test-Path })]
               [string]$FilePath
    )
               
    try
    {
        if (!(Test-Path $FilePath))
               {
                   ## Create the log file
                   New-Item $FilePath -Type File | Out-Null
               }
                              
               ## Set the global variable to be used as the FilePath for all subsequent Write-Log
               ## calls in this session
               $global:ScriptLogFilePath = $FilePath
    }
    catch
    {
        Write-Error $_.Exception.Message
    }
}
Function Write-TSxLog {
               param (
                              [Parameter(Mandatory = $true)]
                              [string]$Message,
                                             
                              [Parameter()]
                              [ValidateSet(1, 2, 3)]
                              [string]$LogLevel = 1
               )

    $TimeGenerated = "$(Get-Date -Format HH:mm:ss).$((Get-Date).Millisecond)+000"
    $Line = '<![LOG[{0}]LOG]!><time="{1}" date="{2}" component="{3}" context="" type="{4}" thread="" file="">'
    $LineFormat = $Message, $TimeGenerated, (Get-Date -Format MM-dd-yyyy), "$($MyInvocation.ScriptName | Split-Path -Leaf):$($MyInvocation.ScriptLineNumber)", $LogLevel
    #$LineFormat = $Message, $TimeGenerated, (Get-Date -Format MM-dd-yyyy), "$($MyInvocation.ScriptName | Split-Path -Leaf)", $LogLevel
    $Line = $Line -f $LineFormat
    Add-Content -Value $Line -Path $ScriptLogFilePath

    if($writetoscreen -eq $true){
        switch ($LogLevel)
        {
            '1'{
                Write-Host $Message -ForegroundColor Gray
                }
            '2'{
                Write-Host $Message -ForegroundColor Yellow
                }
            '3'{
                Write-Host $Message -ForegroundColor Red
                }
            Default {}
        }
    }
}
Function Get-TSxISVM {
    $Win32_computersystem  = Get-WmiObject -Class Win32_computersystem 
    switch ($Win32_computersystem.Model)
    {
        'VMware Virtual Platform' {$IsVM = "True"}
        'VMware7,1' {$IsVM = "True"}
        'Virtual Machine' {$IsVM = "True"}
        'Virtual Box' {$IsVM = "True"}
        Default {$IsVM = "True"}
    }
    Return $IsVM
}
Function Get-TSxISCoreServer {
    (Get-ItemProperty -Path "HKLM:\software\microsoft\windows nt\CurrentVersion").InstallationType -eq "Server Core"
}

# Set Vars
$VerbosePreference = "continue"
$writetoscreen = $true
$osv = ''
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScriptName = Split-Path -Leaf $MyInvocation.MyCommand.Path
$ARCHITECTURE = $env:PROCESSOR_ARCHITECTURE

# Import Microsoft.SMS.TSEnvironment
$tsenv = New-Object -COMObject Microsoft.SMS.TSEnvironment
$Logpath = $tsenv.Value("LogPath")
$LogFile = $Logpath + "\" + "$ScriptName.log"
$DeployRoot = $tsenv.Value("DeployRoot")

#Start logging
Start-TSxLog -FilePath $LogFile
Write-TSxLog "$ScriptName - Logging to $LogFile"

# Generate Vars
$OSSKU = Get-TSxOSSKU
$TSMake = $tsenv.Value("Make")
$TSModel = $tsenv.Value("Model")

Write-TSxLog "$ScriptName - Get-TSxOSVersion"
Get-TSxOSVersion -osv ([ref]$osv)  

Write-TSxLog "$ScriptName - Check if we are IsServerCoreOS"
$IsServerCoreOS = Get-TSxISCoreServer
Write-TSxLog "$ScriptName - IsServerCoreOS is now $IsServerCoreOS"

#Output more info
Write-TSxLog "$ScriptName - ScriptDir: $ScriptDir"
Write-TSxLog "$ScriptName - ScriptName: $ScriptName"
Write-TSxLog "$ScriptName - Log: $LogFile"
Write-TSxLog "$ScriptName - OSSKU: $OSSKU"
Write-TSxLog "$ScriptName - OSVersion: $osv"
Write-TSxLog "$ScriptName - Make:: $TSMake"
Write-TSxLog "$ScriptName - Model: $TSModel"

#Custom Code Starts--------------------------------------

Write-Output "$ScriptName - [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12,[Net.SecurityProtocolType]::Tls11"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12,[Net.SecurityProtocolType]::Tls11

Write-Output "$ScriptName - Install-PackageProvider -Name NuGet -Force -Verbose"
Install-PackageProvider -Name NuGet -Force -Verbose

Write-Output "$ScriptName - Install-Module -Name PowerShellGet -Force -SkipPublisherCheck -Verbose"
Install-Module -Name PowerShellGet -Force -SkipPublisherCheck -Verbose

Write-Output "$ScriptName - Update-Module -Force -Verbose"
Update-Module -Force -Verbose

#Stop Logging
. Stop-Logging