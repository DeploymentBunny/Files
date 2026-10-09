#requires -Version 5.1

<#
.SYNOPSIS
    Exports all retained Windows boot, shutdown, restart and bugcheck events.

.DESCRIPTION
    Creates a filtered snapshot of the local System event log, then exports
    each matching record to CSV and XML in chronological order. There is no
    time window or event-count limit. Run elevated.

    Includes normal boot/shutdown, restart requests, unexpected shutdowns,
    bugchecks (BSOD), crash-dump failures and Shutdown Event Tracker reasons,
    including user comments recorded in User32 events 1074 and 1076.
    Reason fields are extracted from event XML, not localized message text.
    All event data is also preserved as JSON in CSV and as original event XML.

    This is an event timeline, not one row per physical boot. Several records
    can describe the same restart. Event timestamps for unexpected shutdown
    and bugcheck reports can be the next startup, not the time of the failure.
    Kernel-Power 41 alone does not prove a BSOD or identify a root cause.
    Fast startup/hibernate resume is distinguished when BootType is present.
    Only events still retained in the local System log can be recovered.
    No auditing, event channels or system configuration are changed.

.PARAMETER OutputRoot
    Root directory for a unique timestamped collection.
    Default: C:\Temp\Boot-Diagnostics.

.PARAMETER DisplayCount
    Maximum number of latest event records in the colored console quick view.
    Default: 12. The view adapts to console width/height, uses local time and
    truncates long text. Set to 0 to disable it. File exports are always complete.

.EXAMPLE
    .\Get-TSxBoots.ps1

.EXAMPLE
    .\Get-TSxBoots.ps1 -OutputRoot 'D:\Diagnostics' -Verbose

.EXAMPLE
    .\Get-TSxBoots.ps1 -WhatIf

.EXAMPLE
    .\Get-TSxBoots.ps1 -DisplayCount 20

.NOTES
    FileName: Get-TSxBoots.ps1
    Version: 1.1.0
    Author: Mikael Nystrom
    Contact: deploymentbunny@outlook.com
    Created: 2026-10-09
    Updated: 2026-10-09
    Logs may contain user names, process paths and sensitive user comments.
    Protect the collection and share only with authorized recipients.

.LINK
    https://www.deploymentbunny.com
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputRoot = 'C:\Temp\Boot-Diagnostics',

    [Parameter()]
    [ValidateRange(0, 1000)]
    [int]$DisplayCount = 12
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-TSxBootAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Get-TSxBootEventDefinitions {
    @(
        @{ Provider = 'Microsoft-Windows-Kernel-General'; Id = 12; Category = 'Boot' },
        @{ Provider = 'Microsoft-Windows-Kernel-General'; Id = 13; Category = 'Shutdown' },
        @{ Provider = 'Microsoft-Windows-Kernel-Boot'; Id = 20; Category = 'BootStatus' },
        @{ Provider = 'Microsoft-Windows-Kernel-Boot'; Id = 27; Category = 'BootType' },
        @{ Provider = 'Microsoft-Windows-Kernel-Power'; Id = 41; Category = 'UnexpectedRestart' },
        @{ Provider = 'Microsoft-Windows-Kernel-Power'; Id = 109; Category = 'ShutdownTransition' },
        @{ Provider = 'EventLog'; Id = 6005; Category = 'EventLogStarted' },
        @{ Provider = 'EventLog'; Id = 6006; Category = 'EventLogStopped' },
        @{ Provider = 'EventLog'; Id = 6008; Category = 'UnexpectedShutdown' },
        @{ Provider = 'EventLog'; Id = 6009; Category = 'StartupOSVersion' },
        @{ Provider = 'User32'; Id = 1074; Category = 'ShutdownRestartRequest' },
        @{ Provider = 'User32'; Id = 1076; Category = 'UserSuppliedUnexpectedShutdownReason' },
        @{ Provider = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; Category = 'BugCheck' },
        @{ Provider = 'BugCheck'; Id = 1001; Category = 'BugCheck' },
        @{ Provider = 'Save Dump'; Id = 1001; Category = 'BugCheck' },
        @{ Provider = 'volmgr'; Id = 46; Category = 'CrashDumpInitializationFailed' },
        @{ Provider = 'volmgr'; Id = 161; Category = 'CrashDumpCreationFailed' },
        @{ Provider = 'Microsoft-Windows-Eventlog'; Id = 104; Category = 'LogCleared' }
    )
}

function Export-TSxBootEventLog {
    param([string]$Query, [string]$Path)

    $session = New-Object System.Diagnostics.Eventing.Reader.EventLogSession
    try {
        $session.ExportLog('System', [System.Diagnostics.Eventing.Reader.PathType]::LogName, $Query, $Path)
    }
    finally { $session.Dispose() }
}

function Convert-TSxBootEvent {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Event,

        [Parameter(Mandatory = $true)]
        [hashtable]$Categories,

        [Parameter(Mandatory = $true)]
        [string]$Xml,

        [Parameter(Mandatory = $true)]
        [string]$IssuesPath
    )

    [xml]$document = $Xml
    $data = [ordered]@{}
    $index = 0
    foreach ($node in $document.SelectNodes("/*[local-name()='Event']/*[local-name()='EventData']/*[local-name()='Data']")) {
        $index++
        $key = $node.GetAttribute('Name')
        if ([string]::IsNullOrWhiteSpace($key)) { $key = "Data$index" }
        if ($data.Contains($key)) { $key = "$key#$index" }
        $data[$key] = $node.InnerText
    }
    $parameters = @{}
    for ($position = 1; $position -le 7; $position++) {
        $parameters["param$position"] = if ($data.Contains("param$position")) { $data["param$position"] } else { $data["Data$position"] }
    }
    $message = $null
    try { $message = $Event.FormatDescription() }
    catch {
        $issue = "Record $($Event.RecordId): Failed to render event message: $($_.Exception.Message)"
        Write-Warning $issue
        Add-Content -LiteralPath $IssuesPath -Value $issue -Encoding UTF8
    }
    if ([string]::IsNullOrWhiteSpace($message)) {
        $issue = "Record $($Event.RecordId): Event message unavailable; see EventDataJson and BootEvents.xml."
        Write-Warning $issue
        Add-Content -LiteralPath $IssuesPath -Value $issue -Encoding UTF8
    }

    $row = [ordered]@{
        TimeCreatedUtc = $Event.TimeCreated.ToUniversalTime().ToString('o')
        RecordId = $Event.RecordId
        Computer = $Event.MachineName
        Provider = $Event.ProviderName
        EventId = $Event.Id
        Category = $Categories["$($Event.ProviderName):$($Event.Id)"]
        UserSid = if ($null -ne $Event.UserId) { $Event.UserId.Value } else { $null }
        InitiatingUser = $null
        Process = $null
        Reason = $null
        ReasonCode = $null
        ShutdownType = $null
        Comment = $null
        ProblemId = $null
        BugcheckCode = $null
        BugcheckDetails = $null
        DumpPath = $null
        ReportId = $null
        PreviousShutdownTimeText = $null
        PreviousShutdownDateText = $null
        BootType = $null
        LastShutdownGood = $data['LastShutdownGood']
        LastBootGood = $data['LastBootGood']
        Message = $message
        EventDataJson = ConvertTo-Json -InputObject $data -Compress -Depth 10
    }
    if ($Event.ProviderName -eq 'User32') {
        $row.Reason = $parameters['param3']
        if ($Event.Id -eq 1074) {
            $row.Process = $parameters['param1']
            $row.ReasonCode = $parameters['param4']
            $row.ShutdownType = $parameters['param5']
            $row.Comment = $parameters['param6']
            $row.InitiatingUser = $parameters['param7']
        }
        elseif ($Event.Id -eq 1076) {
            $row.Reason = $parameters['param1']
            $row.ReasonCode = $parameters['param2']
            $row.ProblemId = $parameters['param3']
            $row.BugcheckDetails = $parameters['param4']
            $row.Comment = $parameters['param5']
            $row.InitiatingUser = $parameters['param6']
        }
    }
    elseif ($Event.ProviderName -eq 'Microsoft-Windows-Kernel-Power') {
        $row.BugcheckCode = $data['BugcheckCode']
        $row.ReasonCode = $data['ShutdownReason']
    }
    elseif ($row.Category -eq 'BugCheck') {
        $row.BugcheckDetails = $parameters['param1']
        $row.DumpPath = $parameters['param2']
        $row.ReportId = $parameters['param3']
    }
    elseif ($Event.ProviderName -eq 'EventLog' -and $Event.Id -eq 6008) {
        $row.PreviousShutdownTimeText = $parameters['param1']
        $row.PreviousShutdownDateText = $parameters['param2']
    }
    elseif ($Event.ProviderName -eq 'Microsoft-Windows-Kernel-Boot' -and $Event.Id -eq 27) {
        $row.BootType = $data['BootType']
    }
    [pscustomobject]$row
}

function Format-TSxBootDisplayText {
    param([AllowNull()][string]$Text, [int]$Width, [switch]$PreserveSpacing)

    $textLine = $Text -replace '[\x00-\x1f\x7f-\x9f]', ' '
    if (-not $PreserveSpacing) { $textLine = ($textLine -replace '\s+', ' ').Trim() }
    if ($textLine.Length -le $Width) { return $textLine }
    if ($Width -le 3) { return $textLine.Substring(0, $Width) }
    $textLine.Substring(0, $Width - 3) + '...'
}

function Get-TSxBootDisplayStyle {
    param([object]$Row)

    $label = $Row.Category
    $color = 'Gray'
    switch ($Row.Category) {
        'Boot' { $label = 'Boot'; $color = 'Green' }
        'Shutdown' { $label = 'Shutdown'; $color = 'Cyan' }
        'ShutdownTransition' { $label = 'Shutdown'; $color = 'Cyan' }
        'ShutdownRestartRequest' { $label = 'Restart/stop'; $color = 'Cyan' }
        'UnexpectedRestart' { $label = 'Unclean restart'; $color = 'Yellow' }
        'UnexpectedShutdown' { $label = 'Unexpected stop'; $color = 'Yellow' }
        'UserSuppliedUnexpectedShutdownReason' { $label = 'User reason'; $color = 'Magenta' }
        'BugCheck' { $label = 'BSOD/bugcheck'; $color = 'Red' }
        'CrashDumpInitializationFailed' { $label = 'Dump init failed'; $color = 'Red' }
        'CrashDumpCreationFailed' { $label = 'Dump failed'; $color = 'Red' }
        'BootStatus' {
            $label = 'Boot status'
            if ($Row.LastShutdownGood -in @('false', '0') -or $Row.LastBootGood -in @('false', '0')) {
                $color = 'Yellow'
            }
        }
        'BootType' { $label = 'Boot type' }
        'EventLogStarted' { $label = 'Log started' }
        'EventLogStopped' { $label = 'Log stopped' }
        'StartupOSVersion' { $label = 'Startup info' }
        'LogCleared' { $label = 'Log cleared'; $color = 'Yellow' }
    }
    $parts = @(
        if (-not [string]::IsNullOrWhiteSpace($Row.ShutdownType)) { $Row.ShutdownType }
        if (-not [string]::IsNullOrWhiteSpace($Row.Reason)) { $Row.Reason }
        if (-not [string]::IsNullOrWhiteSpace($Row.Comment)) { $Row.Comment }
        if (-not [string]::IsNullOrWhiteSpace($Row.BugcheckDetails)) { $Row.BugcheckDetails }
        if (-not [string]::IsNullOrWhiteSpace($Row.BugcheckCode)) { "Bugcheck=$($Row.BugcheckCode)" }
        if (-not [string]::IsNullOrWhiteSpace($Row.InitiatingUser)) { $Row.InitiatingUser }
    )
    $detail = $parts -join ' | '
    if ([string]::IsNullOrWhiteSpace($detail)) {
        $detail = switch ($Row.Category) {
            'UnexpectedRestart' { 'Restarted without a clean shutdown; cause not established' }
            'UnexpectedShutdown' { "Previous shutdown: $($Row.PreviousShutdownDateText) $($Row.PreviousShutdownTimeText)" }
            'BootStatus' { "Last shutdown OK=$($Row.LastShutdownGood); last boot OK=$($Row.LastBootGood)" }
            'BootType' {
                switch ($Row.BootType) {
                    { $_ -in @('0', '0x0') } { 'Full boot' }
                    { $_ -in @('1', '0x1') } { 'Fast startup / hybrid boot' }
                    { $_ -in @('2', '0x2') } { 'Hibernation resume' }
                    default { "Boot type: $($Row.BootType)" }
                }
            }
            default { $Row.Message }
        }
    }
    [pscustomobject]@{ Label = $label; Color = $color; Detail = $detail }
}

function Show-TSxBootQuickView {
    param(
        [AllowEmptyCollection()][object[]]$Rows,
        [int]$TotalCount,
        [int]$Width,
        [int]$Height
    )

    if ($Width -le 0 -or $Height -le 0) {
        Write-Warning 'Console dimensions unavailable; using an 80-column quick view.'
        $Width = 80
        $Height = 24
    }
    $Width = [Math]::Min(120, $Width)
    $visibleCount = [Math]::Min($Rows.Count, [Math]::Max(0, $Height - 10))
    $timeWidth = if ($Width -ge 80) { 16 } else { 11 }
    $typeWidth = if ($Width -ge 70) { 16 } else { 12 }
    $showId = $Width -ge 70
    $prefixWidth = $timeWidth + $typeWidth + 2
    if ($showId) { $prefixWidth += 6 }
    $detailWidth = [Math]::Max(0, $Width - $prefixWidth)

    Write-Host ''
    Write-Host (Format-TSxBootDisplayText 'BOOT / RESTART / SHUTDOWN - QUICK VIEW' $Width) -ForegroundColor White
    Write-Host (Format-TSxBootDisplayText "Latest $visibleCount of $TotalCount records | Local time | Newest first" $Width) -ForegroundColor Gray
    $header = (Format-TSxBootDisplayText 'Time (local)' $timeWidth).PadRight($timeWidth) + ' ' + 'Type'.PadRight($typeWidth) + ' '
    if ($showId) { $header += 'ID'.PadRight(5) + ' ' }
    $header += 'Reason / comment'
    Write-Host (Format-TSxBootDisplayText $header $Width -PreserveSpacing) -ForegroundColor White
    Write-Host ('-' * $Width) -ForegroundColor DarkGray
    $latest = @($Rows)
    [array]::Reverse($latest)
    foreach ($row in ($latest | Select-Object -First $visibleCount)) {
        $style = Get-TSxBootDisplayStyle $row
        $timeFormat = if ($Width -ge 80) { 'yyyy-MM-dd HH:mm' } else { 'MM-dd HH:mm' }
        $localTime = ([datetime]::Parse($row.TimeCreatedUtc, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind)).ToLocalTime().ToString($timeFormat)
        $line = $localTime.PadRight($timeWidth) + ' ' +
            (Format-TSxBootDisplayText $style.Label $typeWidth).PadRight($typeWidth) + ' '
        if ($showId) { $line += ([string]$row.EventId).PadRight(5) + ' ' }
        $line += Format-TSxBootDisplayText $style.Detail $detailWidth
        Write-Host (Format-TSxBootDisplayText $line $Width -PreserveSpacing) -ForegroundColor $style.Color
    }
    if ($TotalCount -eq 0) {
        Write-Host (Format-TSxBootDisplayText 'No matching events retained.' $Width) -ForegroundColor Yellow
    }
    Write-Host (Format-TSxBootDisplayText 'Green: boot | Cyan: shutdown/request | Yellow: unexpected/warning' $Width) -ForegroundColor Gray
    Write-Host (Format-TSxBootDisplayText 'Red: BSOD/dump error | Magenta: user reason | Gray: information' $Width) -ForegroundColor Gray
    Write-Host (Format-TSxBootDisplayText 'Multiple records may describe one restart. Full details are in the files.' $Width) -ForegroundColor DarkGray
}

$collectionName = '{0}-{1}-{2}' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
$collectionPath = Join-Path $OutputRoot $collectionName
if (-not $PSCmdlet.ShouldProcess($collectionPath, 'Export all retained boot, shutdown, restart and BSOD events')) { return }
if (-not (Test-TSxBootAdministrator)) { throw 'Run Get-TSxBoots.ps1 from an elevated PowerShell session.' }

$null = New-Item -ItemType Directory -Path $collectionPath
$evtxPath = Join-Path $collectionPath 'BootEvents.evtx'
$csvPath = Join-Path $collectionPath 'BootEvents.csv'
$xmlPath = Join-Path $collectionPath 'BootEvents.xml'
$issuesPath = Join-Path $collectionPath 'CollectionIssues.txt'
$definitions = @(Get-TSxBootEventDefinitions)
$categories = @{}
$selectors = foreach ($definition in $definitions) {
    $categories["$($definition.Provider):$($definition.Id)"] = $definition.Category
    "(Provider[@Name='$($definition.Provider)'] and EventID=$($definition.Id))"
}
$query = '*[System[{0}]]' -f ($selectors -join ' or ')
Write-Verbose "Creating a filtered snapshot of all retained System events: $evtxPath"
Export-TSxBootEventLog -Query $query -Path $evtxPath

$settings = New-Object System.Xml.XmlWriterSettings
$settings.Indent = $true
$settings.Encoding = New-Object System.Text.UTF8Encoding($false)
$writer = [System.Xml.XmlWriter]::Create($xmlPath, $settings)
$count = 0
$counts = @{}
$oldest = $null
$newest = $null
$displayRows = New-Object 'System.Collections.Generic.Queue[object]'
$columns = @(
    'TimeCreatedUtc', 'RecordId', 'Computer', 'Provider', 'EventId', 'Category',
    'UserSid', 'InitiatingUser', 'Process', 'Reason', 'ReasonCode', 'ShutdownType',
    'Comment', 'ProblemId', 'BugcheckCode', 'BugcheckDetails', 'DumpPath', 'ReportId',
    'PreviousShutdownTimeText', 'PreviousShutdownDateText', 'BootType',
    'LastShutdownGood', 'LastBootGood', 'Message', 'EventDataJson'
)
try {
    $writer.WriteStartDocument()
    $writer.WriteStartElement('Events')
    try {
        Get-WinEvent -Path $evtxPath -Oldest -ErrorAction Stop | ForEach-Object {
            $event = $_
            try {
                $eventXml = $event.ToXml()
                $row = Convert-TSxBootEvent -Event $event -Categories $categories -Xml $eventXml -IssuesPath $issuesPath
                $writer.WriteRaw($eventXml)
                $count++
                if ($count -eq 1) { $oldest = $row.TimeCreatedUtc }
                $newest = $row.TimeCreatedUtc
                if (-not $counts.ContainsKey($row.Category)) { $counts[$row.Category] = 0 }
                $counts[$row.Category]++
                if ($DisplayCount -gt 0) {
                    $displayRows.Enqueue($row)
                    if ($displayRows.Count -gt $DisplayCount) { $null = $displayRows.Dequeue() }
                }
                $row
            }
            finally { $event.Dispose() }
        } | Select-Object -Property $columns | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    }
    catch {
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw }
        Write-Warning 'No matching boot/shutdown events are retained in the System log.'
        Add-Content -LiteralPath $issuesPath -Value 'No matching boot/shutdown events are retained in the System log.' -Encoding UTF8
    }
    $writer.WriteEndElement()
    $writer.WriteEndDocument()
}
finally { $writer.Dispose() }

if ($count -eq 0) {
    (($columns | ForEach-Object { '"{0}"' -f $_ }) -join ',') | Set-Content -LiteralPath $csvPath -Encoding UTF8
}

[pscustomobject]@{
    Computer = $env:COMPUTERNAME
    CollectionTimeUtc = [datetime]::UtcNow.ToString('o')
    EventCount = $count
    OldestEventUtc = $oldest
    NewestEventUtc = $newest
    CategoryCounts = $counts
    Query = $query
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $collectionPath 'Summary.json') -Encoding UTF8

@'
Boot, shutdown, restart and BSOD event collection
================================================
BootEvents.evtx: Native filtered snapshot of all retained matching System records.
BootEvents.csv: Chronological event timeline, reasons/comments and event data JSON.
BootEvents.xml: Original event XML, including all EventData/UserData/Binary fields.
Summary.json: Event count, category counts, retained time range and selection query.
CollectionIssues.txt: Created when messages are unavailable or no events were found.

Several events can describe one restart. EventLog 6005/6006 describe the event
logging service, not necessarily a physical boot/shutdown. Unexpected shutdown
and bugcheck reports can be logged at the next boot. PreviousShutdownTimeText
and PreviousShutdownDateText are the original localized EventLog 6008 fields.
User32 1074 records the initiating process/user, reason, code, type and comment.
User32 1076 records the reason/comment subsequently supplied by a user.
Kernel-Power 41 means Windows restarted without a clean shutdown; it does not
by itself distinguish power loss, a hang, reset or BSOD. Its BugcheckCode is
normally decimal; WER bugcheck details normally use hexadecimal.
BootType 0 = full boot, 1 = hybrid/fast startup, 2 = hibernation resume.
ShutdownReason is a raw provider-specific code, not a proven root cause.
All TimeCreatedUtc values are UTC. Reasons/messages remain in their original
language. Empty columns mean that the event does not supply that field.
No events can be recovered from before the retained/cleared log history.
Crash dumps themselves are not copied. Protect user names and free-text comments.
The console quick view shows only the latest records in local time with shortened
text. DisplayCount controls the view only; all retained records remain in the files.
'@ | Set-Content -LiteralPath (Join-Path $collectionPath 'README.txt') -Encoding UTF8

if ($DisplayCount -gt 0) {
    $windowSize = $Host.UI.RawUI.WindowSize
    Show-TSxBootQuickView -Rows $displayRows.ToArray() -TotalCount $count `
        -Width ($windowSize.Width - 1) -Height $windowSize.Height
}
Write-Host ("Collected {0} boot/shutdown-related events." -f $count)
Write-Host "Output folder: $collectionPath"
