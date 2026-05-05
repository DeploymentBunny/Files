<#
.Synopsis
    Windows client health log collection.
.Description
    Collects important troubleshooting data from Windows 10 and Windows 11 clients,
    including DISM, CBS, Intune, ConfigMgr, setup/upgrade logs, selected event logs,
    and health command output. The result is packaged into a single archive.
.Example
    .\Get-WindowsClientHealthLogs.ps1 -RunHealthCommands -IncludeMsInfo
.Notes
    ScriptName: Get-WindowsClientHealthLogs.ps1
    Author:     Mikael Nystrom / GitHub Copilot
    Blog:       https://www.deploymentbunny.com
    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the authors or Deployment Artist.
.Link
    https://www.deploymentbunny.com
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "$env:ProgramData\WindowsClientHealthLogs",

    [Parameter(Mandatory = $false)]
    [int]$MaxEventCount = 2000,

    [Parameter(Mandatory = $false)]
    [switch]$RunHealthCommands,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeMsInfo,

    [Parameter(Mandatory = $false)]
    [switch]$NoZip
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:CollectorLog = $null
$script:TranscriptStarted = $false

function Write-CollectorLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    switch ($Level) {
        'INFO' { Write-Host $line -ForegroundColor Gray }
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
    }

    if (-not [string]::IsNullOrWhiteSpace($script:CollectorLog)) {
        try {
            Add-Content -Path $script:CollectorLog -Value $line -ErrorAction Stop
        }
        catch {
            Write-Host "[{0}] [WARN] Could not write to Collector.log: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message -ForegroundColor Yellow
        }
    }
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-DirectorySafe {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Copy-CollectionPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$DestinationSubFolder
    )

    $destination = Join-Path -Path $script:CollectionRoot -ChildPath $DestinationSubFolder
    New-DirectorySafe -Path $destination

    try {
        $items = Get-ChildItem -Path $Source -Force -ErrorAction Stop
        if (-not $items) {
            Write-CollectorLog -Message "No files matched: $Source" -Level 'WARN'
            $script:MissingItems.Add($Source) | Out-Null
            return
        }

        foreach ($item in $items) {
            try {
                Copy-Item -Path $item.FullName -Destination $destination -Recurse -Force -ErrorAction Stop
                $script:CopiedItems.Add($item.FullName) | Out-Null
            }
            catch {
                Write-CollectorLog -Message "Copy failed for '$($item.FullName)': $($_.Exception.Message)" -Level 'WARN'
                $script:FailedItems.Add($item.FullName) | Out-Null
            }
        }

        Write-CollectorLog -Message "Collected from: $Source"
    }
    catch {
        Write-CollectorLog -Message "Path not available: $Source" -Level 'WARN'
        $script:MissingItems.Add($Source) | Out-Null
    }
}

function Export-EventLogChannel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogName
    )

    $safeName = ($LogName -replace '[\\/:*?"<>| ]', '_')
    $evtxFile = Join-Path -Path $script:EventLogFolder -ChildPath ("{0}.evtx" -f $safeName)
    $txtFile = Join-Path -Path $script:EventLogFolder -ChildPath ("{0}.txt" -f $safeName)

    try {
        wevtutil.exe epl "$LogName" "$evtxFile" /ow:true | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-CollectorLog -Message "Exported event log channel: $LogName"
        }
        else {
            Write-CollectorLog -Message "wevtutil returned exit code $LASTEXITCODE for channel $LogName" -Level 'WARN'
        }
    }
    catch {
        Write-CollectorLog -Message "Failed to export channel $LogName as EVTX: $($_.Exception.Message)" -Level 'WARN'
    }

    try {
        Get-WinEvent -LogName $LogName -MaxEvents $MaxEventCount -ErrorAction Stop |
            Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message |
            Format-List |
            Out-File -FilePath $txtFile -Encoding UTF8 -Width 4096
    }
    catch {
        Write-CollectorLog -Message "Failed to export channel $LogName as text: $($_.Exception.Message)" -Level 'WARN'
    }
}

function Invoke-CommandCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    $outputFile = Join-Path -Path $script:CommandFolder -ChildPath ("{0}.txt" -f $Name)

    try {
        $global:LASTEXITCODE = 0
        & $ScriptBlock 2>&1 | Out-File -FilePath $outputFile -Encoding UTF8 -Width 4096
        Write-CollectorLog -Message "Captured command output: $Name"

        if ($LASTEXITCODE -ne 0) {
            Write-CollectorLog -Message "Native command in '$Name' returned exit code $LASTEXITCODE" -Level 'WARN'
        }
    }
    catch {
        $message = "Failed command capture: $Name. Error: $($_.Exception.Message)"
        Write-CollectorLog -Message $message -Level 'WARN'
        $message | Out-File -FilePath $outputFile -Encoding UTF8
    }
}

try {
    $computerName = $env:COMPUTERNAME
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $collectionName = "{0}_{1}" -f $computerName, $timestamp
    $script:CollectionRoot = Join-Path -Path $OutputPath -ChildPath $collectionName
    $script:EventLogFolder = Join-Path -Path $script:CollectionRoot -ChildPath 'EventLogs'
    $script:CommandFolder = Join-Path -Path $script:CollectionRoot -ChildPath 'CommandOutputs'
    $script:FileLogFolder = Join-Path -Path $script:CollectionRoot -ChildPath 'FileLogs'

    $script:CopiedItems = New-Object System.Collections.Generic.List[string]
    $script:FailedItems = New-Object System.Collections.Generic.List[string]
    $script:MissingItems = New-Object System.Collections.Generic.List[string]

    New-DirectorySafe -Path $OutputPath
    New-DirectorySafe -Path $script:CollectionRoot
    New-DirectorySafe -Path $script:EventLogFolder
    New-DirectorySafe -Path $script:CommandFolder
    New-DirectorySafe -Path $script:FileLogFolder

    $script:CollectorLog = Join-Path -Path $script:CollectionRoot -ChildPath 'Collector.log'
    "Windows Client Health Log Collection started: $(Get-Date -Format s)" | Out-File -FilePath $script:CollectorLog -Encoding UTF8
    Write-CollectorLog -Message "Collection root: $script:CollectionRoot"

    try {
        $transcriptPath = Join-Path -Path $script:CollectionRoot -ChildPath 'Transcript.log'
        Start-Transcript -Path $transcriptPath -Append -Force -ErrorAction Stop | Out-Null
        $script:TranscriptStarted = $true
        Write-CollectorLog -Message "Transcript started: $transcriptPath"
    }
    catch {
        Write-CollectorLog -Message "Could not start transcript: $($_.Exception.Message)" -Level 'WARN'
    }

    if (-not (Test-Administrator)) {
        Write-CollectorLog -Message 'Script is not running elevated. Some logs may not be accessible.' -Level 'WARN'
    }

    $logTargets = @(
        @{ Source = 'C:\Windows\Logs\DISM\*'; Destination = 'FileLogs\DISM' },
        @{ Source = 'C:\Windows\Logs\CBS\CBS.log'; Destination = 'FileLogs\CBS' },
        @{ Source = 'C:\Windows\Logs\CBS\CbsPersist*.cab'; Destination = 'FileLogs\CBS' },
        @{ Source = 'C:\Windows\Panther\*.log'; Destination = 'FileLogs\Panther' },
        @{ Source = 'C:\Windows\Panther\UnattendGC\*.log'; Destination = 'FileLogs\Panther' },
        @{ Source = 'C:\$WINDOWS.~BT\Sources\Panther\*.log'; Destination = 'FileLogs\Upgrade' },
        @{ Source = 'C:\$WINDOWS.~BT\Sources\Rollback\*.log'; Destination = 'FileLogs\Upgrade' },
        @{ Source = 'C:\Windows\Logs\MoSetup\*.log'; Destination = 'FileLogs\MoSetup' },
        @{ Source = 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\*.log'; Destination = 'FileLogs\Intune' },
        @{ Source = 'C:\ProgramData\Microsoft\Windows\Provisioning\Logs\*.log'; Destination = 'FileLogs\Provisioning' },
        @{ Source = 'C:\Windows\CCM\Logs\*.log'; Destination = 'FileLogs\ConfigMgr' },
        @{ Source = 'C:\Windows\CCMSetup\Logs\*.log'; Destination = 'FileLogs\ConfigMgr' },
        @{ Source = 'C:\Windows\Temp\SMSTSLog\*.log'; Destination = 'FileLogs\TaskSequence' },
        @{ Source = 'C:\_SMSTaskSequence\Logs\*.log'; Destination = 'FileLogs\TaskSequence' },
        @{ Source = 'C:\MININT\SMSOSD\OSDLOGS\*.log'; Destination = 'FileLogs\TaskSequence' },
        @{ Source = 'C:\ProgramData\USOShared\Logs\*.etl'; Destination = 'FileLogs\WindowsUpdate' },
        @{ Source = 'C:\Windows\Logs\WindowsUpdate\*.etl'; Destination = 'FileLogs\WindowsUpdate' }
    )

    foreach ($target in $logTargets) {
        Copy-CollectionPath -Source $target.Source -DestinationSubFolder $target.Destination
    }

    $eventChannels = @(
        'Application',
        'System',
        'Setup',
        'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin',
        'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Operational',
        'Microsoft-Windows-WindowsUpdateClient/Operational',
        'Microsoft-Windows-Bits-Client/Operational',
        'Microsoft-Windows-AppXDeploymentServer/Operational',
        'Microsoft-Windows-ModernDeployment-Diagnostics-Provider/Autopilot'
    )

    foreach ($channel in $eventChannels) {
        Export-EventLogChannel -LogName $channel
    }

    Invoke-CommandCapture -Name 'OSVersion' -ScriptBlock {
        Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion, OsBuildNumber, OsHardwareAbstractionLayer, CsModel, CsManufacturer, BiosName, BiosVersion
    }

    Invoke-CommandCapture -Name 'SystemInfo' -ScriptBlock { systeminfo.exe }
    Invoke-CommandCapture -Name 'InstalledHotfixes' -ScriptBlock { Get-HotFix | Sort-Object InstalledOn -Descending }
    Invoke-CommandCapture -Name 'Drivers_PnPSigned' -ScriptBlock { Get-CimInstance Win32_PnPSignedDriver | Select-Object DeviceName, DriverVersion, DriverDate, Manufacturer | Sort-Object DeviceName }
    Invoke-CommandCapture -Name 'DefenderStatus' -ScriptBlock { Get-MpComputerStatus }
    Invoke-CommandCapture -Name 'Services_Running' -ScriptBlock { Get-Service | Sort-Object Status, DisplayName }
    Invoke-CommandCapture -Name 'IPConfig_All' -ScriptBlock { ipconfig.exe /all }
    Invoke-CommandCapture -Name 'RoutePrint' -ScriptBlock { route.exe print }
    Invoke-CommandCapture -Name 'WinHTTPProxy' -ScriptBlock { netsh.exe winhttp show proxy }
    Invoke-CommandCapture -Name 'GroupPolicyResult' -ScriptBlock { gpresult.exe /R /SCOPE COMPUTER }
    Invoke-CommandCapture -Name 'WindowsUpdateClientSettings' -ScriptBlock {
        Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue
        Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction SilentlyContinue
    }
    Invoke-CommandCapture -Name 'PendingRebootIndicators' -ScriptBlock {
        $keys = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
            'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
        )

        foreach ($key in $keys) {
            [PSCustomObject]@{
                KeyPath = $key
                Exists  = Test-Path -LiteralPath $key
            }
        }

        Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
    }

    Invoke-CommandCapture -Name 'DISM_CheckHealth' -ScriptBlock {
        dism.exe /Online /Cleanup-Image /CheckHealth
    }

    if ($RunHealthCommands) {
        Invoke-CommandCapture -Name 'DISM_ScanHealth' -ScriptBlock {
            dism.exe /Online /Cleanup-Image /ScanHealth
        }

        Invoke-CommandCapture -Name 'SFC_VerifyOnly' -ScriptBlock {
            sfc.exe /verifyonly
        }
    }
    else {
        Write-CollectorLog -Message 'Skipped DISM /ScanHealth and SFC /verifyonly. Use -RunHealthCommands to include them.'
    }

    if ($IncludeMsInfo) {
        $msinfoPath = Join-Path -Path $script:CollectionRoot -ChildPath 'MSINFO32.nfo'
        try {
            Start-Process -FilePath 'msinfo32.exe' -ArgumentList "/nfo \"$msinfoPath\"" -Wait -NoNewWindow
            Write-CollectorLog -Message 'Captured MSINFO32 report.'
        }
        catch {
            Write-CollectorLog -Message "Failed to capture MSINFO32: $($_.Exception.Message)" -Level 'WARN'
        }
    }

    $summary = [PSCustomObject]@{
        ComputerName      = $computerName
        Timestamp         = $timestamp
        CollectionRoot    = $script:CollectionRoot
        CopiedItemCount   = $script:CopiedItems.Count
        FailedItemCount   = $script:FailedItems.Count
        MissingPathCount  = $script:MissingItems.Count
        IsAdministrator   = (Test-Administrator)
        RunHealthCommands = [bool]$RunHealthCommands
        IncludeMsInfo     = [bool]$IncludeMsInfo
    }

    $summary | ConvertTo-Json -Depth 4 | Out-File -FilePath (Join-Path -Path $script:CollectionRoot -ChildPath 'Summary.json') -Encoding UTF8
    $script:CopiedItems | Sort-Object -Unique | Out-File -FilePath (Join-Path -Path $script:CollectionRoot -ChildPath 'CollectedItems.txt') -Encoding UTF8
    $script:FailedItems | Sort-Object -Unique | Out-File -FilePath (Join-Path -Path $script:CollectionRoot -ChildPath 'FailedItems.txt') -Encoding UTF8
    $script:MissingItems | Sort-Object -Unique | Out-File -FilePath (Join-Path -Path $script:CollectionRoot -ChildPath 'MissingPaths.txt') -Encoding UTF8

    $zipPath = Join-Path -Path $OutputPath -ChildPath ("{0}.zip" -f $collectionName)
    if ($NoZip) {
        Write-CollectorLog -Message "Zip step skipped. Folder retained at: $script:CollectionRoot"
        Write-Output "Collection completed: $script:CollectionRoot"
    }
    else {
        try {
            if (Test-Path -LiteralPath $zipPath) {
                Remove-Item -LiteralPath $zipPath -Force
            }

            Compress-Archive -Path (Join-Path -Path $script:CollectionRoot -ChildPath '*') -DestinationPath $zipPath -CompressionLevel Optimal -Force
            Write-CollectorLog -Message "Zip created: $zipPath"
            Write-Output "Collection completed: $zipPath"
        }
        catch {
            Write-CollectorLog -Message "Failed to create zip: $($_.Exception.Message)" -Level 'ERROR'
            Write-Output "Collection completed (without zip): $script:CollectionRoot"
        }
    }
}
catch {
    $fatalMessage = "Unhandled error: $($_.Exception.Message)"
    Write-CollectorLog -Message $fatalMessage -Level 'ERROR'
    if ($_.ScriptStackTrace) {
        Write-CollectorLog -Message "StackTrace: $($_.ScriptStackTrace)" -Level 'ERROR'
    }
    Write-Error $fatalMessage
    exit 1
}
finally {
    if ($script:TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
            Write-Host "[{0}] [WARN] Failed to stop transcript: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message -ForegroundColor Yellow
        }
    }
}
