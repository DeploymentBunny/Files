
<#
.SYNOPSIS
    DiskSpd benchmark automation (v2.2 XML) with multi-pattern tests, graphs, and HTML report.

.DESCRIPTION
    Runs DiskSpd.exe against a single target path (local or UNC) with three random-mix workloads:
        - Random 60% Read / 40% Write
        - Random 70% Read / 30% Write
        - Random 80% Read / 20% Write

    The target can be:
        - A folder path (e.g., C:\Bench or \\server\share\Bench). The script creates a timestamped file inside it.
        - A file path (e.g., \\server\share\Bench\file.dat). The script uses that exact file.
        - A drive letter (e.g., "C" or "C:"). The script normalizes to "C:\" and creates a timestamped file there.

    Produces:
        - XML raw result per run (via -Rxml)
        - PNG graphs (IOPS over time, latency distribution)
        - CSV and JSON summary
        - Consolidated HTML report

.PARAMETER TargetPath
    The path to test. Can be a local folder, UNC folder, or a specific file path.

.PARAMETER Duration
    Duration of the measurement phase in seconds (DiskSpd warm-up defaults to 5s)

.PARAMETER BlockSizeKB
    Block size in KB

.PARAMETER Threads
    Threads per target (also used as queue depth (-o) to keep it simple)

.PARAMETER OutputPath
    Folder for outputs (XML, CSV, JSON, HTML, PNG)

.PARAMETER DiskSpdPath
    Full path to diskspd.exe if not in PATH

.EXAMPLE
    .\Run-DiskSpd.ps1 -TargetPath 'D:\Bench' -Duration 20 -BlockSizeKB 4 -Threads 2

.EXAMPLE
    .\Run-DiskSpd.ps1 -TargetPath '\\fileserver\share\bench' -Duration 30 -BlockSizeKB 8 -Threads 4

.EXAMPLE
    .\Run-DiskSpd.ps1 -TargetPath '\\server\share\bench\mytest.dat' -Duration 10
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$TargetPath = "$env:TEMP",

    [int]$Duration = 20,
    [int]$BlockSizeKB = 4,
    [int]$Threads = 2,
    [string]$OutputPath = "$PSScriptRoot\DiskSpdResults",
    [string]$DiskSpdPath = "diskspd.exe"
)

# ─────────────────────────────────────────────────────────────
# Setup
# ─────────────────────────────────────────────────────────────
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath | Out-Null
}

# Normalize drive-letter-only inputs (e.g., "C" or "C:")
if ($TargetPath -match '^[A-Za-z]:?$') {
    $TargetPath = ($TargetPath.TrimEnd(':') + ':\')
}

# Determine if TargetPath is a file or a folder.
# If it has an extension (and isn't an existing folder), treat as file.
$targetIsExplicitFile = $false
try {
    $targetIsExplicitFile = [System.IO.Path]::HasExtension($TargetPath) -and -not (Test-Path -LiteralPath $TargetPath -PathType Container)
} catch { $targetIsExplicitFile = $false }

# Ensure the container exists
if ($targetIsExplicitFile) {
    $parentDir = Split-Path -Path $TargetPath -Parent
    if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }
} else {
    if (-not (Test-Path -LiteralPath $TargetPath)) {
        New-Item -ItemType Directory -Path $TargetPath -Force | Out-Null
    }
}

# Safe label for filenames (replace characters invalid for filenames)
$safeName = ($TargetPath -replace '[:\\\/]+','_').Trim('_')
if (-not $safeName) { $safeName = 'root' }

$chartsAvailable = $true
try {
    Add-Type -AssemblyName System.Windows.Forms.DataVisualization -ErrorAction Stop
} catch {
    $chartsAvailable = $false
    Write-Warning "Charting assembly not found. Graphs will be skipped."
}

# Workload patterns
$patterns = @(
    #@{ Name="SeqRead";     Args=@("-si -w0")          },
    #@{ Name="SeqWrite";    Args=@("-si -w100")        },
    @{ Name="Random_60R_40W"; Args=@("-rs100","-w40") },
    @{ Name="Random_70R_30W"; Args=@("-rs100","-w30") },
    @{ Name="Random_80R_20W"; Args=@("-rs100","-w20") }
)

# Chart helper
function New-Chart {
    param(
        [string]$Title,
        [array]$X,
        [array]$Y,
        [string]$Path,
        [string]$XAxisLabel = "Sekund",
        [string]$YAxisLabel = "IOPS",
        [switch]$IsLatency
    )
    if (-not $script:chartsAvailable) { return }

    $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    $chart.Width = 1200
    $chart.Height = 600

    $area = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea "main"
    $area.AxisX.Title = $XAxisLabel
    $area.AxisY.Title = $YAxisLabel
    $chart.ChartAreas.Add($area)

    $chart.Titles.Add($Title) | Out-Null
    $series = New-Object System.Windows.Forms.DataVisualization.Charting.Series "s1"
    $series.ChartType = "Line"
    $series.BorderWidth = 2
    for ($i=0; $i -lt $X.Count; $i++) {
        [void]$series.Points.AddXY($X[$i], $Y[$i])
    }
    $chart.Series.Add($series) | Out-Null

    $chart.SaveImage($Path, "Png")
    $chart.Dispose()
}

$results = New-Object System.Collections.Generic.List[object]

# ─────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────
foreach ($pattern in $patterns) {
    $timestamp  = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

    # Determine the target file per pattern:
    #  - If user provided an explicit file path, use it as-is.
    #  - If user provided a folder, create a timestamped file inside it.
    if ($targetIsExplicitFile) {
        $targetFile = $TargetPath
    } else {
        $targetFile = Join-Path $TargetPath "diskspd_test_$timestamp.dat"
    }

    $xmlOut     = Join-Path $OutputPath "DiskSpd_${safeName}_${($pattern.Name)}_$timestamp.xml"

    # Build DiskSpd argument list (target LAST)
    $argsList = @(
        "-b$($BlockSizeKB)K",         # block size
        "-d$Duration",                # measurement duration
        "-o$Threads",                 # outstanding I/O per thread
        "-t$Threads",                 # threads per target
        "-Sh"                         # disable OS cache and enable write-through
    ) + $pattern.Args + @(
        "-c512M",                     # test file size
        "-L",                         # include latency stats
        "-D1000",                     # 1s IOPS buckets to XML
        "-Rxml",                      # results in XML to STDOUT (redirected below)
        $targetFile                   # target file (MUST be last)
    )

    Write-Host ("Running {0} on `{1}`: {2}" -f $pattern.Name, $TargetPath, ($argsList -join ' ')) -ForegroundColor Cyan

    # Execute DiskSpd (redirect STDOUT → XML file)
    $proc = Start-Process -FilePath $DiskSpdPath `
                          -ArgumentList $argsList `
                          -RedirectStandardOutput $xmlOut `
                          -NoNewWindow -PassThru -Wait

    if ($proc.ExitCode -ne 0) {
        Write-Warning "DiskSpd exited with code $($proc.ExitCode) for $TargetPath / $($pattern.Name). Skipping parse."
        continue
    }

    # Parse XML (DiskSpd 2.2 structure)
    [xml]$xml = Get-Content -LiteralPath $xmlOut -Raw
    $ts = $xml.Results.TimeSpan

    # ---- Compute IOPS from <Iops><Bucket> attributes (sum over buckets / duration) ----
    $readIopsTotal  = ($ts.Iops.Bucket | Measure-Object -Property Read  -Sum).Sum
    $writeIopsTotal = ($ts.Iops.Bucket | Measure-Object -Property Write -Sum).Sum
    $readIops  = [math]::Round(($readIopsTotal  / [double]$Duration), 2)
    $writeIops = [math]::Round(($writeIopsTotal / [double]$Duration), 2)

    # ---- Compute MB/s from per-thread target byte totals ----
    $readBytes  = ($ts.Thread.Target.ReadBytes  | Measure-Object -Sum).Sum
    $writeBytes = ($ts.Thread.Target.WriteBytes | Measure-Object -Sum).Sum
    $readMBps   = [math]::Round(( [double]$readBytes  / 1MB / $Duration), 2)
    $writeMBps  = [math]::Round(( [double]$writeBytes / 1MB / $Duration), 2)

    # ---- Average latency (ms) from summary nodes ----
    $avgReadLatencyMs  = $null
    $avgWriteLatencyMs = $null
    if ($ts.Latency.AverageReadMilliseconds)  { $avgReadLatencyMs  = [math]::Round([double]$ts.Latency.AverageReadMilliseconds, 3) }
    if ($ts.Latency.AverageWriteMilliseconds) { $avgWriteLatencyMs = [math]::Round([double]$ts.Latency.AverageWriteMilliseconds, 3) }

    # Capture results object
    $results.Add([PSCustomObject]@{
        Target        = $TargetPath
        Test          = $pattern.Name
        Timestamp     = Get-Date
        BlockKB       = $BlockSizeKB
        DurationSec   = $Duration
        ReadIOPS      = $readIops
        WriteIOPS     = $writeIops
        ReadMBps      = $readMBps
        WriteMBps     = $writeMBps
        ReadLatencyMs = $avgReadLatencyMs
        WriteLatencyMs= $avgWriteLatencyMs
        XmlFile       = (Split-Path -Leaf $xmlOut)
    })

    # ─────────────────────────────────────────────────────────────
    # Graphs
    # ─────────────────────────────────────────────────────────────

    # IOPS over time
    if ($chartsAvailable -and $ts.Iops.Bucket) {
        $buckets = @($ts.Iops.Bucket)
        $times = $buckets | ForEach-Object { [int]($_.SampleMillisecond / 1000) }
        $totalIops = $buckets | ForEach-Object { [int]$_.Total }
        $iopsChartPath = Join-Path $OutputPath "Graph_IOPS_${safeName}_${($pattern.Name)}_$timestamp.png"
        New-Chart -Title "IOPS över tid - $safeName $($pattern.Name)" `
                  -X $times -Y $totalIops `
                  -Path $iopsChartPath `
                  -XAxisLabel "Sekund" -YAxisLabel "IOPS"
    }

    # Latency distribution
    if ($chartsAvailable -and $ts.Latency.Bucket) {
        $lb = @($ts.Latency.Bucket)
        $pct = $lb | ForEach-Object { [double]$_.Percentile }
        $latMs = $lb | ForEach-Object {
            if ($_.TotalMilliseconds) { [double]$_.TotalMilliseconds }
            elseif ($_.ReadMilliseconds) { [double]$_.ReadMilliseconds }
            else { 0 }
        }
        $latChartPath = Join-Path $OutputPath "Graph_Latens_${safeName}_${($pattern.Name)}_$timestamp.png"
        New-Chart -Title "Latensfördelning (percentiler) - $safeName $($pattern.Name)" `
                  -X $pct -Y $latMs `
                  -Path $latChartPath `
                  -XAxisLabel "Percentil" -YAxisLabel "Latency (ms)" -IsLatency
    }

    # Cleanup test file (works for UNC too)
    Remove-Item -LiteralPath $targetFile -Force -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────
# EXPORT SUMMARY
# ─────────────────────────────────────────────────────────────
$runStamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$csv  = Join-Path $OutputPath "DiskSpd_Summary_$runStamp.csv"
$json = Join-Path $OutputPath "DiskSpd_Summary_$runStamp.json"

$results | Sort-Object Target, Test | Export-Csv -Path $csv -NoTypeInformation
$results | ConvertTo-Json -Depth 4 | Out-File -LiteralPath $json -Encoding UTF8

Write-Host "`n===== Completed Test Suite =====" -ForegroundColor Green
$results | Format-Table Target, Test, ReadIOPS, WriteIOPS, ReadMBps, WriteMBps, ReadLatencyMs, WriteLatencyMs

# ─────────────────────────────────────────────────────────────
# HTML REPORT GENERATION
# ─────────────────────────────────────────────────────────────
$HtmlReport = Join-Path $OutputPath "DiskSpd_Report_$runStamp.html"

$css = @"
body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; background: #f5f5f5; }
h1 { color: #003366; }
h2 { color: #004080; margin-top: 30px; }
h3 { color: #004080; margin-top: 20px; }
table { border-collapse: collapse; width: 100%; margin-bottom: 20px; background: #fff; }
th, td { border: 1px solid #ddd; padding: 8px 10px; text-align: left; }
th { background: #eaeaea; }
.section { background: #fff; padding: 18px; border-radius: 8px; margin: 16px 0 30px 0;
           box-shadow: 0 2px 4px rgba(0,0,0,0.08); }
.graph { margin: 16px 0; text-align: center; background: #fff; }
.graph img { max-width: 100%; height: auto; border: 1px solid #ddd; border-radius: 4px; }
.footer { margin-top: 40px; font-size: 12px; color: #777; }
.meta { margin-bottom: 12px; }
code { background:#f0f0f0; padding:2px 4px; border-radius:4px; }
"@

$html = @"
<html>
<head>
    <meta charset='utf-8' />
    <title>DiskSpd Benchmark Report - $runStamp</title>
    <style>$css</style>
</head>
<body>
<h1>DiskSpd Benchmark Report</h1>
<div class='meta'>
  <p><strong>Generated:</strong> $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</p>
  <p><strong>Test Duration:</strong> $Duration s &nbsp;|&nbsp; <strong>Block Size:</strong> $BlockSizeKB KB &nbsp;|&nbsp; <strong>Threads/Target:</strong> $Threads</p>
  <p><strong>Output folder:</strong> <code>$OutputPath</code></p>
  <p><strong>Target:</strong> <code>$TargetPath</code></p>
</div>

<div class='section'>
<h2>Summary</h2>
<table>
    <thead>
        <tr>
            <th>Target</th>
            <th>Test Pattern</th>
            <th>Read IOPS</th>
            <th>Write IOPS</th>
            <th>Read MB/s</th>
            <th>Write MB/s</th>
            <th>Read Lat (ms)</th>
            <th>Write Lat (ms)</th>
            <th>XML</th>
        </tr>
    </thead>
    <tbody>
"@

foreach ($r in ($results | Sort-Object Target, Test)) {
    $xmlName = $r.XmlFile
    $html += @"
        <tr>
            <td>$($r.Target)</td>
            <td>$($r.Test)</td>
            <td>$($r.ReadIOPS)</td>
            <td>$($r.WriteIOPS)</td>
            <td>$($r.ReadMBps)</td>
            <td>$($r.WriteMBps)</td>
            <td>$($r.ReadLatencyMs)</td>
            <td>$($r.WriteLatencyMs)</td>
            <td><a href='$xmlName'>$xmlName</a></td>
        </tr>
"@
}

$html += @"
    </tbody>
</table>
</div>
"@

# Per-target/pattern sections with graphs
$patternNames = $patterns | ForEach-Object { $_.Name }

foreach ($patternName in $patternNames) {
    $xmlFile   = Get-ChildItem -LiteralPath $OutputPath -Filter "DiskSpd_${safeName}_${patternName}_*.xml"   | Sort-Object LastWriteTime | Select-Object -Last 1
    $iopsGraph = Get-ChildItem -LiteralPath $OutputPath -Filter "Graph_IOPS_${safeName}_${patternName}_*.png" | Sort-Object LastWriteTime | Select-Object -Last 1
    $latGraph  = Get-ChildItem -LiteralPath $OutputPath -Filter "Graph_Latens_${safeName}_${patternName}_*.png"| Sort-Object LastWriteTime | Select-Object -Last 1

    if (-not $xmlFile -and -not $iopsGraph -and -not $latGraph) { continue }

    $html += @"
<div class='section'>
  <h2>$safeName — $patternName</h2>
"@

    if ($xmlFile) {
        $html += @"
  <p><strong>XML Raw Output:</strong> <a href='$($xmlFile.Name)'>$($xmlFile.Name)</a></p>
"@
    }

    if ($iopsGraph) {
        $html += @"
  <div class='graph'>
    <h3>IOPS över tid</h3>
    <img src='$($iopsGraph.Name)' alt='IOPS graph' />
  </div>
"@
    }

    if ($latGraph) {
        $html += @"
  <div class='graph'>
    <h3>Latensfördelning (percentiler)</h3>
    <img src='$($latGraph.Name)' alt='Latency graph' />
  </div>
"@
    }

    $html += "</div>`n"
}

$html += @"
<div class='footer'>
  Generated by automated DiskSpd test suite • Report timestamp: $runStamp
</div>
</body>
</html>
"@

$html | Out-File -FilePath $HtmlReport -Encoding UTF8
Write-Host "HTML report saved to: $HtmlReport" -ForegroundColor Yellow
