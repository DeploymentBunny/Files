<#
.SYNOPSIS
    Verifies that a running RestPS listener is responding correctly.

.DESCRIPTION
    Sends an HTTP GET request to the local RestPS endpoint and returns the
    result. Used to confirm that the RestPS service is up and accessible
    after installation or a restart.

.EXAMPLE
    .\"Test RestPS.ps1"

.NOTES
    FileName:    Test RestPS.ps1
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
$BaseUri   = 'http://localhost:8080'
$TestPath  = '/process?name=powershell'
$MaxRetries = 3
$RetryDelaySec = 2
#endregion

#region Test RestPS endpoint
Write-Host "Testing RestPS endpoint: $BaseUri$TestPath" -ForegroundColor Cyan

$RestMethodParams = @{
    Uri             = "$BaseUri$TestPath"
    Method          = 'Get'
    UseBasicParsing = $true
    ErrorAction     = 'Stop'
}

$Attempt = 0
$Success = $false

do {
    $Attempt++
    try {
        Write-Host "  Attempt $Attempt of $MaxRetries..." -ForegroundColor DarkGray
        $Response = Invoke-RestMethod @RestMethodParams
        $Success  = $true
        Write-Host "RestPS is responding correctly." -ForegroundColor Green
        $Response
    }
    catch {
        Write-Warning "  Attempt $Attempt failed: $($_.Exception.Message)"
        if ($Attempt -lt $MaxRetries) {
            Write-Host "  Retrying in $RetryDelaySec second(s)..." -ForegroundColor DarkGray
            Start-Sleep -Seconds $RetryDelaySec
        }
    }
} until ($Success -or ($Attempt -ge $MaxRetries))

if (-not $Success) {
    Write-Error "RestPS did not respond after $MaxRetries attempt(s). Verify the service is running."
    exit 1
}
#endregion
