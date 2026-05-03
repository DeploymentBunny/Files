<#
.SYNOPSIS
    Starts the RestPS listener interactively.

.DESCRIPTION
    Launches Start-RestPSListener with a specified routes file and port.
    Use this script to start RestPS manually in an interactive session for
    testing or development. For a persistent service-based deployment use
    StartRestPS.ps1 together with NSSM.

.EXAMPLE
    .\"Start RestPS.ps1"

.NOTES
    FileName:    Start RestPS.ps1
    Author:      Mikael Nystrom
    Contact:     deploymentbunny@outlook.com
    Created:     2026-04-28
    Updated:     2026-04-28
    Twitter:     @mikael_nystrom

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the author.
.LINK
    https://www.deploymentbunny.com
#>

#region Configuration
$TranscriptLog = 'C:\RestPSService\Start.log'
$RestPSLog     = 'C:\RestPSService\RestPS.log'
$Port          = 8080
$LogLevel      = 'ALL'
#endregion

#region Start transcript
# Ensure the log directory exists before writing.
$LogDir = Split-Path $TranscriptLog
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
Start-Transcript -Path $TranscriptLog -Append
#endregion

#region Import module
try {
    Import-Module RestPS -Force -Verbose -ErrorAction Stop
}
catch {
    Write-Error "Failed to import RestPS module: $_"
    Stop-Transcript
    exit 1
}
#endregion

#region Start listener
try {
    Start-RestPSListener -Port $Port -LogLevel $LogLevel -Logfile $RestPSLog -Verbose
}
catch {
    Write-Error "RestPS listener encountered an error: $_"
}
finally {
    Stop-Transcript
}
#endregion