# Measure-DiskPerf Tools

This folder contains two scripts:

- Measure-DiskPerf.ps1: command-line benchmark runner.
- Measure-DiskPerfwUI.ps1: Windows Forms launcher for the benchmark runner.

## Overview

Measure-DiskPerf.ps1 runs DiskSpd workloads against a target path and produces:

- Raw XML output from DiskSpd
- CSV and JSON summaries
- PNG graphs
- Consolidated HTML report

Measure-DiskPerfwUI.ps1 provides a graphical front-end to configure and run Measure-DiskPerf.ps1 and optionally open the latest report.

## Files

- Measure-DiskPerf.ps1
- Measure-DiskPerfwUI.ps1

## Prerequisites

- Windows PowerShell 5.1 or later.
- DiskSpd available as diskspd.exe in PATH, or an explicit full path to diskspd.exe.
- Write access to the selected output directory.
- For graph generation in Measure-DiskPerf.ps1: System.Windows.Forms.DataVisualization assembly must be available.

## Script 1: Measure-DiskPerf.ps1

### Purpose

Runs three random mixed read/write workloads and collects performance results.

### Workload Patterns

- Random_60R_40W
- Random_70R_30W
- Random_80R_20W

### Parameters

- TargetPath (string, optional)
  - Default: $env:TEMP
  - Accepts:
    - Folder path (local or UNC)
    - File path (local or UNC)
    - Drive letter only (for example C or C:)
- Duration (int, optional)
  - Default: 120
  - Benchmark duration in seconds.
- BlockSizeKB (int, optional)
  - Default: 4
  - Block size in KB.
- Threads (int, optional)
  - Default: 2
  - Used as both threads per target and outstanding IO depth.
- OutputPath (string, optional)
  - Default: $env:TEMP\DiskSpdResults
  - Directory where all outputs are written.
- DiskSpdPath (string, optional)
  - Default: diskspd.exe
  - Full path to diskspd.exe, or executable name when available in PATH.

### TargetPath Handling

- If TargetPath is a drive letter only, it is normalized to drive root (for example C: becomes C:\).
- If TargetPath looks like a file path, that file path is used directly.
- If TargetPath is a folder path, a timestamped test file is created inside it.

### Output Files

All artifacts are written to OutputPath:

- DiskSpd_<target>_<pattern>_<timestamp>.xml
- Graph_IOPS_<target>_<pattern>_<timestamp>.png
- Graph_Latency_<target>_<pattern>_<timestamp>.png
- DiskSpd_Summary_<timestamp>.csv
- DiskSpd_Summary_<timestamp>.json
- DiskSpd_Report_<timestamp>.html

### Example Commands

Run against a local folder:

```powershell
.\Measure-DiskPerf.ps1 -TargetPath 'D:\Bench' -Duration 60 -BlockSizeKB 4 -Threads 2
```

Run against a UNC folder:

```powershell
.\Measure-DiskPerf.ps1 -TargetPath '\\fileserver\share\bench' -Duration 30 -BlockSizeKB 8 -Threads 4
```

Run against a specific file path:

```powershell
.\Measure-DiskPerf.ps1 -TargetPath '\\server\share\bench\mytest.dat' -Duration 10
```

### Notes

- DiskSpd arguments are built so the target file is passed last.
- Test file size is fixed at 512 MB per run.
- Test file cleanup is attempted after each run.
- If charting assembly is unavailable, graph generation is skipped and data files are still produced.

## Script 2: Measure-DiskPerfwUI.ps1

### Purpose

Provides a graphical interface for launching Measure-DiskPerf.ps1.

### Features

- Select target path (local folder browser or manual UNC path entry).
- Select diskspd.exe path.
- Configure duration, block size, threads, and output path.
- Run Measure-DiskPerf.ps1 with the selected settings.
- Option to open the latest generated HTML report in the default browser.
- Persist last-used settings.
- Write a per-run log file.

### Persisted Settings

Settings are stored at:

- %LOCALAPPDATA%\DeploymentBunny\Measure-DiskPerfwUI.settings.json

### Log File

A log file is written to:

- %TEMP%\Measure-DiskPerfwUI_yyyyMMdd_HHmmss.log

### How To Launch

From this folder:

```powershell
.\Measure-DiskPerfwUI.ps1
```

### Runtime Validation Performed By UI

- Verifies Measure-DiskPerf.ps1 exists in the same folder.
- Requires a non-empty target path.
- Requires a non-empty diskspd path and verifies the file exists.
- Requires a non-empty output path and attempts to create the folder if missing.

### UI Defaults

- TargetPath: $env:TEMP
- DiskSpdPath: diskspd.exe
- OutputPath: $env:TEMP\DiskSpdResults
- Duration: 120
- BlockSizeKB: 4
- Threads: 2
- Open report after run: true

## Typical Workflow

1. Start Measure-DiskPerfwUI.ps1.
2. Set target path and diskspd.exe path.
3. Set duration, block size, threads, and output path.
4. Run benchmark.
5. Review DiskSpd_Report_<timestamp>.html in output folder.

## Troubleshooting

- Error: diskspd.exe was not found
  - Select the correct full path to diskspd.exe in the UI or provide a valid path in the script parameter.
- No charts are generated
  - The charting assembly is unavailable on the host. XML/CSV/JSON/HTML outputs can still be generated.
- No HTML report opens automatically
  - Ensure Open report in default browser is checked and verify a report exists in OutputPath.
- Script cannot write outputs
  - Verify permissions to TargetPath and OutputPath.

## Security and Operational Notes

- Benchmarks generate sustained disk IO and can affect workload performance while running.
- Use controlled test windows on production systems.
- Validate free space on target and output locations before long runs.
