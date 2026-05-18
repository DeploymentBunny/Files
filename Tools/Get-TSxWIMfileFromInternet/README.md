# ESD Download Tools - Simple User Guide

This folder contains small scripts that help you:

- See available Windows installation files (ESD)
- Inspect which images exist inside an ESD file
- Download the file you want
- Convert ESD to WIM format now or later
- Refresh the Microsoft catalog list

This guide is written for non-IT staff and uses copy/paste examples.

## What you need before you start

- Windows PC with internet access
- PowerShell (built into Windows)
- Permission to download large files
- Enough free disk space (10 GB or more recommended)

Optional (only needed for ESD to WIM conversion):

- Administrator rights (recommended)
- DISM available (normally included in Windows)

## Files in this folder

- Show-TSxESDFiles.ps1: Lists available ESD files
- Get-TSxESDInfo.ps1: Shows which image indexes exist inside an ESD file
- Get-TSxESDDownloader.ps1: Downloads selected ESD and can optionally start conversion
- Convert-TSxToWIM.ps1: Converts an existing ESD file to WIM
- Update-TSxESDCatalogs.ps1: Updates local catalog XML files used by the list command

## First-time setup

1. Open PowerShell.
2. Go to this folder:

~~~powershell
Set-Location "C:\Path\To\Get-TSxWIMfileFromInternet"
~~~

3. If script execution is blocked, run this once in the same window:

~~~powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
~~~

## Typical workflow

1. Refresh the catalog list (optional but recommended).
2. List available ESD files.
3. Filter to the one you need.
4. Optional: Inspect image indexes inside the ESD file.
5. Download it.
6. Optional: Convert to WIM now or later.

---

## 1) Refresh catalog list

Use this to get the latest available media entries.

~~~powershell
.\Update-TSxESDCatalogs.ps1
~~~

If successful, it shows a table with catalog file names and paths.

## 2) List available ESD files

Show everything:

~~~powershell
.\Show-TSxESDFiles.ps1
~~~

Show only English, 64-bit:

~~~powershell
.\Show-TSxESDFiles.ps1 -Language en-us -Architecture amd64
~~~

Show Windows 11 24H2 entries:

~~~powershell
.\Show-TSxESDFiles.ps1 -Version 24H2
~~~

Output as JSON (for integrations):

~~~powershell
.\Show-TSxESDFiles.ps1 -AsJson
~~~

## 3) Inspect images inside an ESD file

Use this to see which image indexes exist before converting to WIM.

~~~powershell
.\Get-TSxESDInfo.ps1 -EsdPath "C:\Temp\ESD\install.esd"
~~~

Use downloaded output directly:

~~~powershell
$download = .\Get-TSxESDDownloader.ps1 -Url "https://example.com/install.esd"
$download | .\Get-TSxESDInfo.ps1
~~~

## 4) Download an ESD file

Downloads use the Windows Background Intelligent Transfer Service (BITS) when available.
This is usually better for large files and unstable connections. If BITS is not available,
the script falls back to the normal PowerShell web download method.

### Simple direct URL download

~~~powershell
.\Get-TSxESDDownloader.ps1 -Url "https://example.com/install.esd"
~~~

### Download first matching file from catalog

~~~powershell
$choice = .\Show-TSxESDFiles.ps1 -Language en-us -Architecture amd64 -Version 24H2 | Select-Object -First 1
$choice | .\Get-TSxESDDownloader.ps1 -OutputPath "C:\Temp\ESD"
~~~

### Force overwrite if file already exists

~~~powershell
$choice | .\Get-TSxESDDownloader.ps1 -OutputPath "C:\Temp\ESD" -Force
~~~

Download behavior when file already exists:

- If local and remote file sizes are the same, download is skipped.
- If sizes are different, the file is downloaded again.
- Use -Force to always overwrite and download again.

To see these decisions while running, use -Verbose:

~~~powershell
$choice | .\Get-TSxESDDownloader.ps1 -OutputPath "C:\Temp\ESD" -Verbose
~~~

## 5) Convert ESD to WIM (optional)

Use this only if you need WIM format.
The script now shows a progress bar during conversion. Add -Verbose if you also want status messages for each exported image.

Convert a file later from its ESD path:

~~~powershell
.\Convert-TSxToWIM.ps1 -EsdPath "C:\Temp\ESD\install.esd" -WimPath "C:\Temp\ESD\install.wim"
~~~

Convert only selected image indexes:

~~~powershell
.\Convert-TSxToWIM.ps1 -EsdPath "C:\Temp\ESD\install.esd" -WimPath "C:\Temp\ESD\install.wim" -Index 1,2,3
~~~

Convert directly from downloaded output:

~~~powershell
$download = $choice | .\Get-TSxESDDownloader.ps1 -OutputPath "C:\Temp\ESD"
$download | .\Convert-TSxToWIM.ps1 -Verbose
~~~

If you still want a single step, the downloader can start the converter for you:

~~~powershell
$choice = .\Show-TSxESDFiles.ps1 -Language en-us -Architecture amd64 -Version 24H2 | Select-Object -First 1
$choice | .\Get-TSxESDDownloader.ps1 -OutputPath "C:\Temp\ESD" -ConvertToWim -WimPath "C:\Temp\ESD\install.wim"
~~~

Single-step conversion with selected indexes:

~~~powershell
$choice = .\Show-TSxESDFiles.ps1 -Language en-us -Architecture amd64 -Version 24H2 | Select-Object -First 1
$choice | .\Get-TSxESDDownloader.ps1 -OutputPath "C:\Temp\ESD" -ConvertToWim -Index 1,2
~~~

## Useful filters (plain language)

- Language: en-us, sv-se, de-de, etc.
- Architecture: amd64 (most common), arm64
- Version: 22H2, 23H2, 24H2, build number, etc.
- OSLicense: Retail or Volume

Example:

~~~powershell
.\Show-TSxESDFiles.ps1 -Language en-us -Architecture amd64 -OSLicense Retail
~~~

## Where files are saved

Default download folder:

- Downloads subfolder under this tool folder

If you set OutputPath, files are saved there instead.

Log files are saved here for all scripts:

- %Temp%\TSxWimFileFromInternet

Each script writes to its own log file (for example, Get-TSxESDDownloader.log and Convert-TSxToWIM.log).

## Safety tips

- Download only from trusted sources.
- Keep enough free disk space before starting.
- Do not close PowerShell while a large download is running.
- Use -Force only when you really want to overwrite existing files.

## Troubleshooting

Script blocked:

~~~powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
~~~

No results found:

- Run Update-TSxESDCatalogs.ps1 first
- Remove some filters and try again

Download fails:

- Check internet connection
- Check URL is valid
- Try again with a different output folder

WIM conversion fails:

- Run PowerShell as Administrator
- Verify there is enough free disk space

ESD info read fails:

- Run PowerShell as Administrator
- If mounted image health check times out, the script will warn and continue

## Quick copy/paste examples

List and choose manually:

~~~powershell
$all = .\Show-TSxESDFiles.ps1 -Language en-us -Architecture amd64
$all | Format-Table OperatingSystem, OSVersion, OSLanguageCode, OSActivation, FileName -AutoSize
~~~

Download selected row number 2:

~~~powershell
$all = .\Show-TSxESDFiles.ps1 -Language en-us -Architecture amd64
$selected = $all | Select-Object -Index 1
$selected | .\Get-TSxESDDownloader.ps1 -OutputPath "C:\Temp\ESD"
~~~

Update catalogs then export list as JSON:

~~~powershell
.\Update-TSxESDCatalogs.ps1
.\Show-TSxESDFiles.ps1 -AsJson | Out-File "C:\Temp\esd-list.json" -Encoding utf8
~~~

Inspect indexes and then convert only one image:

~~~powershell
$info = .\Get-TSxESDInfo.ps1 -EsdPath "C:\Temp\ESD\install.esd"
$info | Format-Table ImageIndex, ImageName, ImageDescription -AutoSize
.\Convert-TSxToWIM.ps1 -EsdPath "C:\Temp\ESD\install.esd" -Index 1
~~~

## Version

Guide date: 2026-05-18
