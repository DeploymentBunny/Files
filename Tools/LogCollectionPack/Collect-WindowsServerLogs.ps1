
<#
.SYNOPSIS
    Collect Windows Server health, logs, storage, clustering, Hyper-V, and network diagnostics into an analytic-ready package.

.DESCRIPTION
    Collect-WindowsServerLogs gathers OS health and servicing data, event logs, role and feature inventory,
    performance counters (BLG and CSV), optional Java process metrics, and role-specific diagnostics
    for AD DS, AD CS, DNS, DHCP, Hyper-V, Failover Clustering, Storage Spaces Direct (S2D), and classic SAN (MPIO/iSCSI/FC) when detected.
    Exported EVTX files are converted to TXT, XML, and CSV for easier analytics consumption.
    Java process metrics are collected automatically when java.exe processes are present.
    Use -Verbose for detailed progress and decision logging.

    The script is read-only from a system-configuration perspective and only writes collection artifacts.
    Run from an elevated Windows PowerShell 5.1 session for full collection.

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
.PARAMETER ExcludeEvtxFromZip
    Excludes native .evtx files from the ZIP. Converted TXT/XML/CSV outputs are still included.
.PARAMETER EvtxMaxEvents
    Maximum number of events to export during EVTX conversion to TXT/XML/CSV (to avoid huge files). Default: 250000.
.PARAMETER SelfTest
    Runs full static parse audit and exits (no elevation required, no collection).
.PARAMETER ValidateOnly
    Alias of -SelfTest.

.NOTES
    FileName:  Collect-WindowsServerLogs.ps1
    Version:   5.6.2
    Updated:   2026-05-19
    Author:    Mikael Nystrom
    Contact:   deploymentbunny@outlook.com
    Blog:      https://www.deploymentbunny.com
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
    [switch]$ExcludeEvtxFromZip,
    [int]$EvtxMaxEvents = 250000,

    [switch]$SelfTest,
    [Alias('ValidateOnly')]
    [switch]$StaticAuditOnly
)

# -------------------- SelfTest / Static Parse Audit (no elevation required) --------------------
function Invoke-ScriptSelfTest {
    [CmdletBinding()]
    param()

    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }

    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-Error "SelfTest: Cannot resolve script path. PSCommandPath/MyInvocation path not available."
        exit 2
    }

    Write-Host "=== SelfTest / Static Parse Audit ===" -ForegroundColor Cyan
    Write-Host "Script: $scriptPath"
    Write-Host "PowerShell: $($PSVersionTable.PSVersion)  Edition: $($PSVersionTable.PSEdition)"
    Write-Host ""

    $content = Get-Content -LiteralPath $scriptPath -Raw -ErrorAction Stop

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors)

    if ($errors -and $errors.Count -gt 0) {
        Write-Host "Parser errors found: $($errors.Count)" -ForegroundColor Red
        foreach ($e in $errors) {
            $line = $e.Extent.StartLineNumber
            $col  = $e.Extent.StartColumnNumber
            Write-Host ("  Line {0}, Col {1}: {2}" -f $line, $col, $e.Message) -ForegroundColor Red
            $lines = $content -split "`r?`n"
            if ($line -ge 1 -and $line -le $lines.Count) {
                Write-Host ("    > " + $lines[$line-1].TrimEnd()) -ForegroundColor DarkRed
            }
        }
        Write-Host ""
        Write-Host "SelfTest FAILED (syntax errors). Fix parser errors and rerun -SelfTest." -ForegroundColor Red
        exit 1
    }
    else {
        Write-Host "Parser: OK (no syntax errors)" -ForegroundColor Green
    }

    function Get-CharCount([string]$s, [char]$ch) {
        ($s.ToCharArray() | Where-Object { $_ -eq $ch }).Count
    }

    $openBrace  = Get-CharCount $content '{'
    $closeBrace = Get-CharCount $content '}'
    $openParen  = Get-CharCount $content '('
    $closeParen = Get-CharCount $content ')'
    $openBrkt   = Get-CharCount $content '['
    $closeBrkt  = Get-CharCount $content ']'

    $balanceIssues = @()
    if ($openBrace  -ne $closeBrace) { $balanceIssues += "Braces mismatch: {=$openBrace }=$closeBrace" }
    if ($openParen  -ne $closeParen) { $balanceIssues += "Parens mismatch: (=$openParen )=$closeParen" }
    if ($openBrkt   -ne $closeBrkt)  { $balanceIssues += "Brackets mismatch: [=$openBrkt ]=$closeBrkt" }

    if ($balanceIssues.Count -gt 0) {
        Write-Host "Delimiter balance warnings:" -ForegroundColor Yellow
        $balanceIssues | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    } else {
        Write-Host "Delimiter balance: OK" -ForegroundColor Green
    }

    # Catch accidental ':Max' / ':Round' etc (common copy/paste/rendering artifact)
    $colonCallMatches = [regex]::Matches($content, '(?m)(?<!\S):(?:Max|Min|Round|Ceiling|Floor|Abs|Sqrt|FromHours|FromMinutes|Collect|WaitForPendingFinalizers)\b')
    if ($colonCallMatches.Count -gt 0) {
        Write-Host ""
        Write-Host "Suspicious ':Xxx' tokens found (often indicates broken script text): $($colonCallMatches.Count)" -ForegroundColor Yellow
        $lines = $content -split "`r?`n"
        foreach ($m in ($colonCallMatches | Select-Object -First 50)) {
            $prefix = $content.Substring(0, $m.Index)
            $lineNo = ([regex]::Matches($prefix, "`r?`n").Count) + 1
            if ($lineNo -ge 1 -and $lineNo -le $lines.Count) {
                Write-Host ("  Line {0}: {1}" -f $lineNo, $lines[$lineNo-1].TrimEnd()) -ForegroundColor Yellow
            }
        }
        if ($colonCallMatches.Count -gt 50) { Write-Host "  (showing first 50 matches)" -ForegroundColor Yellow }
    } else {
        Write-Host "Text-lint: No suspicious ':Max/:Round/:Collect' tokens detected" -ForegroundColor Green
    }

    # AST lint: unqualified math/time/gc calls used as commands (Round(...), Max(...), Collect())
    $suspiciousCmds = @('Round','Max','Min','Ceiling','Floor','FromHours','FromMinutes','Collect','WaitForPendingFinalizers')
    $cmdAsts = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -and
        ($suspiciousCmds -contains $node.GetCommandName())
    }, $true)

    if ($cmdAsts.Count -gt 0) {
        Write-Host ""
        Write-Host "Potential missing qualification ([Math]:: / [TimeSpan]:: / [GC]::) for: $($cmdAsts.Count) occurrences" -ForegroundColor Yellow
        $lines = $content -split "`r?`n"
        foreach ($c in ($cmdAsts | Select-Object -First 50)) {
            $ln = $c.Extent.StartLineNumber
            if ($ln -ge 1 -and $ln -le $lines.Count) {
                Write-Host ("  Line {0}: {1}" -f $ln, $lines[$ln-1].TrimEnd()) -ForegroundColor Yellow
            }
        }
        if ($cmdAsts.Count -gt 50) { Write-Host "  (showing first 50 occurrences)" -ForegroundColor Yellow }
    } else {
        Write-Host "AST-lint: No unqualified math/time/gc function-style calls detected" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "SelfTest PASSED ✅ (static parse + lint checks complete)" -ForegroundColor Green
    exit 0
}

if ($SelfTest -or $StaticAuditOnly) {
    Invoke-ScriptSelfTest
    return
}

# -------------------- Safety & Helpers --------------------
$ErrorActionPreference = 'Continue'

function Write-Section {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ""
    Write-Host ("=== {0} ===" -f $Message) -ForegroundColor Cyan
    Write-Verbose ("[{0}] {1}" -f (Get-Date -Format 's'), $Message)
}

function Write-Detail {
    param([Parameter(Mandatory)][string]$Message)
    Write-Verbose ("  - {0}" -f $Message)
}

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

# Java metrics are auto-detected (collect only when java.exe is present)
$DoJavaMetrics = $true

$computer  = $env:COMPUTERNAME
$timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$OutDir    = Join-Path $OutputRoot "$computer-$timestamp"
$null = New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Write-Detail "Output directory: $OutDir"

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
            if ($stderr) { "`n---- STDERR ----`n$stderr" | Out-File -FilePath $OutFile -Encoding UTF8 -Append }
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
                    $features += [PSCustomObject]@{ Name=$matches[1]; State=$matches[2] }
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

function Wait-ForFileUnlock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$RetryCount = 20,
        [int]$DelayMs = 250
    )
    for ($i = 0; $i -lt $RetryCount; $i++) {
        try {
            if (-not (Test-Path -LiteralPath $Path)) { return $true }
            $fs = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
            $fs.Close()
            return $true
        } catch {
            Start-Sleep -Milliseconds $DelayMs
        }
    }
    return $false
}

function Test-ServiceExists {
    param([Parameter(Mandatory)][string]$Name)
    try {
        Get-Service -Name $Name -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Test-ImportModule {
    param([Parameter(Mandatory)][string]$Name)
    try { Import-Module $Name -ErrorAction Stop; return $true } catch { return $false }
}

function Save-Text {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Text)
    try { $Text | Out-File -FilePath $Path -Encoding UTF8 -Force } catch { Write-Warning "Failed to write $Path : $_" }
}

function Convert-WerReportToObject {
    param([Parameter(Mandatory)][string]$Path)

    try {
        $data = [ordered]@{ ReportFile = $Path }
        $section = 'General'

        foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction Stop)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            if ($line -match '^\[(.+)\]\s*$') {
                $section = $matches[1].Trim()
                continue
            }

            if ($line -match '^\s*([^=]+?)\s*=\s*(.*)$') {
                $rawKey = $matches[1].Trim()
                $value  = $matches[2].Trim()
                $key = ($rawKey -replace '[^A-Za-z0-9_]', '_')
                if ($section -ne 'General') {
                    $key = ("{0}_{1}" -f ($section -replace '[^A-Za-z0-9_]', '_'), $key)
                }

                $baseKey = $key
                $i = 2
                while ($data.Contains($key)) {
                    $key = "{0}_{1}" -f $baseKey, $i
                    $i++
                }

                $data[$key] = $value
            }
        }

        return [PSCustomObject]$data
    } catch {
        return $null
    }
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

function Get-ComputerDomainName {
    $d = $env:USERDNSDOMAIN
    if ([string]::IsNullOrWhiteSpace($d)) {
        try {
            $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
            if ($cs.Domain -and $cs.PartOfDomain) { return $cs.Domain }
        } catch {}
    }
    return $d
}

function Test-S2DPresent {
    try {
        $subs = Get-StorageSubSystem -ErrorAction Stop
        foreach ($s in $subs) {
            if ($s.FriendlyName -like 'Clustered Storage Spaces*' -or
                $s.FriendlyName -like '*Storage Spaces Direct*' -or
                $s.FriendlyName -like '*S2D*') { return $true }
        }
    } catch {}
    return $false
}

function Get-RolePresence {
    $isCluster = (Test-ServiceExists -Name 'ClusSvc')
    return [PSCustomObject]@{
        IsADDS    = (Test-ServiceExists -Name 'NTDS')
        IsDNS     = (Test-ServiceExists -Name 'DNS')
        IsDHCP    = (Test-ServiceExists -Name 'DHCPServer')
        IsCA      = (Test-ServiceExists -Name 'CertSvc')
        IsHyperV  = (Test-ServiceExists -Name 'vmms')
        IsCluster = $isCluster
        IsS2D     = if ($isCluster) { Test-S2DPresent } else { $false }
    }
}

# -------------------- System Summary --------------------
Write-Section "Collecting system summary"
$sysDir = Join-Path $OutDir 'System'
$null = New-Item -ItemType Directory -Force -Path $sysDir | Out-Null

$os   = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$cs   = Get-CimInstance Win32_ComputerSystem   -ErrorAction SilentlyContinue
$bios = Get-CimInstance Win32_BIOS             -ErrorAction SilentlyContinue
$proc = Get-CimInstance Win32_Processor        -ErrorAction SilentlyContinue

$installDate = $null
$lastBoot    = $null
if ($os) {
    $installDate = Convert-DmtfSafe $os.InstallDate
    $lastBoot    = Convert-DmtfSafe $os.LastBootUpTime
}

if (-not $lastBoot) {
    try {
        $uptimeSec = (Get-Counter '\System\System Up Time' -ErrorAction Stop).CounterSamples.CookedValue
        $lastBoot  = (Get-Date).AddSeconds(-$uptimeSec)
    } catch { $lastBoot = $null }
}

if (-not $installDate) {
    try {
        $regInst = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        if ($regInst.InstallDate) { $installDate = (Get-Date '1970-01-01').AddSeconds([int64]$regInst.InstallDate) }
    } catch {}
}

$uptimeDays = $null
if ($lastBoot) { $uptimeDays = ((Get-Date) - $lastBoot).TotalDays }

$buildInfo = Get-ServerVersionInfo

$summary = [PSCustomObject]@{
    ComputerName = $env:COMPUTERNAME
    OSCaption    = $os.Caption
    OSVersion    = $os.Version
    Build        = $buildInfo.VersionString
    InstallDate  = $installDate
    LastBoot     = $lastBoot
    UptimeDays   = if ($null -ne $uptimeDays) { [int]$uptimeDays } else { $null }
    Manufacturer = $cs.Manufacturer
    Model        = $cs.Model
    BIOSVersion  = $bios.SMBIOSBIOSVersion -join ' '
    CPU          = $proc.Name -join ' | '
    LogicalCPUs  = ($proc.NumberOfLogicalProcessors | Measure-Object -Sum).Sum
    TotalRAMGB   = if ($cs.TotalPhysicalMemory) { [Math]::Round($cs.TotalPhysicalMemory/1GB,2) } else { $null }
}
Save-ObjectCsv $summary (Join-Path $sysDir 'SystemSummary.csv')

Invoke-CMD -FilePath 'w32tm.exe' -Arguments '/query /status' -OutFile (Join-Path $sysDir 'TimeSync.txt') | Out-Null

# NIC inventory + IP snapshot (fixes InterfaceIndex churn errors)
try {
    $adapters = Get-NetAdapter -ErrorAction Stop | Sort-Object Name
    Save-ObjectCsv $adapters (Join-Path $sysDir 'NetAdapter.csv')

    $ipcfgAll = $null
    try { $ipcfgAll = Get-NetIPConfiguration -ErrorAction Stop } catch { Write-Verbose "Get-NetIPConfiguration snapshot failed: $_" }

    if ($ipcfgAll) { Save-ObjectCsv $ipcfgAll (Join-Path $sysDir 'NetIPConfiguration.csv') }

    $ipByIfIndex = @{}
    if ($ipcfgAll) {
        foreach ($ip in $ipcfgAll) {
            if ($null -ne $ip.InterfaceIndex) { $ipByIfIndex[[int]$ip.InterfaceIndex] = $ip }
        }
    }

    $nicSummary = foreach ($nic in $adapters) {
        $ip = $null
        if ($ipByIfIndex.ContainsKey([int]$nic.ifIndex)) { $ip = $ipByIfIndex[[int]$nic.ifIndex] }

        [PSCustomObject]@{
            Name           = $nic.Name
            Status         = $nic.Status
            LinkSpeed      = $nic.LinkSpeed
            MAC            = $nic.MacAddress
            InterfaceIndex = $nic.ifIndex
            IPv4           = if ($ip) { ($ip.IPv4Address.IPAddress -join ';') } else { $null }
            IPv6           = if ($ip) { ($ip.IPv6Address.IPAddress -join ';') } else { $null }
            DNSServers     = if ($ip) { ($ip.DnsServer.ServerAddresses -join ';') } else { $null }
        }
    }
    if ($nicSummary) { Save-ObjectCsv $nicSummary (Join-Path $sysDir 'NetInterfaceSummary.csv') }
} catch { Write-Warning "NIC inventory failed: $_" }

Write-Detail "System summary collection completed"

# Disk topology
try { Save-ObjectCsv (Get-PhysicalDisk) (Join-Path $sysDir 'PhysicalDisk.csv') } catch {}
try { Save-ObjectCsv (Get-Disk)         (Join-Path $sysDir 'Disk.csv') } catch {}
try { Save-ObjectCsv (Get-Partition)    (Join-Path $sysDir 'Partition.csv') } catch {}
try { Save-ObjectCsv (Get-Volume)       (Join-Path $sysDir 'Volume.csv') } catch {}

# Processes & Services snapshot
try { Get-Process | Sort-Object CPU -Descending | Select-Object -First 50 | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $sysDir 'TopProcessesByCPU.csv') } catch {}
try { Get-Process | Sort-Object WS  -Descending | Select-Object -First 50 | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $sysDir 'TopProcessesByMemory.csv') } catch {}
try { Get-Service | Where-Object { $_.Status -ne 'Running' -and $_.StartType -eq 'Automatic' } | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $sysDir 'AutoServicesNotRunning.csv') } catch {}

# Optional Java process metrics
if ($DoJavaMetrics) {
    try {
        $javaProcs = Get-Process -Name java -ErrorAction SilentlyContinue
        if ($javaProcs) {
            $javaOut = $javaProcs | Select-Object `
                Id, ProcessName,
                @{n='StartTime';e={ try { $_.StartTime } catch { $null } }},
                CPU,
                @{n='WorkingSetMB';e={ [Math]::Round($_.WorkingSet64/1MB,2) }},
                @{n='PrivateBytesMB';e={ [Math]::Round($_.PrivateMemorySize64/1MB,2) }},
                Handles, Threads
            Save-ObjectCsv $javaOut (Join-Path $sysDir 'Java_ProcessMetrics.csv')
        } else {
            "No java.exe processes found at collection time." | Out-File -FilePath (Join-Path $sysDir 'Java_ProcessMetrics.txt') -Encoding UTF8
        }
    } catch { Write-Warning "Java metrics collection failed: $_" }
}

# -------------------- Patch Level & Roles --------------------
Write-Section "Collecting patch level and roles/features"
$patchDir = Join-Path $OutDir 'PatchAndRoles'
$null = New-Item -ItemType Directory -Force -Path $patchDir | Out-Null
try { Get-HotFix | Sort-Object InstalledOn | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $patchDir 'HotFixes.csv') } catch {}
try { Export-RolesAndFeatures -Folder $patchDir } catch {}

# -------------------- Health Checks (DISM/SFC) --------------------
Write-Section "Running health checks (DISM/SFC)"
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
$logsDir = Join-Path $healthDir 'Logs'
$null = New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
try {
    $cbsFolder  = "$env:WINDIR\Logs\CBS"
    $dismFolder = "$env:WINDIR\Logs\DISM"

    if (Test-Path "$cbsFolder\CBS.log") {
        if ($IncludeFullCBS) { Copy-Item "$cbsFolder\CBS.log" (Join-Path $logsDir 'CBS.log') -ErrorAction SilentlyContinue }
        else { Get-Content "$cbsFolder\CBS.log" -Tail 5000 | Out-File -FilePath (Join-Path $logsDir 'CBS_tail5000.log') -Encoding UTF8 }
    }
    if (Test-Path "$cbsFolder\CBS.persist.log") { Copy-Item "$cbsFolder\CBS.persist.log" (Join-Path $logsDir 'CBS.persist.log') -ErrorAction SilentlyContinue }
    if (Test-Path "$dismFolder\dism.log")       { Copy-Item "$dismFolder\dism.log"       (Join-Path $logsDir 'dism.log') -ErrorAction SilentlyContinue }
} catch { Write-Warning "Failed to copy CBS/DISM logs: $_" }

# Collect crash dump files when present (can be large)
$dumpDir = Join-Path $healthDir 'CrashDumps'
$null = New-Item -ItemType Directory -Force -Path $dumpDir | Out-Null
try {
    $dumpCandidates = @(
        "$env:WINDIR\MEMORY.DMP",
        "$env:WINDIR\ActiveMemory.dmp"
    )

    foreach ($dumpFile in $dumpCandidates) {
        if (Test-Path -LiteralPath $dumpFile) {
            Copy-Item -LiteralPath $dumpFile -Destination (Join-Path $dumpDir ([IO.Path]::GetFileName($dumpFile))) -Force -ErrorAction SilentlyContinue
        }
    }

    $miniDumpDir = "$env:WINDIR\Minidump"
    if (Test-Path -LiteralPath $miniDumpDir) {
        Copy-Item -Path (Join-Path $miniDumpDir '*.dmp') -Destination $dumpDir -Force -ErrorAction SilentlyContinue
    }
} catch { Write-Warning "Failed to collect crash dump files: $_" }

try {
    $dumpFiles = Get-ChildItem -Path $dumpDir -File -ErrorAction SilentlyContinue
    if ($dumpFiles) {
        $dumpInventory = $dumpFiles | Select-Object Name, FullName, Extension, Length, CreationTime, LastWriteTime,
            @{n='SizeMB';e={ [Math]::Round($_.Length / 1MB, 2) }}
        Save-ObjectCsv $dumpInventory (Join-Path $dumpDir 'CrashDump_Inventory.csv')
    }

    $dumpArtifacts = @($dumpFiles | Where-Object { $_.Extension -match '^\.(dmp|mdmp|hdmp)$' })
    $presencePath = Join-Path $dumpDir 'CrashDump_Presence.txt'
    if ($dumpArtifacts.Count -gt 0) {
        @(
            'DMP_Files_Present=YES'
            ("DMP_File_Count={0}" -f $dumpArtifacts.Count)
        ) | Out-File -FilePath $presencePath -Encoding UTF8 -Force
        Write-Detail ("Crash dumps detected: {0}" -f $dumpArtifacts.Count)
    } else {
        @(
            'DMP_Files_Present=NO'
            'DMP_File_Count=0'
        ) | Out-File -FilePath $presencePath -Encoding UTF8 -Force
        Write-Detail "Crash dumps detected: 0"
    }
} catch {}

# Collect Windows Error Reporting (WER) artifacts
$werDir = Join-Path $healthDir 'WER'
$null = New-Item -ItemType Directory -Force -Path $werDir | Out-Null
try {
    $werRoot = "$env:ProgramData\Microsoft\Windows\WER"
    $werFolders = @('ReportArchive','ReportQueue','Temp')

    foreach ($folder in $werFolders) {
        $src = Join-Path $werRoot $folder
        if (Test-Path -LiteralPath $src) {
            $dst = Join-Path $werDir $folder
            $null = New-Item -ItemType Directory -Force -Path $dst | Out-Null
            Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    try { Get-Service -Name WerSvc -ErrorAction SilentlyContinue | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $werDir 'WER_Service.csv') } catch {}

    try { Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' -ErrorAction Stop |
            Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $werDir 'WER_Config_HKLM.csv') } catch {}
    try { Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps' -ErrorAction Stop |
            Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $werDir 'WER_LocalDumps_HKLM.csv') } catch {}
    try { Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' -ErrorAction Stop |
            Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $werDir 'WER_Policy_HKLM.csv') } catch {}

    try {
        $werFiles = Get-ChildItem -Path $werDir -File -Recurse -ErrorAction SilentlyContinue
        if ($werFiles) {
            $werInventory = $werFiles | Select-Object Name, FullName, Extension, Length, CreationTime, LastWriteTime,
                @{n='SizeMB';e={ [Math]::Round($_.Length / 1MB, 2) }}
            Save-ObjectCsv $werInventory (Join-Path $werDir 'WER_Files_Inventory.csv')

            $werBinary = $werFiles | Where-Object { $_.Extension -match '^\.(hdmp|mdmp|dmp)$' }
            if ($werBinary) {
                $werBinary | Select-Object Name, FullName, Extension, Length, CreationTime, LastWriteTime,
                    @{n='SizeMB';e={ [Math]::Round($_.Length / 1MB, 2) }} |
                    Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $werDir 'WER_BinaryArtifacts.csv')
            }

            $werReports = $werFiles | Where-Object { $_.Extension -ieq '.wer' }
            if ($werReports) {
                $parsedWer = foreach ($wr in $werReports) {
                    Convert-WerReportToObject -Path $wr.FullName
                }
                $parsedWer = $parsedWer | Where-Object { $_ -ne $null }
                if ($parsedWer) {
                    Save-ObjectCsv $parsedWer (Join-Path $werDir 'WER_Reports_Parsed.csv')
                }
            }
        }
    } catch {}
} catch { Write-Warning "Failed to collect WER artifacts: $_" }
Write-Detail "Health collection completed"

# -------------------- Role-Specific Collection --------------------
Write-Section "Collecting role-specific diagnostics"
$roleDir = Join-Path $OutDir 'RoleSpecific'
$null = New-Item -ItemType Directory -Force -Path $roleDir | Out-Null

$roles = Get-RolePresence
Save-ObjectCsv $roles (Join-Path $roleDir 'RolePresence.csv')

# ---- Active Directory (Domain Controller) ----
if ($roles.IsADDS) {
    $adDir = Join-Path $roleDir 'ActiveDirectory'
    $null = New-Item -ItemType Directory -Force -Path $adDir | Out-Null

    $domainName = Get-ComputerDomainName

    Invoke-AndSave -Title 'DCDiag (verbose)'        -FilePath 'dcdiag.exe'   -Arguments '/v /c /e'         -OutFile (Join-Path $adDir 'dcdiag.txt')
    Invoke-AndSave -Title 'Repadmin ReplSummary'    -FilePath 'repadmin.exe' -Arguments '/replsummary'     -OutFile (Join-Path $adDir 'repadmin_replsummary.txt')
    Invoke-AndSave -Title 'Repadmin ShowRepl (CSV)' -FilePath 'repadmin.exe' -Arguments '/showrepl * /csv' -OutFile (Join-Path $adDir 'repadmin_showrepl.csv.txt')
    Invoke-AndSave -Title 'FSMO Roles'              -FilePath 'netdom.exe'   -Arguments 'query fsmo'       -OutFile (Join-Path $adDir 'fsmo_roles.txt')

    if (-not [string]::IsNullOrWhiteSpace($domainName)) {
        Invoke-AndSave -Title 'NLTEST DCLIST (domain)'  -FilePath 'nltest.exe' -Arguments "/dclist:$domainName" -OutFile (Join-Path $adDir 'nltest_dclist.txt')
        Invoke-AndSave -Title 'NLTEST DSGETDC (domain)' -FilePath 'nltest.exe' -Arguments "/dsgetdc:$domainName" -OutFile (Join-Path $adDir 'nltest_dsgetdc.txt')
    } else {
        Save-Text -Path (Join-Path $adDir 'nltest_note.txt') -Text "Domain name could not be determined. Skipping nltest domain-targeted commands."
    }

    if (Get-Command dfsrdiag.exe -ErrorAction SilentlyContinue) {
        Invoke-AndSave -Title 'DFSRDIAG ReplicationState' -FilePath 'dfsrdiag.exe' -Arguments 'ReplicationState' -OutFile (Join-Path $adDir 'dfsrdiag_replicationstate.txt')
        Invoke-AndSave -Title 'DFSRDIAG PollAD'           -FilePath 'dfsrdiag.exe' -Arguments 'PollAD'          -OutFile (Join-Path $adDir 'dfsrdiag_pollad.txt')
    }

    if (Test-ImportModule -Name 'ActiveDirectory') {
        try { Get-ADDomain  | Select-Object * | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $adDir 'ADDomain.csv') } catch {}
        try { Get-ADForest  | Select-Object * | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $adDir 'ADForest.csv') } catch {}
        try { Get-ADDomainController -Filter * | Select-Object HostName,Site,IPv4Address,OperatingSystem,IsGlobalCatalog |
                Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $adDir 'ADDomainControllers.csv') } catch {}
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
        try { Get-DnsServerZone | Select-Object ZoneName,ZoneType,IsDsIntegrated,IsReverseLookupZone,DynamicUpdate |
                Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $dnsDir 'DnsZones.csv') } catch {}
    } else {
        if (Get-Command dnscmd.exe -ErrorAction SilentlyContinue) {
            Invoke-AndSave -Title 'DNSCMD /Info'      -FilePath 'dnscmd.exe' -Arguments '/info'      -OutFile (Join-Path $dnsDir 'dnscmd_info.txt')
            Invoke-AndSave -Title 'DNSCMD /EnumZones' -FilePath 'dnscmd.exe' -Arguments '/enumzones' -OutFile (Join-Path $dnsDir 'dnscmd_enumzones.txt')
        } else {
            Save-Text -Path (Join-Path $dnsDir 'README.txt') -Text "DnsServer module not available and dnscmd.exe not found."
        }
    }

    try {
        $dnsDbg = "$env:WINDIR\System32\dns\dns.log"
        if (Test-Path $dnsDbg) { Copy-Item $dnsDbg (Join-Path $dnsDir 'dns.log') -Force -ErrorAction SilentlyContinue }
    } catch {}
}

# ---- DHCP Server ----
if ($roles.IsDHCP) {
    $dhcpDir = Join-Path $roleDir 'DHCPServer'
    $null = New-Item -ItemType Directory -Force -Path $dhcpDir | Out-Null

    Invoke-AndSave -Title 'NETSH DHCP dump' -FilePath 'netsh.exe' -Arguments 'dhcp server dump' -OutFile (Join-Path $dhcpDir 'dhcp_netsh_dump.txt')

    if (Test-ImportModule -Name 'DhcpServer') {
        try { Get-DhcpServerSetting | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $dhcpDir 'DhcpServerSetting.csv') } catch {}
        try { Get-DhcpServerv4Scope | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $dhcpDir 'DhcpV4Scopes.csv') } catch {}
        try { Get-DhcpServerv4OptionValue -All | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $dhcpDir 'DhcpV4Options_All.csv') } catch {}
        try { Get-DhcpServerDatabase | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $dhcpDir 'DhcpDatabase.csv') } catch {}
    } else {
        Save-Text -Path (Join-Path $dhcpDir 'README.txt') -Text "DhcpServer module not available; collected netsh dhcp server dump."
    }

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

    Invoke-AndSave -Title 'CertUtil -ping'           -FilePath 'certutil.exe' -Arguments '-ping'            -OutFile (Join-Path $caDir 'certutil_ping.txt')
    Invoke-AndSave -Title 'CertUtil CA Registry'     -FilePath 'certutil.exe' -Arguments '-getreg ca\*'     -OutFile (Join-Path $caDir 'certutil_getreg_ca.txt')
    Invoke-AndSave -Title 'CertUtil Policy Registry' -FilePath 'certutil.exe' -Arguments '-getreg policy\*' -OutFile (Join-Path $caDir 'certutil_getreg_policy.txt')
    Invoke-AndSave -Title 'CertUtil CATemplates'     -FilePath 'certutil.exe' -Arguments '-catemplates'     -OutFile (Join-Path $caDir 'certutil_catemplates.txt')

    try {
        $certLogDir = "$env:WINDIR\System32\CertLog"
        if (Test-Path $certLogDir) {
            $dst = Join-Path $caDir 'CertLog'
            $null = New-Item -ItemType Directory -Force -Path $dst | Out-Null
            Copy-Item (Join-Path $certLogDir '*.log') -Destination $dst -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

# ---- Hyper-V ----
if ($roles.IsHyperV) {
    $hvDir = Join-Path $roleDir 'HyperV'
    $null = New-Item -ItemType Directory -Force -Path $hvDir | Out-Null

    if (Test-ImportModule -Name 'Hyper-V') {
        try { Get-VMHost | Select-Object * | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $hvDir 'VMHost.csv') } catch {}
        try { Get-VM | Select-Object Name, State, Status, CPUUsage, MemoryAssigned, Uptime, Version, Generation |
                Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $hvDir 'VMs.csv') } catch {}
        try { Get-VMSwitch | Select-Object * | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $hvDir 'VMSwitches.csv') } catch {}
        try { Get-VMNetworkAdapter -ManagementOS | Select-Object * |
                Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $hvDir 'MgmtOS_VMNetworkAdapters.csv') } catch {}
        try { Get-VMNetworkAdapter -All | Select-Object VMName, Name, SwitchName, Status, MacAddress, IPAddresses |
                Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $hvDir 'All_VMNetworkAdapters.csv') } catch {}
        try { Get-VMHardDiskDrive -VMName * | Select-Object VMName, Path, ControllerType, ControllerNumber, ControllerLocation |
                Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $hvDir 'VM_Disks.csv') } catch {}
    } else {
        Save-Text -Path (Join-Path $hvDir 'README.txt') -Text "Hyper-V module not available; relying on event logs and service state."
    }

    try { Get-Service vmms, vmcompute -ErrorAction SilentlyContinue | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $hvDir 'HyperV_Services.csv') } catch {}
}

# ---- Failover Clustering (WSFC) ----
if ($roles.IsCluster) {
    $clDir = Join-Path $roleDir 'FailoverCluster'
    $null = New-Item -ItemType Directory -Force -Path $clDir | Out-Null

    if (Test-ImportModule -Name 'FailoverClusters') {
        try { Get-Cluster | Select-Object * | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $clDir 'Cluster.csv') } catch {}
        try { Get-ClusterNode | Select-Object * | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $clDir 'ClusterNodes.csv') } catch {}
        try { Get-ClusterGroup | Select-Object * | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $clDir 'ClusterGroups.csv') } catch {}
        try { Get-ClusterResource | Select-Object * | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $clDir 'ClusterResources.csv') } catch {}
        try { Get-ClusterNetwork | Select-Object * | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $clDir 'ClusterNetworks.csv') } catch {}
        try { Get-ClusterSharedVolume | Select-Object * | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $clDir 'ClusterSharedVolumes.csv') } catch {}
        try { Get-ClusterQuorum | Select-Object * | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $clDir 'ClusterQuorum.csv') } catch {}
        try { (Get-Cluster).EnabledEventLogs | Out-File -FilePath (Join-Path $clDir 'Cluster_EnabledEventLogs.txt') -Encoding UTF8 } catch {}

        try {
            Get-ClusterLog -UseLocalTime -Destination $clDir | Out-Null
            "Cluster log generated into: $clDir (full available history)." | Out-File (Join-Path $clDir 'ClusterLog_Readme.txt') -Encoding UTF8
        } catch { Write-Warning "Get-ClusterLog failed: $_" }
    } else {
        if (Get-Command cluster.exe -ErrorAction SilentlyContinue) {
            Invoke-AndSave -Title 'Cluster.exe /status' -FilePath 'cluster.exe' -Arguments '/status' -OutFile (Join-Path $clDir 'cluster_status.txt')
            Invoke-AndSave -Title 'Cluster.exe /quorum' -FilePath 'cluster.exe' -Arguments '/quorum' -OutFile (Join-Path $clDir 'cluster_quorum.txt')
        }
        Save-Text -Path (Join-Path $clDir 'README.txt') -Text "FailoverClusters module not available; used cluster.exe fallbacks."
    }
}

# ---- Storage Spaces Direct (S2D) ----
if ($roles.IsS2D) {
    $s2dDir = Join-Path $roleDir 'Storage_S2D'
    $null = New-Item -ItemType Directory -Force -Path $s2dDir | Out-Null

    if (Test-ImportModule -Name 'Storage') {
        try { Get-StorageSubSystem | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $s2dDir 'StorageSubSystems.csv') } catch {}
        try { Get-StoragePool -IsPrimordial $false | Select-Object * | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $s2dDir 'StoragePools.csv') } catch {}
        try { Get-PhysicalDisk | Select-Object * | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $s2dDir 'PhysicalDisks.csv') } catch {}
        try { Get-VirtualDisk  | Select-Object * | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $s2dDir 'VirtualDisks.csv') } catch {}
        try { Get-Volume       | Select-Object * | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $s2dDir 'Volumes.csv') } catch {}
        try { Get-StorageJob   | Select-Object * | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $s2dDir 'StorageJobs.csv') } catch {}
        try { Get-StorageTier  | Select-Object * | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $s2dDir 'StorageTiers.csv') } catch {}
        try { Get-StorageFaultDomain | Select-Object * | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $s2dDir 'FaultDomains.csv') } catch {}

        # Faults (returns nothing if healthy)
        try {
            $faultsOut = Join-Path $s2dDir 'HealthService_Faults.txt'
            $faults = @()
            $subs = Get-StorageSubSystem | Where-Object {
                $_.FriendlyName -like 'Clustered Storage Spaces*' -or $_.FriendlyName -like '*Storage Spaces Direct*' -or $_.FriendlyName -like '*S2D*'
            }
            foreach ($ss in $subs) {
                try { $faults += (Debug-StorageSubSystem -InputObject $ss -ErrorAction Stop) } catch {}
            }
            if ($faults -and $faults.Count -gt 0) { $faults | Out-File -FilePath $faultsOut -Encoding UTF8 }
            else { "No faults returned by Debug-StorageSubSystem at collection time." | Out-File -FilePath $faultsOut -Encoding UTF8 }
        } catch {}
    } else {
        Save-Text -Path (Join-Path $s2dDir 'README.txt') -Text "Storage module not available; S2D inventory limited."
    }
}

# ---- SAN Diagnostics (iSCSI / MPIO / FC) ----
$sanDir = Join-Path $roleDir 'Storage_SAN'
$null = New-Item -ItemType Directory -Force -Path $sanDir | Out-Null

# ---- iSCSI ----
if (Test-ServiceExists -Name 'MSiSCSI') {
    $iscsiSvc = Get-Service -Name 'MSiSCSI' -ErrorAction SilentlyContinue
    if ($iscsiSvc -and $iscsiSvc.Status -eq 'Running') {
        if (Test-ImportModule -Name 'iSCSI') {
            try { Get-IscsiInitiatorPort | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $sanDir 'iSCSI_InitiatorPorts.csv') } catch {}
            try { Get-IscsiTarget        | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $sanDir 'iSCSI_Targets.csv') } catch {}
            try { Get-IscsiSession       | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $sanDir 'iSCSI_Sessions.csv') } catch {}
            try { Get-IscsiConnection    | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $sanDir 'iSCSI_Connections.csv') } catch {}
            try { Get-IscsiTargetPortal  | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $sanDir 'iSCSI_TargetPortals.csv') } catch {}
        } elseif (Get-Command iscsicli.exe -ErrorAction SilentlyContinue) {
            Invoke-AndSave -Title 'iscsicli SessionList' -FilePath 'iscsicli.exe' -Arguments 'SessionList' -OutFile (Join-Path $sanDir 'iscsicli_sessionlist.txt')
            Invoke-AndSave -Title 'iscsicli ReportTargetMappings' -FilePath 'iscsicli.exe' -Arguments 'ReportTargetMappings' -OutFile (Join-Path $sanDir 'iscsicli_targetmappings.txt')
        }
    } else {
        Save-Text -Path (Join-Path $sanDir 'iSCSI_Skipped.txt') -Text 'MSiSCSI service is not running; skipping iSCSI collection.'
    }
}

# ---- MPIO ----
if (Test-ServiceExists -Name 'mpio') {
    if (Test-ImportModule -Name 'MPIO') {
        try { Get-MPIOSetting | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $sanDir 'MPIO_Settings.csv') } catch {}
        try { Get-MSDSMSupportedHW | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $sanDir 'MPIO_SupportedHW.csv') } catch {}
        try { Get-MSDSMAutomaticClaimSettings | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $sanDir 'MPIO_AutoClaimSettings.csv') } catch {}
    }
    if (Get-Command mpclaim.exe -ErrorAction SilentlyContinue) {
        Invoke-AndSave -Title 'mpclaim -s -d' -FilePath 'mpclaim.exe' -Arguments '-s -d' -OutFile (Join-Path $sanDir 'mpclaim_status.txt')
    }
}

# ---- Fibre Channel HBA (WMI best-effort) ----
try {
    $fc = Get-CimInstance -Namespace root\wmi -ClassName MSFC_FCAdapterHBAAttributes -ErrorAction SilentlyContinue
    if ($fc) { $fc | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $sanDir 'FC_HBAAttributes.csv') }
} catch {}

# ---- RDMA / SMB Direct / NIC & DCB/QoS ----
$rdmaDir = Join-Path $roleDir 'RDMA_Network'
$null = New-Item -ItemType Directory -Force -Path $rdmaDir | Out-Null

try { Get-NetAdapter | Select-Object Name, Status, LinkSpeed, DriverFileName, DriverVersion, InterfaceDescription |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $rdmaDir 'NetAdapter_Basics.csv') } catch {}
try { Get-NetAdapterAdvancedProperty -ErrorAction SilentlyContinue |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $rdmaDir 'NetAdapter_AdvancedProperties.csv') } catch {}
try { Get-NetAdapterRdma -ErrorAction SilentlyContinue |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $rdmaDir 'NetAdapter_RDMA.csv') } catch {}

try { Get-SmbClientNetworkInterface -ErrorAction SilentlyContinue |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $rdmaDir 'SMBClient_NetworkInterfaces.csv') } catch {}
try { Get-SmbServerNetworkInterface -ErrorAction SilentlyContinue |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $rdmaDir 'SMBServer_NetworkInterfaces.csv') } catch {}
try { Get-SmbMultichannelConnection -ErrorAction SilentlyContinue |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $rdmaDir 'SMB_MultichannelConnections.csv') } catch {}

try { Get-NetQosPolicy -ErrorAction SilentlyContinue |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $rdmaDir 'NetQos_Policies.csv') } catch {}
try { Get-NetQosTrafficClass -ErrorAction SilentlyContinue |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $rdmaDir 'NetQos_TrafficClasses.csv') } catch {}
try { Get-NetQosFlowControl -ErrorAction SilentlyContinue |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $rdmaDir 'NetQos_FlowControl.csv') } catch {}
try { Get-NetQosDcbxSetting -ErrorAction SilentlyContinue |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $rdmaDir 'NetQos_DcbxSetting.csv') } catch {}

# -------------------- Event Logs (Existence-Checked) --------------------
Write-Section "Exporting event logs"
$evDir = Join-Path $OutDir 'EventLogs'
$null = New-Item -ItemType Directory -Force -Path $evDir | Out-Null

$eventLogs = @(
    'System','Application','Setup',
    'Microsoft-Windows-WindowsUpdateClient/Operational',
    'Microsoft-Windows-Servicing/Operational',
    'Microsoft-Windows-WER-SystemErrorReporting/Operational',
    'Microsoft-Windows-WER-Diag/Operational',
    'Microsoft-Windows-WER-PayloadHealth/Operational'
)

if ($roles.IsADDS) {
    $eventLogs += @('Directory Service','DFS Replication','Microsoft-Windows-GroupPolicy/Operational','Microsoft-Windows-Kerberos/Operational')
}
if ($roles.IsDNS)  { $eventLogs += @('DNS Server','Microsoft-Windows-DNS-Server/Operational') }
if ($roles.IsDHCP) { $eventLogs += @('Microsoft-Windows-DHCP-Server/Operational') }
if ($roles.IsCA)   { $eventLogs += @('Microsoft-Windows-CertificationAuthority/Operational','Microsoft-Windows-CAPI2/Operational') }

if ($roles.IsHyperV) {
    $eventLogs += @(
        'Microsoft-Windows-Hyper-V-VMMS-Admin',
        'Microsoft-Windows-Hyper-V-Worker-Admin',
        'Microsoft-Windows-Hyper-V-Config-Admin',
        'Microsoft-Windows-Hyper-V-Hypervisor-Admin',
        'Microsoft-Windows-Hyper-V-VID-Admin',
        'Microsoft-Windows-Hyper-V-VmSwitch-Operational'
    )
}

if ($roles.IsCluster) {
    $eventLogs += @(
        'Microsoft-Windows-FailoverClustering/Operational',
        'Microsoft-Windows-FailoverClustering/Diagnostic',
        'Microsoft-Windows-FailoverClustering/DiagnosticVerbose',
        'Microsoft-Windows-ClusterAwareUpdating/Admin',
        'Microsoft-Windows-ClusterAwareUpdating/Operational',
        'Microsoft-Windows-FailoverClustering-CsvFs/Operational'
    )
}

# Storage Spaces driver logs (S2D & Storage Spaces)
$eventLogs += @(
    'Microsoft-Windows-StorageSpaces-Driver/Operational',
    'Microsoft-Windows-StorageSpaces-Driver/Diagnostic'
)

# RDMA / SMB Direct / networking logs (SMBDirect/Debug may be disabled; will be skipped automatically)
$eventLogs += @(
    'Microsoft-Windows-SMBServer/Operational',
    'Microsoft-Windows-SMBClient/Connectivity',
    'Microsoft-Windows-SMBClient/Operational',
    'Microsoft-Windows-NDIS/Operational',
    'Microsoft-Windows-SMBDirect/Debug'
)

$eventLogs = $eventLogs | Select-Object -Unique

$available = @{}
try { wevtutil el | ForEach-Object { $available[$_] = $true } } catch { Write-Warning "Failed to enumerate event logs via wevtutil el: $_" }

$exported = New-Object System.Collections.Generic.List[string]
$skipped  = New-Object System.Collections.Generic.List[string]

foreach ($logName in $eventLogs) {
    try {
        if (-not $available.ContainsKey($logName)) { $skipped.Add($logName) | Out-Null; continue }
        $safeName = ($logName -replace '[\\/]', '_')
        $evtxPath = Join-Path $evDir "$safeName.evtx"
        wevtutil epl "$logName" "$evtxPath"
        $exported.Add($logName) | Out-Null
    } catch {
        $skipped.Add($logName) | Out-Null
    }
}

Write-Detail ("Event logs exported: {0}" -f $exported.Count)
Write-Detail ("Event logs skipped: {0}" -f $skipped.Count)

@"
Event Log Export Summary
========================
Exported:
$( ($exported | ForEach-Object { "  - $_" }) -join "`n" )

Skipped (missing/not accessible):
$( ($skipped | ForEach-Object { "  - $_" }) -join "`n" )
"@ | Out-File -FilePath (Join-Path $evDir 'FoundVsSkipped.txt') -Encoding UTF8

# -------------------- EVTX Auto-Conversion (TXT + XML + CSV) --------------------
Write-Section "Converting EVTX logs (TXT/XML/CSV)"
$convDir = Join-Path $evDir 'Converted'
$null = New-Item -ItemType Directory -Force -Path $convDir | Out-Null

function Convert-EvtxForAnalytic {
    param([Parameter(Mandatory)][string]$EvtxPath)

    $baseName = [IO.Path]::GetFileNameWithoutExtension($EvtxPath)
    $txtPath  = Join-Path $convDir "$baseName.txt"
    $xmlPath  = Join-Path $convDir "$baseName.xml"
    $csvPath  = Join-Path $convDir "$baseName.csv"

    $max = [Math]::Max($EvtxMaxEvents, 1)

    try { wevtutil qe "$EvtxPath" /lf:true /rd:true /f:Text /c:$max | Out-File -FilePath $txtPath -Encoding UTF8 -Force } catch {}
    try { wevtutil qe "$EvtxPath" /lf:true /rd:true /f:XML  /c:$max | Out-File -FilePath $xmlPath -Encoding UTF8 -Force } catch {}

    try {
        Get-WinEvent -Path $EvtxPath -MaxEvents $max -ErrorAction Stop |
            Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message |
            Export-Csv $csvPath -NoTypeInformation -Encoding UTF8
    } catch {}
}

$evtxFiles = Get-ChildItem -Path $evDir -Filter *.evtx -ErrorAction SilentlyContinue
Write-Detail ("EVTX files found for conversion: {0}" -f @($evtxFiles).Count)
foreach ($f in $evtxFiles) {
    Write-Verbose ("Converting EVTX: {0}" -f $f.Name)
    Convert-EvtxForAnalytic -EvtxPath $f.FullName
}

[GC]::Collect()
[GC]::WaitForPendingFinalizers()

foreach ($f in $evtxFiles) { $null = Wait-ForFileUnlock -Path $f.FullName -RetryCount 40 -DelayMs 250 }
Write-Host "EVTX conversion complete. Files stored in: $convDir"
Write-Detail "EVTX conversion completed"

# -------------------- Performance Counters --------------------
Write-Section "Sampling performance counters"
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
$hypervCounters = @(
    '\Hyper-V Hypervisor Logical Processor(_Total)\% Total Run Time',
    '\Hyper-V Hypervisor Root Virtual Processor(_Total)\% Total Run Time',
    '\Hyper-V Virtual Switch(*)\Bytes Received/sec',
    '\Hyper-V Virtual Switch(*)\Bytes Sent/sec'
)
$clusterCounters = @('\Cluster Node(*)\*','\Cluster Network(*)\*')
$smbDirectCounters = @('\SMB Direct Connection(*)\*','\SMB Server Shares(*)\*')

$allCounters = $cpuCounters + $memCounters + $diskCounters + $netCounters + $hypervCounters + $clusterCounters + $smbDirectCounters
Write-Detail ("Configured counter paths: {0}" -f $allCounters.Count)

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
        Get-Counter -Counter $allCounters -SampleInterval $SampleIntervalSeconds -MaxSamples $maxSamples -ErrorAction Stop |
            Export-Counter -Path $blgPath -FileFormat BLG
    } catch {
        Write-Detail "BLG counter collection skipped due to unavailable counter paths"
    }
    try {
        Get-Counter -Counter $allCounters -SampleInterval $SampleIntervalSeconds -MaxSamples $maxSamples -ErrorAction Stop |
            Export-Counter -Path $csvPath -FileFormat CSV
    } catch {
        Write-Detail "CSV counter collection skipped due to unavailable counter paths"
    }
} else {
    "No counters collected." | Out-File -FilePath (Join-Path $perfDir 'PerfCollectionSkipped.txt') -Encoding UTF8
}

try {
    $snap = Get-Counter '\Network Interface(*)\Bytes Total/sec' -ErrorAction Stop
    $perNic = $snap.CounterSamples | ForEach-Object {
        [PSCustomObject]@{
            Timestamp         = Get-Date
            InterfaceInstance = $_.InstanceName
            BytesTotalPerSec  = [int64]$_.CookedValue
            Mbps              = [Math]::Round(($_.CookedValue * 8 / 1MB), 2)
        }
    }
    Save-ObjectCsv $perNic (Join-Path $perfDir 'Network_QuickThroughput.csv')
} catch {}

# Quick Snapshot
Write-Section "Computing quick snapshot"
try {
    $lastMem = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $memFreeMB  = if ($lastMem) { $lastMem.FreePhysicalMemory/1024 } else { $null }
    $memTotalMB = if ($lastMem) { $lastMem.TotalVisibleMemorySize/1024 } else { $null }
    $memCommit  = if ($lastMem) { [Math]::Round(($lastMem.TotalVirtualMemorySize - $lastMem.FreeVirtualMemory)/1MB,2) } else { $null }

    $cpuQueue=$null; $cpuPct=$null; $pfUsage=$null; $diskRead=$null; $diskWrite=$null; $diskQL=$null; $netBytes=$null; $tcpConn=$null
    try { $cpuQueue = (Get-Counter '\System\Processor Queue Length' -ErrorAction Stop).CounterSamples.CookedValue } catch {}
    try { $cpuPct   = (Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction Stop).CounterSamples.CookedValue } catch {}
    try { $pfUsage  = (Get-Counter '\Paging File(_Total)\% Usage' -ErrorAction Stop).CounterSamples.CookedValue } catch {}
    try { $diskRead = (Get-Counter '\PhysicalDisk(_Total)\Avg. Disk sec/Read' -ErrorAction Stop).CounterSamples.CookedValue } catch {}
    try { $diskWrite= (Get-Counter '\PhysicalDisk(_Total)\Avg. Disk sec/Write' -ErrorAction Stop).CounterSamples.CookedValue } catch {}
    try { $diskQL   = (Get-Counter '\PhysicalDisk(_Total)\Current Disk Queue Length' -ErrorAction Stop).CounterSamples.CookedValue } catch {}
    try { $netBytes = ((Get-Counter '\Network Interface(*)\Bytes Total/sec' -ErrorAction Stop).CounterSamples | Measure-Object CookedValue -Sum).Sum } catch {}
    try { $tcpConn  = ((Get-Counter '\TCPv4\Connections Established' -ErrorAction Stop).CounterSamples.CookedValue + (Get-Counter '\TCPv6\Connections Established' -ErrorAction Stop).CounterSamples.CookedValue) } catch {}

    [PSCustomObject]@{
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
    } | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $perfDir 'QuickSnapshot.csv')
} catch {}

# -------------------- Analytic-Ready Pack --------------------
Write-Section "Assembling Analytic-Ready pack"
$crDir = Join-Path $OutDir 'Analytic-Ready'
$null = New-Item -ItemType Directory -Force -Path $crDir | Out-Null

$toCopy = @(
    (Join-Path $sysDir    'SystemSummary.csv'),
    (Join-Path $perfDir   'PerfMeta.txt'),
    (Join-Path $perfDir   'PerfSamples.csv'),
    (Join-Path $perfDir   'QuickSnapshot.csv'),
    (Join-Path $perfDir   'Network_QuickThroughput.csv'),
    (Join-Path $sysDir    'TopProcessesByCPU.csv'),
    (Join-Path $sysDir    'TopProcessesByMemory.csv'),
    (Join-Path $sysDir    'NetInterfaceSummary.csv'),
    (Join-Path $patchDir  'HotFixes.csv'),
    (Join-Path $patchDir  'WindowsFeatures_Installed.csv'),
    (Join-Path $healthDir 'DISM_CheckHealth.txt'),
    (Join-Path $healthDir 'SFC_VerifyOnly.txt'),
    (Join-Path $healthDir 'Logs\CBS_tail5000.log'),
    (Join-Path $healthDir 'Logs\dism.log')
)

foreach ($p in $toCopy) {
    if (Test-Path $p) { try { Copy-Item $p -Destination $crDir -Force -ErrorAction Stop } catch {} }
}

if (Test-Path $convDir) {
    $crEv = Join-Path $crDir 'EventLogs_Converted'
    $null = New-Item -ItemType Directory -Force -Path $crEv | Out-Null
    try { Copy-Item (Join-Path $convDir '*') -Destination $crEv -Force -ErrorAction Stop } catch {}
}

if (Test-Path $roleDir) {
    $crRole = Join-Path $crDir 'RoleSpecific'
    $null = New-Item -ItemType Directory -Force -Path $crRole | Out-Null
    try { Copy-Item (Join-Path $roleDir '*') -Destination $crRole -Recurse -Force -ErrorAction Stop } catch {}
}

$javaCsv = Join-Path $sysDir 'Java_ProcessMetrics.csv'
$javaTxt = Join-Path $sysDir 'Java_ProcessMetrics.txt'
if (Test-Path $javaCsv) { Copy-Item $javaCsv -Destination $crDir -Force | Out-Null }
if (Test-Path $javaTxt) { Copy-Item $javaTxt -Destination $crDir -Force | Out-Null }

"Analytic-Ready pack created at: $crDir" | Out-File -FilePath (Join-Path $crDir 'README_Analytic.txt') -Encoding UTF8

# -------------------- Finalize & Zip --------------------
Write-Section "Finalizing"
try {
    $allFiles = Get-ChildItem -Path $OutDir -File -Recurse -ErrorAction SilentlyContinue
    foreach ($af in $allFiles) { $null = Wait-ForFileUnlock -Path $af.FullName -RetryCount 40 -DelayMs 100 }
} catch {}

$readme = @"
Windows Server Health & Performance Collection (v5.6.2)
Computer:  $computer
Timestamp: $timestamp

Folders:
- System: system summary, time sync, networking, storage, processes, services, optional java.exe metrics
- PatchAndRoles: installed hotfixes and Windows roles/features (ServerManager or DISM fallback)
- Health: DISM/SFC health results, CBS/DISM logs, crash dumps (with inventory CSV), WER artifacts (parsed .wer + binary inventory CSV)
- RoleSpecific: AD/CA/DNS/DHCP/Hyper-V/Cluster/S2D + RDMA + SAN artifacts
- EventLogs: exported .evtx channels; see FoundVsSkipped.txt
- EventLogs\Converted: EVTX converted to TXT/XML/CSV (capped by -EvtxMaxEvents)
- Performance: perf counters (.blg + .csv), quick snapshot, per-NIC throughput
- Analytic-Ready: single place to upload (CSV/TXT/XML + role-specific data)

Notes:
- Debug/Analytic event channels are exported only if they exist and are enabled.
- Self-test mode: -SelfTest / -ValidateOnly runs static parse audit and exits.
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
        Write-Host "Analytic-Ready:    $crDir"
    } catch {
        Write-Warning "Failed to zip output: $_"
        Write-Host "Artifacts available at: $OutDir"
        Write-Host "Analytic-Ready:    $crDir"
    }
} else {
    Write-Host "ZIP creation skipped. Artifacts available at: $OutDir"
    Write-Host "Analytic-Ready:    $crDir"
}
