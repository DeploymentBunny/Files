# Get-TSxLatestWindowsUpdate

Toolset to search and download the latest Windows cumulative updates from Microsoft Update Catalog.

## Included scripts

- `Get-TSxWindowsUpdateUI.ps1`: Windows Forms GUI for search and download.
- `Get-TSxWindowsUpdateList.ps1`: CLI script that returns catalog entries.
- `Save-TSxWindowsUpdateFromCatalog.ps1`: CLI script that downloads files from catalog entries.

## Logging

All scripts now log by default to:

`%TEMP%\Get-TSxLatestWindowsUpdate`

Default log files:

- `Get-TSxWindowsUpdate.log`
- `Get-TSxWindowsUpdateList.log`
- `Save-TSxWindowsUpdateFromCatalog.log`

Each script logs automatically to `%TEMP%\Get-TSxLatestWindowsUpdate\<script-name>.log`. `-Force` recreates the current script's log file content for that run.
No script in this folder accepts a `-LogPath` parameter.

## For users

### Option 1: GUI workflow

1. Run:

```powershell
.\Get-TSxWindowsUpdateUI.ps1 -Verbose
```

2. Enter Operating System (example: `Windows 11 24H2`).
3. Choose Architecture.
4. Click **Search**.
5. Select one or more updates.
6. Choose download folder.
7. Keep **WhatIf download** checked to simulate, or clear it to download.
8. Check **Force overwrite existing** only when you want to replace existing files.
9. Click **Download Selected**.

### Option 2: CLI quick flow

```powershell
$updates = .\Get-TSxWindowsUpdateList.ps1 -OperatingSystem 'Windows 11 24H2' -Architecture x64 -IncludeCumulative -IncludeDotNet -IncludeSSU -LatestOnly -Verbose
$updates | .\Save-TSxWindowsUpdateFromCatalog.ps1 -Path 'C:\Temp\Updates' -WhatIf -Verbose
```

Remove `-WhatIf` to perform real downloads.

## For IT Pros

### Automation pattern

```powershell
$os = 'Windows 11 24H2'
$arch = 'x64'
$target = 'D:\Packages\WindowsUpdates'

$updates = .\Get-TSxWindowsUpdateList.ps1 -OperatingSystem $os -Architecture $arch -IncludeCumulative -IncludeDotNet -IncludeSSU -LatestOnly -Verbose
$results = $updates | .\Save-TSxWindowsUpdateFromCatalog.ps1 -Path $target -Force -Verbose

$results | Format-Table UpdateType, UpdateId, KB, Architecture, FileName, DestinationPath, WasDownloaded, WasSkipped -AutoSize
```

### Parameter behavior

- `-Verbose`: detailed progress and decision logging.
- `-WhatIf`: simulates actions protected by `ShouldProcess`.
- `-Force`: recreates current log file content and overwrites existing destination files during download.

### Update categories (list script)

- `-IncludeCumulative`: includes LCU updates.
- `-IncludeDotNet`: includes .NET Framework cumulative updates.
- `-IncludeSSU`: includes servicing stack updates (when separate).
- `-IncludeDefender`: includes Defender-related updates.
- `-IncludeEdge`: includes Edge-related updates.
- `-IncludePreview`: includes preview updates; by default previews are excluded.
- `-IncludeInsider`: includes Windows Insider pre-release updates; by default Insider updates are excluded.

Default offline servicing profile:

- Enabled by default: `-IncludeCumulative`, `-IncludeDotNet`, `-IncludeSSU`
- Disabled by default: `-IncludeDefender`, `-IncludeEdge`, `-IncludePreview`, `-IncludeInsider`

### Typical operational recommendations

- Start with `-WhatIf` in new environments.
- Use `-Force` only for known replacement scenarios.
- Capture output objects and archive logs for audit/change records.

## Requirements

- Windows PowerShell 5.1+
- Internet access to `catalog.update.microsoft.com`

## Notes

- Catalog HTML structure can change over time. If parsing fails, review and update regex parsing logic.
- `-WhatIf` for list/search operations skips the web query by design and returns no catalog results.
