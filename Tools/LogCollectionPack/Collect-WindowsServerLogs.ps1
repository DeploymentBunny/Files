
<#
.SYNOPSIS
        Collect Windows Server health, logs, and role diagnostics into an analytic-ready package.
.DESCRIPTION
    Collect-WindowsServerLogs gathers OS health and servicing data, event logs, role and feature inventory,
        performance counters (BLG and CSV), optional Java process metrics, and role-specific diagnostics
        for AD DS, AD CS, DNS, and DHCP when those roles are present. Exported EVTX files are converted to
        TXT, XML, and CSV for easier analytics consumption. Output includes a timestamped collection folder,
        an Analytic-Ready subfolder, and an optional ZIP archive.

        The script is read-only from a system-configuration perspective and only writes collection artifacts.
        Run from an elevated Windows PowerShell 5.1 session.
.PARAMETER OutputRoot
        Root folder for output. Default: C:\WS-Diagnostics.
.PARAMETER DurationMinutes
        Duration to sample performance counters (minutes). Default: 10.
.PARAMETER SampleIntervalSeconds
        Sampling interval for performance counters (seconds). Default: 5.
.PARAMETER DeepHealth
        Runs DISM /ScanHealth and SFC /verifyonly (read-only, can take longer).
.PARAMETER IncludeFullCBS
        Copies full CBS.log (can be large). If omitted, only the last 5000 lines are copied.
.PARAMETER NoZip
        Skips creation of the ZIP archive.
.PARAMETER ValidateCounters
        Pre-tests performance counters and excludes unavailable counters.
.PARAMETER JavaMetrics
        Collects java.exe process metrics when present. Enabled by default.
.PARAMETER ExcludeEvtxFromZip
        Excludes native .evtx files from the ZIP. Converted TXT/XML/CSV outputs are still included.
.EXAMPLE
    .\Collect-WindowsServerLogs.ps1
.EXAMPLE
    .\Collect-WindowsServerLogs.ps1 -OutputRoot D:\Diagnostics -DurationMinutes 15 -SampleIntervalSeconds 5 -Verbose
.EXAMPLE
    .\Collect-WindowsServerLogs.ps1 -DeepHealth -IncludeFullCBS -ExcludeEvtxFromZip
.NOTES
    FileName:    Collect-WindowsServerLogs.ps1
    Version:     5.4
        Updated:     2026-05-07
        Author:      Mikael Nystrom
        Contact:     deploymentbunny@outlook.com
        Blog:        https://www.deploymentbunny.com
        Disclaimer:
        This script is provided "AS IS" with no warranties, confers no rights and
        is not supported by the author.
.LINK
        https://www.deploymentbunny.com
.FUNCTIONALITY
        - Collect OS and servicing health data (CBS, DISM, SFC status)
        - Collect performance counters and optional Java process metrics
        - Collect event logs and convert EVTX to TXT/XML/CSV
        - Collect role-specific diagnostics for AD DS, AD CS, DNS, DHCP when detected
        - Build timestamped output, Analytic-Ready structure, and optional ZIP
#>

[CmdletBinding()]
param(
    [string]$OutputRoot = "$env:SystemDrive\WS-Diagnostics",
    [int]$DurationMinutes = 10,
    [int]$SampleIntervalSeconds = 5,
    [switch]$DeepHealth,
    [switch]$IncludeFullCBS,
    [switch]$NoZip,
    [switch]$ValidateCounters,
    [switch]$JavaMetrics = $true,
    [switch]$ExcludeEvtxFromZip
)

# -------------------- Safety & Helpers --------------------
$ErrorActionPreference = 'Continue'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Warning "This script must be run as Administrator. Exiting."
    return
}

# Require Windows PowerShell 5.1
if (-not ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -ge 1)) {
    Write-Warning "Windows PowerShell 5.1 is required. Detected: $($PSVersionTable.PSVersion). Exiting."
    return
}

$computer  = $env:COMPUTERNAME
$timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$OutDir    = Join-Path $OutputRoot "$computer-$timestamp"
$null = New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Save-ObjectCsv {
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string]$Path
    )
    try { $InputObject | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $Path }
    catch { Write-Warning "Failed to save CSV $Path : $_" }
}

function Invoke-CMD {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = '',
        [string]$OutFile
    )
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.Arguments = $Arguments
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute = $false
        $p = [System.Diagnostics.Process]::Start($psi)
        $stdout = $p.StandardOutput.ReadToEnd()
        $stderr = $p.StandardError.ReadToEnd()
        $p.WaitForExit()

        if ($OutFile) {
            $stdout | Out-File -FilePath $OutFile -Encoding UTF8 -Force
            if ($stderr) {
                "`n---- STDERR ----`n$stderr" | Out-File -FilePath $OutFile -Encoding UTF8 -Append
            }
        }
        return @{ExitCode=$p.ExitCode; StdOut=$stdout; StdErr=$stderr}
    }
    catch {
        Write-Warning "Failed to run $FilePath $Arguments : $_"
        if ($OutFile) { "ERROR: $_" | Out-File -FilePath $OutFile -Encoding UTF8 -Force }
    }
}

function Convert-DmtfSafe {
    param([string]$Dmtf)
    if ([string]::IsNullOrWhiteSpace($Dmtf)) { return $null }
    if ($Dmtf.Length -lt 14) { return $null }
    try { return [Management.ManagementDateTimeConverter]::ToDateTime($Dmtf) }
    catch { return $null }
}

function Test-CounterPresent {
    param([string[]]$Counters)
    $valid = New-Object System.Collections.Generic.List[string]
    foreach ($c in $Counters) {
        try {
            $null = Get-Counter -Counter $c -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
            $valid.Add($c)
        } catch {
            Write-Verbose "Skipping unavailable counter: $c"
        }
    }
    return $valid.ToArray()
}

function Get-ServerVersionInfo {
    $regNT = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    [PSCustomObject]@{
        ProductName    = $regNT.ProductName
        ReleaseId      = $regNT.ReleaseId
        DisplayVersion = $regNT.DisplayVersion
        CurrentBuild   = $regNT.CurrentBuild
        UBR            = $regNT.UBR
        VersionString  = if ($regNT.UBR) { "$($regNT.CurrentBuild).$($regNT.UBR)" } else { "$($regNT.CurrentBuild)" }
    }
}

# Roles/Features with ServerManager or DISM fallback
function Export-RolesAndFeatures {
    param([string]$Folder)
    $allPath  = Join-Path $Folder 'WindowsFeatures_All.csv'
    $instPath = Join-Path $Folder 'WindowsFeatures_Installed.csv'
    try {
        Import-Module ServerManager -ErrorAction Stop
        $all = Get-WindowsFeature
        $all | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $allPath
        $all | Where-Object Installed | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $instPath
        return
    } catch {
        Write-Warning "ServerManager module not available; falling back to DISM parsing."
    }
    try {
        $tmpAll = Join-Path $Folder 'dism_features_all.txt'
        $tmpCap = Join-Path $Folder 'dism_capabilities.txt'
        Invoke-CMD -FilePath 'dism.exe' -Arguments '/online /Get-Features /Format:Table' -OutFile $tmpAll | Out-Null
        Invoke-CMD -FilePath 'dism.exe' -Arguments '/online /Get-Capabilities' -OutFile $tmpCap | Out-Null

        $features = @()
        if (Test-Path $tmpAll) {
            $lines = Get-Content $tmpAll
            foreach ($ln in $lines) {
                if ($ln -match '^\s*([A-Za-z0-9\.\-\_]+)\s+\|\s+(\w+)') {
                    $features += [PSCustomObject]@{
                        Name  = $matches[1]
                        State = $matches[2]
                    }
                }
            }
        }
        if ($features) {
            $features | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $allPath
            $features | Where-Object { $_.State -match 'Enabled|EnablePending|PartiallyInstalled' } |
                Export-Csv -NoTypeInformation -Encoding UTF8 -Path $instPath
        } else {
            "Unable to parse DISM feature output." | Out-File -FilePath (Join-Path $Folder 'WindowsFeatures_Readme.txt') -Encoding UTF8
        }

        if (Test-Path $tmpCap) {
            Copy-Item $tmpCap (Join-Path $Folder 'DISM_Capabilities.txt') -Force
        }
    } catch {
        Write-Warning "DISM roles/features export failed: $_"
    }
}

# Wait until a file can be exclusively opened (unlocked)
function Wait-ForFileUnlock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$RetryCount = 20,
        [int]$DelayMs = 250
    )
    for ($i = 0; $i -lt $RetryCount; $i++) {
        try {
            if (-not (Test-Path -LiteralPath $Path)) { return $true }  # missing is fine
            $fs = [System.IO.File]::Open($Path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None)
            $fs.Close()
            return $true
        } catch {
            Start-Sleep -Milliseconds $DelayMs
        }
    }
    return $false
}

# -------------------- Role Detection & Role-Specific Collection Helpers --------------------
function Test-ServiceExists {
    param([Parameter(Mandatory)][string]$Name)
    try { return (Get-Service -Name $Name -ErrorAction Stop) -ne $null } catch { return $false }
}

function Get-RolePresence {
    # Use well-known services as "role exists" signals.
    # AD DS (DC)        -> NTDS
    # DNS Server        -> DNS
    # DHCP Server       -> DHCPServer
    # AD CS (CA)        -> CertSvc
    [PSCustomObject]@{
        IsADDS = (Test-ServiceExists -Name 'NTDS')
        IsDNS  = (Test-ServiceExists -Name 'DNS')
        IsDHCP = (Test-ServiceExists -Name 'DHCPServer')
        IsCA   = (Test-ServiceExists -Name 'CertSvc')
    }
}

function Save-Text {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Text
    )
    try { $Text | Out-File -FilePath $Path -Encoding UTF8 -Force } catch { Write-Warning "Failed to write $Path : $_" }
}

function Invoke-AndSave {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = '',
        [Parameter(Mandatory)][string]$OutFile
    )
    "==== $Title ====" | Out-File -FilePath $OutFile -Encoding UTF8 -Force
    Invoke-CMD -FilePath $FilePath -Arguments $Arguments -OutFile $OutFile | Out-Null
}

function Test-ImportModule {
    param([Parameter(Mandatory)][string]$Name)
    try {
        Import-Module $Name -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Get-ComputerDomainName {
    # Best-effort domain name (works even if USERDNSDOMAIN empty)
    $d = $env:USERDNSDOMAIN
    if ([string]::IsNullOrWhiteSpace($d)) {
        try {
            $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
            if ($cs.Domain -and $cs.PartOfDomain) { return $cs.Domain }
        } catch {}
    }
    return $d
}

# -------------------- System Summary --------------------
Write-Host "Collecting system summary ..."
$sysDir = Join-Path $OutDir 'System'
$null = New-Item -ItemType Directory -Force -Path $sysDir | Out-Null

$os   = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$cs   = Get-CimInstance Win32_ComputerSystem   -ErrorAction SilentlyContinue
$bios = Get-CimInstance Win32_BIOS             -ErrorAction SilentlyContinue
$proc = Get-CimInstance Win32_Processor        -ErrorAction SilentlyContinue

# DMTF conversion with fallbacks
$installDate = $null
$lastBoot    = $null
if ($os) {
    $installDate = Convert-DmtfSafe $os.InstallDate
    $lastBoot    = Convert-DmtfSafe $os.LastBootUpTime
}

# Fallback if LastBoot missing
if (-not $lastBoot) {
    try {
        $uptimeSec = (Get-Counter '\System\System Up Time').CounterSamples.CookedValue
        $lastBoot  = (Get-Date).AddSeconds(-$uptimeSec)
    } catch { $lastBoot = $null }
}

# Fallback if InstallDate missing
if (-not $installDate) {
    try {
        $regInst = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        if ($regInst.InstallDate) {
            # Windows stores InstallDate as UNIX timestamp (seconds since 1970-01-01)
            $installDate = (Get-Date '1970-01-01').AddSeconds([int64]$regInst.InstallDate)
        }
    }
    catch {
        Write-Verbose "Failed to retrieve InstallDate fallback: $_"
    }
}

$uptimeDays = $null
if ($lastBoot) { $uptimeDays = ((Get-Date) - $lastBoot).TotalDays }

# Build info
$buildInfo = Get-ServerVersionInfo

# Summary (never null)
$summary = [PSCustomObject]@{
    ComputerName = $computer
    OSCaption    = $os.Caption
    OSVersion    = $os.Version
    Build        = $buildInfo.VersionString
    InstallDate  = $installDate
    LastBoot     = $lastBoot
    UptimeDays   = if ($uptimeDays) { [int]$uptimeDays } else { $null }
    Manufacturer = $cs.Manufacturer
    Model        = $cs.Model
    BIOSVersion  = $bios.SMBIOSBIOSVersion -join ' '
    CPU          = $proc.Name -join ' | '
    LogicalCPUs  = ($proc.NumberOfLogicalProcessors | Measure-Object -Sum).Sum
    TotalRAMGB   = if ($cs.TotalPhysicalMemory) { [Math]::Round($cs.TotalPhysicalMemory/1GB,2) } else { $null }
}
Save-ObjectCsv $summary (Join-Path $sysDir 'SystemSummary.csv')

# Time sync
Invoke-CMD -FilePath 'w32tm.exe' -Arguments '/query /status' -OutFile (Join-Path $sysDir 'TimeSync.txt') | Out-Null

# NIC & IP (+ per-interface summary)
try {
    $adapters = Get-NetAdapter | Sort-Object Name
    Save-ObjectCsv $adapters (Join-Path $sysDir 'NetAdapter.csv')
} catch { Write-Warning "Get-NetAdapter failed: $_" }

try {
    $ipcfg = Get-NetIPConfiguration
    Save-ObjectCsv $ipcfg (Join-Path $sysDir 'NetIPConfiguration.csv')
} catch { Write-Warning "Get-NetIPConfiguration failed: $_" }

try {
    $nicSummary = foreach ($nic in (Get-NetAdapter -ErrorAction SilentlyContinue)) {
        $ip = $null
        try { $ip = Get-NetIPConfiguration -InterfaceIndex $nic.ifIndex -ErrorAction SilentlyContinue } catch {}
        [PSCustomObject]@{
            Name        = $nic.Name
            Status      = $nic.Status
            LinkSpeed   = $nic.LinkSpeed
            MAC         = $nic.MacAddress
            IPv4        = if ($ip) { ($ip.IPv4Address.IPAddress -join ';') } else { $null }
            IPv6        = if ($ip) { ($ip.IPv6Address.IPAddress -join ';') } else { $null }
            DNSServers  = if ($ip) { ($ip.DnsServer.ServerAddresses -join ';') } else { $null }
        }
    }
    if ($nicSummary) { Save-ObjectCsv $nicSummary (Join-Path $sysDir 'NetInterfaceSummary.csv') }
} catch { Write-Warning "NIC summary failed: $_" }

# Disk topology
try { Save-ObjectCsv (Get-PhysicalDisk) (Join-Path $sysDir 'PhysicalDisk.csv') } catch { Write-Warning "Get-PhysicalDisk failed: $_" }
try { Save-ObjectCsv (Get-Disk)         (Join-Path $sysDir 'Disk.csv')         } catch { Write-Warning "Get-Disk failed: $_" }
try { Save-ObjectCsv (Get-Partition)    (Join-Path $sysDir 'Partition.csv')    } catch { Write-Warning "Get-Partition failed: $_" }
try { Save-ObjectCsv (Get-Volume)       (Join-Path $sysDir 'Volume.csv')       } catch { Write-Warning "Get-Volume failed: $_" }

# Processes & Services snapshot
try {
    Get-Process | Sort-Object CPU -Descending | Select-Object -First 50 |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $sysDir 'TopProcessesByCPU.csv')
} catch { Write-Warning "Top processes by CPU failed: $_" }

try {
    Get-Process | Sort-Object WS -Descending | Select-Object -First 50 |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $sysDir 'TopProcessesByMemory.csv')
} catch { Write-Warning "Top processes by memory failed: $_" }

try {
    Get-Service | Where-Object { $_.Status -ne 'Running' -and $_.StartType -eq 'Automatic' } |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $sysDir 'AutoServicesNotRunning.csv')
} catch { Write-Warning "Service snapshot failed: $_" }

# Optional Java process metrics
if ($JavaMetrics) {
    try {
        $javaProcs = Get-Process -Name java -ErrorAction SilentlyContinue
        if ($javaProcs) {
            $javaOut = $javaProcs | Select-Object `
                Id, ProcessName,
                @{n='StartTime';e={ try { $_.StartTime } catch { $null } }},
                CPU,
                @{n='WorkingSetMB';e={ [math]::Round($_.WorkingSet64/1MB,2) }},
                @{n='PrivateBytesMB';e={ [math]::Round($_.PrivateMemorySize64/1MB,2) }},
                Handles, Threads
            Save-ObjectCsv $javaOut (Join-Path $sysDir 'Java_ProcessMetrics.csv')
        } else {
            "No java.exe processes found at collection time." | Out-File -FilePath (Join-Path $sysDir 'Java_ProcessMetrics.txt') -Encoding UTF8
        }
    } catch { Write-Warning "Java metrics collection failed: $_" }
}

# -------------------- Patch Level & Roles --------------------
Write-Host "Collecting patch level and roles/features ..."
$patchDir = Join-Path $OutDir 'PatchAndRoles'
$null = New-Item -ItemType Directory -Force -Path $patchDir | Out-Null

try {
    Get-HotFix | Sort-Object InstalledOn | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $patchDir 'HotFixes.csv')
} catch { Write-Warning "Get-HotFix failed: $_" }

try {
    Export-RolesAndFeatures -Folder $patchDir
} catch { Write-Warning "Roles/Features export failed: $_" }

# -------------------- Health Checks (DISM/SFC) --------------------
Write-Host "Running health checks (DISM/SFC) ..."
$healthDir = Join-Path $OutDir 'Health'
$null = New-Item -ItemType Directory -Force -Path $healthDir | Out-Null

Invoke-CMD -FilePath 'dism.exe' -Arguments '/Online /Cleanup-Image /CheckHealth' -OutFile (Join-Path $healthDir 'DISM_CheckHealth.txt') | Out-Null

if ($DeepHealth) {
    Invoke-CMD -FilePath 'dism.exe' -Arguments '/Online /Cleanup-Image /ScanHealth' -OutFile (Join-Path $healthDir 'DISM_ScanHealth.txt') | Out-Null
    Invoke-CMD -FilePath 'sfc.exe'  -Arguments '/verifyonly'                          -OutFile (Join-Path $healthDir 'SFC_VerifyOnly.txt') | Out-Null
} else {
    "DeepHealth not requested. Use -DeepHealth to run DISM /ScanHealth and SFC /verifyonly." |
        Out-File -FilePath (Join-Path $healthDir 'Readme.txt') -Encoding UTF8
}

# Copy CBS/DISM logs
$cbsFolder  = "$env:WINDIR\Logs\CBS"
$dismFolder = "$env:WINDIR\Logs\DISM"
$logsDir = Join-Path $healthDir 'Logs'
$null = New-Item -ItemType Directory -Force -Path $logsDir | Out-Null

try {
    if (Test-Path "$cbsFolder\CBS.log") {
        if ($IncludeFullCBS) {
            Copy-Item "$cbsFolder\CBS.log" (Join-Path $logsDir 'CBS.log') -ErrorAction SilentlyContinue
        } else {
            Get-Content "$cbsFolder\CBS.log" -Tail 5000 | Out-File -FilePath (Join-Path $logsDir 'CBS_tail5000.log') -Encoding UTF8
        }
    }
    if (Test-Path "$cbsFolder\CBS.persist.log") {
        Copy-Item "$cbsFolder\CBS.persist.log" (Join-Path $logsDir 'CBS.persist.log') -ErrorAction SilentlyContinue
    }
    if (Test-Path "$dismFolder\dism.log") {
        Copy-Item "$dismFolder\dism.log" (Join-Path $logsDir 'dism.log') -ErrorAction SilentlyContinue
    }
} catch { Write-Warning "Failed to copy CBS/DISM logs: $_" }

# -------------------- Role-Specific Collection (AD / CA / DNS / DHCP) --------------------
Write-Host "Collecting role-specific diagnostics (if roles exist) ..."

$roleDir = Join-Path $OutDir 'RoleSpecific'
$null = New-Item -ItemType Directory -Force -Path $roleDir | Out-Null

$roles = Get-RolePresence
Save-ObjectCsv $roles (Join-Path $roleDir 'RolePresence.csv')

# ---- Active Directory (Domain Controller) ----
if ($roles.IsADDS) {
    $adDir = Join-Path $roleDir 'ActiveDirectory'
    $null = New-Item -ItemType Directory -Force -Path $adDir | Out-Null

    $domainName = Get-ComputerDomainName

    Invoke-AndSave -Title 'DCDiag (verbose)' -FilePath 'dcdiag.exe' -Arguments '/v /c /e' -OutFile (Join-Path $adDir 'dcdiag.txt')
    Invoke-AndSave -Title 'Repadmin ReplSummary' -FilePath 'repadmin.exe' -Arguments '/replsummary' -OutFile (Join-Path $adDir 'repadmin_replsummary.txt')
    Invoke-AndSave -Title 'Repadmin ShowRepl (CSV to stdout)' -FilePath 'repadmin.exe' -Arguments '/showrepl * /csv' -OutFile (Join-Path $adDir 'repadmin_showrepl.csv.txt')
    Invoke-AndSave -Title 'FSMO Roles' -FilePath 'netdom.exe' -Arguments 'query fsmo' -OutFile (Join-Path $adDir 'fsmo_roles.txt')

    if (-not [string]::IsNullOrWhiteSpace($domainName)) {
        Invoke-AndSave -Title 'NLTEST DCLIST (domain)' -FilePath 'nltest.exe' -Arguments "/dclist:$domainName" -OutFile (Join-Path $adDir 'nltest_dclist.txt')
        Invoke-AndSave -Title 'NLTEST DSGETDC (domain)' -FilePath 'nltest.exe' -Arguments "/dsgetdc:$domainName" -OutFile (Join-Path $adDir 'nltest_dsgetdc.txt')
    } else {
        Save-Text -Path (Join-Path $adDir 'nltest_note.txt') -Text "Domain name could not be determined (USERDNSDOMAIN empty and CIM fallback failed). Skipping nltest domain-targeted commands."
    }

    if (Get-Command dfsrdiag.exe -ErrorAction SilentlyContinue) {
        Invoke-AndSave -Title 'DFSRDIAG ReplicationState' -FilePath 'dfsrdiag.exe' -Arguments 'ReplicationState' -OutFile (Join-Path $adDir 'dfsrdiag_replicationstate.txt')
        Invoke-AndSave -Title 'DFSRDIAG PollAD' -FilePath 'dfsrdiag.exe' -Arguments 'PollAD' -OutFile (Join-Path $adDir 'dfsrdiag_pollad.txt')
    }

    if (Test-ImportModule -Name 'ActiveDirectory') {
        try { Get-ADDomain | Select-Object * | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $adDir 'ADDomain.csv') } catch { Write-Warning "Get-ADDomain failed: $_" }
        try { Get-ADForest | Select-Object * | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $adDir 'ADForest.csv') } catch { Write-Warning "Get-ADForest failed: $_" }
        try {
            Get-ADDomainController -Filter * | Select-Object HostName,Site,IPv4Address,OperatingSystem,IsGlobalCatalog |
                Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $adDir 'ADDomainControllers.csv')
        } catch { Write-Warning "Get-ADDomainController failed: $_" }
    } else {
        Save-Text -Path (Join-Path $adDir 'README.txt') -Text "ActiveDirectory module not available; collected dcdiag/repadmin/netdom/nltest instead."
    }
}

# ---- DNS Server ----
if ($roles.IsDNS) {
    $dnsDir = Join-Path $roleDir 'DNSServer'
    $null = New-Item -ItemType Directory -Force -Path $dnsDir | Out-Null

    if (Test-ImportModule -Name 'DnsServer') {
        try { Get-DnsServer | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $dnsDir 'DnsServer.csv') } catch {}
        try { Get-DnsServerSetting -All | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $dnsDir 'DnsServerSetting.csv') } catch {}
        try { Get-DnsServerForwarder | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $dnsDir 'DnsForwarders.csv') } catch {}
        try { Get-DnsServerRootHint | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $dnsDir 'DnsRootHints.csv') } catch {}
        try { Get-DnsServerStatistics | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $dnsDir 'DnsStatistics.csv') } catch {}
        try {
            $zones = Get-DnsServerZone
            $zones | Select-Object ZoneName,ZoneType,IsDsIntegrated,IsReverseLookupZone,DynamicUpdate |
                Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $dnsDir 'DnsZones.csv')
        } catch { Write-Warning "Get-DnsServerZone failed: $_" }
    } else {
        if (Get-Command dnscmd.exe -ErrorAction SilentlyContinue) {
            Invoke-AndSave -Title 'DNSCMD /Info' -FilePath 'dnscmd.exe' -Arguments '/info' -OutFile (Join-Path $dnsDir 'dnscmd_info.txt')
            Invoke-AndSave -Title 'DNSCMD /EnumZones' -FilePath 'dnscmd.exe' -Arguments '/enumzones' -OutFile (Join-Path $dnsDir 'dnscmd_enumzones.txt')
        } else {
            Save-Text -Path (Join-Path $dnsDir 'README.txt') -Text "DnsServer module not available and dnscmd.exe not found. Only event logs (if any) will be collected."
        }
    }

    # Copy DNS debug log if enabled (best-effort)
    try {
        $dnsDbg = "$env:WINDIR\System32\dns\dns.log"
        if (Test-Path $dnsDbg) { Copy-Item $dnsDbg (Join-Path $dnsDir 'dns.log') -Force -ErrorAction SilentlyContinue }
    } catch {}
}

# ---- DHCP Server ----
if ($roles.IsDHCP) {
    $dhcpDir = Join-Path $roleDir 'DHCPServer'
    $null = New-Item -ItemType Directory -Force -Path $dhcpDir | Out-Null

    # Netsh dump is extremely useful for full config (read-only)
    Invoke-AndSave -Title 'NETSH DHCP dump' -FilePath 'netsh.exe' -Arguments 'dhcp server dump' -OutFile (Join-Path $dhcpDir 'dhcp_netsh_dump.txt')

    if (Test-ImportModule -Name 'DhcpServer') {
        try { Get-DhcpServerSetting | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $dhcpDir 'DhcpServerSetting.csv') } catch {}
        try { Get-DhcpServerv4Scope | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $dhcpDir 'DhcpV4Scopes.csv') } catch {}
        try { Get-DhcpServerv4OptionValue -All | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $dhcpDir 'DhcpV4Options_All.csv') } catch {}
        try { Get-DhcpServerDatabase | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $dhcpDir 'DhcpDatabase.csv') } catch {}
    } else {
        Save-Text -Path (Join-Path $dhcpDir 'README.txt') -Text "DhcpServer module not available; collected netsh dhcp server dump."
    }

    # Copy DHCP audit logs
    try {
        $dhcpLogDir = "$env:WINDIR\System32\dhcp"
        if (Test-Path $dhcpLogDir) {
            $dst = Join-Path $dhcpDir 'AuditLogs'
            $null = New-Item -ItemType Directory -Force -Path $dst | Out-Null
            Copy-Item (Join-Path $dhcpLogDir 'DhcpSrvLog-*.*') -Destination $dst -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

# ---- Certificate Authority (AD CS) ----
if ($roles.IsCA) {
    $caDir = Join-Path $roleDir 'CertificateAuthority'
    $null = New-Item -ItemType Directory -Force -Path $caDir | Out-Null

    Invoke-AndSave -Title 'CertUtil -ping' -FilePath 'certutil.exe' -Arguments '-ping' -OutFile (Join-Path $caDir 'certutil_ping.txt')
    Invoke-AndSave -Title 'CertUtil CA Registry (ca\*)' -FilePath 'certutil.exe' -Arguments '-getreg ca\*' -OutFile (Join-Path $caDir 'certutil_getreg_ca.txt')
    Invoke-AndSave -Title 'CertUtil Policy Registry (policy\*)' -FilePath 'certutil.exe' -Arguments '-getreg policy\*' -OutFile (Join-Path $caDir 'certutil_getreg_policy.txt')
    Invoke-AndSave -Title 'CertUtil CATemplates' -FilePath 'certutil.exe' -Arguments '-catemplates' -OutFile (Join-Path $caDir 'certutil_catemplates.txt')

    # Copy CA log files (not the locked edb)
    try {
        $certLogDir = "$env:WINDIR\System32\CertLog"
        if (Test-Path $certLogDir) {
            $dst = Join-Path $caDir 'CertLog'
            $null = New-Item -ItemType Directory -Force -Path $dst | Out-Null
            Copy-Item (Join-Path $certLogDir '*.log') -Destination $dst -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

# -------------------- Event Logs (existence-checked) --------------------
Write-Host "Exporting event logs ..."
$evDir = Join-Path $OutDir 'EventLogs'
$null = New-Item -ItemType Directory -Force -Path $evDir | Out-Null

# Base logs
$eventLogs = @(
    'System',
    'Application',
    'Setup',
    'Microsoft-Windows-WindowsUpdateClient/Operational',
    'Microsoft-Windows-Servicing/Operational'
)

# Role-aware additions
if ($roles -eq $null) { $roles = Get-RolePresence } # safety fallback

if ($roles.IsADDS) {
    $eventLogs += @(
        'Directory Service',
        'DFS Replication',
        'Microsoft-Windows-GroupPolicy/Operational',
        'Microsoft-Windows-Kerberos/Operational'
    )
}

if ($roles.IsDNS) {
    $eventLogs += @(
        'DNS Server',
        'Microsoft-Windows-DNS-Server/Operational'
    )
}

if ($roles.IsDHCP) {
    $eventLogs += @(
        'Microsoft-Windows-DHCP-Server/Operational'
    )
}

if ($roles.IsCA) {
    $eventLogs += @(
        'Microsoft-Windows-CertificationAuthority/Operational',
        'Microsoft-Windows-CAPI2/Operational'
    )
}

$eventLogs = $eventLogs | Select-Object -Unique

# Build an index of available channels once
$available = @{}
try {
    wevtutil el | ForEach-Object { $available[$_] = $true }
} catch {
    Write-Warning "Failed to enumerate event logs via 'wevtutil el': $_"
}

$exported = New-Object System.Collections.Generic.List[string]
$skipped  = New-Object System.Collections.Generic.List[string]

foreach ($logName in $eventLogs) {
    try {
        if (-not $available.ContainsKey($logName)) {
            Write-Warning "Skipping missing event channel: $logName"
            $skipped.Add($logName) | Out-Null
            continue
        }
        $safeName = ($logName -replace '[\\/]', '_')
        $evtxPath = Join-Path $evDir "$safeName.evtx"
        wevtutil epl "$logName" "$evtxPath"
        $exported.Add($logName) | Out-Null
    } catch {
        Write-Warning "Failed to export event log $logName : $_"
        $skipped.Add($logName) | Out-Null
    }
}

@"
Event Log Export Summary
========================
Exported:
$( ($exported | ForEach-Object { "  - $_" }) -join "`n" )

Skipped (missing/not accessible):
$( ($skipped | ForEach-Object { "  - $_" }) -join "`n" )
"@ | Out-File -FilePath (Join-Path $evDir 'FoundVsSkipped.txt') -Encoding UTF8

# -------------------- EVTX Auto-Conversion (TXT + XML + CSV) --------------------
Write-Host "Converting EVTX logs into Analytic-friendly formats (TXT, XML, CSV) ..."
$convDir = Join-Path $evDir 'Converted'
$null = New-Item -ItemType Directory -Force -Path $convDir | Out-Null

function Convert-EvtxForAnalytic {
    param([Parameter(Mandatory)][string]$EvtxPath)

    $baseName = [IO.Path]::GetFileNameWithoutExtension($EvtxPath)
    $txtPath  = Join-Path $convDir "$baseName.txt"
    $xmlPath  = Join-Path $convDir "$baseName.xml"
    $csvPath  = Join-Path $convDir "$baseName.csv"

    try { wevtutil qe /lf:"$EvtxPath" /f:Text /c:2000000 > $txtPath 2>$null } catch { Write-Warning "TXT conversion failed for $EvtxPath : $_" }
    try { wevtutil qe /lf:"$EvtxPath" /f:XML  /c:2000000 > $xmlPath 2>$null } catch { Write-Warning "XML conversion failed for $EvtxPath : $_" }

    try {
        Get-WinEvent -Path $EvtxPath -ErrorAction Stop |
            Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message |
            Export-Csv $csvPath -NoTypeInformation -Encoding UTF8
    } catch { Write-Warning "CSV conversion failed for $EvtxPath : $_" }
}

$evtxFiles = Get-ChildItem -Path $evDir -Filter *.evtx -ErrorAction SilentlyContinue
foreach ($f in $evtxFiles) {
    Write-Host "Converting $($f.Name)..."
    Convert-EvtxForAnalytic -EvtxPath $f.FullName
}

[GC]::Collect()
[GC]::WaitForPendingFinalizers()

foreach ($f in $evtxFiles) {
    if (-not (Wait-ForFileUnlock -Path $f.FullName -RetryCount 40 -DelayMs 250)) {
        Write-Warning "File still locked after retries: $($f.FullName). Zipping may fail."
    }
}
Write-Host "EVTX conversion complete. Files stored in: $convDir"

# -------------------- Performance Counters --------------------
Write-Host "Sampling performance counters ..."
$perfDir = Join-Path $OutDir 'Performance'
$null = New-Item -ItemType Directory -Force -Path $perfDir | Out-Null

$cpuCounters = @(
    '\Processor(_Total)\% Processor Time',
    '\System\Processor Queue Length',
    '\Processor Information(_Total)\% Privileged Time',
    '\Processor Information(_Total)\% User Time'
)

$memCounters = @(
    '\Memory\Available MBytes',
    '\Memory\Pages/sec',
    '\Memory\Page Faults/sec',
    '\Paging File(_Total)\% Usage',
    '\Memory\Cache Faults/sec',
    '\Memory\Committed Bytes'
)

$diskCounters = @(
    '\PhysicalDisk(_Total)\% Disk Time',
    '\PhysicalDisk(_Total)\Avg. Disk sec/Read',
    '\PhysicalDisk(_Total)\Avg. Disk sec/Write',
    '\PhysicalDisk(_Total)\Disk Reads/sec',
    '\PhysicalDisk(_Total)\Disk Writes/sec',
    '\PhysicalDisk(_Total)\Current Disk Queue Length',
    '\LogicalDisk(_Total)\% Free Space'
)

$netCounters = @(
    '\Network Interface(*)\Bytes Total/sec',
    '\Network Interface(*)\Output Queue Length',
    '\Network Interface(*)\Packets Received Errors',
    '\Network Interface(*)\Packets Outbound Errors',
    '\TCPv4\Connections Established',
    '\TCPv6\Connections Established'
)

$allCounters = $cpuCounters + $memCounters + $diskCounters + $netCounters

if ($ValidateCounters) {
    Write-Host "Validating counters (one-time quick probe) ..."
    $allCounters = Test-CounterPresent -Counters $allCounters
    if (-not $allCounters -or $allCounters.Count -eq 0) {
        Write-Warning "No performance counters validated; skipping perf collection."
    }
}

$maxSamples = [int][Math]::Ceiling(($DurationMinutes * 60) / [Math]::Max($SampleIntervalSeconds,1))
$blgPath  = Join-Path $perfDir 'PerfSamples.blg'
$csvPath  = Join-Path $perfDir 'PerfSamples.csv'
$metaPath = Join-Path $perfDir 'PerfMeta.txt'

@"
Sampling started: $(Get-Date -Format 's')
Duration (min):   $DurationMinutes
Interval (sec):   $SampleIntervalSeconds
Total samples:    $maxSamples
"@ | Out-File -FilePath $metaPath -Encoding UTF8

if ($allCounters -and $allCounters.Count -gt 0) {
    try {
        Get-Counter -Counter $allCounters -SampleInterval $SampleIntervalSeconds -MaxSamples $maxSamples |
            Export-Counter -Path $blgPath -FileFormat BLG
    } catch { Write-Warning "BLG export failed: $_" }

    try {
        Get-Counter -Counter $allCounters -SampleInterval $SampleIntervalSeconds -MaxSamples $maxSamples |
            Export-Counter -Path $csvPath -FileFormat CSV
    } catch { Write-Warning "CSV export failed: $_" }
} else {
    "No counters collected." | Out-File -FilePath (Join-Path $perfDir 'PerfCollectionSkipped.txt') -Encoding UTF8
}

try {
    $snap = Get-Counter '\Network Interface(*)\Bytes Total/sec'
    $perNic = $snap.CounterSamples | ForEach-Object {
        [PSCustomObject]@{
            Timestamp         = Get-Date
            InterfaceInstance = $_.InstanceName
            BytesTotalPerSec  = [int64]$_.CookedValue
            Mbps              = [math]::Round(($_.CookedValue * 8 / 1MB), 2)
        }
    }
    Save-ObjectCsv $perNic (Join-Path $perfDir 'Network_QuickThroughput.csv')
} catch { Write-Warning "Quick throughput snapshot failed: $_" }

# -------------------- Quick Bottleneck Snapshot --------------------
Write-Host "Computing quick snapshot ..."
try {
    $lastMem = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $memFreeMB  = if ($lastMem) { $lastMem.FreePhysicalMemory/1024 } else { $null }
    $memTotalMB = if ($lastMem) { $lastMem.TotalVisibleMemorySize/1024 } else { $null }
    $memCommit  = if ($lastMem) { [Math]::Round(($lastMem.TotalVirtualMemorySize - $lastMem.FreeVirtualMemory)/1MB,2) } else { $null }

    $cpuQueue = $null; $cpuPct = $null; $pfUsage = $null; $diskRead = $null; $diskWrite = $null; $diskQL = $null; $netBytes = $null; $tcpConn = $null

    try { $cpuQueue = (Get-Counter '\System\Processor Queue Length').CounterSamples.CookedValue } catch {}
    try { $cpuPct   = (Get-Counter '\Processor(_Total)\% Processor Time').CounterSamples.CookedValue } catch {}
    try { $pfUsage  = (Get-Counter '\Paging File(_Total)\% Usage').CounterSamples.CookedValue } catch {}
    try { $diskRead = (Get-Counter '\PhysicalDisk(_Total)\Avg. Disk sec/Read').CounterSamples.CookedValue } catch {}
    try { $diskWrite= (Get-Counter '\PhysicalDisk(_Total)\Avg. Disk sec/Write').CounterSamples.CookedValue } catch {}
    try { $diskQL   = (Get-Counter '\PhysicalDisk(_Total)\Current Disk Queue Length').CounterSamples.CookedValue } catch {}
    try { $netBytes = ((Get-Counter '\Network Interface(*)\Bytes Total/sec').CounterSamples | Measure-Object CookedValue -Sum).Sum } catch {}
    try { $tcpConn  = ((Get-Counter '\TCPv4\Connections Established').CounterSamples.CookedValue + (Get-Counter '\TCPv6\Connections Established').CounterSamples.CookedValue) } catch {}

    $q = [ordered]@{
        Timestamp               = (Get-Date)
        CPU_QueueLength         = $cpuQueue
        CPU_PercentTotal        = $cpuPct
        Mem_AvailableMB         = $memFreeMB
        Mem_TotalMB             = $memTotalMB
        PagingFile_UsagePct     = $pfUsage
        Disk_AvgReadSec         = $diskRead
        Disk_AvgWriteSec        = $diskWrite
        Disk_QueueLength        = $diskQL
        Net_TotalBytesPerSec    = $netBytes
        TCP_Connections         = $tcpConn
        CommitBytes             = $memCommit
    }
    [PSCustomObject]$q | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $perfDir 'QuickSnapshot.csv')
} catch { Write-Warning "Quick snapshot failed: $_" }

# -------------------- Analytic-Ready Pack --------------------
Write-Host "Assembling Analytic-Ready pack ..."
$crDir = Join-Path $OutDir 'Analytic-Ready'
$null = New-Item -ItemType Directory -Force -Path $crDir | Out-Null

$toCopy = @()
$toCopy += Join-Path $sysDir   'SystemSummary.csv'
$toCopy += Join-Path $perfDir  'PerfMeta.txt'
$toCopy += Join-Path $perfDir  'PerfSamples.csv'
$toCopy += Join-Path $perfDir  'QuickSnapshot.csv'
$toCopy += Join-Path $perfDir  'Network_QuickThroughput.csv'
$toCopy += Join-Path $sysDir   'TopProcessesByCPU.csv'
$toCopy += Join-Path $sysDir   'TopProcessesByMemory.csv'
$toCopy += Join-Path $sysDir   'NetInterfaceSummary.csv'
$toCopy += Join-Path $patchDir 'HotFixes.csv'
$toCopy += Join-Path $patchDir 'WindowsFeatures_Installed.csv'
$toCopy += Join-Path $healthDir 'DISM_CheckHealth.txt'
$toCopy += Join-Path $healthDir 'SFC_VerifyOnly.txt'
$toCopy += Join-Path $healthDir 'Logs\CBS_tail5000.log'
$toCopy += Join-Path $healthDir 'Logs\dism.log'

foreach ($p in $toCopy) {
    if (Test-Path $p) {
        try { Copy-Item $p -Destination $crDir -Force -ErrorAction Stop } catch { Write-Verbose "Skip copy: $p : $_" }
    }
}

# Include converted event logs
if (Test-Path $convDir) {
    $crEv = Join-Path $crDir 'EventLogs_Converted'
    $null = New-Item -ItemType Directory -Force -Path $crEv | Out-Null
    try { Copy-Item (Join-Path $convDir '*') -Destination $crEv -Force -ErrorAction Stop } catch { Write-Verbose "Skip copy of converted logs: $_" }
}

# Include role-specific collection
if (Test-Path $roleDir) {
    $crRole = Join-Path $crDir 'RoleSpecific'
    $null = New-Item -ItemType Directory -Force -Path $crRole | Out-Null
    try { Copy-Item (Join-Path $roleDir '*') -Destination $crRole -Recurse -Force -ErrorAction Stop } catch { Write-Verbose "Skip copy role-specific: $_" }
}

# Include Java metrics if present
$javaCsv = Join-Path $sysDir 'Java_ProcessMetrics.csv'
$javaTxt = Join-Path $sysDir 'Java_ProcessMetrics.txt'
if (Test-Path $javaCsv) { Copy-Item $javaCsv -Destination $crDir -Force | Out-Null }
if (Test-Path $javaTxt) { Copy-Item $javaTxt -Destination $crDir -Force | Out-Null }

"Analytic-Ready pack created at: $crDir" | Out-File -FilePath (Join-Path $crDir 'README_Analytic.txt') -Encoding UTF8

# -------------------- Finalize & Zip --------------------
Write-Host "Finalizing ..."

try {
    $allFiles = Get-ChildItem -Path $OutDir -File -Recurse -ErrorAction SilentlyContinue
    foreach ($af in $allFiles) {
        $null = Wait-ForFileUnlock -Path $af.FullName -RetryCount 40 -DelayMs 100
    }
} catch {
    Write-Verbose "Unlock sweep skipped: $_"
}

$readme = @"
Windows Server Health & Performance Collection (v5.4)
Computer: $computer
Timestamp: $timestamp

Folders:
- System: system summary, time sync, networking, storage, processes, services, optional java.exe metrics
- PatchAndRoles: installed hotfixes and Windows roles/features (ServerManager or DISM fallback)
- Health: DISM/SFC health results, CBS/DISM logs
- RoleSpecific: if roles exist, collects AD/CA/DNS/DHCP diagnostics and related artifacts
- EventLogs: .evtx exports of channels that exist; see FoundVsSkipped.txt
- EventLogs\Converted: EVTX converted to TXT, XML, and CSV (Analytic-friendly)
- Performance: perf counters (.blg + .csv), quick bottleneck snapshot, quick per-NIC throughput
- Analytic-Ready: single place to upload to Analytic (CSV/TXT/XML + role-specific data)

Notes:
- DISM CheckHealth is quick; -DeepHealth includes ScanHealth and SFC /verifyonly (longer, read-only).
- BLG can be opened in Performance Monitor; CSV can be analyzed in Excel/Power BI.
- Compatible with Windows Server 2016, 2019, 2022, and 2025 (Windows PowerShell 5.1).
"@
$readme | Out-File -FilePath (Join-Path $OutDir 'README.txt') -Encoding UTF8

if (-not $NoZip) {
    try {
        $zipPath = Join-Path $OutputRoot "$computer-$timestamp.zip"
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue }

        if ($ExcludeEvtxFromZip) {
            $tempStage = Join-Path $OutDir '_zipstage'
            Remove-Item $tempStage -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
            New-Item -ItemType Directory -Force -Path $tempStage | Out-Null

            $itemsToZip = Get-ChildItem -Path $OutDir -Recurse -File | Where-Object { $_.Extension -ne '.evtx' }
            foreach ($file in $itemsToZip) {
                $relPath = $file.FullName.Substring($OutDir.Length).TrimStart('\','/')
                $dest    = Join-Path $tempStage $relPath
                New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($dest)) | Out-Null
                Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
            }

            Compress-Archive -Path $tempStage -DestinationPath $zipPath -CompressionLevel Optimal
            Remove-Item $tempStage -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        } else {
            Compress-Archive -Path $OutDir -DestinationPath $zipPath -CompressionLevel Optimal
        }

        Write-Host "Done. Output folder: $OutDir"
        Write-Host "ZIP archive:       $zipPath"
        Write-Host "Analytic-Ready:     $crDir"
    } catch {
        Write-Warning "Failed to zip output: $_"
        Write-Host "Artifacts available at: $OutDir"
        Write-Host "Analytic-Ready:     $crDir"
    }
} else {
    Write-Host "ZIP creation skipped. Artifacts available at: $OutDir"
    Write-Host "Analytic-Ready:     $crDir"
}
