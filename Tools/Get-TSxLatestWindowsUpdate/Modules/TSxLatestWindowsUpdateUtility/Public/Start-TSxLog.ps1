function Start-TSxLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter()]
        [switch]$Force
    )

    $parentPath = Split-Path -Path $FilePath -Parent
    if (-not (Test-Path -Path $parentPath)) {
        $null = New-Item -Path $parentPath -ItemType Directory -Force
    }

    if (-not (Test-Path -Path $FilePath)) {
        $null = New-Item -Path $FilePath -ItemType File -Force
    }

    if ($Force) {
        Clear-Content -Path $FilePath -Force
    }

    $script:ScriptLogFilePath = $FilePath
}
