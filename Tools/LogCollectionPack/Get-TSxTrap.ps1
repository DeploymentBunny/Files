[CmdletBinding()]
param(
    [switch]$Simulate
)

$Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

$DiskResult = "OK"
try {
    if ($Simulate) { throw "Simulated disk failure" }
    Get-Disk -ErrorAction Stop | Out-Null
}
catch {
    $DiskResult = $_.Exception.Message
}

$NetResult = "OK"
try {
    if ($Simulate) { throw "Simulated network failure" }
    Get-NetAdapter -ErrorAction Stop | Out-Null
}
catch {
    $NetResult = $_.Exception.Message
}

$BiosResult = "OK"
try {
    if ($Simulate) { throw "Simulated BIOS failure" }
    Get-CimInstance Win32_BIOS -ErrorAction Stop | Out-Null
}
catch {
    $BiosResult = $_.Exception.Message
}

$AnyFailure = ($DiskResult -ne "OK") -or ($NetResult -ne "OK") -or ($BiosResult -ne "OK") -or $Simulate

$FallbackResult = "Not needed"
$ComServicesResult = "Not needed"
$ComAppEventsResult = "Not needed"
if ($AnyFailure) {
    $OsInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $DiskInfo = Get-Disk -ErrorAction SilentlyContinue | Select-Object Number, FriendlyName, HealthStatus, BusType, Size | Format-Table -HideTableHeaders | Out-String
    $NetInfo = Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object Name, Status, MacAddress | Format-Table -HideTableHeaders | Out-String
    $ServiceInfo = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne "Running" } | Select-Object -ExpandProperty Name | Sort-Object | Out-String
    $VolumeInfo = Get-Volume -ErrorAction SilentlyContinue | Select-Object DriveLetter, FileSystemLabel, HealthStatus, SizeRemaining, Size | Format-Table -HideTableHeaders | Out-String

    $ComServices = Get-Service RpcSs, DcomLaunch, EventSystem, Winmgmt, MSDTC -ErrorAction SilentlyContinue
    $ComServicesResult = @(
        $ComServices | Select-Object Name, Status, StartType | Format-Table -HideTableHeaders | Out-String
    ) -join '; '

    $ComAppEvents = Get-WinEvent -LogName Application -MaxEvents 50 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProviderName -match 'COMRuntime|COM\+|MSDTC|VSS'
        } |
        Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message |
        Format-Table -AutoSize | Out-String
    $ComAppEventsResult = $ComAppEvents.Trim()

    $FallbackResult = @(
        "OS: $($OsInfo.Caption) $($OsInfo.Version)",
        "LastBootUpTime: $($OsInfo.LastBootUpTime)",
        "DiskInfo: $($DiskInfo.Trim())",
        "NetInfo: $($NetInfo.Trim())",
        "StoppedServices: $($ServiceInfo.Trim())",
        "VolumeInfo: $($VolumeInfo.Trim())",
        "COMServices: $($ComServicesResult.Trim())",
        "COMAppEvents: $($ComAppEventsResult)"
    ) -join '; '
}

$ExportPath = 'C:\Temp\COMHealth.csv'
$ErrorExportPath = 'C:\Temp\COMHealth_error.csv'

[PSCustomObject]@{
    Timestamp      = $Time
    DiskTest       = $DiskResult
    NetAdapterTest = $NetResult
    CimBiosTest    = $BiosResult
} | Export-Csv -Path $ExportPath -Append -NoTypeInformation

if ($AnyFailure) {
    [PSCustomObject]@{
        Timestamp          = $Time
        DiskTest           = $DiskResult
        NetAdapterTest     = $NetResult
        CimBiosTest        = $BiosResult
        AnyFailure         = $AnyFailure
        FallbackRun        = $AnyFailure
        FallbackResult     = $FallbackResult
        ComServicesResult  = $ComServicesResult
        ComAppEventsResult = $ComAppEventsResult
    } | Export-Csv -Path $ErrorExportPath -Append -NoTypeInformation
}