$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-TSxBoots.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors -join '; ') }
$functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
. ([scriptblock]::Create(($functions | ForEach-Object { $_.Extent.Text }) -join "`n"))
$source = Get-Content -LiteralPath $scriptPath -Raw
$runStart = $source.IndexOf('$collectionName =')
if ($runStart -lt 0) { throw 'Cannot locate the collection entry point.' }
$runBlock = [scriptblock]::Create('[CmdletBinding(SupportsShouldProcess = $true)]param()' + "`nSet-StrictMode -Version Latest`n" + $source.Substring($runStart))

function New-TestBootEvent {
    param(
        [string]$Provider,
        [int]$Id,
        [string]$DataXml = '',
        [int]$RecordId = 1,
        [bool]$MessageFails = $false
    )
    $event = [pscustomobject]@{
        Id = $Id
        ProviderName = $Provider
        RecordId = $RecordId
        TimeCreated = [datetime]::SpecifyKind([datetime]'2026-01-02T03:04:05', [DateTimeKind]::Utc)
        MachineName = 'TEST-PC'
        UserId = $null
        MessageFails = $MessageFails
        Disposed = $false
        Xml = "<Event xmlns='http://schemas.microsoft.com/win/2004/08/events'><System><Provider Name='$Provider'/><EventID>$Id</EventID></System><EventData>$DataXml</EventData></Event>"
    }
    $event | Add-Member -MemberType ScriptMethod -Name ToXml -Value { $this.Xml }
    $event | Add-Member -MemberType ScriptMethod -Name FormatDescription -Value {
        if ($this.MessageFails) { throw 'Message resource missing.' }
        'Original localized event message'
    }
    $event | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed = $true }
    $event
}

Describe 'Boot event selection and interpretation' {
    BeforeEach {
        $script:categories = @{}
        foreach ($definition in Get-TSxBootEventDefinitions) {
            $script:categories["$($definition.Provider):$($definition.Id)"] = $definition.Category
        }
        $script:issues = Join-Path $TestDrive 'Issues.txt'
        Mock Write-Warning {}
    }

    It 'includes normal boots, restart requests, user reasons, unexpected shutdowns and BSOD/dump failures' {
        foreach ($key in @(
            'Microsoft-Windows-Kernel-General:12', 'Microsoft-Windows-Kernel-General:13',
            'Microsoft-Windows-Kernel-Boot:20', 'Microsoft-Windows-Kernel-Boot:27',
            'Microsoft-Windows-Kernel-Power:41', 'Microsoft-Windows-Kernel-Power:109',
            'EventLog:6005', 'EventLog:6006', 'EventLog:6008', 'EventLog:6009',
            'User32:1074', 'User32:1076', 'Microsoft-Windows-WER-SystemErrorReporting:1001',
            'BugCheck:1001', 'Save Dump:1001', 'volmgr:46', 'volmgr:161'
        )) { $script:categories.ContainsKey($key) | Should Be $true }
        $script:categories.ContainsKey('Unrelated:1001') | Should Be $false
    }

    It 'extracts the initiating process, user, reason and comment without parsing localized text' {
        $event = New-TestBootEvent -Provider 'User32' -Id 1074 -DataXml @'
<Data Name="param1">C:\Windows\System32\shutdown.exe</Data>
<Data Name="param2">TEST-PC</Data><Data Name="param3">Maintenance (Planned)</Data>
<Data Name="param4">0x80000000</Data><Data Name="param5">restart</Data>
<Data Name="param6">Patch, reboot &amp; verify "service"</Data>
<Data Name="param7">CONTOSO\Operator</Data>
'@
        $row = Convert-TSxBootEvent -Event $event -Categories $script:categories -Xml $event.Xml -IssuesPath $script:issues
        $row.Category | Should Be 'ShutdownRestartRequest'
        $row.Process | Should Be 'C:\Windows\System32\shutdown.exe'
        $row.InitiatingUser | Should Be 'CONTOSO\Operator'
        $row.Reason | Should Be 'Maintenance (Planned)'
        $row.ReasonCode | Should Be '0x80000000'
        $row.ShutdownType | Should Be 'restart'
        $row.Comment | Should Be 'Patch, reboot & verify "service"'
        ($row.EventDataJson | ConvertFrom-Json).param6 | Should Be $row.Comment
        $row.TimeCreatedUtc | Should Be '2026-01-02T03:04:05.0000000Z'
    }

    It 'extracts the user-supplied post-failure reason, problem id, bugcheck string and comment' {
        $event = New-TestBootEvent -Provider 'User32' -Id 1076 -DataXml @'
<Data Name="param1">Power failure</Data><Data Name="param2">0xa000000</Data>
<Data Name="param3">INC123</Data><Data Name="param4">0x0000009f</Data>
<Data Name="param5">UPS battery failed</Data><Data Name="param6">CONTOSO\Admin</Data>
'@
        $row = Convert-TSxBootEvent -Event $event -Categories $script:categories -Xml $event.Xml -IssuesPath $script:issues
        $row.Reason | Should Be 'Power failure'
        $row.ReasonCode | Should Be '0xa000000'
        $row.ProblemId | Should Be 'INC123'
        $row.BugcheckDetails | Should Be '0x0000009f'
        $row.Comment | Should Be 'UPS battery failed'
        $row.InitiatingUser | Should Be 'CONTOSO\Admin'
    }

    It 'preserves the reported previous shutdown date/time separately from the report time' {
        $event = New-TestBootEvent -Provider 'EventLog' -Id 6008 -DataXml '<Data>22:30:00</Data><Data>2026-01-01</Data><Data>Extra data</Data>'
        $row = Convert-TSxBootEvent -Event $event -Categories $script:categories -Xml $event.Xml -IssuesPath $script:issues
        $row.PreviousShutdownTimeText | Should Be '22:30:00'
        $row.PreviousShutdownDateText | Should Be '2026-01-01'
        ($row.EventDataJson | ConvertFrom-Json).Data3 | Should Be 'Extra data'
    }

    It 'exports WER and legacy bugcheck details, dump path and report id' {
        foreach ($provider in @('Microsoft-Windows-WER-SystemErrorReporting', 'BugCheck', 'Save Dump')) {
            $event = New-TestBootEvent -Provider $provider -Id 1001 -DataXml '<Data>0x0000009f (parameters)</Data><Data>C:\Windows\MEMORY.DMP</Data><Data>Report-GUID</Data>'
            $row = Convert-TSxBootEvent -Event $event -Categories $script:categories -Xml $event.Xml -IssuesPath $script:issues
            $row.Category | Should Be 'BugCheck'
            $row.BugcheckDetails | Should Be '0x0000009f (parameters)'
            $row.DumpPath | Should Be 'C:\Windows\MEMORY.DMP'
            $row.ReportId | Should Be 'Report-GUID'
        }
    }

    It 'does not equate Kernel-Power 41 with a proven bugcheck and preserves all its data' {
        $event = New-TestBootEvent -Provider 'Microsoft-Windows-Kernel-Power' -Id 41 -DataXml '<Data Name="BugcheckCode">0</Data><Data Name="PowerButtonTimestamp">1234</Data>'
        $row = Convert-TSxBootEvent -Event $event -Categories $script:categories -Xml $event.Xml -IssuesPath $script:issues
        $row.Category | Should Be 'UnexpectedRestart'
        $row.BugcheckCode | Should Be '0'
        ($row.EventDataJson | ConvertFrom-Json).PowerButtonTimestamp | Should Be '1234'
    }

    It 'preserves boot type and prior boot/shutdown success indicators' {
        $event = New-TestBootEvent -Provider 'Microsoft-Windows-Kernel-Boot' -Id 27 -DataXml '<Data Name="BootType">1</Data>'
        $row = Convert-TSxBootEvent -Event $event -Categories $script:categories -Xml $event.Xml -IssuesPath $script:issues
        $row.BootType | Should Be '1'
        $event = New-TestBootEvent -Provider 'Microsoft-Windows-Kernel-Boot' -Id 20 -DataXml '<Data Name="LastShutdownGood">false</Data><Data Name="LastBootGood">true</Data>'
        $row = Convert-TSxBootEvent -Event $event -Categories $script:categories -Xml $event.Xml -IssuesPath $script:issues
        $row.LastShutdownGood | Should Be 'false'
        $row.LastBootGood | Should Be 'true'
    }

    It 'keeps event data and reports missing message resources explicitly' {
        $event = New-TestBootEvent -Provider 'User32' -Id 1074 -DataXml '<Data Name="param6">Reason still retained</Data>' -MessageFails $true
        $row = Convert-TSxBootEvent -Event $event -Categories $script:categories -Xml $event.Xml -IssuesPath $script:issues
        $row.Comment | Should Be 'Reason still retained'
        (Get-Content -LiteralPath $script:issues -Raw) | Should Match 'Failed to render event message'
        $row.Message | Should BeNullOrEmpty
    }
}

Describe 'Boot history collection outputs' {
    BeforeEach {
        $OutputRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $DisplayCount = 12
        $script:events = @(
            (New-TestBootEvent -Provider 'Microsoft-Windows-Kernel-General' -Id 12 -RecordId 1),
            (New-TestBootEvent -Provider 'User32' -Id 1074 -RecordId 2 -DataXml '<Data Name="param6">Scheduled reboot</Data>')
        )
        $script:noEvents = $false
        $script:readFails = $false
        $script:exportFails = $false
        $script:savedQuery = $null
        Mock Test-TSxBootAdministrator { $true }
        Mock Export-TSxBootEventLog {
            if ($script:exportFails) { throw 'System export access denied.' }
            $script:savedQuery = $Query
            Set-Content -LiteralPath $Path -Value 'Mock EVTX snapshot'
        }
        Mock Get-WinEvent {
            if ($script:readFails) { throw 'Corrupt snapshot.' }
            if ($script:noEvents) {
                $exception = New-Object System.Exception('No matching events')
                $errorRecord = New-Object System.Management.Automation.ErrorRecord($exception, 'NoMatchingEventsFound', 'ObjectNotFound', $Path)
                $PSCmdlet.ThrowTerminatingError($errorRecord)
            }
            $script:events
        }
        Mock Write-Warning {}
    }

    It 'writes every record to CSV and original XML, creates a summary and disposes events' {
        . $runBlock
        $rows = @(Import-Csv -LiteralPath $csvPath)
        $rows.Count | Should Be 2
        $rows[1].Comment | Should Be 'Scheduled reboot'
        [xml]$xml = Get-Content -LiteralPath $xmlPath -Raw
        @($xml.Events.Event).Count | Should Be 2
        $summary = Get-Content -LiteralPath (Join-Path $collectionPath 'Summary.json') -Raw | ConvertFrom-Json
        $summary.EventCount | Should Be 2
        $summary.CategoryCounts.Boot | Should Be 1
        foreach ($event in $script:events) { $event.Disposed | Should Be $true }
        $script:savedQuery | Should Match "Provider\[@Name='User32'\] and EventID=1076"
        $script:savedQuery | Should Not Match 'TimeCreated'
        Assert-MockCalled Get-WinEvent -Times 1 -Exactly -Scope It -ParameterFilter { $Oldest -and -not $PSBoundParameters.ContainsKey('MaxEvents') }
    }

    It 'writes a valid empty XML, CSV header and explicit warning when no events remain' {
        $script:noEvents = $true
        . $runBlock
        $summary = Get-Content -LiteralPath (Join-Path $collectionPath 'Summary.json') -Raw | ConvertFrom-Json
        $summary.EventCount | Should Be 0
        (Get-Content -LiteralPath $csvPath -Raw) | Should Match '"TimeCreatedUtc","RecordId"'
        [xml]$xml = Get-Content -LiteralPath $xmlPath -Raw
        $xml.DocumentElement.Name | Should Be 'Events'
        (Get-Content -LiteralPath $issuesPath -Raw) | Should Match 'No matching'
    }

    It 'limits only the quick view buffer and preserves all exported rows and full comments' {
        $DisplayCount = 1
        $script:events[1].Xml = $script:events[1].Xml.Replace('Scheduled reboot', ('Detailed reason ' * 30))
        . $runBlock
        $displayRows.Count | Should Be 1
        $displayRows.Peek().RecordId | Should Be 2
        $rows = @(Import-Csv -LiteralPath $csvPath)
        $rows.Count | Should Be 2
        $rows[1].Comment.Length | Should Be 480
    }

    It 'can disable the quick view without changing file collection' {
        $DisplayCount = 0
        Mock Show-TSxBootQuickView {}
        . $runBlock
        $displayRows.Count | Should Be 0
        @(Import-Csv -LiteralPath $csvPath).Count | Should Be 2
        Assert-MockCalled Show-TSxBootQuickView -Times 0 -Exactly -Scope It
    }

    It 'fails on access/export errors rather than creating a success summary' {
        $script:exportFails = $true
        { . $runBlock } | Should Throw 'System export access denied'
    }

    It 'fails on read errors instead of treating them as an empty history' {
        $script:readFails = $true
        { . $runBlock } | Should Throw 'Corrupt snapshot'
        @(Get-ChildItem -LiteralPath $OutputRoot -Filter 'Summary.json' -Recurse).Count | Should Be 0
    }

    It 'requires elevation before writing collection files' {
        Mock Test-TSxBootAdministrator { $false }
        { . $runBlock } | Should Throw 'elevated PowerShell'
        Test-Path -LiteralPath $OutputRoot | Should Be $false
    }
}

Describe 'Compact colored boot quick view' {
        BeforeEach {
            $script:displayLines = @()
            Mock Write-Host {
                param($Object, $ForegroundColor)
                $script:displayLines += [pscustomobject]@{ Text = [string]$Object; Color = [string]$ForegroundColor }
            }
            $script:categories = @{}
            foreach ($definition in Get-TSxBootEventDefinitions) {
                $script:categories["$($definition.Provider):$($definition.Id)"] = $definition.Category
            }
            $script:issues = Join-Path $TestDrive 'DisplayIssues.txt'
        }

        It 'uses distinct colors and labels without asserting a root cause for unclean restarts' {
            $cases = @(
                @{ Provider = 'Microsoft-Windows-Kernel-General'; Id = 12; Color = 'Green' },
                @{ Provider = 'User32'; Id = 1074; Color = 'Cyan' },
                @{ Provider = 'EventLog'; Id = 6008; Color = 'Yellow' },
                @{ Provider = 'User32'; Id = 1076; Color = 'Magenta' },
                @{ Provider = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; Color = 'Red' },
                @{ Provider = 'EventLog'; Id = 6005; Color = 'Gray' }
            )
            foreach ($case in $cases) {
                $event = New-TestBootEvent -Provider $case.Provider -Id $case.Id
                $row = Convert-TSxBootEvent -Event $event -Categories $script:categories -Xml $event.Xml -IssuesPath $script:issues
                (Get-TSxBootDisplayStyle $row).Color | Should Be $case.Color
            }
            $event = New-TestBootEvent -Provider 'Microsoft-Windows-Kernel-Power' -Id 41
            $row = Convert-TSxBootEvent -Event $event -Categories $script:categories -Xml $event.Xml -IssuesPath $script:issues
            $style = Get-TSxBootDisplayStyle $row
            $style.Label | Should Be 'Unclean restart'
            $style.Detail | Should Match 'cause not established'
        }

        It 'keeps every line within narrow and wide consoles and flattens multiline/control text' {
            $event = New-TestBootEvent -Provider 'User32' -Id 1074 -DataXml '<Data Name="param6">First line&#10;Second line&#9;Long comment that will be truncated</Data>'
            $row = Convert-TSxBootEvent -Event $event -Categories $script:categories -Xml $event.Xml -IssuesPath $script:issues
            foreach ($width in @(25, 40, 65, 80, 120)) {
                $script:displayLines = @()
                Show-TSxBootQuickView -Rows @($row) -TotalCount 1 -Width $width -Height 24
                foreach ($line in $script:displayLines) {
                    ($line.Text.Length -le $width) | Should Be $true
                    $line.Text | Should Not Match '[\r\n\t]'
                }
            }
            $row.Comment | Should Match "`n"
            Format-TSxBootDisplayText ("a`n`tb" + [char]27 + '[31m') 80 | Should Not Match '[\x00-\x1f]'
        }

        It 'shows newest first and limits rows to the available screen height' {
            $rows = @(
                foreach ($id in 1..12) {
                    $event = New-TestBootEvent -Provider 'User32' -Id 1074 -RecordId $id -DataXml "<Data Name='param6'>Comment$id</Data>"
                    Convert-TSxBootEvent -Event $event -Categories $script:categories -Xml $event.Xml -IssuesPath $script:issues
                }
            )
            Show-TSxBootQuickView -Rows $rows -TotalCount 100 -Width 80 -Height 14
            $eventLines = @($script:displayLines | Where-Object Color -eq 'Cyan')
            $eventLines.Count | Should Be 4
            $eventLines[0].Text | Should Match 'Comment12'
            $eventLines[3].Text | Should Match 'Comment9'
            $expectedLocalTime = ([datetime]::SpecifyKind([datetime]'2026-01-02T03:04:05', [DateTimeKind]::Utc)).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
            $eventLines[0].Text.StartsWith($expectedLocalTime) | Should Be $true
            $eventLines[0].Text.Substring(17, 16).Trim() | Should Be 'Restart/stop'
            ($script:displayLines.Text -join "`n") | Should Match 'Latest 4 of 100 records'
            ($script:displayLines.Text -join "`n") | Should Match 'Local time'
            ($script:displayLines.Count -le 14) | Should Be $true
        }

        It 'makes an empty history clear without emitting pipeline data' {
            $output = @(Show-TSxBootQuickView -Rows @() -TotalCount 0 -Width 80 -Height 24)
            $output.Count | Should Be 0
            ($script:displayLines.Text -join "`n") | Should Match 'No matching events retained'
        }
    }
