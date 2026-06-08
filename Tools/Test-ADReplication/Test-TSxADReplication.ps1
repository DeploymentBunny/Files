#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
Tests Active Directory and SYSVOL replication health across all domain controllers in the current domain.

.DESCRIPTION
Collects AD replication partner metadata for every domain controller and validates for replication errors.
Checks SYSVOL replication state on each domain controller (DFSR when available, with FRS fallback detection).
If the DFSR module is available, also runs SYSVOL backlog checks between all source/destination DC pairs.
Each test includes start timestamp, end timestamp, and duration in seconds.

.PARAMETER ReplicationFailureThreshold
Number of allowed consecutive replication failures before a DC is flagged as problematic.

.PARAMETER SkipSysvolBacklog
Skips DFSR SYSVOL backlog checks.

.PARAMETER DelayThresholdMinutes
Minutes since last successful AD replication before status is marked as delayed.

.PARAMETER DetailedOutput
Returns detailed raw diagnostic output in addition to friendly per-DC results.

.EXAMPLE
.\Test-TSxADReplication.ps1 -Verbose

.EXAMPLE
.\Test-TSxADReplication.ps1 -ReplicationFailureThreshold 1

.NOTES
	FileName:    Test-TSxADReplication.ps1
	Version:     1.1.3
	Author:      Mikael Nystrom
	Contact:     @mikael_nystrom
	Created:     2026-05-29
	Updated:     2026-05-29
	Twitter:     @mikael_nystrom
	Disclaimer:  This script is provided "AS IS" with no warranties.

.LINK
https://www.deploymentbunny.com
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
	[Parameter()]
	[ValidateRange(0, 100)]
	[int]$ReplicationFailureThreshold = 0,

	[Parameter()]
	[ValidateRange(1, 10080)]
	[int]$DelayThresholdMinutes = 30,

	[Parameter()]
	[switch]$SkipSysvolBacklog,

	[Parameter()]
	[switch]$DetailedOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DfsrStateName {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[int]$State
	)

	switch ($State) {
		0 { 'Uninitialized' }
		1 { 'Initialized' }
		2 { 'Initial Sync' }
		3 { 'Auto Recovery' }
		4 { 'Normal' }
		5 { 'In Error' }
		Default { "Unknown ($State)" }
	}
}

function New-ReplicationResult {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Category,

		[Parameter(Mandatory = $true)]
		[string]$DomainController,

		[Parameter(Mandatory = $true)]
		[datetime]$StartTime,

		[Parameter(Mandatory = $true)]
		[datetime]$EndTime,

		[Parameter(Mandatory = $true)]
		[string]$Status,

		[Parameter(Mandatory = $true)]
		[string]$Details,

		[Parameter()]
		[int]$SampleCount = 0,

		[Parameter()]
		[Nullable[datetime]]$LastSuccess = $null
	)

	[pscustomobject]@{
		Category         = $Category
		DomainController = $DomainController
		StartTime        = $StartTime
		EndTime          = $EndTime
		DurationSeconds  = [math]::Round(($EndTime - $StartTime).TotalSeconds, 2)
		Status           = $Status
		Details          = $Details
		SampleCount      = $SampleCount
		LastSuccess      = $LastSuccess
	}
}

function Get-StatusRank {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[ValidateSet('ok', 'delayed', 'broken')]
		[string]$Status
	)

	switch ($Status) {
		'ok' { 0 }
		'delayed' { 1 }
		'broken' { 2 }
	}
}

function Resolve-StatusFromRank {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[int]$Rank
	)

	switch ($Rank) {
		0 { 'ok' }
		1 { 'delayed' }
		default { 'broken' }
	}
}

$scriptStart = Get-Date
Write-Verbose "[$($scriptStart.ToString('s'))] Starting AD/SYSVOL replication validation."

Import-Module ActiveDirectory -ErrorAction Stop

$domain = Get-ADDomain
$domainControllers = @(Get-ADDomainController -Filter * -Server $domain.DNSRoot | Sort-Object -Property HostName)

if ($domainControllers.Count -eq 0) {
	throw "No domain controllers were found in domain '$($domain.DNSRoot)'."
}

Write-Verbose "Found $($domainControllers.Count) domain controller(s) in domain '$($domain.DNSRoot)'."

$adReplicationResults = @()
$sysvolStateResults = @()
$sysvolShareResults = @()
$sysvolBacklogResults = @()

foreach ($dc in $domainControllers) {
	$dcName = $dc.HostName

	if (-not $PSCmdlet.ShouldProcess($dcName, 'Test AD replication metadata')) {
		continue
	}

	$adStart = Get-Date
	try {
		$partnerMetadata = @(
			Get-ADReplicationPartnerMetadata -Target $dcName -Scope Server -Partition * -ErrorAction Stop
		)

		$problemRows = @(
			$partnerMetadata | Where-Object {
				($_.LastReplicationResult -ne 0) -or ($_.ConsecutiveReplicationFailures -gt $ReplicationFailureThreshold)
			}
		)

		$oldestLastSuccess = $null
		if ($partnerMetadata.Count -gt 0) {
			$oldestLastSuccess = ($partnerMetadata | Sort-Object -Property LastReplicationSuccess | Select-Object -First 1).LastReplicationSuccess
		}

		$adStatus = if ($problemRows.Count -eq 0) { 'Healthy' } else { 'IssuesFound' }
		$adDetail = if ($partnerMetadata.Count -eq 0) {
			'No replication partner metadata returned.'
		} elseif ($problemRows.Count -eq 0) {
			"Replication metadata healthy across $($partnerMetadata.Count) partner sample(s)."
		} else {
			$problemPartners = @($problemRows | Select-Object -ExpandProperty Partner -Unique)
			"Found $($problemRows.Count) issue sample(s) from partner(s): $($problemPartners -join ', ')"
		}

		$adEnd = Get-Date
		$adReplicationResults += New-ReplicationResult -Category 'ADReplication' -DomainController $dcName -StartTime $adStart -EndTime $adEnd -Status $adStatus -Details $adDetail -SampleCount $partnerMetadata.Count -LastSuccess $oldestLastSuccess
	}
	catch {
		$adEnd = Get-Date
		$adReplicationResults += New-ReplicationResult -Category 'ADReplication' -DomainController $dcName -StartTime $adStart -EndTime $adEnd -Status 'Error' -Details $_.Exception.Message
	}

	if (-not $PSCmdlet.ShouldProcess($dcName, 'Test SYSVOL replication state')) {
		continue
	}

	$sysvolStart = Get-Date
	try {
		$dfsrInfo = @(
			Get-CimInstance -ComputerName $dcName -Namespace 'root\microsoftdfs' -ClassName 'DfsrReplicatedFolderInfo' -Filter "ReplicatedFolderName='SYSVOL Share'" -ErrorAction Stop
		)

		if ($dfsrInfo.Count -gt 0) {
			$nonNormal = @($dfsrInfo | Where-Object { $_.State -ne 4 })
			$status = if ($nonNormal.Count -eq 0) { 'Healthy' } else { 'IssuesFound' }
			$stateNames = @($dfsrInfo | ForEach-Object { Get-DfsrStateName -State ([int]$_.State) } | Select-Object -Unique)
			$detail = "DFSR SYSVOL state(s): $($stateNames -join ', ')"

			$sysvolEnd = Get-Date
			$sysvolStateResults += New-ReplicationResult -Category 'SYSVOLState' -DomainController $dcName -StartTime $sysvolStart -EndTime $sysvolEnd -Status $status -Details $detail -SampleCount $dfsrInfo.Count
		}
		else {
			$ntfrsService = Get-Service -ComputerName $dcName -Name 'NtFrs' -ErrorAction SilentlyContinue
			if ($null -ne $ntfrsService) {
				$frsStatus = if ($ntfrsService.Status -eq 'Running') { 'LegacyFRS' } else { 'IssuesFound' }
				$sysvolEnd = Get-Date
				$sysvolStateResults += New-ReplicationResult -Category 'SYSVOLState' -DomainController $dcName -StartTime $sysvolStart -EndTime $sysvolEnd -Status $frsStatus -Details "FRS detected. Service status: $($ntfrsService.Status)."
			}
			else {
				throw 'Unable to detect DFSR SYSVOL folder or FRS service.'
			}
		}
	}
	catch {
		$sysvolEnd = Get-Date
		$sysvolStateResults += New-ReplicationResult -Category 'SYSVOLState' -DomainController $dcName -StartTime $sysvolStart -EndTime $sysvolEnd -Status 'Error' -Details $_.Exception.Message
	}

	if (-not $PSCmdlet.ShouldProcess($dcName, 'Test SYSVOL share availability')) {
		continue
	}

	$sysvolShareStart = Get-Date
	try {
		$sysvolShare = @(
			Get-CimInstance -ComputerName $dcName -ClassName 'Win32_Share' -Filter "Name='SYSVOL'" -ErrorAction Stop
		)

		if ($sysvolShare.Count -gt 0) {
			$sysvolShareEnd = Get-Date
			$sysvolShareResults += New-ReplicationResult -Category 'SYSVOLShare' -DomainController $dcName -StartTime $sysvolShareStart -EndTime $sysvolShareEnd -Status 'Healthy' -Details 'SYSVOL share is present.' -SampleCount $sysvolShare.Count
		}
		else {
			$sysvolShareEnd = Get-Date
			$sysvolShareResults += New-ReplicationResult -Category 'SYSVOLShare' -DomainController $dcName -StartTime $sysvolShareStart -EndTime $sysvolShareEnd -Status 'IssuesFound' -Details 'SYSVOL share is missing on this domain controller.'
			Write-Warning "[$dcName] SYSVOL share is missing. SYSVOL should be shared on every domain controller."
		}
	}
	catch {
		$sysvolShareEnd = Get-Date
		$sysvolShareResults += New-ReplicationResult -Category 'SYSVOLShare' -DomainController $dcName -StartTime $sysvolShareStart -EndTime $sysvolShareEnd -Status 'Error' -Details $_.Exception.Message
		Write-Warning "[$dcName] Unable to validate SYSVOL share presence: $($_.Exception.Message)"
	}
}

$canCheckBacklog = (Get-Command -Name 'Get-DfsrBacklog' -ErrorAction SilentlyContinue) -and -not $SkipSysvolBacklog

if ($canCheckBacklog -and $domainControllers.Count -gt 1) {
	foreach ($sourceDc in $domainControllers) {
		foreach ($destinationDc in $domainControllers) {
			if ($sourceDc.HostName -eq $destinationDc.HostName) {
				continue
			}

			$pairName = "$($sourceDc.HostName) -> $($destinationDc.HostName)"

			if (-not $PSCmdlet.ShouldProcess($pairName, 'Test SYSVOL DFSR backlog')) {
				continue
			}

			$backlogStart = Get-Date
			try {
				$backlogItems = @(
					Get-DfsrBacklog -SourceComputerName $sourceDc.HostName -DestinationComputerName $destinationDc.HostName -GroupName 'Domain System Volume' -FolderName 'SYSVOL Share' -ErrorAction Stop
				)

				$backlogCount = $backlogItems.Count
				$backlogStatus = if ($backlogCount -eq 0) { 'Healthy' } else { 'BacklogDetected' }
				$backlogDetail = "DFSR backlog count: $backlogCount"

				$backlogEnd = Get-Date
				$sysvolBacklogResults += New-ReplicationResult -Category 'SYSVOLBacklog' -DomainController $pairName -StartTime $backlogStart -EndTime $backlogEnd -Status $backlogStatus -Details $backlogDetail -SampleCount $backlogCount
			}
			catch {
				$backlogEnd = Get-Date
				$sysvolBacklogResults += New-ReplicationResult -Category 'SYSVOLBacklog' -DomainController $pairName -StartTime $backlogStart -EndTime $backlogEnd -Status 'Error' -Details $_.Exception.Message
			}
		}
	}
}
elseif (-not $SkipSysvolBacklog) {
	Write-Warning 'Skipping DFSR SYSVOL backlog checks because Get-DfsrBacklog is unavailable or only one domain controller was found.'
}

$scriptEnd = Get-Date

$summary = [pscustomobject]@{
	Domain                    = $domain.DNSRoot
	Started                   = $scriptStart
	Ended                     = $scriptEnd
	DurationSeconds           = [math]::Round(($scriptEnd - $scriptStart).TotalSeconds, 2)
	DomainControllerCount     = $domainControllers.Count
	ADReplicationIssues       = @($adReplicationResults | Where-Object { $_.Status -ne 'Healthy' }).Count
	SYSVOLStateIssues         = @($sysvolStateResults | Where-Object { $_.Status -notin @('Healthy', 'LegacyFRS') }).Count
	SYSVOLShareIssues         = @($sysvolShareResults | Where-Object { $_.Status -ne 'Healthy' }).Count
	SYSVOLBacklogIssues       = @($sysvolBacklogResults | Where-Object { $_.Status -notin @('Healthy') }).Count
	BacklogChecksPerformed    = $sysvolBacklogResults.Count
	ReplicationFailureAllowed = $ReplicationFailureThreshold
}

$friendlyResults = foreach ($dc in $domainControllers) {
	$dcName = $dc.HostName
	$adResult = $adReplicationResults | Where-Object { $_.DomainController -eq $dcName } | Select-Object -First 1
	$sysvolResult = $sysvolStateResults | Where-Object { $_.DomainController -eq $dcName } | Select-Object -First 1
	$sysvolShareResult = $sysvolShareResults | Where-Object { $_.DomainController -eq $dcName } | Select-Object -First 1

	$relatedBacklogResults = @(
		$sysvolBacklogResults | Where-Object {
			$_.DomainController -like "$dcName -> *" -or $_.DomainController -like "* -> $dcName"
		}
	)

	$adStatus = 'broken'
	$adNote = 'No AD replication data returned.'
	$lastSuccess = $null
	$lastSuccessAgeMinutes = $null

	if ($null -ne $adResult) {
		$lastSuccess = $adResult.LastSuccess
		if ($null -ne $lastSuccess) {
			$lastSuccessAgeMinutes = [math]::Round(((Get-Date) - $lastSuccess).TotalMinutes, 2)
		}

		if ($adResult.Status -eq 'Healthy') {
			if (($null -ne $lastSuccessAgeMinutes) -and ($lastSuccessAgeMinutes -gt $DelayThresholdMinutes)) {
				$adStatus = 'delayed'
				$adNote = "Last AD success is $lastSuccessAgeMinutes minute(s) old (threshold $DelayThresholdMinutes)."
			}
			else {
				$adStatus = 'ok'
				$adNote = 'AD replication metadata is healthy.'
			}
		}
		elseif ($adResult.Status -eq 'IssuesFound') {
			$adStatus = 'broken'
			$adNote = $adResult.Details
		}
		else {
			$adStatus = 'broken'
			$adNote = $adResult.Details
		}
	}

	$sysvolStatus = 'broken'
	$sysvolNote = 'No SYSVOL state data returned.'
	if ($null -ne $sysvolResult) {
		switch ($sysvolResult.Status) {
			'Healthy' {
				$sysvolStatus = 'ok'
				$sysvolNote = $sysvolResult.Details
			}
			'LegacyFRS' {
				$sysvolStatus = 'delayed'
				$sysvolNote = $sysvolResult.Details
			}
			'IssuesFound' {
				if ($sysvolResult.Details -like '*Initial Sync*' -or $sysvolResult.Details -like '*Auto Recovery*') {
					$sysvolStatus = 'delayed'
				}
				else {
					$sysvolStatus = 'broken'
				}
				$sysvolNote = $sysvolResult.Details
			}
			default {
				$sysvolStatus = 'broken'
				$sysvolNote = $sysvolResult.Details
			}
		}
	}

	$backlogStatus = 'ok'
	$backlogNote = 'No backlog detected.'
	if ($relatedBacklogResults.Count -gt 0) {
		if (@($relatedBacklogResults | Where-Object { $_.Status -eq 'Error' }).Count -gt 0) {
			$backlogStatus = 'delayed'
			$firstBacklogError = $relatedBacklogResults | Where-Object { $_.Status -eq 'Error' } | Select-Object -First 1
			$backlogNote = "Backlog query returned an error: $($firstBacklogError.Details)"
		}
		elseif (@($relatedBacklogResults | Where-Object { $_.Status -eq 'BacklogDetected' }).Count -gt 0) {
			$backlogStatus = 'delayed'
			$backlogCount = ($relatedBacklogResults | Where-Object { $_.Status -eq 'BacklogDetected' } | Measure-Object -Property SampleCount -Sum).Sum
			if ($null -eq $backlogCount) {
				$backlogCount = 0
			}
			$backlogNote = "SYSVOL backlog item(s) detected: $backlogCount"
		}
	}

	$sysvolShareStatus = 'broken'
	$sysvolShareNote = 'No SYSVOL share data returned.'
	if ($null -ne $sysvolShareResult) {
		if ($sysvolShareResult.Status -eq 'Healthy') {
			$sysvolShareStatus = 'ok'
			$sysvolShareNote = $sysvolShareResult.Details
		}
		else {
			$sysvolShareStatus = 'broken'
			$sysvolShareNote = $sysvolShareResult.Details
		}
	}

	if ($adStatus -eq 'broken' -or $sysvolStatus -eq 'broken' -or $sysvolShareStatus -eq 'broken') {
		$overallStatus = 'broken'
	}
	elseif ($adStatus -eq 'delayed' -or $sysvolStatus -eq 'delayed' -or $backlogStatus -eq 'delayed') {
		$overallStatus = 'delayed'
	}
	else {
		$overallStatus = 'ok'
	}

	$statusReason = if ($overallStatus -eq 'broken') {
		if ($adStatus -eq 'broken') {
			$adNote
		}
		elseif ($sysvolShareStatus -eq 'broken') {
			$sysvolShareNote
		}
		else {
			$sysvolNote
		}
	}
	elseif ($overallStatus -eq 'delayed') {
		if ($adStatus -eq 'delayed') {
			$adNote
		}
		elseif ($sysvolStatus -eq 'delayed') {
			$sysvolNote
		}
		else {
			$backlogNote
		}
	}
	else {
		'No replication problems detected.'
	}

	[pscustomobject]@{
		DomainController           = $dcName
		ReplicationStatus          = $overallStatus
		StatusReason               = $statusReason
		ADReplication              = $adStatus
		SYSVOLReplication          = $sysvolStatus
		SYSVOLShare                = $sysvolShareStatus
		SYSVOLBacklog              = $backlogStatus
		LastReplicationSuccess     = $lastSuccess
		LastSuccessAgeMinutes      = $lastSuccessAgeMinutes
		ADCheckDurationSeconds     = if ($null -ne $adResult) { $adResult.DurationSeconds } else { $null }
		SYSVOLCheckDurationSeconds = if ($null -ne $sysvolResult) { $sysvolResult.DurationSeconds } else { $null }
		SYSVOLShareCheckDurationSeconds = if ($null -ne $sysvolShareResult) { $sysvolShareResult.DurationSeconds } else { $null }
		BacklogChecks              = $relatedBacklogResults.Count
		ADNote                     = $adNote
		SYSVOLNote                 = $sysvolNote
		SYSVOLShareNote            = $sysvolShareNote
		BacklogNote                = $backlogNote
	}
}

$friendlyIssueCount = @($friendlyResults | Where-Object { $_.ReplicationStatus -ne 'ok' }).Count
if ($friendlyIssueCount -gt 0) {
	Write-Warning "Replication validation completed with $friendlyIssueCount non-ok domain controller result(s)."
}

$friendlyDisplayResults = $friendlyResults | Select-Object -Property @(
	'DomainController',
	'ReplicationStatus',
	'StatusReason',
	'ADReplication',
	'SYSVOLReplication',
	'SYSVOLShare',
	'SYSVOLBacklog',
	'LastReplicationSuccess',
	'LastSuccessAgeMinutes',
	'ADCheckDurationSeconds',
	'SYSVOLCheckDurationSeconds',
	'SYSVOLShareCheckDurationSeconds',
	'BacklogChecks'
)

if ($DetailedOutput) {
	[pscustomobject]@{
		Domain               = $domain.DNSRoot
		Summary              = $summary
		FriendlyResults      = $friendlyDisplayResults
		FriendlyResultNotes  = $friendlyResults
		ADReplicationResults = $adReplicationResults
		SYSVOLStateResults   = $sysvolStateResults
		SYSVOLShareResults   = $sysvolShareResults
		SYSVOLBacklogResults = $sysvolBacklogResults
	}
}
else {
	$friendlyDisplayResults
}
