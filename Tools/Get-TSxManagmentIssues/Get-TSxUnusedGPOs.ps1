#requires -Version 5.1

<#
.SYNOPSIS
	Gets Group Policy Objects that are not linked or are linked only to empty OUs.

.DESCRIPTION
	Queries all GPOs in the current Active Directory domain and returns GPOs that
	are either completely unlinked or are linked only to Organizational Units that
	contain no non-OU objects.

	The script returns the matching GPO objects as output and prints a readable
	summary on screen.

.PARAMETER Details
	Shows a readable table of the matching GPOs on screen.

.EXAMPLE
	.\Get-TSxUnusedGPOs.ps1 -Verbose

.EXAMPLE
	.\Get-TSxUnusedGPOs.ps1 -Details -Verbose

.NOTES
	FileName:    Get-TSxUnusedGPOs.ps1
	Version:     1.0.3
	Author:      Mikael Nystrom
	Contact:     @mikael_nystrom
	Created:     2026-06-09
	Updated:     2026-06-09
	Twitter:     @mikael_nystrom

	Disclaimer:
	This script is provided "AS IS" with no warranties, confers no rights and
	is not supported by the author.
.LINK
	https://www.deploymentbunny.com
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
	[Parameter()]
	[switch]$Details
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:EnableFileLog = (($PSBoundParameters.ContainsKey('Debug') -and [bool]$PSBoundParameters['Debug']) -or $DebugPreference -eq 'Continue')
$script:LogRootPath = Join-Path -Path $env:TEMP -ChildPath 'Get-TSxUnusedGPOs'
$script:LogFilePath = Join-Path -Path $script:LogRootPath -ChildPath ('{0}.log' -f [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath))

if ($script:EnableFileLog -and -not (Test-Path -Path $script:LogRootPath -PathType Container)) {
	New-Item -Path $script:LogRootPath -ItemType Directory -Force | Out-Null
}

if ($script:EnableFileLog -and (Test-Path -Path $script:LogFilePath -PathType Leaf)) {
	Clear-Content -Path $script:LogFilePath -ErrorAction SilentlyContinue
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
	if ($script:EnableFileLog) {
		Add-Content -Path $script:LogFilePath -Value $entry
	}

	if ($WriteVerbose -or $VerbosePreference -eq 'Continue') {
		Write-Verbose $entry
	}
}

function Convert-TSxNullableDateTimeToText {
	[CmdletBinding()]
	param(
		[Parameter()]
		[AllowNull()]
		[datetime]$Value
	)

	if ($null -eq $Value) {
		return $null
	}

	return $Value.ToString('yyyy-MM-dd HH:mm:ss')
}

function Get-TSxGpoLinksFromDirectory {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$DomainDn,

		[Parameter(Mandatory = $true)]
		[string]$ConfigurationDn
	)

	$links = New-Object System.Collections.Generic.List[object]
	$linkPattern = '\[LDAP://cn=\{(?<GpoId>[0-9A-Fa-f-]+)\},.*?;(?<State>\d)\]'

	$domainTargets = @(Get-ADObject -LDAPFilter '(gPLink=*)' -SearchBase $DomainDn -SearchScope Subtree -Properties gPLink -ErrorAction Stop)
	foreach ($directoryObject in $domainTargets) {
		$targetDn = [string]$directoryObject.DistinguishedName
		if ([string]::IsNullOrWhiteSpace($targetDn) -or [string]::IsNullOrWhiteSpace([string]$directoryObject.gPLink)) {
			continue
		}

		$targetType = if ($targetDn -ieq $DomainDn) { 'Domain' } else { 'OU' }
		foreach ($match in [regex]::Matches([string]$directoryObject.gPLink, $linkPattern, 'IgnoreCase')) {
			$null = $links.Add([pscustomobject]@{
				GpoId      = [guid]$match.Groups['GpoId'].Value
				TargetDn   = $targetDn
				TargetType = $targetType
			})
		}
	}

	$siteTargets = @(Get-ADObject -LDAPFilter '(objectClass=site)' -SearchBase $ConfigurationDn -SearchScope Subtree -Properties gPLink -ErrorAction Stop)
	foreach ($siteObject in $siteTargets) {
		$targetDn = [string]$siteObject.DistinguishedName
		if ([string]::IsNullOrWhiteSpace($targetDn) -or [string]::IsNullOrWhiteSpace([string]$siteObject.gPLink)) {
			continue
		}

		foreach ($match in [regex]::Matches([string]$siteObject.gPLink, $linkPattern, 'IgnoreCase')) {
			$null = $links.Add([pscustomobject]@{
				GpoId      = [guid]$match.Groups['GpoId'].Value
				TargetDn   = $targetDn
				TargetType = 'Site'
			})
		}
	}

	return $links
}

function Test-TSxOuHasObjects {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$DistinguishedName,

		[Parameter(Mandatory = $true)]
		[hashtable]$Cache
	)

	if ($Cache.ContainsKey($DistinguishedName)) {
		return [bool]$Cache[$DistinguishedName]
	}

	$adParams = @{
		SearchBase    = $DistinguishedName
		SearchScope   = 'Subtree'
		LDAPFilter    = '(!(objectClass=organizationalUnit))'
		ResultSetSize = 1
		ErrorAction   = 'Stop'
	}

	$hasObjects = $false
	try {
		$hasObjects = @(Get-ADObject @adParams).Count -gt 0
	}
	catch {
		Write-TSxLog -Message ('Failed to inspect OU {0}: {1}' -f $DistinguishedName, $_.Exception.Message) -Level 'WARN' -WriteVerbose
		$hasObjects = $true
	}

	$Cache[$DistinguishedName] = $hasObjects
	return $hasObjects
}

Import-Module GroupPolicy -ErrorAction Stop
Import-Module ActiveDirectory -ErrorAction Stop

$scriptName = Split-Path -Path $PSCommandPath -Leaf
Write-TSxLog -Message ('{0} started' -f $scriptName)
Write-TSxLog -Message ('Details: {0}' -f $Details.IsPresent)
Write-TSxLog -Message ('File logging enabled: {0}' -f $script:EnableFileLog)
if ($script:EnableFileLog) {
	Write-TSxLog -Message ('Log path: {0}' -f $script:LogFilePath)
}

$domain = Get-ADDomain -ErrorAction Stop
$domainDn = $domain.DistinguishedName
$domainName = $domain.DNSRoot
$rootDse = Get-ADRootDSE -ErrorAction Stop
$configurationDn = $rootDse.ConfigurationNamingContext

$summary = [ordered]@{
	DomainController      = $domain.PDCEmulator
	DomainName            = $domainName
	TotalGpoCount         = 0
	UnusedGpoCount        = 0
	UnlinkedGpoCount      = 0
	EmptyOuLinkedGpoCount = 0
	EmptyOuCount          = 0
	QueryTimeUtc          = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
	LogFile               = $(if ($script:EnableFileLog) { $script:LogFilePath } else { $null })
}

$candidates = New-Object System.Collections.Generic.List[object]
$ouHasObjectsCache = @{}

$queryTarget = 'Active Directory Group Policy in current domain'
if ($PSCmdlet.ShouldProcess($queryTarget, 'Find unused GPOs')) {
	Write-TSxLog -Message ('Domain DN: {0}' -f $domainDn) -WriteVerbose
	Write-TSxLog -Message ('Domain DNS root: {0}' -f $domainName) -WriteVerbose
	Write-TSxLog -Message ('Configuration DN: {0}' -f $configurationDn) -WriteVerbose

	$emptyOuSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
	$organizationalUnits = @(Get-ADOrganizationalUnit -Filter * -SearchBase $domainDn -ErrorAction Stop)
	foreach ($ou in $organizationalUnits) {
		if (-not (Test-TSxOuHasObjects -DistinguishedName $ou.DistinguishedName -Cache $ouHasObjectsCache)) {
			$null = $emptyOuSet.Add($ou.DistinguishedName)
		}
	}
	$summary.EmptyOuCount = @($emptyOuSet).Count

	$gpos = @(Get-GPO -All -Domain $domainName -ErrorAction Stop)
	$summary.TotalGpoCount = @($gpos).Count
	Write-TSxLog -Message ('Loaded {0} GPO(s)' -f $summary.TotalGpoCount) -WriteVerbose

	$linkedTargets = @(Get-TSxGpoLinksFromDirectory -DomainDn $domainDn -ConfigurationDn $configurationDn)
	Write-TSxLog -Message ('Loaded {0} GPO link target(s) from AD' -f @($linkedTargets).Count) -WriteVerbose
	$linkMap = @{}
	foreach ($linkedTarget in $linkedTargets) {
		$linkKey = $linkedTarget.GpoId.Guid
		if (-not $linkMap.ContainsKey($linkKey)) {
			$linkMap[$linkKey] = New-Object System.Collections.Generic.List[object]
		}

		$null = $linkMap[$linkKey].Add($linkedTarget)
	}

	foreach ($gpo in $gpos) {
		$links = if ($linkMap.ContainsKey($gpo.Id.Guid)) { @($linkMap[$gpo.Id.Guid]) } else { @() }
		Write-TSxLog -Message ('GPO {0}: found {1} link target(s) in AD' -f $gpo.DisplayName, @($links).Count) -WriteVerbose
		if (@($links).Count -eq 0) {
			$summary.UnlinkedGpoCount++
			$summary.UnusedGpoCount++
			$null = $candidates.Add([pscustomobject]@{
				DisplayName       = $gpo.DisplayName
				Name              = $gpo.DisplayName
				Id                = $gpo.Id.Guid
				Status            = 'Unlinked'
				LinkCount         = 0
				LinkedTargets     = @()
				EmptyLinkedTargets = @()
				Reason            = 'No links configured'
				GpoStatus         = $gpo.GpoStatus
				Owner             = $gpo.Owner
				CreationTime      = Convert-TSxNullableDateTimeToText -Value $gpo.CreationTime
				ModificationTime  = Convert-TSxNullableDateTimeToText -Value $gpo.ModificationTime
			})
			continue
		}

		if (@(@($links) | Where-Object { $_.TargetType -ne 'OU' }).Count -gt 0) {
			continue
		}

		$ouLinks = @($links | Where-Object { $_.TargetType -eq 'OU' })
		if (@($ouLinks).Count -eq 0) {
			continue
		}

		$linkedOuPaths = New-Object System.Collections.Generic.List[string]
		$allOuLinksEmpty = $true
		foreach ($ouLink in $ouLinks) {
			$ouPath = $ouLink.TargetDn
			if ([string]::IsNullOrWhiteSpace($ouPath)) {
				$allOuLinksEmpty = $false
				break
			}

			$null = $linkedOuPaths.Add($ouPath)
			if (-not $emptyOuSet.Contains($ouPath)) {
				if (Test-TSxOuHasObjects -DistinguishedName $ouPath -Cache $ouHasObjectsCache) {
					$allOuLinksEmpty = $false
					break
				}
			}
		}

		if ($allOuLinksEmpty) {
			$summary.EmptyOuLinkedGpoCount++
			$summary.UnusedGpoCount++
			$null = $candidates.Add([pscustomobject]@{
				DisplayName        = $gpo.DisplayName
				Name               = $gpo.DisplayName
				Id                 = $gpo.Id.Guid
				Status             = 'LinkedToEmptyOU'
				LinkCount          = $links.Count
				LinkedTargets      = @($linkedOuPaths.ToArray())
				EmptyLinkedTargets = @($linkedOuPaths.ToArray())
				Reason             = 'Linked only to empty OU(s)'
				GpoStatus          = $gpo.GpoStatus
				Owner              = $gpo.Owner
				CreationTime       = Convert-TSxNullableDateTimeToText -Value $gpo.CreationTime
				ModificationTime   = Convert-TSxNullableDateTimeToText -Value $gpo.ModificationTime
			})
		}
	}
}
else {
	Write-TSxLog -Message 'WhatIf: skipped GPO query' -Level 'WARN'
}

Write-TSxLog -Message ('Found {0} unused GPO(s)' -f $summary.UnusedGpoCount)
Write-TSxLog -Message ('Unlinked: {0}' -f $summary.UnlinkedGpoCount)
Write-TSxLog -Message ('Linked to empty OU(s): {0}' -f $summary.EmptyOuLinkedGpoCount)
Write-TSxLog -Message ('{0} completed' -f $scriptName)

Write-Host ''
Write-Host 'Unused Group Policy Objects' -ForegroundColor Cyan
Write-Host ('Domain controller : {0}' -f $(if (-not [string]::IsNullOrWhiteSpace($summary.DomainController)) { $summary.DomainController } else { 'N/A' }))
Write-Host ('Domain name       : {0}' -f $summary.DomainName)
Write-Host ('Total GPOs        : {0}' -f $summary.TotalGpoCount)
Write-Host ('Unlinked GPOs     : {0}' -f $summary.UnlinkedGpoCount)
Write-Host ('Empty OU GPOs     : {0}' -f $summary.EmptyOuLinkedGpoCount)
Write-Host ('Returned GPOs     : {0}' -f $summary.UnusedGpoCount)
Write-Host ('Empty OUs found   : {0}' -f $summary.EmptyOuCount)
Write-Host ('Query time (UTC)  : {0}' -f $summary.QueryTimeUtc)

if ($Details.IsPresent) {
	Write-Host ''
	Write-Host 'Matching GPOs' -ForegroundColor Yellow
	if ($candidates.Count -gt 0) {
		$candidates | Sort-Object -Property DisplayName | Format-Table -Property DisplayName, Status, LinkCount, Reason -AutoSize | Out-Host
	}
	else {
		Write-Host 'No unused GPOs found.'
	}
}

$candidates | Sort-Object -Property DisplayName
