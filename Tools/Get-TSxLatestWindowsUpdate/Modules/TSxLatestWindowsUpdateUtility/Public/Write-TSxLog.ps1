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
        throw 'LogFilePath is required when ScriptLogFilePath is not set.'
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = '[{0}] [{1}] {2}' -f $timestamp, $Level, $Message
    Add-Content -Path $LogFilePath -Value $entry

    if ($WriteVerbose -or $VerbosePreference -eq 'Continue') {
        Write-Verbose $entry
    }
}
