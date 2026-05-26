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
        [string]$UpdateName,

        [Parameter()]
        [switch]$UiProgress,

        [Parameter()]
        [bool]$EmitNativeProgress = $true,

        [Parameter()]
        [switch]$UseLegacyTranser
    )

    $displayName = if ([string]::IsNullOrWhiteSpace($UpdateName)) { $UpdateId } else { $UpdateName }

    $progressId = [Math]::Abs($DestinationPath.GetHashCode())
    if ($progressId -eq 0) { $progressId = 1 }

    $emitProgress = [bool]$EmitNativeProgress
    $lastUiPercent = -1
    $lastUiTick = [datetime]::MinValue
    $isIseHost = (Get-TSxExecutionContext) -eq 'ISE'

    function Get-TSxShortErrorMessage {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Message,

            [Parameter()]
            [int]$MaxLength = 180
        )

        $normalized = (($Message -replace '\s+', ' ').Trim())
        if ($normalized.Length -le $MaxLength) {
            return $normalized
        }

        return ('{0}...' -f $normalized.Substring(0, $MaxLength))
    }

    function Write-TSxUiProgressMessage {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Message
        )

        if ($UiProgress) {
            if ($isIseHost) {
                # ISE can buffer information records in nested calls; host output stays live.
                Write-Host $Message
            }
            else {
                Write-Information -MessageData $Message
            }
            return
        }

        if ($isIseHost) {
            Write-Host $Message
        }
    }

    function Invoke-TSxLegacyHttpTransfer {
        $response = $null
        $responseStream = $null
        $fileStream = $null
        $originalProgressPreference = $ProgressPreference

        try {
            if ($emitProgress) {
                $ProgressPreference = 'Continue'
            }

            Write-Verbose ('Starting legacy HTTP download: {0} (UpdateId: {1})' -f $displayName, $UpdateId)
            $request = [System.Net.HttpWebRequest]::Create($Url)
            $request.Method = 'GET'
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
                    if ($emitProgress) {
                        Write-Progress -Id $progressId -Activity ('Downloading: {0}' -f $displayName) -Status $status -PercentComplete $percentComplete
                    }
                    if ($UiProgress -and ($percentComplete -ge ($lastUiPercent + 5) -or $percentComplete -eq 100)) {
                        $lastUiPercent = $percentComplete
                        Write-TSxUiProgressMessage -Message ('Download progress [{0}]: {1}% ({2})' -f $displayName, $percentComplete, $status)
                    }
                }
                elseif ($UiProgress -and ([datetime]::UtcNow - $lastUiTick).TotalSeconds -ge 1) {
                    $lastUiTick = [datetime]::UtcNow
                    Write-TSxUiProgressMessage -Message ('Download progress [{0}]: {1:N1} MB downloaded' -f $displayName, ($totalRead / 1MB))
                }
            }

            if ($totalBytes -gt 0 -and $emitProgress) {
                Write-Progress -Id $progressId -Activity ('Downloading: {0}' -f $displayName) -Completed
            }
            if ($UiProgress -and $totalBytes -gt 0 -and $lastUiPercent -lt 100) {
                Write-TSxUiProgressMessage -Message ('Download progress [{0}]: 100%' -f $displayName)
            }

            Write-Verbose ('Completed legacy HTTP download: {0} ({1:N1} MB)' -f $displayName, ($totalRead / 1MB))
            return $true
        }
        finally {
            if ($fileStream) { $fileStream.Dispose() }
            if ($responseStream) { $responseStream.Dispose() }
            if ($response) { $response.Dispose() }
            $ProgressPreference = $originalProgressPreference
        }
    }

    function Invoke-TSxBitsTransfer {
        param(
            [Parameter(Mandatory = $true)]
            [int]$MaxRetries
        )

        function Get-TSxBitsJobIdentifier {
            param(
                [Parameter(Mandatory = $true)]
                [object]$BitsJob
            )

            if ($null -eq $BitsJob) {
                return $null
            }

            if ($BitsJob.PSObject.Properties['JobId'] -and $BitsJob.JobId) {
                return $BitsJob.JobId
            }

            if ($BitsJob.PSObject.Properties['Id'] -and $BitsJob.Id) {
                return $BitsJob.Id
            }

            return $null
        }

        $bitsCommand = Get-Command -Name Start-BitsTransfer -ErrorAction SilentlyContinue
        if (-not $bitsCommand) {
            throw 'BITS cmdlets are not available on this system.'
        }

        for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
            $bitsJob = $null
            try {
                Write-TSxLog -Message ('BITS attempt {0}/{1} for {2} (UpdateId: {3})' -f $attempt, $MaxRetries, $displayName, $UpdateId)
                Write-Verbose ('Starting BITS attempt {0}/{1}: {2}' -f $attempt, $MaxRetries, $displayName)
                Write-TSxUiProgressMessage -Message ('Download progress [{0}]: Starting BITS attempt {1}/{2}' -f $displayName, $attempt, $MaxRetries)

                if ($UiProgress) {
                    $bitsJob = Start-BitsTransfer -Source $Url -Destination $DestinationPath -DisplayName $displayName -Description ('UpdateId: {0}' -f $UpdateId) -Asynchronous -ErrorAction Stop
                    $bitsJobId = Get-TSxBitsJobIdentifier -BitsJob $bitsJob
                    if (-not $bitsJobId) {
                        throw 'BITS did not return a valid JobId for asynchronous tracking.'
                    }
                    $lastBitsPercent = -1
                    $lastBitsTick = [datetime]::MinValue
                    $lastBitsHeartbeat = [datetime]::MinValue

                    while ($true) {
                        $bitsJob = Get-BitsTransfer -JobId $bitsJobId -ErrorAction Stop

                        if ($bitsJob.BytesTotal -gt 0) {
                            $bitsPercent = [int](($bitsJob.BytesTransferred * 100) / $bitsJob.BytesTotal)
                            if ($bitsPercent -ge ($lastBitsPercent + 5) -or $bitsPercent -eq 100 -or ([datetime]::UtcNow - $lastBitsHeartbeat).TotalSeconds -ge 2) {
                                $lastBitsPercent = $bitsPercent
                                $lastBitsHeartbeat = [datetime]::UtcNow
                                $status = '{0:N1} MB / {1:N1} MB' -f ($bitsJob.BytesTransferred / 1MB), ($bitsJob.BytesTotal / 1MB)
                                Write-TSxUiProgressMessage -Message ('Download progress [{0}]: {1}% ({2})' -f $displayName, $bitsPercent, $status)
                            }
                        }
                        elseif (([datetime]::UtcNow - $lastBitsTick).TotalSeconds -ge 1) {
                            $lastBitsTick = [datetime]::UtcNow
                            Write-TSxUiProgressMessage -Message ('Download progress [{0}]: {1} MB downloaded' -f $displayName, ('{0:N1}' -f ($bitsJob.BytesTransferred / 1MB)))
                        }

                        if ($bitsJob.JobState -in @('Transferred', 'Acknowledged')) {
                            Complete-BitsTransfer -BitsJob $bitsJob -ErrorAction Stop
                            $bitsJob = $null
                            break
                        }

                        if ($bitsJob.JobState -in @('Error', 'TransientError', 'Cancelled')) {
                            $bitsError = if ($bitsJob.ErrorDescription) { $bitsJob.ErrorDescription } else { ('BITS state: {0}' -f $bitsJob.JobState) }
                            Remove-BitsTransfer -BitsJob $bitsJob -ErrorAction SilentlyContinue
                            throw $bitsError
                        }

                        [System.Threading.Thread]::Sleep(250)
                    }
                }
                else {
                    Start-BitsTransfer -Source $Url -Destination $DestinationPath -DisplayName $displayName -Description ('UpdateId: {0}' -f $UpdateId) -ErrorAction Stop
                }

                Write-TSxUiProgressMessage -Message ('Download progress [{0}]: 100% (BITS complete)' -f $displayName)
                Write-TSxLog -Message ('BITS download completed for {0} (UpdateId: {1})' -f $displayName, $UpdateId)
                return $true
            }
            catch {
                $errorMessage = $_.Exception.Message
                $shortErrorMessage = Get-TSxShortErrorMessage -Message $errorMessage
                Write-TSxLog -Level 'WARN' -Message ('BITS attempt {0}/{1} failed for {2} (UpdateId: {3}): {4}' -f $attempt, $MaxRetries, $displayName, $UpdateId, $errorMessage)
                Write-TSxUiProgressMessage -Message ('Download progress [{0}]: BITS attempt {1}/{2} failed - {3}' -f $displayName, $attempt, $MaxRetries, $shortErrorMessage)
                if (Test-Path -LiteralPath $DestinationPath) {
                    Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
                }

                if ($attempt -eq $MaxRetries) {
                    throw
                }
            }
            finally {
                if ($bitsJob) {
                    try {
                        $bitsJobId = Get-TSxBitsJobIdentifier -BitsJob $bitsJob
                        if ($bitsJobId) {
                            $existingBitsJob = Get-BitsTransfer -JobId $bitsJobId -ErrorAction SilentlyContinue
                            if ($existingBitsJob) {
                                if ($existingBitsJob.JobState -in @('Transferred', 'Acknowledged')) {
                                    Complete-BitsTransfer -BitsJob $existingBitsJob -ErrorAction SilentlyContinue
                                }
                                elseif ($existingBitsJob.JobState -notin @('Cancelled')) {
                                    Remove-BitsTransfer -BitsJob $existingBitsJob -ErrorAction SilentlyContinue
                                }
                            }
                        }
                    }
                    catch {
                        # Cleanup best-effort; main transfer error handling is above.
                    }
                }
            }
        }

        throw ('BITS failed after {0} attempt(s).' -f $MaxRetries)
    }

    try {
        if ($UseLegacyTranser) {
            Write-TSxLog -Message ('Using legacy HTTP transfer for {0} (UpdateId: {1}) because -UseLegacyTranser was specified.' -f $displayName, $UpdateId)
            Write-Verbose ('Legacy transfer forced for {0} (UpdateId: {1})' -f $displayName, $UpdateId)
            Invoke-TSxLegacyHttpTransfer
            return $true
        }

        try {
            Invoke-TSxBitsTransfer -MaxRetries 3
            return $true
        }
        catch {
            Write-TSxLog -Level 'WARN' -Message ('BITS transfer failed for {0} (UpdateId: {1}). Falling back to legacy HTTP transfer. Details: {2}' -f $displayName, $UpdateId, $_.Exception.Message)
            Write-Verbose ('BITS failed for {0} (UpdateId: {1}), falling back to legacy HTTP transfer.' -f $displayName, $UpdateId)
            $fallbackReason = Get-TSxShortErrorMessage -Message $_.Exception.Message
            Write-TSxUiProgressMessage -Message ('Download progress [{0}]: Falling back to legacy transfer - {1}' -f $displayName, $fallbackReason)
            Invoke-TSxLegacyHttpTransfer
            return $true
        }

        return $true
    }
    catch {
        Write-TSxLog -Level 'ERROR' -Message ('Download failed for {0} (UpdateId: {1}): {2}' -f $displayName, $UpdateId, $_.Exception.Message)
        throw
    }
}
