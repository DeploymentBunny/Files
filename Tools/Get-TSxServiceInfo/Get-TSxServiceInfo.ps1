<#
.SYNOPSIS
Checks services and processes on remote Windows servers using PowerShell remoting.

.DESCRIPTION
Connects to one or more remote Windows servers with Invoke-Command and checks whether
the specified services and processes exist. Services are reported with state
(Running/Stopped) and startup type. Processes are reported with state and instance
count. Services and processes are reported in separate sections per server using
colored text output. All activity is logged to a log file in $env:TEMP\Get-TSxServiceInfo.

.PARAMETER ComputerName
One or more remote Windows servers to query. Accepts pipeline input.

.PARAMETER ServiceName
One or more service names to check. Matches both service Name and DisplayName.

.PARAMETER ProcessName
One or more process names to check. The .exe extension is optional.

.PARAMETER Credential
Optional credential used for the remote PowerShell connections.

.PARAMETER UseSSL
Connects over HTTPS (port 5986) instead of HTTP (port 5985).

.EXAMPLE
.\Get-TSxServiceInfo.ps1 -ComputerName 'SRV01', 'SRV02' -ServiceName 'WinRM', 'W3SVC' -ProcessName 'notepad'

Checks the WinRM and W3SVC services and the notepad process on SRV01 and SRV02.

.EXAMPLE
'SRV01', 'SRV02' | .\Get-TSxServiceInfo.ps1 -ServiceName 'Spooler' -Verbose

Pipes two server names into the script and checks the Print Spooler service.

.EXAMPLE
.\Get-TSxServiceInfo.ps1 -ComputerName 'SRV01' -ServiceName 'WinRM' -WhatIf

Shows what would be queried without connecting to the remote server.

.NOTES
	FileName:    Get-TSxServiceInfo.ps1
	Version:     1.0.0
	Author:      Mikael Nystrom
	Contact:     deploymentbunny@outlook.com
	Created:     2026-09-03
	Updated:     2026-09-03
	Twitter:     @mikael_nystrom

	Disclaimer:
	This script is provided "AS IS" with no warranties, confers no rights and
	is not supported by the author.
.LINK
	https://www.deploymentbunny.com
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
	[Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
	[ValidateNotNullOrEmpty()]
	[Alias('CN', 'Server')]
	[string[]]$ComputerName,

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string[]]$ServiceName,

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string[]]$ProcessName,

	[Parameter()]
	[System.Management.Automation.PSCredential]
	[System.Management.Automation.Credential()]
	$Credential,

	[Parameter()]
	[switch]$UseSSL
)

begin {
	Set-StrictMode -Version Latest
	$ErrorActionPreference = 'Stop'

	$Script:LogRootPath = Join-Path $env:TEMP 'Get-TSxServiceInfo'
	$Script:LogFilePath = Join-Path $Script:LogRootPath ("{0}.log" -f [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath))

	function Write-TSxLog {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$Message,

			[ValidateSet('INFO', 'WARN', 'ERROR')]
			[string]$Level = 'INFO',

			[switch]$WriteVerbose
		)

		$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
		$entry = "$timestamp [$Level] $Message"
		Add-Content -Path $Script:LogFilePath -Value $entry

		if ($WriteVerbose) {
			Write-Verbose $entry
		}
	}

	function Write-TSxReportLine {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[AllowEmptyString()]
			[string]$Text,

			[Parameter()]
			[System.ConsoleColor]$ForegroundColor = [System.ConsoleColor]::Gray
		)

		Write-Host -Object $Text -ForegroundColor $ForegroundColor
	}

	function Get-TSxStatusColor {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[bool]$Exists,

			[Parameter(Mandatory = $true)]
			[string]$State
		)

		if (-not $Exists) {
			return [System.ConsoleColor]::Red
		}

		switch ($State) {
			'Running' { return [System.ConsoleColor]::Green }
			'Stopped' { return [System.ConsoleColor]::Yellow }
			default { return [System.ConsoleColor]::DarkYellow }
		}
	}

	if (-not (Test-Path -Path $Script:LogRootPath)) {
		New-Item -Path $Script:LogRootPath -ItemType Directory -Force | Out-Null
	}
	Write-TSxLog -Message 'Script start.' -WriteVerbose

	if (-not $ServiceName -and -not $ProcessName) {
		Write-TSxLog -Level 'ERROR' -Message 'No services or processes specified.'
		throw 'Specify at least one of -ServiceName or -ProcessName.'
	}

	$computerList = New-Object System.Collections.Generic.List[string]
}

process {
	foreach ($computer in $ComputerName) {
		if (-not [string]::IsNullOrWhiteSpace($computer)) {
			$computerList.Add($computer.Trim())
		}
	}
}

end {
	if ($computerList.Count -eq 0) {
		Write-TSxLog -Level 'ERROR' -Message 'No valid computer names provided.'
		throw 'No valid computer names provided.'
	}

	Write-TSxLog -Message ('ComputerName: {0}' -f ($computerList -join ', ')) -WriteVerbose
	Write-TSxLog -Message ('ServiceName: {0}' -f ($ServiceName -join ', ')) -WriteVerbose
	Write-TSxLog -Message ('ProcessName: {0}' -f ($ProcessName -join ', ')) -WriteVerbose
	Write-TSxLog -Message ('UseSSL: {0}' -f $UseSSL.IsPresent) -WriteVerbose
	Write-TSxLog -Message ('Credential supplied: {0}' -f ($null -ne $Credential)) -WriteVerbose

	$remoteScript = {
		param(
			[string[]]$Services,
			[string[]]$Processes
		)

		$allServices = @()
		$allProcesses = @()

		try {
			if ($null -ne $Services -and $Services.Count -gt 0) {
				$allServices = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)
			}
			if ($null -ne $Processes -and $Processes.Count -gt 0) {
				$allProcesses = @(Get-Process -ErrorAction Stop)
			}
		}
		catch {
			[PSCustomObject]@{
				Kind    = 'QueryError'
				Message = $_.Exception.Message
			}
			return
		}

		$queryResults = New-Object System.Collections.Generic.List[object]

		foreach ($service in $Services) {
			$serviceMatch = $allServices | Where-Object { $_.Name -eq $service -or $_.DisplayName -eq $service } | Select-Object -First 1
			if ($null -ne $serviceMatch) {
				$queryResults.Add([PSCustomObject]@{
						Kind        = 'Service'
						Name        = $serviceMatch.Name
						DisplayName = $serviceMatch.DisplayName
						Exists      = $true
						State       = [string]$serviceMatch.State
						StartMode   = [string]$serviceMatch.StartMode
					})
			}
			else {
				$queryResults.Add([PSCustomObject]@{
						Kind        = 'Service'
						Name        = $service
						DisplayName = ''
						Exists      = $false
						State       = 'NotFound'
						StartMode   = ''
					})
			}
		}

		foreach ($process in $Processes) {
			$processBaseName = $process -replace '\.exe$', ''
			$processMatches = @($allProcesses | Where-Object { $_.Name -eq $processBaseName })
			if ($processMatches.Count -gt 0) {
				$queryResults.Add([PSCustomObject]@{
						Kind   = 'Process'
						Name   = $processMatches[0].Name
						Exists = $true
						State  = 'Running'
						Count  = $processMatches.Count
					})
			}
			else {
				$queryResults.Add([PSCustomObject]@{
						Kind   = 'Process'
						Name   = $processBaseName
						Exists = $false
						State  = 'NotFound'
						Count  = 0
					})
			}
		}

		$queryResults
	}

	$invokeSplat = @{
		ComputerName  = [string[]]$computerList
		ScriptBlock   = $remoteScript
		ArgumentList  = @($ServiceName, $ProcessName)
		ErrorAction   = 'SilentlyContinue'
		ErrorVariable = 'invokeErrors'
	}
	if ($null -ne $Credential) {
		$invokeSplat['Credential'] = $Credential
	}
	if ($UseSSL.IsPresent) {
		$invokeSplat['UseSSL'] = $true
	}

	$invokeErrors = $null
	$remoteData = @()
	$targetDescription = $computerList -join ', '

	if ($PSCmdlet.ShouldProcess($targetDescription, 'Query services and processes')) {
		Write-TSxLog -Message ('Connecting to {0} using PowerShell remoting.' -f $targetDescription) -WriteVerbose
		$remoteData = @(Invoke-Command @invokeSplat)
	}
	else {
		Write-TSxLog -Level 'WARN' -Message ('WhatIf mode skipped remote query for {0}' -f $targetDescription)
		Write-TSxReportLine -Text ('WhatIf: would query services and processes on {0}. No remote connections were made.' -f $targetDescription) -ForegroundColor Yellow
		return
	}

	$unreachableServers = @{}
	foreach ($invokeError in $invokeErrors) {
		$failedServer = [string]$invokeError.TargetObject
		if ([string]::IsNullOrWhiteSpace($failedServer)) {
			$failedServer = 'Unknown'
		}
		if (-not $unreachableServers.ContainsKey($failedServer)) {
			$unreachableServers[$failedServer] = $invokeError.Exception.Message
		}
		Write-TSxLog -Level 'ERROR' -Message ('Remote query failed for {0}: {1}' -f $failedServer, $invokeError.Exception.Message)
	}

	Write-TSxReportLine -Text ''
	Write-TSxReportLine -Text ('=' * 70) -ForegroundColor Cyan
	Write-TSxReportLine -Text ' Service and Process status report' -ForegroundColor Cyan
	Write-TSxReportLine -Text ('=' * 70) -ForegroundColor Cyan
	Write-TSxReportLine -Text (' Servers   : {0}' -f $targetDescription) -ForegroundColor Gray
	if ($ServiceName) {
		Write-TSxReportLine -Text (' Services  : {0}' -f ($ServiceName -join ', ')) -ForegroundColor Gray
	}
	if ($ProcessName) {
		Write-TSxReportLine -Text (' Processes : {0}' -f ($ProcessName -join ', ')) -ForegroundColor Gray
	}
	Write-TSxReportLine -Text ' Legend    : Green = Running, Yellow = Stopped, DarkYellow = Other state, Red = Does not exist / unreachable' -ForegroundColor DarkGray

	foreach ($computer in $computerList) {
		Write-TSxReportLine -Text ''
		Write-TSxReportLine -Text ('Server: {0}' -f $computer) -ForegroundColor White
		Write-TSxReportLine -Text ('-' * 70) -ForegroundColor DarkCyan

		if ($unreachableServers.ContainsKey($computer)) {
			Write-TSxReportLine -Text ('  ERROR: {0}' -f $unreachableServers[$computer]) -ForegroundColor Red
			continue
		}

		$serverResults = @($remoteData | Where-Object { $_.PSComputerName -eq $computer })

		$queryError = $serverResults | Where-Object { $_.Kind -eq 'QueryError' } | Select-Object -First 1
		if ($null -ne $queryError) {
			Write-TSxReportLine -Text ('  ERROR: {0}' -f $queryError.Message) -ForegroundColor Red
			continue
		}

		if ($serverResults.Count -eq 0) {
			Write-TSxReportLine -Text '  WARNING: No data returned from this server.' -ForegroundColor DarkYellow
			continue
		}

		if ($ServiceName) {
			Write-TSxReportLine -Text ''
			Write-TSxReportLine -Text '  Services' -ForegroundColor Cyan
			Write-TSxReportLine -Text ('    {0,-28} {1,-15} {2,-12} {3}' -f 'Name', 'Status', 'Startup', 'Display name') -ForegroundColor DarkGray

			foreach ($serviceResult in ($serverResults | Where-Object { $_.Kind -eq 'Service' })) {
				$statusText = $serviceResult.State
				$startupText = $serviceResult.StartMode
				if ($startupText -eq 'Auto') {
					$startupText = 'Automatic'
				}
				if (-not $serviceResult.Exists) {
					$statusText = 'Does not exist'
					$startupText = '-'
				}

				$lineColor = Get-TSxStatusColor -Exists $serviceResult.Exists -State $serviceResult.State
				Write-TSxReportLine -Text ('    {0,-28} {1,-15} {2,-12} {3}' -f $serviceResult.Name, $statusText, $startupText, $serviceResult.DisplayName) -ForegroundColor $lineColor
				Write-TSxLog -Message ('{0} service {1}: Exists={2}; State={3}; StartMode={4}' -f $computer, $serviceResult.Name, $serviceResult.Exists, $serviceResult.State, $serviceResult.StartMode)
			}
		}

		if ($ProcessName) {
			Write-TSxReportLine -Text ''
			Write-TSxReportLine -Text '  Processes' -ForegroundColor Cyan
			Write-TSxReportLine -Text ('    {0,-28} {1,-15} {2}' -f 'Name', 'Status', 'Instances') -ForegroundColor DarkGray

			foreach ($processResult in ($serverResults | Where-Object { $_.Kind -eq 'Process' })) {
				$statusText = $processResult.State
				$instanceText = [string]$processResult.Count
				if (-not $processResult.Exists) {
					$statusText = 'Does not exist'
					$instanceText = '-'
				}

				$lineColor = Get-TSxStatusColor -Exists $processResult.Exists -State $processResult.State
				Write-TSxReportLine -Text ('    {0,-28} {1,-15} {2}' -f $processResult.Name, $statusText, $instanceText) -ForegroundColor $lineColor
				Write-TSxLog -Message ('{0} process {1}: Exists={2}; State={3}; Count={4}' -f $computer, $processResult.Name, $processResult.Exists, $processResult.State, $processResult.Count)
			}
		}
	}

	Write-TSxReportLine -Text ''
	Write-TSxReportLine -Text ('=' * 70) -ForegroundColor Cyan
	$reachableCount = $computerList.Count - $unreachableServers.Count
	Write-TSxReportLine -Text (' Summary: {0} server(s) queried, {1} reachable, {2} unreachable' -f $computerList.Count, $reachableCount, $unreachableServers.Count) -ForegroundColor Cyan
	if ($unreachableServers.Count -gt 0) {
		Write-TSxReportLine -Text (' Unreachable: {0}' -f ($unreachableServers.Keys -join ', ')) -ForegroundColor Red
	}
	Write-TSxReportLine -Text (' Log file: {0}' -f $Script:LogFilePath) -ForegroundColor DarkGray
	Write-TSxLog -Message 'Script end.' -WriteVerbose
}
