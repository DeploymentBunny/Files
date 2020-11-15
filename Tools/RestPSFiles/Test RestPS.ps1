# Verify that RestPS works
$RestMethodParams = @{
            Uri = 'http://localhost:8080/process?name=powershell'
            Method = 'Get'
            UseBasicParsing = $true
        }
Invoke-RestMethod @RestMethodParams
