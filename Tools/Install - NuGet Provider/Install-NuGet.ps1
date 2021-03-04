<#
.Synopsis
   Short description.
.DESCRIPTION
   Long description
.EXAMPLE

#>

[cmdletbinding(SupportsShouldProcess=$True)]
Param(
)

Function Get-TSxTest {
    Return "OK"
}
Function Get-TSxOSVersion([ref]$OSv) {
    $OS = Get-WmiObject -Class Win32_OperatingSystem | Select *
    Switch -Regex ($OS.Version)
    {
    "6.1"
        {If($OS.ProductType -eq 1)
            {$OSv.value = "Windows 7 SP1"}
                Else
            {$OSv.value = "Windows Server 2008 R2"}
        }
    "6.2"
        {If($OS.ProductType -eq 1)
            {$OSv.value = "Windows 8"}
                Else
            {$OSv.value = "Windows Server 2012"}
        }
    "6.3"
        {If($OS.ProductType -eq 1)
            {$OSv.value = "Windows 8.1"}
                Else
            {$OSv.value = "Windows Server 2012 R2"}
        }
    "10.0.14"
        {If($OS.ProductType -eq 1)
            {$OSv.value = "Windows 10 1607"}
                Else
            {$OSv.value = "Windows Server 2016"}
        }
    "10.0.17"
        {If($OS.ProductType -eq 1)
            {$OSv.value = "Windows 10 1809"}
                Else
            {$OSv.value = "Windows Server 2019"}
        }
    DEFAULT { "Version not listed" }
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