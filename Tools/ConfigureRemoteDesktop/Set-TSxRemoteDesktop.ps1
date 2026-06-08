#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
Enables or disables Remote Desktop and configures common RDP settings.

.DESCRIPTION
Administrative utility script that can run locally or against a remote computer.
It tries layered execution methods in this order:
PowerShell remoting, WinRM/CIM, WMI/DCOM, and PsExec.

The tool configures core Remote Desktop settings such as RDP enable/disable, NLA,
firewall rules, listening port, and security/encryption levels. It returns a
friendly summary object for automation.

.PARAMETER Action
Enable or disable Remote Desktop access.

.PARAMETER ComputerName
Target computer to configure. Defaults to the local computer.

.PARAMETER Credential
Optional credential used when connecting to a remote computer.

.PARAMETER NetworkLevelAuthentication
Controls Network Level Authentication (NLA).

.PARAMETER Firewall
Controls Remote Desktop firewall rule group state.

.PARAMETER Port
RDP listener TCP port number.

.PARAMETER SecurityLayer
RDP security layer.

.PARAMETER EncryptionLevel
Minimum encryption level for RDP.

.PARAMETER NoProgress
Suppresses progress output.

.PARAMETER ResultTimeoutSec
How long to wait for a non-remoting result file after starting a remote process.

.EXAMPLE
.\Set-TSxRemoteDesktop.ps1 -Action Enable -ComputerName SRV01 -Verbose

.EXAMPLE
.\Set-TSxRemoteDesktop.ps1 -Action Disable -Firewall Disabled

.EXAMPLE
Invoke-Command -ComputerName SRV01 -FilePath .\Set-TSxRemoteDesktop.ps1 -ArgumentList 'Enable'

.NOTES
	FileName:    Set-TSxRemoteDesktop.ps1
	Version:     1.2.0
	Author:      Mikael Nystrom
	Contact:     deploymentbunny@outlook.com
	Created:     2026-05-29
	Updated:     2026-06-02
	Twitter:     @mikael_nystrom

	Disclaimer:
	This script is provided "AS IS" with no warranties, confers no rights and
	is not supported by the author.
.LINK
	https://www.deploymentbunny.com
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
	[Parameter()]
	[ValidateSet('Enable', 'Disable')]
	[string]$Action = 'Enable',

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string]$ComputerName = $env:COMPUTERNAME,

	[Parameter()]
	[System.Management.Automation.PSCredential]$Credential,

	[Parameter()]
	[ValidateSet('Enabled', 'Disabled')]
	[string]$NetworkLevelAuthentication = 'Enabled',

	[Parameter()]
	[ValidateSet('Enabled', 'Disabled')]
	[string]$Firewall = 'Enabled',

	[Parameter()]
	[ValidateRange(1, 65535)]
	[int]$Port = 3389,

	[Parameter()]
	[ValidateSet('RDP', 'Negotiate', 'SSL')]
	[string]$SecurityLayer = 'Negotiate',

	[Parameter()]
	[ValidateSet('Low', 'ClientCompatible', 'High', 'FipsCompliant')]
	[string]$EncryptionLevel = 'High',

	[Parameter()]
	[switch]$NoProgress,

	[Parameter()]
	[ValidateRange(30, 3600)]
	[int]$ResultTimeoutSec = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:LogRootPath = Join-Path $env:TEMP 'ConfigureRemoteDesktop'
$Script:LogFilePath = Join-Path $Script:LogRootPath ('{0}.log' -f [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath))

if (-not (Test-Path -Path $Script:LogRootPath -PathType Container)) {
	New-Item -Path $Script:LogRootPath -ItemType Directory -Force | Out-Null
}

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

	if ($WriteVerbose -or $VerbosePreference -eq 'Continue') {
		Write-Verbose $entry
	}
}

function Write-TSxProgress {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[int]$Id,

		[Parameter(Mandatory = $true)]
		[string]$Activity,

		[Parameter(Mandatory = $true)]
		[string]$Status,

		[int]$PercentComplete = -1
	)

	if ($NoProgress) {
		return
	}

	if ($PercentComplete -ge 0) {
		Write-Progress -Id $Id -Activity $Activity -Status $Status -PercentComplete $PercentComplete
	}
	else {
		Write-Progress -Id $Id -Activity $Activity -Status $Status
	}
}

function Complete-TSxProgress {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[int]$Id,

		[Parameter(Mandatory = $true)]
		[string]$Activity
	)

	if ($NoProgress) {
		return
	}

	Write-Progress -Id $Id -Activity $Activity -Completed
}

function Test-TSxLocalTarget {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$TargetName
	)

	$normalized = $TargetName.Trim().ToLowerInvariant()
	return $normalized -in @('.', 'localhost', '127.0.0.1', '::1', $env:COMPUTERNAME.ToLowerInvariant())
}

function ConvertTo-TSxSingleQuotedText {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Text
	)

	return $Text.Replace("'", "''")
}

function ConvertTo-TSxEncodedCommand {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Text
	)

	return [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Text))
}

function Get-TSxRemoteDesktopResultPath {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$ComputerName
	)

	$fileName = 'Set-TSxRemoteDesktop.{0}.json' -f ([guid]::NewGuid().ToString('N'))
	if (Test-TSxLocalTarget -TargetName $ComputerName) {
		$path = Join-Path $env:WINDIR "Temp\$fileName"
	}
	else {
		$path = "\\$ComputerName\ADMIN$\Temp\$fileName"
	}

	[pscustomobject]@{
		FileName = $fileName
		Path     = $path
	}
}

function Read-TSxRemoteDesktopResult {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$ResultPath,

		[Parameter()]
		[int]$TimeoutSec = 300
	)

	$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
	while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSec) {
		if (Test-Path -Path $ResultPath -PathType Leaf) {
			$raw = Get-Content -Path $ResultPath -Raw -ErrorAction Stop
			if (-not [string]::IsNullOrWhiteSpace($raw)) {
				return $raw | ConvertFrom-Json
			}
		}

		Start-Sleep -Seconds 2
	}

	return $null
}

function Get-TSxRemoteDesktopPayloadText {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Action,

		[Parameter(Mandatory = $true)]
		[string]$Firewall,

		[Parameter(Mandatory = $true)]
		[int]$Port,

		[Parameter(Mandatory = $true)]
		[string]$SecurityLayer,

		[Parameter(Mandatory = $true)]
		[string]$EncryptionLevel,

		[Parameter(Mandatory = $true)]
		[string]$NetworkLevelAuthentication,

		[Parameter(Mandatory = $true)]
		[string]$TransportUsed,

		[Parameter(Mandatory = $true)]
		[string]$ResultPath,

		[Parameter(Mandatory = $true)]
		[string]$LogPath
	)

	$template = @'
+Set-StrictMode -Version Latest
+$ErrorActionPreference = 'Stop'
+
+$Action = '__ACTION__'
+$Firewall = '__FIREWALL__'
+$Port = [int]__PORT__
+$SecurityLayer = '__SECURITYLAYER__'
+$EncryptionLevel = '__ENCRYPTIONLEVEL__'
+$NetworkLevelAuthentication = '__NLA__'
+$TransportUsed = '__TRANSPORT__'
+$ResultPath = '__RESULTPATH__'
+$LogPath = '__LOGPATH__'
+$ComputerName = $env:COMPUTERNAME
+
+function Write-RemoteLog {
+	param(
+		[string]$Message,
+		[ValidateSet('INFO', 'WARN', 'ERROR')]
+		[string]$Level = 'INFO'
+	)
+
+	$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
+	$entry = "$timestamp [$Level] $Message"
+	Add-Content -Path $LogPath -Value $entry
+}
+
+function Get-SecurityLayerValue {
+	param([string]$Name)
+	switch ($Name) {
+		'RDP' { 0 }
+		'Negotiate' { 1 }
+		'SSL' { 2 }
+	}
+}
+
+function Get-EncryptionLevelValue {
+	param([string]$Name)
+	switch ($Name) {
+		'Low' { 1 }
+		'ClientCompatible' { 2 }
+		'High' { 3 }
+		'FipsCompliant' { 4 }
+	}
+}
+
+function Get-SecurityLayerName {
+	param([int]$Value)
+	switch ($Value) {
+		0 { 'RDP' }
+		1 { 'Negotiate' }
+		2 { 'SSL' }
+		default { "Unknown ($Value)" }
+	}
+}
+
+function Get-EncryptionLevelName {
+	param([int]$Value)
+	switch ($Value) {
+		1 { 'Low' }
+		2 { 'ClientCompatible' }
+		3 { 'High' }
+		4 { 'FipsCompliant' }
+		default { "Unknown ($Value)" }
+	}
+}
+
+function Set-RemoteDesktopFirewallState {
+	param([string]$State)
+
+	$enable = if ($State -eq 'Enabled') { 'True' } else { 'False' }
+	$netFirewallCmd = Get-Command -Name Get-NetFirewallRule -ErrorAction SilentlyContinue
+	if ($null -ne $netFirewallCmd) {
+		Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue | Set-NetFirewallRule -Enabled $enable -ErrorAction Stop
+		return
+	}
+
+	$legacyEnableValue = if ($State -eq 'Enabled') { 'yes' } else { 'no' }
+	netsh advfirewall firewall set rule group='remote desktop' new enable=$legacyEnableValue | Out-Null
+}
+
+$scriptStart = Get-Date
+$terminalServerPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
+$rdpTcpPath = Join-Path $terminalServerPath 'WinStations\RDP-Tcp'
+$resultObject = $null
+
+try {
+	Write-RemoteLog -Message "Starting remote desktop configuration. Action=$Action Firewall=$Firewall Port=$Port SecurityLayer=$SecurityLayer EncryptionLevel=$EncryptionLevel NLA=$NetworkLevelAuthentication"
+
+	if (-not (Test-Path -Path $terminalServerPath -PathType Container)) {
+		throw "Terminal Server registry path was not found: $terminalServerPath"
+	}
+
+	if (-not (Test-Path -Path $rdpTcpPath -PathType Container)) {
+		throw "RDP listener registry path was not found: $rdpTcpPath"
+	}
+
+	$securityLayerValue = Get-SecurityLayerValue -Name $SecurityLayer
+	$encryptionLevelValue = Get-EncryptionLevelValue -Name $EncryptionLevel
+	$nlaValue = if ($NetworkLevelAuthentication -eq 'Enabled') { 1 } else { 0 }
+	$denyTsValue = if ($Action -eq 'Enable') { 0 } else { 1 }
+
+	Set-ItemProperty -Path $terminalServerPath -Name 'fDenyTSConnections' -Value $denyTsValue -Type DWord
+	Set-ItemProperty -Path $rdpTcpPath -Name 'UserAuthentication' -Value $nlaValue -Type DWord
+	Set-ItemProperty -Path $rdpTcpPath -Name 'SecurityLayer' -Value $securityLayerValue -Type DWord
+	Set-ItemProperty -Path $rdpTcpPath -Name 'MinEncryptionLevel' -Value $encryptionLevelValue -Type DWord
+	Set-ItemProperty -Path $rdpTcpPath -Name 'PortNumber' -Value $Port -Type DWord
+
+	if ($Action -eq 'Enable') {
+		Set-Service -Name 'TermService' -StartupType Automatic
+		if ((Get-Service -Name 'TermService').Status -ne 'Running') {
+			Start-Service -Name 'TermService'
+		}
+	}
+	else {
+		if ((Get-Service -Name 'TermService').Status -eq 'Running') {
+			Stop-Service -Name 'TermService' -Force
+		}
+		Set-Service -Name 'TermService' -StartupType Manual
+	}
+
+	if ($Firewall -eq 'Enabled') {
+		Set-RemoteDesktopFirewallState -State 'Enabled'
+	}
+	else {
+		Set-RemoteDesktopFirewallState -State 'Disabled'
+	}
+
+	$rdpProps = Get-ItemProperty -Path $rdpTcpPath
+	$tsProps = Get-ItemProperty -Path $terminalServerPath
+	$service = Get-Service -Name 'TermService'
+	$firewallRules = @()
+	if (Get-Command -Name Get-NetFirewallRule -ErrorAction SilentlyContinue) {
+		$firewallRules = @(Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue)
+	}
+
+	$enabledFirewallCount = @($firewallRules | Where-Object { $_.Enabled -eq 'True' }).Count
+	$firewallStatus = if ($firewallRules.Count -eq 0) {
+		'Unknown'
+	}
+	elseif ($enabledFirewallCount -gt 0) {
+		'Enabled'
+	}
+	else {
+		'Disabled'
+	}
+
+	$resultObject = [pscustomobject]@{
+		ComputerName            = $ComputerName
+		Action                  = $Action
+		TransportUsed           = $TransportUsed
+		RemoteDesktopEnabled    = ([int]$tsProps.fDenyTSConnections -eq 0)
+		NetworkLevelAuthEnabled = ([int]$rdpProps.UserAuthentication -eq 1)
+		FirewallRequested       = $Firewall
+		FirewallStatus          = $firewallStatus
+		RdpPort                 = [int]$rdpProps.PortNumber
+		SecurityLayer           = Get-SecurityLayerName -Value ([int]$rdpProps.SecurityLayer)
+		EncryptionLevel         = Get-EncryptionLevelName -Value ([int]$rdpProps.MinEncryptionLevel)
+		TermServiceStatus       = $service.Status.ToString()
+		Started                 = $scriptStart
+		Ended                   = Get-Date
+		DurationSeconds         = 0
+		Success                 = $true
+		ErrorMessage            = $null
+	}
+	$resultObject.DurationSeconds = [math]::Round(($resultObject.Ended - $resultObject.Started).TotalSeconds, 2)
+}
+catch {
+	$resultObject = [pscustomobject]@{
+		ComputerName            = $ComputerName
+		Action                  = $Action
+		TransportUsed           = $TransportUsed
+		RemoteDesktopEnabled    = $null
+		NetworkLevelAuthEnabled = $null
+		FirewallRequested       = $Firewall
+		FirewallStatus          = $null
+		RdpPort                 = $Port
+		SecurityLayer           = $SecurityLayer
+		EncryptionLevel         = $EncryptionLevel
+		TermServiceStatus       = $null
+		Started                 = $scriptStart
+		Ended                   = Get-Date
+		DurationSeconds         = 0
+		Success                 = $false
+		ErrorMessage            = $_.Exception.Message
+	}
+	$resultObject.DurationSeconds = [math]::Round(($resultObject.Ended - $resultObject.Started).TotalSeconds, 2)
+	Write-RemoteLog -Level 'ERROR' -Message $resultObject.ErrorMessage
+}
+finally {
+	$null = New-Item -Path (Split-Path -Path $ResultPath -Parent) -ItemType Directory -Force -ErrorAction SilentlyContinue
+	$resultObject | ConvertTo-Json -Depth 4 | Set-Content -Path $ResultPath -Encoding UTF8
+	$resultObject
+}
+'@
+
+	$replacements = @{
+		'__ACTION__' = (ConvertTo-TSxSingleQuotedText -Text $Action)
+		'__FIREWALL__' = (ConvertTo-TSxSingleQuotedText -Text $Firewall)
+		'__PORT__' = [string]$Port
+		'__SECURITYLAYER__' = (ConvertTo-TSxSingleQuotedText -Text $SecurityLayer)
+		'__ENCRYPTIONLEVEL__' = (ConvertTo-TSxSingleQuotedText -Text $EncryptionLevel)
+		'__NLA__' = (ConvertTo-TSxSingleQuotedText -Text $NetworkLevelAuthentication)
+		'__TRANSPORT__' = (ConvertTo-TSxSingleQuotedText -Text $TransportUsed)
+		'__RESULTPATH__' = (ConvertTo-TSxSingleQuotedText -Text $ResultPath)
+		'__LOGPATH__' = (ConvertTo-TSxSingleQuotedText -Text $LogPath)
+	}
+
+	foreach ($key in $replacements.Keys) {
+		$template = $template.Replace($key, $replacements[$key])
+	}
+
+	return $template
+}
+
+function Get-TSxPsExecPath {
+	[CmdletBinding()]
+	param()
+
+	$toolRoot = Join-Path $env:TEMP 'ConfigureRemoteDesktop'
+	$pstoolsRoot = Join-Path $toolRoot 'PSTools'
+	$psexecPath = Join-Path $pstoolsRoot 'PsExec.exe'
+
+	if (Test-Path -Path $psexecPath -PathType Leaf) {
+		return $psexecPath
+	}
+
+	if (-not (Test-Path -Path $toolRoot -PathType Container)) {
+		New-Item -Path $toolRoot -ItemType Directory -Force | Out-Null
+	}
+
+	$zipPath = Join-Path $toolRoot 'PSTools.zip'
+	$downloadUri = 'https://download.sysinternals.com/files/PSTools.zip'
+	Write-TSxLog -Level 'WARN' -Message "Downloading PsExec from $downloadUri" -WriteVerbose
+
+	[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
+	Invoke-WebRequest -Uri $downloadUri -OutFile $zipPath -UseBasicParsing
+	if (Test-Path -Path $pstoolsRoot -PathType Container) {
+		Remove-Item -Path $pstoolsRoot -Recurse -Force
+	}
+	Expand-Archive -Path $zipPath -DestinationPath $pstoolsRoot -Force
+
+	if (-not (Test-Path -Path $psexecPath -PathType Leaf)) {
+		throw 'PsExec download completed but PsExec.exe was not found after extraction.'
+	}
+
+	return $psexecPath
+}
+
+function Invoke-TSxRemoteDesktopByPowerShellRemoting {
+	[CmdletBinding()]
+	param(
+		[Parameter(Mandatory = $true)]
+		[string]$ComputerName,
+
+		[Parameter(Mandatory = $true)]
+		[string]$PayloadText,
+
+		[Parameter()]
+		[System.Management.Automation.PSCredential]$Credential
+	)
+
+	$invokeParams = @{ ComputerName = $ComputerName; ScriptBlock = [scriptblock]::Create($PayloadText); ErrorAction = 'Stop' }
+	if ($null -ne $Credential) {
+		$invokeParams.Credential = $Credential
+	}
+
+	return Invoke-Command @invokeParams
+}
+
+function Invoke-TSxRemoteDesktopByCimProcess {
+	[CmdletBinding()]
+	param(
+		[Parameter(Mandatory = $true)]
+		[string]$ComputerName,
+
+		[Parameter(Mandatory = $true)]
+		[string]$PayloadText,
+
+		[Parameter(Mandatory = $true)]
+		[string]$ResultPath,
+
+		[Parameter()]
+		[System.Management.Automation.PSCredential]$Credential
+	)
+
+	$cimSessionParams = @{ ComputerName = $ComputerName }
+	if ($null -ne $Credential) {
+		$cimSessionParams.Credential = $Credential
+	}
+
+	$cimSession = New-CimSession @cimSessionParams
+	try {
+		$encoded = ConvertTo-TSxEncodedCommand -Text $PayloadText
+		$commandLine = "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
+		Invoke-CimMethod -CimSession $cimSession -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $commandLine } -ErrorAction Stop | Out-Null
+	}
+	finally {
+		if ($null -ne $cimSession) {
+			Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue
+		}
+	}
+
+	return Read-TSxRemoteDesktopResult -ResultPath $ResultPath -TimeoutSec $ResultTimeoutSec
+}
+
+function Invoke-TSxRemoteDesktopByWmiProcess {
+	[CmdletBinding()]
+	param(
+		[Parameter(Mandatory = $true)]
+		[string]$ComputerName,
+
+		[Parameter(Mandatory = $true)]
+		[string]$PayloadText,
+
+		[Parameter(Mandatory = $true)]
+		[string]$ResultPath,
+
+		[Parameter()]
+		[System.Management.Automation.PSCredential]$Credential
+	)
+
+	$wmiParams = @{ ComputerName = $ComputerName; Namespace = 'root\cimv2'; Class = 'Win32_Process'; Name = 'Create'; ArgumentList = "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $(ConvertTo-TSxEncodedCommand -Text $PayloadText)"; ErrorAction = 'Stop' }
+	if ($null -ne $Credential) {
+		$wmiParams.Credential = $Credential
+	}
+
+	Invoke-WmiMethod @wmiParams | Out-Null
+	return Read-TSxRemoteDesktopResult -ResultPath $ResultPath -TimeoutSec $ResultTimeoutSec
+}
+
+function Invoke-TSxRemoteDesktopByPsExec {
+	[CmdletBinding()]
+	param(
+		[Parameter(Mandatory = $true)]
+		[string]$ComputerName,
+
+		[Parameter(Mandatory = $true)]
+		[string]$PayloadText,
+
+		[Parameter(Mandatory = $true)]
+		[string]$ResultPath
+	)
+
+	$psexecPath = Get-TSxPsExecPath
+	$arguments = @(
+		"\\$ComputerName"
+		'-accepteula'
+		'-nobanner'
+		'-h'
+		'powershell.exe'
+		'-NoLogo'
+		'-NoProfile'
+		'-NonInteractive'
+		'-ExecutionPolicy'
+		'Bypass'
+		'-EncodedCommand'
+		(ConvertTo-TSxEncodedCommand -Text $PayloadText)
+	)
+
+	Start-Process -FilePath $psexecPath -ArgumentList $arguments -Wait -NoNewWindow | Out-Null
+	return Read-TSxRemoteDesktopResult -ResultPath $ResultPath -TimeoutSec $ResultTimeoutSec
+}
+
+if (-not $PSBoundParameters.ContainsKey('NetworkLevelAuthentication')) {
+	$NetworkLevelAuthentication = if ($Action -eq 'Enable') { 'Enabled' } else { 'Disabled' }
+}
+
+if (-not $PSBoundParameters.ContainsKey('Firewall')) {
+	$Firewall = if ($Action -eq 'Enable') { 'Enabled' } else { 'Disabled' }
+}
+
+$scriptStart = Get-Date
+$activity = 'Configure Remote Desktop'
+$targetComputerName = $ComputerName.Trim()
+$resultInfo = Get-TSxRemoteDesktopResultPath -ComputerName $targetComputerName
+$resultPath = $resultInfo.Path
+
+Write-TSxLog -Message "Script start. Action=$Action Target=$targetComputerName NLA=$NetworkLevelAuthentication Firewall=$Firewall Port=$Port SecurityLayer=$SecurityLayer EncryptionLevel=$EncryptionLevel" -WriteVerbose
+Write-TSxProgress -Id 1 -Activity $activity -Status 'Preparing remote desktop configuration...' -PercentComplete 5
+
+if (-not $PSCmdlet.ShouldProcess($targetComputerName, 'Configure Remote Desktop')) {
+	Complete-TSxProgress -Id 1 -Activity $activity
+	return
+}
+
+$payloadBase = Get-TSxRemoteDesktopPayloadText -Action $Action -Firewall $Firewall -Port $Port -SecurityLayer $SecurityLayer -EncryptionLevel $EncryptionLevel -NetworkLevelAuthentication $NetworkLevelAuthentication -TransportUsed 'Local' -ResultPath $resultPath -LogPath $Script:LogFilePath
+
+try {
+	if (Test-TSxLocalTarget -TargetName $targetComputerName) {
+		Write-TSxLog -Message 'Using local execution path.' -WriteVerbose
+		$result = Invoke-TSxRemoteDesktopByPowerShellRemoting -ComputerName $targetComputerName -PayloadText $payloadBase -Credential $Credential
+		$executionMethod = 'Local'
+	}
+	else {
+		Write-TSxProgress -Id 1 -Activity $activity -Status 'Trying PowerShell remoting...' -PercentComplete 20
+		try {
+			$payload = Get-TSxRemoteDesktopPayloadText -Action $Action -Firewall $Firewall -Port $Port -SecurityLayer $SecurityLayer -EncryptionLevel $EncryptionLevel -NetworkLevelAuthentication $NetworkLevelAuthentication -TransportUsed 'PowerShellRemoting' -ResultPath $resultPath -LogPath $Script:LogFilePath
+			$result = Invoke-TSxRemoteDesktopByPowerShellRemoting -ComputerName $targetComputerName -PayloadText $payload -Credential $Credential
+			$executionMethod = 'PowerShellRemoting'
+		}
+		catch {
+			Write-TSxLog -Level 'WARN' -Message "PowerShell remoting failed on $targetComputerName: $($_.Exception.Message)" -WriteVerbose
+			Write-TSxProgress -Id 1 -Activity $activity -Status 'Trying WinRM/CIM...' -PercentComplete 45
+			try {
+				$payload = Get-TSxRemoteDesktopPayloadText -Action $Action -Firewall $Firewall -Port $Port -SecurityLayer $SecurityLayer -EncryptionLevel $EncryptionLevel -NetworkLevelAuthentication $NetworkLevelAuthentication -TransportUsed 'WinRM-CIM' -ResultPath $resultPath -LogPath $Script:LogFilePath
+				$result = Invoke-TSxRemoteDesktopByCimProcess -ComputerName $targetComputerName -PayloadText $payload -ResultPath $resultPath -Credential $Credential
+				$executionMethod = 'WinRM-CIM'
+			}
+			catch {
+				Write-TSxLog -Level 'WARN' -Message "WinRM/CIM failed on $targetComputerName: $($_.Exception.Message)" -WriteVerbose
+				Write-TSxProgress -Id 1 -Activity $activity -Status 'Trying WMI/DCOM...' -PercentComplete 65
+				try {
+					$payload = Get-TSxRemoteDesktopPayloadText -Action $Action -Firewall $Firewall -Port $Port -SecurityLayer $SecurityLayer -EncryptionLevel $EncryptionLevel -NetworkLevelAuthentication $NetworkLevelAuthentication -TransportUsed 'WMI-DCOM' -ResultPath $resultPath -LogPath $Script:LogFilePath
+					$result = Invoke-TSxRemoteDesktopByWmiProcess -ComputerName $targetComputerName -PayloadText $payload -ResultPath $resultPath -Credential $Credential
+					$executionMethod = 'WMI-DCOM'
+				}
+				catch {
+					Write-TSxLog -Level 'WARN' -Message "WMI/DCOM failed on $targetComputerName: $($_.Exception.Message)" -WriteVerbose
+					Write-TSxProgress -Id 1 -Activity $activity -Status 'Trying PsExec...' -PercentComplete 85
+					$payload = Get-TSxRemoteDesktopPayloadText -Action $Action -Firewall $Firewall -Port $Port -SecurityLayer $SecurityLayer -EncryptionLevel $EncryptionLevel -NetworkLevelAuthentication $NetworkLevelAuthentication -TransportUsed 'PsExec' -ResultPath $resultPath -LogPath $Script:LogFilePath
+					$result = Invoke-TSxRemoteDesktopByPsExec -ComputerName $targetComputerName -PayloadText $payload -ResultPath $resultPath
+					$executionMethod = 'PsExec'
+				}
+			}
+		}
+	}
+
+	if ($null -eq $result) {
+		throw "Remote desktop configuration completed but no result object was returned from $targetComputerName."
+	}
+
+	if (-not $result.Success) {
+		throw $result.ErrorMessage
+	}
+
+	$scriptEnd = Get-Date
+	$output = [pscustomobject]@{
+		ComputerName            = $result.ComputerName
+		TargetComputerName      = $targetComputerName
+		Action                  = $result.Action
+		ExecutionMethod         = $executionMethod
+		ExecutionStatus         = 'Success'
+		RemoteDesktopEnabled    = $result.RemoteDesktopEnabled
+		NetworkLevelAuthEnabled = $result.NetworkLevelAuthEnabled
+		FirewallRequested       = $result.FirewallRequested
+		FirewallStatus          = $result.FirewallStatus
+		RdpPort                 = $result.RdpPort
+		SecurityLayer           = $result.SecurityLayer
+		EncryptionLevel         = $result.EncryptionLevel
+		TermServiceStatus       = $result.TermServiceStatus
+		Started                 = $scriptStart
+		Ended                   = $scriptEnd
+		DurationSeconds         = [math]::Round(($scriptEnd - $scriptStart).TotalSeconds, 2)
+		LogFilePath             = $Script:LogFilePath
+		ResultPath              = $resultPath
+	}
+
+	Write-TSxProgress -Id 1 -Activity $activity -Status 'Completed.' -PercentComplete 100
+	Write-TSxLog -Message "Configuration finished using $executionMethod. RemoteDesktopEnabled=$($output.RemoteDesktopEnabled) Firewall=$($output.FirewallStatus) Port=$($output.RdpPort)" -WriteVerbose
+	$output
+}
+catch {
+	Write-TSxLog -Level 'ERROR' -Message $_.Exception.Message -WriteVerbose
+	throw
+}
+finally {
+	Complete-TSxProgress -Id 1 -Activity $activity
+}
