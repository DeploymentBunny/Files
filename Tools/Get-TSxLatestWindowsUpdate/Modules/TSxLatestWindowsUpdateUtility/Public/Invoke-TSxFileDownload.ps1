function Invoke-TSxFileDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$UpdateId,

        [Parameter()]
        [string]$UpdateName
    )

    $displayName = if ([string]::IsNullOrWhiteSpace($UpdateName)) { $UpdateId } else { $UpdateName }

    $progressId = [Math]::Abs($DestinationPath.GetHashCode())
    if ($progressId -eq 0) { $progressId = 1 }

    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = 'GET'

    $response = $null
    $responseStream = $null
    $fileStream = $null
    $originalProgressPreference = $ProgressPreference
    $lastPercentPrinted = -1
    $lastIsePercentPrinted = -10
    $printedInlineProgress = $false
    $isIseHost = $Host.Name -match '(?i)ISE'
    $useInlineConsoleProgress = -not $isIseHost

    try {
        $ProgressPreference = 'Continue'
        if ($useInlineConsoleProgress) {
            Write-Host ('Starting download: {0} (UpdateId: {1})' -f $displayName, $UpdateId)
        }
        $response = $request.GetResponse()
        $responseStream = $response.GetResponseStream()
        $fileStream = [System.IO.File]::Open($DestinationPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

        $buffer = New-Object byte[] 81920
        $totalBytes = [int64]$response.ContentLength
        $totalRead = [int64]0

        while (($bytesRead = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $bytesRead)
            $totalRead += $bytesRead

            if ($totalBytes -gt 0) {
                $percentComplete = [int](($totalRead * 100) / $totalBytes)
                $status = '{0:N1} MB / {1:N1} MB' -f ($totalRead / 1MB), ($totalBytes / 1MB)
                Write-Progress -Id $progressId -Activity ('Downloading: {0}' -f $displayName) -Status $status -PercentComplete $percentComplete

                if ($useInlineConsoleProgress -and $percentComplete -ne $lastPercentPrinted) {
                    Write-Host -NoNewline ("`rDownloading {0}: {1,3}% ({2})" -f $displayName, $percentComplete, $status)
                    $lastPercentPrinted = $percentComplete
                    $printedInlineProgress = $true
                }

                if ($isIseHost -and $percentComplete -ge ($lastIsePercentPrinted + 10)) {
                    Write-Verbose ('Downloading {0}: {1}% ({2})' -f $displayName, $percentComplete, $status)
                    $lastIsePercentPrinted = $percentComplete
                }
            }
        }

        if ($printedInlineProgress -and $useInlineConsoleProgress) {
            Write-Host ''
        }

        if ($totalBytes -gt 0) {
            Write-Progress -Id $progressId -Activity ('Downloading: {0}' -f $displayName) -Completed
        }

        Write-Host ('Completed download: {0} ({1:N1} MB)' -f $displayName, ($totalRead / 1MB))
        return $true
    }
    catch {
        Write-TSxLog -Level 'ERROR' -Message ('Download failed for {0} (UpdateId: {1}): {2}' -f $displayName, $UpdateId, $_.Exception.Message)
        throw
    }
    finally {
        if ($fileStream) { $fileStream.Dispose() }
        if ($responseStream) { $responseStream.Dispose() }
        if ($response) { $response.Dispose() }
        $ProgressPreference = $originalProgressPreference
    }
}
