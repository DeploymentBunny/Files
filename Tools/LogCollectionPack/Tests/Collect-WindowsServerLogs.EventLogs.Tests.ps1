$collectorPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Collect-WindowsServerLogs.ps1'
$collector = Get-Content -LiteralPath $collectorPath -Raw
$start = $collector.IndexOf('# -------------------- Event Logs (Existence-Checked) --------------------')
$end = $collector.IndexOf('# -------------------- EVTX Auto-Conversion (TXT + XML + CSV) --------------------')
if ($start -lt 0 -or $end -le $start) { throw 'Cannot locate the event log collection section.' }
$collectionBlock = [scriptblock]::Create($collector.Substring($start, $end - $start))

Describe 'Windows Server event log collection' {
    function Write-Section { param([string]$Message) }
    function Write-Detail { param([string]$Message) }

    function wevtutil {
        param([string]$Operation, [string]$LogName, [string]$Destination)

        $script:LASTEXITCODE = 0
        switch ($Operation) {
            'el' {
                if ($script:enumerationFails) {
                    $script:LASTEXITCODE = 5
                    return 'Access is denied.'
                }
                return $script:testLogs
            }
            'epl' {
                $script:exportRequests += $LogName
                if ($LogName -eq $script:failedLog) {
                    $script:LASTEXITCODE = 5
                    return 'Access is denied.'
                }
                Set-Content -LiteralPath $Destination -Value 'Mock EVTX'
            }
            default { throw "Unexpected wevtutil operation: $Operation" }
        }
    }

    BeforeEach {
        $OutDir = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $roles = [pscustomobject]@{
            IsADDS = $false
            IsDNS = $false
            IsDHCP = $false
            IsCA = $false
            IsHyperV = $false
            IsCluster = $false
        }
        $script:testLogs = @('System', 'Application', 'Setup', 'Security')
        $script:exportRequests = @()
        $script:failedLog = $null
        $script:enumerationFails = $false
        $script:warnings = @()
        Mock Write-Warning { param($Message) $script:warnings += $Message }
    }

    It 'exports Security without AD DS and preserves the standard logs' {
        . $collectionBlock
        foreach ($name in @('System', 'Application', 'Setup', 'Security')) {
            ($exported -contains $name) | Should Be $true
            Test-Path -LiteralPath (Join-Path $OutDir "EventLogs\$name.evtx") | Should Be $true
        }
    }

    It 'discovers all AD-related channel types without exporting unrelated channels or duplicates' {
        $roles.IsADDS = $true
        $adLogs = @(
            'Directory Service', 'DFS Replication', 'File Replication Service', 'Active Directory Web Services',
            'Microsoft-Windows-ActiveDirectory_DomainService/Operational',
            'Microsoft-Windows-ActiveDirectory_DomainService/Debug',
            'Microsoft-Windows-ActiveDirectory_WebServices/Analytic',
            'Microsoft-Windows-DirectoryServices-Deployment/Operational',
            'Microsoft-Windows-Directory-Services-SAM/Diagnostic',
            'Microsoft-Windows-ADWS/Debug', 'Microsoft-Windows-NTDS/Analytic',
            'Microsoft-Windows-Kerberos-Key-Distribution-Center/Operational',
            'Microsoft-Windows-Kerberos/Diagnostic', 'Microsoft-Windows-KDC/Analytic',
            'Microsoft-Windows-Security-Kerberos/Operational',
            'Microsoft-Windows-Security-Netlogon/Operational',
            'Microsoft-Windows-Authentication/AuthenticationPolicyFailures-DomainController',
            'Microsoft-Windows-Authentication/ProtectedUserFailures-DomainController',
            'Microsoft-Windows-Authentication/ProtectedUserSuccesses-DomainController',
            'Microsoft-Windows-NTLM/Operational', 'Microsoft-Windows-LSA/Diagnostic',
            'Microsoft-Windows-SAM/Debug', 'Microsoft-Windows-Netlogon/Operational',
            'Microsoft-Windows-DFSR-Server/Diagnostic', 'Microsoft-Windows-DNS-Server/Audit',
            'Microsoft-Windows-GroupPolicy/Operational', 'Microsoft-Windows-Time-Service/Operational'
        )
        $script:testLogs += $adLogs + @('Microsoft-Windows-Unrelated/Operational')
        . $collectionBlock
        foreach ($name in $adLogs) { ($exported -contains $name) | Should Be $true }
        ($script:exportRequests -contains 'Microsoft-Windows-Unrelated/Operational') | Should Be $false
        @($script:exportRequests | Where-Object { $_ -eq 'Security' }).Count | Should Be 1
        @($script:exportRequests | Where-Object { $_ -eq 'Microsoft-Windows-ActiveDirectory_DomainService/Operational' }).Count | Should Be 1
    }

    It 'does not discover AD-specific channels without AD DS' {
        $script:testLogs += 'Microsoft-Windows-ActiveDirectory_DomainService/Debug'
        . $collectionBlock
        ($script:exportRequests -contains 'Microsoft-Windows-ActiveDirectory_DomainService/Debug') | Should Be $false
    }

    It 'reports missing channels without attempting an export' {
        $script:testLogs = @('System')
        . $collectionBlock
        ($skipped -contains 'Security') | Should Be $true
        ($script:exportRequests -contains 'Security') | Should Be $false
    }

    It 'preserves event log collection for the other installed roles' {
        $roles.IsDNS = $true
        $roles.IsDHCP = $true
        $roles.IsCA = $true
        $roles.IsHyperV = $true
        $roles.IsCluster = $true
        $roleLogs = @(
            'DNS Server', 'Microsoft-Windows-DHCP-Server/Operational',
            'Microsoft-Windows-CertificationAuthority/Operational',
            'Microsoft-Windows-Hyper-V-VMMS-Admin',
            'Microsoft-Windows-FailoverClustering/Operational'
        )
        $script:testLogs += $roleLogs
        . $collectionBlock
        foreach ($name in $roleLogs) { ($exported -contains $name) | Should Be $true }
    }

    It 'reports inaccessible AD diagnostic channels without enabling them' {
        $roles.IsADDS = $true
        $script:failedLog = 'Microsoft-Windows-ActiveDirectory_DomainService/Debug'
        $script:testLogs += $script:failedLog
        . $collectionBlock
        ($skipped -contains $script:failedLog) | Should Be $true
        ($exported -contains $script:failedLog) | Should Be $false
        ($exported -contains 'Security') | Should Be $true
        ($script:warnings -join "`n") | Should Match 'DomainService/Debug.*exit code 5'
    }

    It 'reports native export failures and continues exporting other logs' {
        $script:failedLog = 'Security'
        . $collectionBlock
        ($exported -contains 'Security') | Should Be $false
        ($skipped -contains 'Security') | Should Be $true
        ($exported -contains 'Application') | Should Be $true
        ($script:warnings -join "`n") | Should Match 'Security.*exit code 5'
        $summary = Get-Content -LiteralPath (Join-Path $OutDir 'EventLogs\FoundVsSkipped.txt') -Raw
        $summary | Should Match 'Export failures:\s+ - Security:.*Access is denied'
    }

    It 'warns when native enumeration fails instead of treating error text as a channel' {
        $script:enumerationFails = $true
        . $collectionBlock
        $available.Count | Should Be 0
        $script:exportRequests.Count | Should Be 0
        ($script:warnings -join "`n") | Should Match 'enumerate event logs.*exit code 5'
    }
}
