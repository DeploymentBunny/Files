<#
.SYNOPSIS
    Collect Windows client OS health, crash/BSOD, network, storage, and performance diagnostics.

.DESCRIPTION
    Collect-WindowsClient gathers OS summary, crash/BSOD artifacts (minidumps, WER, hardware
    error records via WHEA), network diagnostics (NIC, IP, DNS, proxy, Winsock, Wi-Fi,
    connectivity and DNS resolution tests), disk and storage health (SMART, page file, disk
    space, shadow copies), driver and device status (problem devices, third-party drivers),
    Windows Update state, Windows Defender and firewall posture, reliability monitor data,
    performance counters, and event logs for Windows 7, 10, and 11.

    Exported EVTX files are converted to CSV for easier analytics consumption.
    Use -Verbose for detailed progress and decision logging.

    The script is read-only from a system-configuration perspective and only writes collection
    artifacts. Run from an elevated Windows PowerShell 5.1 session for best results.
    On Windows 7 (WMF 5.1 required) some newer cmdlets fall back to WMI and CLI tools.

.PARAMETER OutputRoot
    Root folder for output. Default: C:\WC-Diagnostics.
.PARAMETER DurationMinutes
    Duration to sample performance counters (minutes). Default: 5.
.PARAMETER SampleIntervalSeconds
    Sampling interval for performance counters (seconds). Default: 5.
.PARAMETER SkipPerformance
    Skips performance counter collection and quick performance snapshot.
.PARAMETER DeepHealth
    Runs DISM /ScanHealth and SFC /verifyonly (read-only; can take several minutes).
.PARAMETER IncludeFullCBS
    Copies full CBS.log. If omitted, only the last 5000 lines are collected.
.PARAMETER NoZip
    Skips creation of the ZIP archive.
.PARAMETER ValidateCounters
    Pre-tests performance counters and excludes unavailable ones.
.PARAMETER ExcludeEvtxFromZip
    Excludes .evtx files from the ZIP. Converted CSV outputs are still included.
.PARAMETER EvtxMaxEvents
    Maximum events per log during EVTX conversion. Default: 25000.
.PARAMETER EvtxDaysBack
    Convert only events from the last N days during EVTX conversion. Default: 30.
.PARAMETER IncludeEventMessage
    Includes full event Message text in EVTX CSV conversion. This is slower.
.PARAMETER EvtxPerFileTimeoutSeconds
    Maximum seconds to spend converting a single EVTX file before skipping it. Default: 180.
.PARAMETER SelfTest
    Runs static parse audit and exits (no elevation required).
.PARAMETER ValidateOnly
    Alias of -SelfTest.

.NOTES
    FileName:  Collect-WindowsClient.ps1
    Version:   1.7.2
    Updated:   2026-06-12
    Author:    Mikael Nystrom
    Contact:   deploymentbunny@outlook.com
    Blog:      https://www.deploymentbunny.com

.LINK
    https://www.deploymentbunny.com
#>

[CmdletBinding()]
param(
    [string]$OutputRoot = "$env:SystemDrive\WC-Diagnostics",
    [int]$DurationMinutes = 5,
    [int]$SampleIntervalSeconds = 5,
    [switch]$SkipPerformance,
    [switch]$DeepHealth,
    [switch]$IncludeFullCBS,
    [switch]$NoZip,
    [switch]$ValidateCounters,
    [switch]$ExcludeEvtxFromZip,
    [int]$EvtxMaxEvents = 25000,
    [int]$EvtxDaysBack = 30,
    [switch]$IncludeEventMessage,
    [int]$EvtxPerFileTimeoutSeconds = 180,
    [switch]$SelfTest,
    [Alias('ValidateOnly')]
    [switch]$StaticAuditOnly
)

# -------------------- SelfTest / Static Parse Audit --------------------
function Invoke-ScriptSelfTest {
    [CmdletBinding()]
    param()

    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }

    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-Error "SelfTest: Cannot resolve script path."
        exit 2
    }

    Write-Host "=== SelfTest / Static Parse Audit ===" -ForegroundColor Cyan
    Write-Host "Script: $scriptPath"
    Write-Host "PowerShell: $($PSVersionTable.PSVersion)  Edition: $($PSVersionTable.PSEdition)"
    Write-Host ""

    $content = Get-Content -LiteralPath $scriptPath -Raw -ErrorAction Stop
    $tokens  = $null
    $errors  = $null
    $ast     = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors)

    if ($errors -and $errors.Count -gt 0) {
        Write-Host "Parser errors found: $($errors.Count)" -ForegroundColor Red
        foreach ($e in $errors) {
            $line = $e.Extent.StartLineNumber
            $col  = $e.Extent.StartColumnNumber
            Write-Host ("  Line {0}, Col {1}: {2}" -f $line, $col, $e.Message) -ForegroundColor Red
            $lines = $content -split "`r?`n"
            if ($line -ge 1 -and $line -le $lines.Count) {
                Write-Host ("    > " + $lines[$line - 1].TrimEnd()) -ForegroundColor DarkRed
            }
        }
        Write-Host ""
        Write-Host "SelfTest FAILED (syntax errors)." -ForegroundColor Red
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
    }
    else {
        Write-Host "Delimiter balance: OK" -ForegroundColor Green
    }

    $colonCallMatches = [regex]::Matches($content, '(?m)(?<!\S):(?:Max|Min|Round|Ceiling|Floor|Abs|Sqrt|FromHours|FromMinutes|Collect|WaitForPendingFinalizers)\b')
    if ($colonCallMatches.Count -gt 0) {
        Write-Host "Suspicious ':Xxx' tokens found: $($colonCallMatches.Count)" -ForegroundColor Yellow
        $lines = $content -split "`r?`n"
        foreach ($m in ($colonCallMatches | Select-Object -First 50)) {
            $prefix = $content.Substring(0, $m.Index)
            $lineNo = ([regex]::Matches($prefix, "`r?`n").Count) + 1
            if ($lineNo -ge 1 -and $lineNo -le $lines.Count) {
                Write-Host ("  Line {0}: {1}" -f $lineNo, $lines[$lineNo - 1].TrimEnd()) -ForegroundColor Yellow
            }
        }
    }
    else {
        Write-Host "Text-lint: No suspicious ':Max/:Round/:Collect' tokens detected" -ForegroundColor Green
    }

    $suspiciousCmds = @('Round', 'Max', 'Min', 'Ceiling', 'Floor', 'FromHours', 'FromMinutes', 'Collect', 'WaitForPendingFinalizers')
    $cmdAsts = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -and
        ($suspiciousCmds -contains $node.GetCommandName())
    }, $true)

    if ($cmdAsts.Count -gt 0) {
        Write-Host "Potential missing [Math]::/[GC]:: qualification: $($cmdAsts.Count)" -ForegroundColor Yellow
    }
    else {
        Write-Host "AST-lint: No unqualified math/time/gc function-style calls detected" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "SelfTest PASSED (static parse + lint checks complete)" -ForegroundColor Green
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
        $psi.FileName               = $FilePath
        $psi.Arguments              = $Arguments
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $p = [System.Diagnostics.Process]::Start($psi)
        $stdout = $p.StandardOutput.ReadToEnd()
        $stderr = $p.StandardError.ReadToEnd()
        $p.WaitForExit()

        if ($OutFile) {
            $stdout | Out-File -FilePath $OutFile -Encoding UTF8 -Force
            if ($stderr) { "`n---- STDERR ----`n$stderr" | Out-File -FilePath $OutFile -Encoding UTF8 -Append }
        }
        return @{ ExitCode = $p.ExitCode; StdOut = $stdout; StdErr = $stderr }
    }
    catch {
        Write-Warning "Failed to run $FilePath $Arguments : $_"
        if ($OutFile) { "ERROR: $_" | Out-File -FilePath $OutFile -Encoding UTF8 -Force }
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

function Convert-DmtfSafe {
    param([string]$Dmtf)
    if ([string]::IsNullOrWhiteSpace($Dmtf)) { return $null }
    if ($Dmtf.Length -lt 14) { return $null }
    try { return [Management.ManagementDateTimeConverter]::ToDateTime($Dmtf) }
    catch { return $null }
}

function Wait-ForFileUnlock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$RetryCount = 20,
        [int]$DelayMs    = 250
    )
    for ($i = 0; $i -lt $RetryCount; $i++) {
        try {
            if (-not (Test-Path -LiteralPath $Path)) { return $true }
            $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $fs.Close()
            return $true
        }
        catch { Start-Sleep -Milliseconds $DelayMs }
    }
    return $false
}

function Save-Text {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    try { $Text | Out-File -FilePath $Path -Encoding UTF8 -Force }
    catch { Write-Warning "Failed to write $Path : $_" }
}

function Convert-WerReportToObject {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $data    = [ordered]@{ ReportFile = $Path }
        $section = 'General'
        foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction Stop)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -match '^\[(.+)\]\s*$') { $section = $matches[1].Trim(); continue }
            if ($line -match '^\s*([^=]+?)\s*=\s*(.*)$') {
                $rawKey  = $matches[1].Trim()
                $value   = $matches[2].Trim()
                $key     = ($rawKey -replace '[^A-Za-z0-9_]', '_')
                if ($section -ne 'General') {
                    $key = ("{0}_{1}" -f ($section -replace '[^A-Za-z0-9_]', '_'), $key)
                }
                $baseKey = $key
                $i       = 2
                while ($data.Contains($key)) { $key = "{0}_{1}" -f $baseKey, $i; $i++ }
                $data[$key] = $value
            }
        }
        return [PSCustomObject]$data
    }
    catch { return $null }
}

function Get-ClientVersionInfo {
    $regNT = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    [PSCustomObject]@{
        ProductName    = $regNT.ProductName
        ReleaseId      = $regNT.ReleaseId
        DisplayVersion = $regNT.DisplayVersion
        CurrentBuild   = $regNT.CurrentBuild
        UBR            = $regNT.UBR
        VersionString  = if ($regNT.UBR) { "$($regNT.CurrentBuild).$($regNT.UBR)" } else { "$($regNT.CurrentBuild)" }
        Edition        = $regNT.EditionID
    }
}

function Test-CounterPresent {
    param([string[]]$Counters)
    $valid = New-Object System.Collections.Generic.List[string]
    foreach ($c in $Counters) {
        try {
            $null = Get-Counter -Counter $c -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
            $valid.Add($c)
        }
        catch { Write-Verbose "Skipping unavailable counter: $c" }
    }
    return $valid.ToArray()
}

$computer  = $env:COMPUTERNAME
$timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$OutDir    = Join-Path $OutputRoot "$computer-$timestamp"
$null = New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Write-Detail "Output directory: $OutDir"

# ============================================================================================
# 1. SYSTEM SUMMARY
# ============================================================================================
Write-Section "Collecting system summary"
$sysDir = Join-Path $OutDir 'System'
$null = New-Item -ItemType Directory -Force -Path $sysDir | Out-Null

$os   = Get-CimInstance Win32_OperatingSystem  -ErrorAction SilentlyContinue
$cs   = Get-CimInstance Win32_ComputerSystem   -ErrorAction SilentlyContinue
$bios = Get-CimInstance Win32_BIOS             -ErrorAction SilentlyContinue
$proc = Get-CimInstance Win32_Processor        -ErrorAction SilentlyContinue
$mb   = Get-CimInstance Win32_BaseBoard        -ErrorAction SilentlyContinue

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
    }
    catch {}
}

if (-not $installDate) {
    try {
        $regInst = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        if ($regInst.InstallDate) {
            $installDate = (Get-Date '1970-01-01').AddSeconds([int64]$regInst.InstallDate)
        }
    }
    catch {}
}

$uptimeDays = $null
if ($lastBoot) { $uptimeDays = ((Get-Date) - $lastBoot).TotalDays }

$buildInfo = Get-ClientVersionInfo

$summary = [PSCustomObject]@{
    ComputerName   = $env:COMPUTERNAME
    OSCaption      = $os.Caption
    OSVersion      = $os.Version
    Build          = $buildInfo.VersionString
    Edition        = $buildInfo.Edition
    DisplayVersion = $buildInfo.DisplayVersion
    InstallDate    = $installDate
    LastBoot       = $lastBoot
    UptimeDays     = if ($null -ne $uptimeDays) { [Math]::Round($uptimeDays, 2) } else { $null }
    Manufacturer   = $cs.Manufacturer
    Model          = $cs.Model
    BIOSVersion    = ($bios.SMBIOSBIOSVersion -join ' ')
    BIOSDate       = (Convert-DmtfSafe $bios.ReleaseDate)
    Motherboard    = if ($mb) { "$($mb.Manufacturer) $($mb.Product)" } else { $null }
    CPU            = ($proc.Name -join ' | ')
    LogicalCPUs    = ($proc.NumberOfLogicalProcessors | Measure-Object -Sum).Sum
    TotalRAMGB     = if ($cs.TotalPhysicalMemory) { [Math]::Round($cs.TotalPhysicalMemory / 1GB, 2) } else { $null }
    Domain         = $cs.Domain
    PartOfDomain   = $cs.PartOfDomain
    Username       = $env:USERNAME
}
Save-ObjectCsv $summary (Join-Path $sysDir 'SystemSummary.csv')

# Time sync
Invoke-CMD -FilePath 'w32tm.exe' -Arguments '/query /status' -OutFile (Join-Path $sysDir 'TimeSync.txt') | Out-Null

# Battery / laptop
try {
    $batt = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if ($batt) {
        $batt | Select-Object DeviceID, BatteryStatus, EstimatedChargeRemaining, EstimatedRunTime, FullChargeCapacity, DesignCapacity |
            Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $sysDir 'Battery.csv')
        Write-Detail "Battery detected; portability data collected"
    }
}
catch {}

# Power plans
try {
    Invoke-CMD -FilePath 'powercfg.exe' -Arguments '/list'      -OutFile (Join-Path $sysDir 'PowerPlans.txt')        | Out-Null
    Invoke-CMD -FilePath 'powercfg.exe' -Arguments '/query'     -OutFile (Join-Path $sysDir 'ActivePowerPlan.txt')   | Out-Null
    Invoke-CMD -FilePath 'powercfg.exe' -Arguments '/lastwake'  -OutFile (Join-Path $sysDir 'LastWakeDevice.txt')    | Out-Null
    Invoke-CMD -FilePath 'powercfg.exe' -Arguments '/waketimers'-OutFile (Join-Path $sysDir 'WakeTimers.txt')        | Out-Null
}
catch {}

# Secure Boot
try {
    $sbPath = Join-Path $sysDir 'SecureBoot.txt'
    try {
        $sb = Confirm-SecureBootUEFI -ErrorAction Stop
        "SecureBootEnabled=$sb" | Out-File -FilePath $sbPath -Encoding UTF8
    }
    catch {
        "SecureBootEnabled=Unknown (cmdlet unavailable or Legacy BIOS)" | Out-File -FilePath $sbPath -Encoding UTF8
    }
}
catch {}

# TPM
try {
    $tpm = Get-CimInstance -Namespace root\cimv2\Security\MicrosoftTpm -ClassName Win32_Tpm -ErrorAction SilentlyContinue
    if ($tpm) {
        $tpm | Select-Object IsActivated_InitialValue, IsEnabled_InitialValue, IsOwned_InitialValue, SpecVersion, ManufacturerVersion |
            Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $sysDir 'TPM.csv')
    }
    else {
        "TPM not detected or WMI namespace unavailable." | Out-File -FilePath (Join-Path $sysDir 'TPM_NotFound.txt') -Encoding UTF8
    }
}
catch {}

# UAC settings
try {
    $uac = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
    if ($uac) {
        [PSCustomObject]@{
            EnableLUA                  = $uac.EnableLUA
            ConsentPromptBehaviorAdmin = $uac.ConsentPromptBehaviorAdmin
            PromptOnSecureDesktop      = $uac.PromptOnSecureDesktop
        } | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $sysDir 'UAC_Settings.csv')
    }
}
catch {}

# Processes & services snapshot
try { Get-Process | Sort-Object CPU -Descending | Select-Object -First 50 | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $sysDir 'TopProcessesByCPU.csv')    } catch {}
try { Get-Process | Sort-Object WS  -Descending | Select-Object -First 50 | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $sysDir 'TopProcessesByMemory.csv') } catch {}
try { Get-Service | Where-Object { $_.Status -ne 'Running' -and $_.StartType -eq 'Automatic' } | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $sysDir 'AutoServicesNotRunning.csv') } catch {}
try { Get-Service | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $sysDir 'AllServices.csv') } catch {}

# Startup programs (run keys)
try {
    $startupPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Run'
    )
    $startupItems = foreach ($path in $startupPaths) {
        try {
            $props = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
            if ($props) {
                foreach ($p in ($props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })) {
                    [PSCustomObject]@{
                        RegistryHive = $path
                        Name         = $p.Name
                        Value        = $p.Value
                    }
                }
            }
        }
        catch {}
    }
    if ($startupItems) { Save-ObjectCsv $startupItems (Join-Path $sysDir 'StartupPrograms.csv') }
}
catch {}

# Installed applications (classic + modern where available)
try {
    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $classicApps = foreach ($uPath in $uninstallPaths) {
        try {
            Get-ChildItem -LiteralPath $uPath -ErrorAction Stop | ForEach-Object {
                try {
                    $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop
                    if ($p.DisplayName) {
                        [PSCustomObject]@{
                            AppType         = 'Classic'
                            DisplayName     = $p.DisplayName
                            DisplayVersion  = $p.DisplayVersion
                            Publisher       = $p.Publisher
                            InstallDate     = $p.InstallDate
                            InstallLocation = $p.InstallLocation
                            Source          = $uPath
                            PackageFullName = $null
                        }
                    }
                }
                catch {}
            }
        }
        catch {}
    }

    if ($classicApps) {
        Save-ObjectCsv ($classicApps | Sort-Object DisplayName, DisplayVersion) (Join-Path $sysDir 'InstalledApplications.csv')
        Save-ObjectCsv ($classicApps | Sort-Object DisplayName, DisplayVersion) (Join-Path $sysDir 'InstalledApplications_Classic.csv')
    }

    $modernApps = @()
    try {
        $appxCmd = Get-Command Get-AppxPackage -ErrorAction SilentlyContinue
        if ($appxCmd) {
            $modernApps = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
                Select-Object @{
                    n = 'AppType'; e = { 'ModernAppx' }
                }, @{
                    n = 'DisplayName'; e = { if ($_.Name) { $_.Name } else { $_.PackageFamilyName } }
                }, @{
                    n = 'DisplayVersion'; e = { $_.Version }
                }, @{
                    n = 'Publisher'; e = { $_.Publisher }
                }, @{
                    n = 'InstallDate'; e = { $null }
                }, @{
                    n = 'InstallLocation'; e = { $_.InstallLocation }
                }, @{
                    n = 'Source'; e = { 'Get-AppxPackage -AllUsers' }
                }, @{
                    n = 'PackageFullName'; e = { $_.PackageFullName }
                }
        }
    }
    catch {}

    if ($modernApps -and @($modernApps).Count -gt 0) {
        Save-ObjectCsv ($modernApps | Sort-Object DisplayName, DisplayVersion) (Join-Path $sysDir 'InstalledApplications_ModernAppx.csv')
    }
    else {
        'Get-AppxPackage is unavailable or returned no packages on this OS.' |
            Out-File -FilePath (Join-Path $sysDir 'InstalledApplications_ModernAppx_NotAvailable.txt') -Encoding UTF8 -Force
    }

    $allApps = @()
    if ($classicApps) { $allApps += $classicApps }
    if ($modernApps)  { $allApps += $modernApps }

    if ($allApps -and @($allApps).Count -gt 0) {
        Save-ObjectCsv ($allApps | Sort-Object AppType, DisplayName, DisplayVersion) (Join-Path $sysDir 'InstalledApplications_All.csv')
    }
}
catch {}

# Environment variables
try { Get-ChildItem Env: | Sort-Object Name | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $sysDir 'EnvironmentVariables.csv') } catch {}

Write-Detail "System summary collection completed"

# ============================================================================================
# 2. PATCH LEVEL & WINDOWS UPDATE
# ============================================================================================
Write-Section "Collecting patch level and Windows Update state"
$patchDir = Join-Path $OutDir 'PatchAndUpdate'
$null = New-Item -ItemType Directory -Force -Path $patchDir | Out-Null

try { Get-HotFix | Sort-Object InstalledOn | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $patchDir 'HotFixes.csv') } catch {}

# Windows Update log (Win7: plaintext file; Win10/11: ETL converted via Get-WindowsUpdateLog)
try {
    $wuLogSrc  = "$env:WINDIR\WindowsUpdate.log"
    $wuLogDest = Join-Path $patchDir 'WindowsUpdate.log'
    if (Test-Path $wuLogSrc) {
        if ($IncludeFullCBS) { Copy-Item $wuLogSrc $wuLogDest -Force -ErrorAction SilentlyContinue }
        else { Get-Content $wuLogSrc -Tail 5000 | Out-File -FilePath $wuLogDest -Encoding UTF8 }
    }
    else {
        try {
            Get-WindowsUpdateLog -LogPath $wuLogDest -ErrorAction Stop | Out-Null
        }
        catch {
            "Get-WindowsUpdateLog failed or not available: $_" | Out-File -FilePath (Join-Path $patchDir 'WindowsUpdateLog_Note.txt') -Encoding UTF8
        }
    }
}
catch {}

# WUA COM-based update history (Win7+)
try {
    $updateSession  = New-Object -ComObject Microsoft.Update.Session
    $updateSearcher = $updateSession.CreateUpdateSearcher()
    $histCount      = $updateSearcher.GetTotalHistoryCount()
    if ($histCount -gt 0) {
        $history    = $updateSearcher.QueryHistory(0, [Math]::Min($histCount, 500))
        $histItems  = for ($i = 0; $i -lt $history.Count; $i++) {
            $h = $history.Item($i)
            [PSCustomObject]@{
                Date        = $h.Date
                Title       = $h.Title
                Description = $h.Description
                Operation   = $h.Operation
                ResultCode  = $h.ResultCode
                HResult     = $h.HResult
            }
        }
        Save-ObjectCsv $histItems (Join-Path $patchDir 'WUA_UpdateHistory.csv')
    }
    try {
        $result = $updateSearcher.Search("IsInstalled=0 and Type='Software'")
        "PendingUpdates=$($result.Updates.Count)" | Out-File -FilePath (Join-Path $patchDir 'WUA_PendingCount.txt') -Encoding UTF8
    }
    catch {}
}
catch { Write-Warning "WUA COM query failed: $_" }

# SoftwareDistribution state
try {
    [PSCustomObject]@{
        SoftwareDistributionPath = "$env:WINDIR\SoftwareDistribution"
        DataStoreExists          = (Test-Path "$env:WINDIR\SoftwareDistribution\DataStore")
        DownloadExists           = (Test-Path "$env:WINDIR\SoftwareDistribution\Download")
    } | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $patchDir 'SoftwareDistribution_State.csv')
}
catch {}

Write-Detail "Patch and update collection completed"

# ============================================================================================
# 3. DEVICE & DRIVER HEALTH
# ============================================================================================
Write-Section "Collecting device and driver health"
$driverDir = Join-Path $OutDir 'DevicesAndDrivers'
$null = New-Item -ItemType Directory -Force -Path $driverDir | Out-Null

# Problem devices (ConfigManagerErrorCode != 0)
try {
    $allDevices = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue
    if ($allDevices) {
        $problemDevices = $allDevices | Where-Object { $_.ConfigManagerErrorCode -ne 0 } |
            Select-Object Name, DeviceID, ConfigManagerErrorCode, Status, Manufacturer

        if ($problemDevices) {
            Save-ObjectCsv $problemDevices (Join-Path $driverDir 'ProblemDevices.csv')
            Write-Detail ("Problem devices found: {0}" -f @($problemDevices).Count)
        }
        else {
            "No problem devices found (all ConfigManagerErrorCode = 0)." |
                Out-File -FilePath (Join-Path $driverDir 'ProblemDevices_None.txt') -Encoding UTF8
        }

        $allDevices | Select-Object Name, DeviceID, Status, ConfigManagerErrorCode, Manufacturer, PNPDeviceID |
            Sort-Object Name |
            Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $driverDir 'AllDevices.csv')
    }
}
catch { Write-Warning "Device enumeration failed: $_" }

# Driver inventory via DISM cmdlet (Win8+), fallback to driverquery
try {
    $drivers = Get-WindowsDriver -Online -ErrorAction Stop
    if ($drivers) {
        $drivers | Select-Object Driver, OriginalFileName, ClassName, ClassDescription, BootCritical, ProviderName, Date, Version, Inbox |
            Sort-Object Date -Descending |
            Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $driverDir 'InstalledDrivers.csv')

        $recent = $drivers | Where-Object { $_.Date -gt (Get-Date).AddDays(-30) } | Sort-Object Date -Descending
        if ($recent) { Save-ObjectCsv $recent (Join-Path $driverDir 'Drivers_ChangedLast30Days.csv') }

        $thirdParty = $drivers | Where-Object { -not $_.Inbox }
        if ($thirdParty) { Save-ObjectCsv $thirdParty (Join-Path $driverDir 'Drivers_ThirdParty.csv') }
    }
}
catch {
    Write-Verbose "Get-WindowsDriver not available; using driverquery.exe fallback"
    try {
        Invoke-CMD -FilePath 'driverquery.exe' -Arguments '/fo csv /v' -OutFile (Join-Path $driverDir 'InstalledDrivers_driverquery.csv') | Out-Null
    }
    catch {}
}

Write-Detail "Device and driver collection completed"

# ============================================================================================
# 4. SECURITY STATE
# ============================================================================================
Write-Section "Collecting security state"
$secDir = Join-Path $OutDir 'Security'
$null = New-Item -ItemType Directory -Force -Path $secDir | Out-Null

# Windows Defender
try {
    $mpStatus = Get-MpComputerStatus -ErrorAction Stop
    $mpStatus | Select-Object `
        AMProductVersion, AMEngineVersion, AMServiceEnabled, AMServiceVersion,
        AntivirusEnabled, AntivirusSignatureLastUpdated, AntivirusSignatureVersion,
        AntispywareEnabled, AntispywareSignatureLastUpdated,
        BehaviorMonitorEnabled, IoavProtectionEnabled,
        NISEnabled, NISEngineVersion, NISSignatureVersion,
        OnAccessProtectionEnabled, RealTimeProtectionEnabled,
        ComputerState, FullScanAge, QuickScanAge |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $secDir 'WindowsDefender_Status.csv')

    $mpPrefs = Get-MpPreference -ErrorAction SilentlyContinue
    if ($mpPrefs) {
        $mpPrefs | Select-Object `
            DisableRealtimeMonitoring, DisableBehaviorMonitoring, DisableIOAVProtection,
            DisablePrivacyMode, ExclusionPath, ExclusionExtension, ExclusionProcess |
            Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $secDir 'WindowsDefender_Preferences.csv')
    }

    $threats = Get-MpThreatDetection -ErrorAction SilentlyContinue
    if ($threats) {
        Save-ObjectCsv $threats (Join-Path $secDir 'WindowsDefender_ThreatDetections.csv')
    }
    else {
        "No active threat detections." | Out-File -FilePath (Join-Path $secDir 'WindowsDefender_NoThreats.txt') -Encoding UTF8
    }
}
catch {
    Write-Verbose "Get-MpComputerStatus not available; checking service state"
    try {
        $defSvc = Get-Service -Name WinDefend -ErrorAction SilentlyContinue
        if ($defSvc) {
            $defSvc | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $secDir 'WindowsDefender_Service.csv')
        }
        else {
            "Windows Defender service (WinDefend) not found." | Out-File -FilePath (Join-Path $secDir 'WindowsDefender_Note.txt') -Encoding UTF8
        }
    }
    catch {}
}

# Windows Firewall profiles
try {
    $fwProfiles = Get-NetFirewallProfile -ErrorAction Stop
    $fwProfiles | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction, LogAllowed, LogBlocked, LogFileName |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $secDir 'Firewall_Profiles.csv')
}
catch {
    Invoke-CMD -FilePath 'netsh.exe' -Arguments 'advfirewall show allprofiles' -OutFile (Join-Path $secDir 'Firewall_Profiles.txt') | Out-Null
}

# BitLocker
try {
    $blStatus = Get-BitLockerVolume -ErrorAction Stop
    if ($blStatus) {
        $blStatus | Select-Object MountPoint, VolumeStatus, EncryptionPercentage, EncryptionMethod, LockStatus, KeyProtector |
            Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $secDir 'BitLocker_Status.csv')
    }
}
catch {
    try {
        $drives = (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Z]:\\$' }).Root
        foreach ($d in $drives) {
            $dLetter = ($d -replace '\\', '')
            Invoke-CMD -FilePath 'manage-bde.exe' -Arguments "-status $d" -OutFile (Join-Path $secDir "BitLocker_${dLetter}.txt") | Out-Null
        }
    }
    catch {}
}

# AppLocker policy
try {
    $alPath = Join-Path $secDir 'AppLocker_Policy.xml'
    Get-AppLockerPolicy -Effective -Xml -ErrorAction Stop | Out-File -FilePath $alPath -Encoding UTF8
}
catch {}

Write-Detail "Security state collection completed"

# ============================================================================================
# 5. HEALTH CHECKS (DISM / SFC / CBS)
# ============================================================================================
Write-Section "Running health checks (DISM/SFC)"
$healthDir = Join-Path $OutDir 'Health'
$null = New-Item -ItemType Directory -Force -Path $healthDir | Out-Null

Invoke-CMD -FilePath 'dism.exe' -Arguments '/Online /Cleanup-Image /CheckHealth' -OutFile (Join-Path $healthDir 'DISM_CheckHealth.txt') | Out-Null

if ($DeepHealth) {
    Invoke-CMD -FilePath 'dism.exe' -Arguments '/Online /Cleanup-Image /ScanHealth' -OutFile (Join-Path $healthDir 'DISM_ScanHealth.txt') | Out-Null
    Invoke-CMD -FilePath 'sfc.exe'  -Arguments '/verifyonly'                         -OutFile (Join-Path $healthDir 'SFC_VerifyOnly.txt')  | Out-Null
}
else {
    "Use -DeepHealth to run DISM /ScanHealth and SFC /verifyonly." |
        Out-File -FilePath (Join-Path $healthDir 'Readme.txt') -Encoding UTF8
}

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
    if (Test-Path "$dismFolder\dism.log")       { Copy-Item "$dismFolder\dism.log"        (Join-Path $logsDir 'dism.log')        -ErrorAction SilentlyContinue }
}
catch {}

Write-Detail "Health check collection completed"

# ============================================================================================
# 6. BSOD & CRASH ANALYSIS
# ============================================================================================
Write-Section "Collecting BSOD and crash artifacts"
$crashDir = Join-Path $OutDir 'Crashes_BSOD'
$null = New-Item -ItemType Directory -Force -Path $crashDir | Out-Null

# CrashControl registry settings
try {
    $cc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction SilentlyContinue
    if ($cc) {
        [PSCustomObject]@{
            DumpFile         = $cc.DumpFile
            MinidumpDir      = $cc.MinidumpDir
            CrashDumpEnabled = $cc.CrashDumpEnabled   # 0=None 1=Complete 2=Kernel 3=Small 7=Auto
            AutoReboot       = $cc.AutoReboot
            Overwrite        = $cc.Overwrite
            LogEvent         = $cc.LogEvent
        } | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $crashDir 'CrashControl_Settings.csv')
    }
}
catch {}

# Minidumps
$miniDumpSrc = "$env:WINDIR\Minidump"
try {
    $cc2 = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction SilentlyContinue
    if ($cc2 -and $cc2.MinidumpDir -and (Test-Path -LiteralPath $cc2.MinidumpDir)) {
        $miniDumpSrc = $cc2.MinidumpDir
    }
}
catch {}

$miniDumpDst = Join-Path $crashDir 'Minidumps'
$null = New-Item -ItemType Directory -Force -Path $miniDumpDst | Out-Null
try {
    if (Test-Path -LiteralPath $miniDumpSrc) {
        $miniFiles = Get-ChildItem -Path $miniDumpSrc -Filter '*.dmp' -ErrorAction SilentlyContinue
        if ($miniFiles) {
            Copy-Item -Path (Join-Path $miniDumpSrc '*.dmp') -Destination $miniDumpDst -Force -ErrorAction SilentlyContinue
            $miniInventory = $miniFiles | Select-Object Name, FullName, Length, CreationTime, LastWriteTime,
                @{n = 'SizeMB'; e = { [Math]::Round($_.Length / 1MB, 2) } }
            Save-ObjectCsv $miniInventory (Join-Path $miniDumpDst 'Minidump_Inventory.csv')
            Write-Detail ("Minidumps collected: {0}" -f $miniFiles.Count)
        }
        else {
            "No minidump files found in $miniDumpSrc" | Out-File -FilePath (Join-Path $miniDumpDst 'Minidump_None.txt') -Encoding UTF8
        }
    }
    else {
        "Minidump directory not found: $miniDumpSrc" | Out-File -FilePath (Join-Path $miniDumpDst 'Minidump_None.txt') -Encoding UTF8
    }
}
catch {}

# Full / kernel dump presence (do not copy - can be many GB)
try {
    $dumpCandidates = @("$env:WINDIR\MEMORY.DMP", "$env:WINDIR\ActiveMemory.dmp")
    foreach ($df in $dumpCandidates) {
        if (Test-Path -LiteralPath $df) {
            $sz = (Get-Item -LiteralPath $df).Length
            "$df exists (size: $([Math]::Round($sz / 1GB, 1)) GB)" |
                Out-File -FilePath (Join-Path $crashDir 'FullDump_Present.txt') -Encoding UTF8 -Append
            Write-Detail "Full dump detected: $df"
        }
    }
}
catch {}

# WER crash artifacts
$werDir = Join-Path $crashDir 'WER'
$null = New-Item -ItemType Directory -Force -Path $werDir | Out-Null
try {
    $werRoot    = "$env:ProgramData\Microsoft\Windows\WER"
    $werFolders = @('ReportArchive', 'ReportQueue', 'Temp')
    foreach ($folder in $werFolders) {
        $src = Join-Path $werRoot $folder
        if (Test-Path -LiteralPath $src) {
            $dst = Join-Path $werDir $folder
            $null = New-Item -ItemType Directory -Force -Path $dst | Out-Null
            Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $werFiles = Get-ChildItem -Path $werDir -File -Recurse -ErrorAction SilentlyContinue
    if ($werFiles) {
        $werInventory = $werFiles | Select-Object Name, FullName, Extension, Length, CreationTime, LastWriteTime,
            @{n = 'SizeMB'; e = { [Math]::Round($_.Length / 1MB, 2) } }
        Save-ObjectCsv $werInventory (Join-Path $werDir 'WER_Inventory.csv')

        $werReports = $werFiles | Where-Object { $_.Extension -ieq '.wer' }
        if ($werReports) {
            $parsedWer = $werReports | ForEach-Object { Convert-WerReportToObject -Path $_.FullName } |
                Where-Object { $_ -ne $null }
            if ($parsedWer) { Save-ObjectCsv $parsedWer (Join-Path $werDir 'WER_Parsed.csv') }
        }
    }
}
catch { Write-Warning "WER collection failed: $_" }

# BSOD-related system events (IDs 41=unexpected reboot, 6008=unexpected shutdown, 1001=bugcheck)
try {
    $bsodEvents = Get-WinEvent -LogName System -ErrorAction Stop |
        Where-Object { ($_.Id -eq 41 -or $_.Id -eq 1001 -or $_.Id -eq 6008) } |
        Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message
    if ($bsodEvents) {
        Save-ObjectCsv $bsodEvents (Join-Path $crashDir 'BsodEvents_System.csv')
        Write-Detail ("BSOD-related system events: {0}" -f @($bsodEvents).Count)
    }
    else {
        "No BSOD-related events (41/6008/1001) found in System log." |
            Out-File -FilePath (Join-Path $crashDir 'BsodEvents_None.txt') -Encoding UTF8
    }
}
catch { Write-Warning "BSOD event query failed: $_" }

Write-Detail "BSOD and crash collection completed"

# ============================================================================================
# 7. NETWORK DIAGNOSTICS
# ============================================================================================
Write-Section "Collecting network diagnostics"
$netDir = Join-Path $OutDir 'Network'
$null = New-Item -ItemType Directory -Force -Path $netDir | Out-Null

# NIC inventory
try {
    $adapters = Get-NetAdapter -ErrorAction Stop | Sort-Object Name
    Save-ObjectCsv $adapters (Join-Path $netDir 'NetAdapter.csv')

    $ipcfgAll = $null
    try { $ipcfgAll = Get-NetIPConfiguration -ErrorAction Stop } catch {}
    if ($ipcfgAll) { Save-ObjectCsv $ipcfgAll (Join-Path $netDir 'NetIPConfiguration.csv') }

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
            MediaType      = $nic.MediaType
            MAC            = $nic.MacAddress
            InterfaceIndex = $nic.ifIndex
            IPv4           = if ($ip) { ($ip.IPv4Address.IPAddress -join ';') } else { $null }
            IPv6           = if ($ip) { ($ip.IPv6Address.IPAddress -join ';') } else { $null }
            DefaultGateway = if ($ip) { ($ip.IPv4DefaultGateway.NextHop -join ';') } else { $null }
            DNSServers     = if ($ip) { ($ip.DnsServer.ServerAddresses -join ';') } else { $null }
        }
    }
    if ($nicSummary) { Save-ObjectCsv $nicSummary (Join-Path $netDir 'NetInterfaceSummary.csv') }
}
catch {
    # Fallback: ipconfig /all
    Invoke-CMD -FilePath 'ipconfig.exe' -Arguments '/all' -OutFile (Join-Path $netDir 'ipconfig_all.txt') | Out-Null
}

# Routing table
try {
    $routes = Get-NetRoute -ErrorAction SilentlyContinue
    if ($routes) { Save-ObjectCsv $routes (Join-Path $netDir 'RoutingTable.csv') }
}
catch {
    Invoke-CMD -FilePath 'route.exe' -Arguments 'print' -OutFile (Join-Path $netDir 'route_print.txt') | Out-Null
}

# ARP cache
try {
    $arp = Get-NetNeighbor -ErrorAction SilentlyContinue
    if ($arp) { Save-ObjectCsv $arp (Join-Path $netDir 'ARP_Cache.csv') }
}
catch {
    Invoke-CMD -FilePath 'arp.exe' -Arguments '-a' -OutFile (Join-Path $netDir 'arp_a.txt') | Out-Null
}

# DNS
Invoke-CMD -FilePath 'ipconfig.exe' -Arguments '/displaydns' -OutFile (Join-Path $netDir 'DNS_Cache.txt') | Out-Null
try {
    $dnsClients = Get-DnsClient -ErrorAction SilentlyContinue
    if ($dnsClients) { Save-ObjectCsv $dnsClients (Join-Path $netDir 'DNS_ClientSettings.csv') }
    $dnsGlobal = Get-DnsClientGlobalSetting -ErrorAction SilentlyContinue
    if ($dnsGlobal) { Save-ObjectCsv $dnsGlobal (Join-Path $netDir 'DNS_GlobalSettings.csv') }
    $dnsCache = Get-DnsClientCache -ErrorAction SilentlyContinue
    if ($dnsCache) { Save-ObjectCsv $dnsCache (Join-Path $netDir 'DNS_CacheEntries.csv') }
}
catch {}

# TCP connections
try {
    $tcpConn = Get-NetTCPConnection -ErrorAction SilentlyContinue
    if ($tcpConn) { Save-ObjectCsv $tcpConn (Join-Path $netDir 'TCP_Connections.csv') }
}
catch {
    Invoke-CMD -FilePath 'netstat.exe' -Arguments '-ano' -OutFile (Join-Path $netDir 'netstat_ano.txt') | Out-Null
}
Invoke-CMD -FilePath 'netstat.exe' -Arguments '-s' -OutFile (Join-Path $netDir 'netstat_stats.txt') | Out-Null

# Proxy settings (HKCU + HKLM + WinHTTP)
try {
    $proxyReg = Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($proxyReg) {
        [PSCustomObject]@{
            Source        = 'HKCU Internet Settings'
            ProxyEnable   = $proxyReg.ProxyEnable
            ProxyServer   = $proxyReg.ProxyServer
            ProxyOverride = $proxyReg.ProxyOverride
            AutoConfigURL = $proxyReg.AutoConfigURL
        } | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $netDir 'Proxy_Settings_HKCU.csv')
    }
    $proxyMach = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($proxyMach) {
        [PSCustomObject]@{
            Source        = 'HKLM Internet Settings'
            ProxyEnable   = $proxyMach.ProxyEnable
            ProxyServer   = $proxyMach.ProxyServer
            ProxyOverride = $proxyMach.ProxyOverride
            AutoConfigURL = $proxyMach.AutoConfigURL
        } | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $netDir 'Proxy_Settings_HKLM.csv')
    }
}
catch {}
Invoke-CMD -FilePath 'netsh.exe' -Arguments 'winhttp show proxy' -OutFile (Join-Path $netDir 'Proxy_WinHTTP.txt') | Out-Null

# Winsock catalog
Invoke-CMD -FilePath 'netsh.exe' -Arguments 'winsock show catalog' -OutFile (Join-Path $netDir 'Winsock_Catalog.txt') | Out-Null

# Default gateway and internet connectivity tests
try {
    $gw = $null
    try {
        $gw = (Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1).IPv4DefaultGateway.NextHop
    }
    catch {}

    # Build target list with explicit Category labels
    $testTargets = [System.Collections.Generic.List[object]]::new()
    if ($gw) {
        $testTargets.Add([PSCustomObject]@{ Target = $gw;                         Category = 'DefaultGateway' })
    }
    else {
        $testTargets.Add([PSCustomObject]@{ Target = 'NO_GATEWAY_DETECTED';       Category = 'DefaultGateway' })
    }
    foreach ($inet in @('8.8.8.8','1.1.1.1','www.microsoft.com','windowsupdate.microsoft.com')) {
        $testTargets.Add([PSCustomObject]@{ Target = $inet; Category = 'Internet' })
    }

    $pingResults = foreach ($item in $testTargets) {
        $t = $item.Target
        if ($t -eq 'NO_GATEWAY_DETECTED') {
            [PSCustomObject]@{
                Category      = $item.Category
                Target        = $t
                PingSucceeded = $false
                RTT_ms        = $null
                NameResolved  = $null
                ResolvedIP    = $null
                Note          = 'No default gateway found'
            }
            continue
        }
        try {
            $r = Test-NetConnection -ComputerName $t -WarningAction SilentlyContinue -ErrorAction Stop
            [PSCustomObject]@{
                Category      = $item.Category
                Target        = $t
                PingSucceeded = $r.PingSucceeded
                RTT_ms        = $r.PingReplyDetails.RoundtripTime
                NameResolved  = $r.NameResolutionSucceeded
                ResolvedIP    = ($r.ResolvedAddresses -join ';')
                Note          = $null
            }
        }
        catch {
            $pingOut = & ping.exe -n 2 $t 2>&1
            [PSCustomObject]@{
                Category      = $item.Category
                Target        = $t
                PingSucceeded = (($pingOut -join ' ') -notmatch 'unreachable|timed out|could not find|Request timeout')
                RTT_ms        = $null
                NameResolved  = $null
                ResolvedIP    = $null
                Note          = 'Test-NetConnection unavailable; used ping.exe fallback'
            }
        }
    }
    Save-ObjectCsv $pingResults (Join-Path $netDir 'Connectivity_Tests.csv')
}
catch { Write-Warning "Connectivity test failed: $_" }

# DNS resolution tests
try {
    $dnsTargets = @('www.microsoft.com', 'www.google.com', 'windowsupdate.microsoft.com')
    $dnsResults = foreach ($dt in $dnsTargets) {
        try {
            $r = Resolve-DnsName -Name $dt -ErrorAction Stop | Select-Object -First 1
            [PSCustomObject]@{ Target = $dt; Resolved = $true; IPAddress = $r.IPAddress; QueryType = $r.Type }
        }
        catch {
            [PSCustomObject]@{ Target = $dt; Resolved = $false; IPAddress = $null; QueryType = $null }
        }
    }
    Save-ObjectCsv $dnsResults (Join-Path $netDir 'DNS_ResolutionTest.csv')
}
catch {}

# Domain Controller connectivity (only when domain-joined)
if ($cs -and $cs.PartOfDomain) {
    Write-Detail "Device is domain-joined ($($cs.Domain)) - running DC connectivity checks"
    $dcDir = Join-Path $netDir 'DomainController_Tests'
    $null = New-Item -ItemType Directory -Force -Path $dcDir | Out-Null

    # Discover DCs
    $dcList = @()
    try {
        $dcList = ([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()).DomainControllers |
            ForEach-Object { $_.Name }
    }
    catch {
        # nltest fallback
        try {
            $nltestOut = & nltest.exe /dclist:$($cs.Domain) 2>&1
            $dcList = $nltestOut | Where-Object { $_ -match '\\\\' } |
                ForEach-Object { ($_ -replace '.*\\\\', '').Trim().Split()[0] } |
                Where-Object { $_ -ne '' }
        }
        catch {}
    }

    if (-not $dcList) {
        "No domain controllers discovered for domain: $($cs.Domain)" |
            Out-File -FilePath (Join-Path $dcDir 'DC_Discovery_Failed.txt') -Encoding UTF8
        Write-Detail "DC discovery failed - skipping DC connectivity tests"
    }
    else {
        Write-Detail ("DCs discovered: {0}" -f ($dcList -join ', '))

        $dcResults = foreach ($dc in $dcList) {
            # --- Basic ping ---
            $pingOK = $false
            $rtt    = $null
            try {
                $r = Test-NetConnection -ComputerName $dc -WarningAction SilentlyContinue -ErrorAction Stop
                $pingOK = $r.PingSucceeded
                $rtt    = $r.PingReplyDetails.RoundtripTime
            }
            catch {
                $pingOut = & ping.exe -n 2 $dc 2>&1
                $pingOK  = (($pingOut -join ' ') -notmatch 'unreachable|timed out|could not find|Request timeout')
            }

            # --- SMB access to SYSVOL (port 445 + UNC path list) ---
            $smbPort    = $false
            $sysvolList = $false
            $sysvolErr  = $null
            try {
                $smbTnc  = Test-NetConnection -ComputerName $dc -Port 445 -WarningAction SilentlyContinue -ErrorAction Stop
                $smbPort = $smbTnc.TcpTestSucceeded
            }
            catch { $smbErr = $_.Exception.Message }

            if ($smbPort) {
                try {
                    $unc  = "\\$dc\SYSVOL"
                    $null = Get-ChildItem -LiteralPath $unc -ErrorAction Stop
                    $sysvolList = $true
                }
                catch { $sysvolErr = $_.Exception.Message }
            }

            # --- Kerberos (port 88) ---
            $kerberosPort = $false
            $kerberosAuth = $false
            $kerberosErr  = $null
            try {
                $kTnc         = Test-NetConnection -ComputerName $dc -Port 88 -WarningAction SilentlyContinue -ErrorAction Stop
                $kerberosPort = $kTnc.TcpTestSucceeded
            }
            catch { $kerberosErr = $_.Exception.Message }

            if ($kerberosPort) {
                # klist tgt: exit 0 means valid TGT (Kerberos auth working)
                try {
                    $klistOut = & klist.exe tgt 2>&1
                    $kerberosAuth = (($klistOut -join ' ') -match 'Cached Tickets|KerbTicket Expiration')
                }
                catch { $kerberosErr = "klist not available: $($_.Exception.Message)" }
            }

            [PSCustomObject]@{
                DomainController  = $dc
                PingSucceeded     = $pingOK
                RTT_ms            = $rtt
                SMB_Port445_Open  = $smbPort
                SYSVOL_Accessible = $sysvolList
                SYSVOL_Error      = $sysvolErr
                Kerberos_Port88   = $kerberosPort
                Kerberos_TGTValid = $kerberosAuth
                Kerberos_Error    = $kerberosErr
            }
        }

        Save-ObjectCsv $dcResults (Join-Path $dcDir 'DC_Connectivity.csv')
        Write-Detail ("DC connectivity results saved for {0} DCs" -f $dcList.Count)

        # nltest /sc_query: reports secure channel status
        Invoke-CMD -FilePath 'nltest.exe' -Arguments "/sc_query:$($cs.Domain)" -OutFile (Join-Path $dcDir 'NLTest_SecureChannel.txt') | Out-Null
        Invoke-CMD -FilePath 'nltest.exe' -Arguments '/dsgetdc:' -OutFile (Join-Path $dcDir 'NLTest_DsGetDc.txt') | Out-Null

        # klist: show all cached Kerberos tickets
        try { & klist.exe 2>&1 | Out-File -FilePath (Join-Path $dcDir 'Kerberos_Tickets.txt') -Encoding UTF8 -Force } catch {}
    }
}
else {
    Write-Detail "Device is not domain-joined - skipping DC connectivity checks"
    "Device is not domain-joined." | Out-File -FilePath (Join-Path $netDir 'DomainController_NotApplicable.txt') -Encoding UTF8
}

# Wi-Fi state and profiles
try {
    Invoke-CMD -FilePath 'netsh.exe' -Arguments 'wlan show profiles'          -OutFile (Join-Path $netDir 'WiFi_Profiles.txt')    | Out-Null
    Invoke-CMD -FilePath 'netsh.exe' -Arguments 'wlan show interfaces'        -OutFile (Join-Path $netDir 'WiFi_Interfaces.txt')  | Out-Null
    Invoke-CMD -FilePath 'netsh.exe' -Arguments 'wlan show networks mode=bssid'-OutFile (Join-Path $netDir 'WiFi_Networks.txt')   | Out-Null
}
catch {}

# Hosts file (common source of name-resolution issues)
try {
    $hostsPath = "$env:WINDIR\System32\drivers\etc\hosts"
    if (Test-Path $hostsPath) {
        Copy-Item $hostsPath (Join-Path $netDir 'hosts_file.txt') -Force -ErrorAction SilentlyContinue
    }
}
catch {}

# Network profile (Public/Private/Domain affects firewall)
try {
    $netProfiles = Get-NetConnectionProfile -ErrorAction SilentlyContinue
    if ($netProfiles) { Save-ObjectCsv $netProfiles (Join-Path $netDir 'NetworkProfiles.csv') }
}
catch {}

# SMB client settings (file share access issues)
try {
    $smbCfg = Get-SmbClientConfiguration -ErrorAction SilentlyContinue
    if ($smbCfg) { Save-ObjectCsv $smbCfg (Join-Path $netDir 'SMB_ClientConfig.csv') }
}
catch {}

Write-Detail "Network diagnostics collection completed"

# ============================================================================================
# 8. DISK & STORAGE
# ============================================================================================
Write-Section "Collecting disk and storage information"
$diskDir = Join-Path $OutDir 'Disk_Storage'
$null = New-Item -ItemType Directory -Force -Path $diskDir | Out-Null

try { Save-ObjectCsv (Get-PhysicalDisk) (Join-Path $diskDir 'PhysicalDisk.csv') } catch {}
try { Save-ObjectCsv (Get-Disk)         (Join-Path $diskDir 'Disk.csv')         } catch {}
try { Save-ObjectCsv (Get-Partition)    (Join-Path $diskDir 'Partition.csv')    } catch {}
try { Save-ObjectCsv (Get-Volume)       (Join-Path $diskDir 'Volume.csv')       } catch {}

# SMART status via WMI (Win7+)
try {
    $smart = Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction SilentlyContinue
    if ($smart) { Save-ObjectCsv $smart (Join-Path $diskDir 'SMART_FailurePredict.csv') }
}
catch {}

# Disk info via Win32_DiskDrive WMI (Win7+)
try {
    $wmiDisks = Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue
    if ($wmiDisks) {
        $wmiDisks | Select-Object Caption, Model, SerialNumber, Status, Size, MediaType, InterfaceType, FirmwareRevision |
            Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $diskDir 'DiskDrive_WMI.csv')
    }
}
catch {}

# Volume shadow copies
try {
    $vss = Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue
    if ($vss) { Save-ObjectCsv $vss (Join-Path $diskDir 'ShadowCopies.csv') }
    else { "No shadow copies found." | Out-File -FilePath (Join-Path $diskDir 'ShadowCopies_None.txt') -Encoding UTF8 }
}
catch {}

# Disk space summary
try {
    $fsDisks = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $null -ne $_.Used }
    if ($fsDisks) {
        $diskSpace = $fsDisks | ForEach-Object {
            $total = $_.Used + $_.Free
            [PSCustomObject]@{
                Drive       = $_.Name
                Root        = $_.Root
                UsedGB      = if ($total -gt 0) { [Math]::Round($_.Used / 1GB, 2) } else { 0 }
                FreeGB      = [Math]::Round($_.Free / 1GB, 2)
                TotalGB     = [Math]::Round($total / 1GB, 2)
                PercentFree = if ($total -gt 0) { [Math]::Round($_.Free / $total * 100, 1) } else { 0 }
            }
        }
        Save-ObjectCsv $diskSpace (Join-Path $diskDir 'DiskSpaceSummary.csv')
    }
}
catch {}

# Page file configuration and usage
try {
    $pf = Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue
    if ($pf) { Save-ObjectCsv $pf (Join-Path $diskDir 'PageFile_Config.csv') }
    $pfUsage = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
    if ($pfUsage) { Save-ObjectCsv $pfUsage (Join-Path $diskDir 'PageFile_Usage.csv') }
}
catch {}

# Temp folder sizes (disk pressure indicator)
try {
    $tempPaths = @($env:TEMP, $env:TMP, "$env:WINDIR\Temp") | Select-Object -Unique | Where-Object { Test-Path $_ }
    $tempSizes = foreach ($tp in $tempPaths) {
        try {
            $items = Get-ChildItem -Path $tp -Recurse -ErrorAction SilentlyContinue
            $sz    = ($items | Measure-Object -Property Length -Sum).Sum
            [PSCustomObject]@{
                Path   = $tp
                SizeMB = if ($sz) { [Math]::Round($sz / 1MB, 2) } else { 0 }
                Count  = ($items | Measure-Object).Count
            }
        }
        catch {}
    }
    if ($tempSizes) { Save-ObjectCsv $tempSizes (Join-Path $diskDir 'TempFolder_Sizes.csv') }
}
catch {}

Write-Detail "Disk and storage collection completed"

# ============================================================================================
# 9. MEMORY
# ============================================================================================
Write-Section "Collecting memory information"
$memDir = Join-Path $OutDir 'Memory'
$null = New-Item -ItemType Directory -Force -Path $memDir | Out-Null

# Physical RAM stick inventory
try {
    $physMem = Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue
    if ($physMem) {
        $physMem | Select-Object BankLabel, DeviceLocator, Capacity, Speed, Manufacturer, PartNumber, SerialNumber, MemoryType, SMBIOSMemoryType |
            Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $memDir 'PhysicalMemory.csv')
    }
}
catch {}

# OS memory state
try {
    $memOS = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($memOS) {
        [PSCustomObject]@{
            TotalVisibleMB = [Math]::Round($memOS.TotalVisibleMemorySize / 1KB, 2)
            FreePhysicalMB = [Math]::Round($memOS.FreePhysicalMemory / 1KB, 2)
            TotalVirtualMB = [Math]::Round($memOS.TotalVirtualMemorySize / 1KB, 2)
            FreeVirtualMB  = [Math]::Round($memOS.FreeVirtualMemory / 1KB, 2)
            UsedMB         = [Math]::Round(($memOS.TotalVisibleMemorySize - $memOS.FreePhysicalMemory) / 1KB, 2)
            MemUsagePct    = [Math]::Round(($memOS.TotalVisibleMemorySize - $memOS.FreePhysicalMemory) / $memOS.TotalVisibleMemorySize * 100, 1)
        } | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $memDir 'MemoryState.csv')
    }
}
catch {}

Write-Detail "Memory collection completed"

# ============================================================================================
# 10. PERFORMANCE COUNTERS
# ============================================================================================
$perfDir = Join-Path $OutDir 'Performance'
$null = New-Item -ItemType Directory -Force -Path $perfDir | Out-Null

if ($SkipPerformance) {
    Write-Section "Skipping performance collectors"
    "Performance collection skipped via -SkipPerformance." |
        Out-File -FilePath (Join-Path $perfDir 'PerformanceSkipped.txt') -Encoding UTF8 -Force
    Write-Detail "Performance counter collection skipped"
}
else {
    Write-Section "Sampling performance counters"

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
        '\TCPv4\Connections Established'
    )

    $allCounters = $cpuCounters + $memCounters + $diskCounters + $netCounters

    if ($ValidateCounters) {
        Write-Host "Validating counters (one-time probe) ..."
        $allCounters = Test-CounterPresent -Counters $allCounters
    }

    $maxSamples = [int][Math]::Ceiling(($DurationMinutes * 60) / [Math]::Max($SampleIntervalSeconds, 1))
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
        }
        catch { Write-Detail "BLG counter collection failed: $_" }
        try {
            Get-Counter -Counter $allCounters -SampleInterval $SampleIntervalSeconds -MaxSamples $maxSamples -ErrorAction Stop |
                Export-Counter -Path $csvPath -FileFormat CSV
        }
        catch { Write-Detail "CSV counter collection failed: $_" }
    }

    # Quick point-in-time snapshot
    try {
        $memOS  = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $cpuPct = $null; $cpuQ = $null; $pfPct = $null; $diskQ = $null
        try { $cpuPct = (Get-Counter '\Processor(_Total)\% Processor Time'              -ErrorAction Stop).CounterSamples.CookedValue } catch {}
        try { $cpuQ   = (Get-Counter '\System\Processor Queue Length'                    -ErrorAction Stop).CounterSamples.CookedValue } catch {}
        try { $pfPct  = (Get-Counter '\Paging File(_Total)\% Usage'                      -ErrorAction Stop).CounterSamples.CookedValue } catch {}
        try { $diskQ  = (Get-Counter '\PhysicalDisk(_Total)\Current Disk Queue Length'   -ErrorAction Stop).CounterSamples.CookedValue } catch {}
        [PSCustomObject]@{
            Timestamp           = (Get-Date)
            CPU_PercentTotal    = $cpuPct
            CPU_QueueLength     = $cpuQ
            Mem_AvailableMB     = if ($memOS) { $memOS.FreePhysicalMemory / 1KB } else { $null }
            PagingFile_UsagePct = $pfPct
            Disk_QueueLength    = $diskQ
        } | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $perfDir 'QuickSnapshot.csv')
    }
    catch {}

    Write-Detail "Performance counter collection completed"
}

# ============================================================================================
# 11. RELIABILITY MONITOR DATA
# ============================================================================================
Write-Section "Collecting reliability monitor data"
$reliDir = Join-Path $OutDir 'Reliability'
$null = New-Item -ItemType Directory -Force -Path $reliDir | Out-Null

try {
    $reliRecords = Get-CimInstance -ClassName Win32_ReliabilityRecords -ErrorAction Stop |
        Select-Object ComputerName, EventIdentifier, InsertionStrings, Logfile,
            Message, ProductName, RecordNumber, SourceName, TimeGenerated, User |
        Sort-Object TimeGenerated -Descending
    if ($reliRecords) {
        Save-ObjectCsv $reliRecords (Join-Path $reliDir 'ReliabilityRecords.csv')
        Write-Detail ("Reliability records collected: {0}" -f @($reliRecords).Count)
    }
}
catch { Write-Warning "Win32_ReliabilityRecords query failed: $_" }

try {
    $stability = Get-CimInstance -ClassName Win32_ReliabilityStabilityMetrics -ErrorAction Stop |
        Select-Object TimeGenerated, SystemStabilityIndex |
        Sort-Object TimeGenerated -Descending |
        Select-Object -First 30
    if ($stability) { Save-ObjectCsv $stability (Join-Path $reliDir 'StabilityIndex_Last30Days.csv') }
}
catch { Write-Warning "Win32_ReliabilityStabilityMetrics query failed: $_" }

Write-Detail "Reliability data collection completed"

# ============================================================================================
# 12. GROUP POLICY
# ============================================================================================
Write-Section "Collecting Group Policy (applied GPOs)"
$gpoDir = Join-Path $OutDir 'GroupPolicy'
$null = New-Item -ItemType Directory -Force -Path $gpoDir | Out-Null

# Text summary
Invoke-CMD -FilePath 'gpresult.exe' -Arguments '/R /SCOPE COMPUTER' -OutFile (Join-Path $gpoDir 'GPResult_Computer_Summary.txt') | Out-Null
Invoke-CMD -FilePath 'gpresult.exe' -Arguments '/R'                 -OutFile (Join-Path $gpoDir 'GPResult_Full_Summary.txt')     | Out-Null

# HTML and XML (full applied configuration)
$gpHtmlPath = Join-Path $gpoDir 'GPResult_Applied.html'
$gpXmlPath  = Join-Path $gpoDir 'GPResult_Applied.xml'
try { & gpresult.exe /H "$gpHtmlPath" /F 2>&1 | Out-Null } catch { Write-Warning "gpresult /H failed: $_" }
try { & gpresult.exe /X "$gpXmlPath"  /F 2>&1 | Out-Null } catch { Write-Warning "gpresult /X failed: $_" }

# Parse XML into CSV (applied GPO names, link order, scope)
try {
    if (Test-Path -LiteralPath $gpXmlPath) {
        [xml]$gpXml     = Get-Content -LiteralPath $gpXmlPath -Encoding UTF8 -ErrorAction Stop
        $appliedGpos    = New-Object System.Collections.Generic.List[object]

        foreach ($scope in @('ComputerResults','UserResults')) {
            $gpoNodes = $gpXml.Rsop.$scope.GPO
            if ($gpoNodes) {
                foreach ($gpo in $gpoNodes) {
                    $appliedGpos.Add([PSCustomObject]@{
                        Scope     = ($scope -replace 'Results','')
                        Name      = $gpo.Name
                        Enabled   = $gpo.Enabled
                        Allowed   = $gpo.FilterAllowed
                        LinkOrder = $gpo.Link.LinkOrder
                        SOMPath   = $gpo.Link.SOMPath
                    })
                }
            }
        }

        if ($appliedGpos.Count -gt 0) {
            Save-ObjectCsv $appliedGpos (Join-Path $gpoDir 'GPResult_AppliedGPOs.csv')
            Write-Detail ("Applied GPOs parsed: {0}" -f $appliedGpos.Count)
        }
        else {
            "gpresult XML contained no GPO nodes (workgroup device or XML parse issue)." |
                Out-File -FilePath (Join-Path $gpoDir 'GPResult_NoGPOs.txt') -Encoding UTF8
        }
    }
}
catch { Write-Warning "GPO XML parsing failed: $_" }

# Registry: effective policy values written by GPOs
try {
    $regPoliciesPath = Join-Path $gpoDir 'Registry_HKLM_SOFTWARE_Policies.reg'
    Invoke-CMD -FilePath 'reg.exe' -Arguments "export `"HKLM\SOFTWARE\Policies`" `"$regPoliciesPath`" /y" | Out-Null
} catch {}

try {
    $policyItems = Get-ChildItem -Path 'HKLM:\SOFTWARE\Policies' -Recurse -ErrorAction SilentlyContinue
    if ($policyItems) {
        $policyValues = foreach ($item in $policyItems) {
            try {
                $props = Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction SilentlyContinue
                if ($props) {
                    foreach ($prop in ($props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })) {
                        [PSCustomObject]@{
                            RegistryKey = ($item.PSPath -replace 'Microsoft.PowerShell.Core\\Registry::','')
                            ValueName   = $prop.Name
                            Value       = $prop.Value
                            ValueType   = $prop.TypeNameOfValue
                        }
                    }
                }
            }
            catch {}
        }
        if ($policyValues) { Save-ObjectCsv $policyValues (Join-Path $gpoDir 'Registry_HKLM_SOFTWARE_Policies.csv') }
    }
}
catch {}

Write-Detail "Group Policy collection completed"

# ============================================================================================
# 13. EVENT LOGS
# ============================================================================================
# (renumbered from 12; all section numbers below shift accordingly)
Write-Section "Exporting event logs"
$evDir = Join-Path $OutDir 'EventLogs'
$null = New-Item -ItemType Directory -Force -Path $evDir | Out-Null

$eventLogs = @(
    # Core OS
    'System',
    'Application',
    'Security',
    'Setup',

    # Windows Update & Servicing
    'Microsoft-Windows-WindowsUpdateClient/Operational',
    'Microsoft-Windows-Servicing/Operational',

    # BSOD / Kernel / Power
    'Microsoft-Windows-Kernel-Power/Operational',
    'Microsoft-Windows-Kernel-EventTracing/Admin',
    'Microsoft-Windows-Power-Troubleshooter/Operational',

    # Hardware errors: RAM, CPU, chipset (WHEA - key for diagnosing faulty hardware)
    'Microsoft-Windows-WHEA-Logger/Operational',

    # Slow boot, slow logon, slow app launch
    'Microsoft-Windows-Diagnostics-Performance/Operational',

    # App crashes and WER
    'Microsoft-Windows-WER-SystemErrorReporting/Operational',
    'Microsoft-Windows-WER-Diag/Operational',
    'Microsoft-Windows-Application-Experience/Program-Compatibility-Assistant',

    # Device and driver problems
    'Microsoft-Windows-DriverFrameworks-UserMode/Operational',
    'Microsoft-Windows-Kernel-PnP/Device Configuration',

    # Disk and storage
    'Microsoft-Windows-Ntfs/Operational',
    'Microsoft-Windows-Ntfs/WHC',
    'Microsoft-Windows-Disk/Operational',
    'Microsoft-Windows-Storage-Storport/Health',
    'Microsoft-Windows-Storage-Storport/Operational',
    'Microsoft-Windows-Volume/Diagnostic',

    # Network
    'Microsoft-Windows-NCSI/Operational',
    'Microsoft-Windows-NetworkProfile/Operational',
    'Microsoft-Windows-WLAN-AutoConfig/Operational',
    'Microsoft-Windows-DNS-Client/Operational',
    'Microsoft-Windows-NlaSvc/Operational',
    'Microsoft-Windows-Dhcp-Client/Admin',
    'Microsoft-Windows-Dhcp-Client/Operational',

    # Security / Defender / BitLocker
    'Microsoft-Windows-Windows Defender/Operational',
    'Microsoft-Windows-BitLocker/BitLocker Operational',
    'Microsoft-Windows-BitLocker-DrivePreparationTool/Operational',

    # Group Policy (can cause many issues on domain-joined clients)
    'Microsoft-Windows-GroupPolicy/Operational',

    # Task Scheduler (can cause high CPU, unexpected reboots)
    'Microsoft-Windows-TaskScheduler/Operational',
    'Microsoft-Windows-TaskScheduler/Maintenance',

    # Print (common communication issue)
    'Microsoft-Windows-PrintService/Admin',
    'Microsoft-Windows-PrintService/Operational',

    # User profile (login issues)
    'Microsoft-Windows-User Profile Service/Operational',

    # Windows Firewall
    'Microsoft-Windows-Windows Firewall With Advanced Security/Firewall',
    'Microsoft-Windows-Windows Firewall With Advanced Security/ConnectionSecurity'
)

$available = @{}
try { wevtutil el | ForEach-Object { $available[$_] = $true } }
catch { Write-Warning "Failed to enumerate event logs via wevtutil el: $_" }

$exported = New-Object System.Collections.Generic.List[string]
$skipped  = New-Object System.Collections.Generic.List[string]

foreach ($logName in ($eventLogs | Select-Object -Unique)) {
    try {
        if (-not $available.ContainsKey($logName)) { $skipped.Add($logName) | Out-Null; continue }
        $safeName = ($logName -replace '[\\/]', '_')
        $evtxPath = Join-Path $evDir "$safeName.evtx"
        wevtutil epl "$logName" "$evtxPath"
        $exported.Add($logName) | Out-Null
    }
    catch { $skipped.Add($logName) | Out-Null }
}

Write-Detail ("Event logs exported: {0}" -f $exported.Count)
Write-Detail ("Event logs skipped:  {0}" -f $skipped.Count)

@"
Event Log Export Summary
========================
Exported:
$( ($exported | ForEach-Object { "  - $_" }) -join "`n" )

Skipped (missing / disabled):
$( ($skipped | ForEach-Object { "  - $_" }) -join "`n" )
"@ | Out-File -FilePath (Join-Path $evDir 'FoundVsSkipped.txt') -Encoding UTF8

# ============================================================================================
# 13. EVTX AUTO-CONVERSION (CSV)
# ============================================================================================
Write-Section "Converting EVTX logs (CSV)"
$convDir = Join-Path $evDir 'Converted'
$null = New-Item -ItemType Directory -Force -Path $convDir | Out-Null

function Convert-EvtxForAnalytic {
    param([Parameter(Mandatory)][string]$EvtxPath)

    $baseName = [IO.Path]::GetFileNameWithoutExtension($EvtxPath)
    $csvPath  = Join-Path $convDir "$baseName.csv"
    $max      = [Math]::Max($EvtxMaxEvents, 1)
    $days     = [Math]::Max($EvtxDaysBack, 1)
    $start    = (Get-Date).AddDays(-$days)

    try {
        if ($IncludeEventMessage) {
            Get-WinEvent -Path $EvtxPath -MaxEvents $max -ErrorAction Stop |
                Where-Object { $_.TimeCreated -ge $start } |
                Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message |
                Export-Csv $csvPath -NoTypeInformation -Encoding UTF8
        }
        else {
            # Fast mode: omit Message text because rendering localized message strings is expensive.
            Get-WinEvent -Path $EvtxPath -MaxEvents $max -ErrorAction Stop |
                Where-Object { $_.TimeCreated -ge $start } |
                Select-Object TimeCreated, Id, LevelDisplayName, ProviderName |
                Export-Csv $csvPath -NoTypeInformation -Encoding UTF8
        }
    }
    catch {
        throw
    }
}

$evtxFiles = Get-ChildItem -Path $evDir -Filter *.evtx -ErrorAction SilentlyContinue
Write-Detail ("EVTX files found for conversion: {0}" -f @($evtxFiles).Count)
$conversionIssues = New-Object System.Collections.Generic.List[object]
for ($i = 0; $i -lt @($evtxFiles).Count; $i++) {
    $f = $evtxFiles[$i]
    Write-Verbose ("Converting EVTX [{0}/{1}]: {2}" -f ($i + 1), @($evtxFiles).Count, $f.Name)

    $baseName = [IO.Path]::GetFileNameWithoutExtension($f.FullName)
    $csvPath  = Join-Path $convDir "$baseName.csv"
    $max      = [Math]::Max($EvtxMaxEvents, 1)
    $days     = [Math]::Max($EvtxDaysBack, 1)
    $start    = (Get-Date).AddDays(-$days)
    $withMessage = $IncludeEventMessage.IsPresent

    # Pre-flight: check whether the file contains at least one event within the time window.
    # This avoids launching a background job for empty or out-of-window logs.
    $hasData = $false
    try {
        $probe = Get-WinEvent -Path $f.FullName -MaxEvents 1 -ErrorAction Stop |
            Where-Object { $_.TimeCreated -ge $start }
        $hasData = ($null -ne $probe)
    }
    catch {
        # NoMatchingEventsException means the log exists but has no events at all - skip silently.
        if ($_.Exception.GetType().Name -eq 'NoMatchingEventsException' -or
            $_.Exception.Message -match 'No events were found') {
            Write-Verbose ("Skipping {0}: no events in log" -f $f.Name)
        }
        else {
            # Unexpected read error - record it and move on.
            $conversionIssues.Add([PSCustomObject]@{
                File  = $f.FullName
                Name  = $f.Name
                Error = "Pre-flight read error: $($_.Exception.Message)"
                When  = Get-Date
            }) | Out-Null
            Write-Warning ("EVTX pre-flight failed for {0}: {1}" -f $f.Name, $_.Exception.Message)
        }
        continue
    }

    if (-not $hasData) {
        Write-Verbose ("Skipping {0}: no events within the last {1} days" -f $f.Name, $days)
        continue
    }

    $job = Start-Job -ScriptBlock {
        param(
            [string]$EvtxPath,
            [string]$CsvPath,
            [int]$Max,
            [datetime]$Start,
            [bool]$WithMessage
        )

        $ErrorActionPreference = 'Stop'
        if ($WithMessage) {
            Get-WinEvent -Path $EvtxPath -MaxEvents $Max -ErrorAction Stop |
                Where-Object { $_.TimeCreated -ge $Start } |
                Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message |
                Export-Csv $CsvPath -NoTypeInformation -Encoding UTF8
        }
        else {
            Get-WinEvent -Path $EvtxPath -MaxEvents $Max -ErrorAction Stop |
                Where-Object { $_.TimeCreated -ge $Start } |
                Select-Object TimeCreated, Id, LevelDisplayName, ProviderName |
                Export-Csv $CsvPath -NoTypeInformation -Encoding UTF8
        }
    } -ArgumentList $f.FullName, $csvPath, $max, $start, $withMessage

    $completed = Wait-Job -Job $job -Timeout ([Math]::Max($EvtxPerFileTimeoutSeconds, 10))
    if (-not $completed) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
        $conversionIssues.Add([PSCustomObject]@{
            File  = $f.FullName
            Name  = $f.Name
            Error = "Timed out after $EvtxPerFileTimeoutSeconds seconds"
            When  = Get-Date
        }) | Out-Null
        Write-Warning ("EVTX conversion timed out for {0} after {1}s" -f $f.Name, $EvtxPerFileTimeoutSeconds)
        continue
    }

    $jobState = $job.State
    if ($jobState -ne 'Completed') {
        $reason = $null
        try { $reason = $job.ChildJobs[0].JobStateInfo.Reason.Message } catch {}
        if (-not $reason) { $reason = "Job ended with state: $jobState" }
        $conversionIssues.Add([PSCustomObject]@{
            File  = $f.FullName
            Name  = $f.Name
            Error = $reason
            When  = Get-Date
        }) | Out-Null
        Write-Warning ("EVTX conversion failed for {0}: {1}" -f $f.Name, $reason)
    }

    # Drain job output/errors and remove job to avoid accumulation over many files.
    try { Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-Null } catch {}
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
}

if ($conversionIssues.Count -gt 0) {
    Save-ObjectCsv $conversionIssues (Join-Path $convDir 'ConversionIssues.csv')
}

[GC]::Collect()
[GC]::WaitForPendingFinalizers()

foreach ($f in $evtxFiles) { $null = Wait-ForFileUnlock -Path $f.FullName -RetryCount 40 -DelayMs 250 }
Write-Host "EVTX conversion complete. Files stored in: $convDir"
Write-Detail "EVTX conversion completed"

# ============================================================================================
# 14. ANALYTIC-READY PACK
# ============================================================================================
Write-Section "Assembling Analytic-Ready pack"
$crDir = Join-Path $OutDir 'Analytic-Ready'
$null = New-Item -ItemType Directory -Force -Path $crDir | Out-Null

$toCopy = @(
    (Join-Path $sysDir    'SystemSummary.csv'),
    (Join-Path $sysDir    'TopProcessesByCPU.csv'),
    (Join-Path $sysDir    'TopProcessesByMemory.csv'),
    (Join-Path $sysDir    'AutoServicesNotRunning.csv'),
    (Join-Path $sysDir    'InstalledApplications.csv'),
    (Join-Path $sysDir    'StartupPrograms.csv'),
    (Join-Path $sysDir    'UAC_Settings.csv'),
    (Join-Path $sysDir    'SecureBoot.txt'),
    (Join-Path $sysDir    'TimeSync.txt'),
    (Join-Path $patchDir  'HotFixes.csv'),
    (Join-Path $patchDir  'WUA_UpdateHistory.csv'),
    (Join-Path $patchDir  'WUA_PendingCount.txt'),
    (Join-Path $driverDir 'ProblemDevices.csv'),
    (Join-Path $driverDir 'Drivers_ThirdParty.csv'),
    (Join-Path $driverDir 'Drivers_ChangedLast30Days.csv'),
    (Join-Path $secDir    'WindowsDefender_Status.csv'),
    (Join-Path $secDir    'WindowsDefender_ThreatDetections.csv'),
    (Join-Path $secDir    'Firewall_Profiles.csv'),
    (Join-Path $secDir    'BitLocker_Status.csv'),
    (Join-Path $healthDir 'DISM_CheckHealth.txt'),
    (Join-Path $healthDir 'Logs\CBS_tail5000.log'),
    (Join-Path $crashDir  'BsodEvents_System.csv'),
    (Join-Path $crashDir  'CrashControl_Settings.csv'),
    (Join-Path $crashDir  'WER\WER_Parsed.csv'),
    (Join-Path $crashDir  'Minidumps\Minidump_Inventory.csv'),
    (Join-Path $netDir    'NetInterfaceSummary.csv'),
    (Join-Path $netDir    'Connectivity_Tests.csv'),
    (Join-Path $netDir    'DNS_ResolutionTest.csv'),
    (Join-Path $netDir    'Proxy_Settings_HKCU.csv'),
    (Join-Path $netDir    'Proxy_Settings_HKLM.csv'),
    (Join-Path $netDir    'Proxy_WinHTTP.txt'),
    (Join-Path $netDir    'hosts_file.txt'),
    (Join-Path $netDir    'Winsock_Catalog.txt'),
    (Join-Path $diskDir   'DiskSpaceSummary.csv'),
    (Join-Path $diskDir   'PhysicalDisk.csv'),
    (Join-Path $diskDir   'SMART_FailurePredict.csv'),
    (Join-Path $diskDir   'Volume.csv'),
    (Join-Path $diskDir   'PageFile_Config.csv'),
    (Join-Path $memDir    'PhysicalMemory.csv'),
    (Join-Path $memDir    'MemoryState.csv'),
    (Join-Path $perfDir   'QuickSnapshot.csv'),
    (Join-Path $perfDir   'PerfMeta.txt'),
    (Join-Path $reliDir   'ReliabilityRecords.csv'),
    (Join-Path $reliDir   'StabilityIndex_Last30Days.csv'),
    (Join-Path $gpoDir    'GPResult_Full_Summary.txt'),
    (Join-Path $gpoDir    'GPResult_AppliedGPOs.csv'),
    (Join-Path $gpoDir    'GPResult_Applied.xml'),
    (Join-Path $gpoDir    'Registry_HKLM_SOFTWARE_Policies.csv'),
    (Join-Path $netDir    'DomainController_Tests\DC_Connectivity.csv'),
    (Join-Path $netDir    'DomainController_Tests\NLTest_SecureChannel.txt'),
    (Join-Path $netDir    'DomainController_Tests\Kerberos_Tickets.txt')
)

foreach ($p in $toCopy) {
    if (Test-Path $p) { try { Copy-Item $p -Destination $crDir -Force -ErrorAction Stop } catch {} }
}

if (Test-Path $convDir) {
    $crEv = Join-Path $crDir 'EventLogs_Converted'
    $null = New-Item -ItemType Directory -Force -Path $crEv | Out-Null
    try { Copy-Item (Join-Path $convDir '*') -Destination $crEv -Force -ErrorAction Stop } catch {}
}

"Analytic-Ready pack created at: $crDir" | Out-File -FilePath (Join-Path $crDir 'README_Analytic.txt') -Encoding UTF8

# ============================================================================================
# 15. FINALIZE & ZIP
# ============================================================================================
Write-Section "Finalizing"
try {
    $allFiles = Get-ChildItem -Path $OutDir -File -Recurse -ErrorAction SilentlyContinue
    foreach ($af in $allFiles) { $null = Wait-ForFileUnlock -Path $af.FullName -RetryCount 40 -DelayMs 100 }
}
catch {}

$readme = @"
Windows Client Health & Diagnostics Collection (v1.7.2)
Computer:  $computer
Timestamp: $timestamp

Folders:
- System:            OS summary, hardware, BIOS, CPU, RAM, battery, power plan, UAC, Secure Boot,
                     TPM, startup programs, installed applications, environment variables
- PatchAndUpdate:    Installed hotfixes, WU history via COM, pending update count, Windows Update log,
                     SoftwareDistribution state
- DevicesAndDrivers: Problem devices (ConfigManagerErrorCode != 0), all device inventory,
                     driver inventory (third-party, recently changed last 30 days)
- Security:          Windows Defender status/threats/preferences, firewall profiles, BitLocker status,
                     AppLocker policy
- Health:            DISM CheckHealth, optional ScanHealth/SFC (-DeepHealth), CBS and DISM logs
- Crashes_BSOD:      Minidump files + inventory, WER artifacts (parsed .wer), full dump detection,
                     BSOD system events (41=unexpected reboot / 6008=unexpected shutdown / 1001=bugcheck),
                     CrashControl registry settings
- Network:           NIC summary, IP/routing/ARP/DNS state, DNS cache, TCP connections, proxy settings
                     (HKCU/HKLM/WinHTTP), Winsock catalog, Wi-Fi state, hosts file, network profiles,
                     connectivity tests (default gateway + internet), DNS resolution tests, SMB client config,
                     DomainController_Tests\: DC ping, SMB port 445, SYSVOL UNC access, Kerberos port 88,
                     TGT validity (klist), secure channel (nltest) - domain-joined only
- GroupPolicy:       gpresult /R text, /X XML, /H HTML; applied GPO names parsed to CSV;
                     HKLM\SOFTWARE\Policies registry dump (.reg + .csv)
- Disk_Storage:      Physical disk info, SMART failure predict, partition/volume inventory, shadow copies,
                     disk space summary, page file config/usage, temp folder sizes
- Memory:            Physical RAM slot inventory, OS memory state (used/free/commit)
- Performance:       Perf counters (.blg + .csv), quick point-in-time snapshot
- Reliability:       Win32_ReliabilityRecords, stability index (last 30 entries)
- EventLogs:         Exported .evtx channels; see FoundVsSkipped.txt
- EventLogs\Converted: EVTX converted to CSV (last -EvtxDaysBack days, capped by -EvtxMaxEvents)
- Analytic-Ready:    Key CSV/TXT files consolidated for upload and analysis

Key diagnostic event channels collected:
- WHEA-Logger/Operational     : hardware errors (RAM, CPU, chipset)
- Kernel-Power/Operational    : unexpected shutdowns/reboots
- Diagnostics-Performance     : slow boot, slow logon, slow app launch
- Disk/Operational            : disk I/O errors
- Ntfs/Operational            : file system errors
- NCSI/Operational            : network connectivity status changes
- Windows Defender/Operational: AV detections and scan events
- GroupPolicy/Operational     : policy application failures

Notes:
- Run with -DeepHealth to add DISM /ScanHealth and SFC /verifyonly.
- Run with -SelfTest to validate script syntax without collecting data.
- Tune EVTX speed/scope with -EvtxDaysBack (default 30) and -EvtxMaxEvents.
- Use -EvtxPerFileTimeoutSeconds to skip logs that hang during conversion.
- Use -IncludeEventMessage when you need full event text in CSV (slower conversion).
- If a specific EVTX file fails conversion, see EventLogs\Converted\ConversionIssues.csv.
- Windows 7 requires WMF 5.1. Where newer cmdlets are unavailable the script falls back to WMI and CLI tools.
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
                $relPath = $file.FullName.Substring($OutDir.Length).TrimStart('\', '/')
                $dest    = Join-Path $tempStage $relPath
                New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($dest)) | Out-Null
                Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
            }
            Compress-Archive -Path $tempStage -DestinationPath $zipPath -CompressionLevel Optimal
            Remove-Item $tempStage -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
        else {
            Compress-Archive -Path $OutDir -DestinationPath $zipPath -CompressionLevel Optimal
        }

        Write-Host "Done. Output folder: $OutDir"
        Write-Host "ZIP archive:         $zipPath"
        Write-Host "Analytic-Ready:      $crDir"
    }
    catch {
        Write-Warning "Failed to zip output: $_"
        Write-Host "Artifacts available at: $OutDir"
    }
}
else {
    Write-Host "ZIP creation skipped. Artifacts available at: $OutDir"
    Write-Host "Analytic-Ready:      $crDir"
}
