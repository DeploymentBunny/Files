function Write-TSxLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',

        [Parameter()]
        [string]$LogFilePath,

        [Parameter()]
        [switch]$WriteVerbose
    )

    if ([string]::IsNullOrWhiteSpace($LogFilePath)) {
        $LogFilePath = $script:ScriptLogFilePath
    }

    if ([string]::IsNullOrWhiteSpace($LogFilePath)) {
        $tempRoot = if ([string]::IsNullOrWhiteSpace($env:TEMP)) { [System.IO.Path]::GetTempPath() } else { $env:TEMP }
        $fallbackRoot = Join-Path -Path $tempRoot -ChildPath 'Get-TSxLatestWindowsUpdate'
        if (-not (Test-Path -Path $fallbackRoot)) {
            $null = New-Item -Path $fallbackRoot -ItemType Directory -Force
        }

        $LogFilePath = Join-Path -Path $fallbackRoot -ChildPath 'TSxWindowsUpdateUtility.log'
        if (-not (Test-Path -Path $LogFilePath)) {
            $null = New-Item -Path $LogFilePath -ItemType File -Force
        }

        # Persist fallback path for this module scope/runspace so later calls do not need to reinitialize.
        $script:ScriptLogFilePath = $LogFilePath
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = '[{0}] [{1}] {2}' -f $timestamp, $Level, $Message
    Add-Content -Path $LogFilePath -Value $entry

    if ($WriteVerbose -or $VerbosePreference -eq 'Continue') {
        Write-Verbose $entry
    }
}
