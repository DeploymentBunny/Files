#requires -Version 5.1

<#
.SYNOPSIS
	Sets the UPN suffix on AD user accounts, keeping the existing UPN prefix.

.DESCRIPTION
	Designed to work together with Get-TSxADusers.ps1: pipe its output (optionally
	filtered through Out-GridView) into this script along with the desired UPN
	suffix, and each user's UserPrincipalName is updated to "<prefix>@<NewUPNSuffix>".

	The existing prefix (the part before '@' in the current UserPrincipalName) is
	preserved. If a user has no UserPrincipalName set, SamAccountName is used as
	the prefix instead.

.PARAMETER Identity
	The user to update. Accepts SamAccountName, DistinguishedName, GUID, or SID.
	Can be supplied via the pipeline, including by property name (e.g. the
	SamAccountName or DistinguishedName properties emitted by Get-TSxADusers.ps1).

.PARAMETER NewUPNSuffix
	The UPN suffix to apply, e.g. 'contoso.com'.

.PARAMETER Server
	Optional domain controller to target for the query and update.

.PARAMETER PassThru
	Emits the updated user object (SamAccountName, UserPrincipalName, Enabled) to the pipeline.

.PARAMETER Force
	Suppresses the per-user confirmation prompt.

.EXAMPLE
	.\Get-TSxADusers.ps1 -SearchBase 'OU=Users,DC=contoso,DC=com' -ExpectedUPNSuffix 'contoso.com' |
		Out-GridView -PassThru |
		.\Set-TSxADUserUPNSuffix.ps1 -NewUPNSuffix 'contoso.com'

.EXAMPLE
	.\Set-TSxADUserUPNSuffix.ps1 -Identity 'jdoe' -NewUPNSuffix 'contoso.com' -PassThru -Verbose

.NOTES
	FileName:    Set-TSxADUserUPNSuffix.ps1
	Version:     1.0.0
	Author:      Mikael Nystrom
	Contact:     deploymentbunny@outlook.com
	Created:     2026-09-11
	Updated:     2026-09-11
	Twitter:     @mikael_nystrom

	Disclaimer:
	This script is provided "AS IS" with no warranties, confers no rights and
	is not supported by the author.
.LINK
	https://www.deploymentbunny.com
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
	[Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
	[ValidateNotNullOrEmpty()]
	[Alias('SamAccountName', 'DistinguishedName')]
	[string]$Identity,

	[Parameter(Mandatory = $true)]
	[ValidateNotNullOrEmpty()]
	[string]$NewUPNSuffix,

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string]$Server,

	[Parameter()]
	[switch]$PassThru,

	[Parameter()]
	[switch]$Force
)

begin {
	Set-StrictMode -Version Latest
	$ErrorActionPreference = 'Stop'

	$script:EnableFileLog = (($PSBoundParameters.ContainsKey('Debug') -and [bool]$PSBoundParameters['Debug']) -or $DebugPreference -eq 'Continue')
	$script:LogRootPath = Join-Path -Path $env:TEMP -ChildPath 'Set-TSxADUserUPNSuffix'
	$script:LogFilePath = Join-Path -Path $script:LogRootPath -ChildPath ('{0}.log' -f [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath))

	if ($script:EnableFileLog -and -not (Test-Path -Path $script:LogRootPath -PathType Container)) {
		New-Item -Path $script:LogRootPath -ItemType Directory -Force | Out-Null
	}

	if ($script:EnableFileLog -and $Force.IsPresent -and (Test-Path -Path $script:LogFilePath -PathType Leaf)) {
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

	$scriptName = Split-Path -Path $PSCommandPath -Leaf

	Write-TSxLog -Message ('{0} started' -f $scriptName)
	Write-TSxLog -Message ('NewUPNSuffix: {0}' -f $NewUPNSuffix)
	Write-TSxLog -Message ('Server: {0}' -f $Server)
	Write-TSxLog -Message ('File logging enabled: {0}' -f $script:EnableFileLog)
	if ($script:EnableFileLog) {
		Write-TSxLog -Message ('Log path: {0}' -f $script:LogFilePath)
	}

	Import-Module ActiveDirectory -ErrorAction Stop

	$adGetParams = @{ ErrorAction = 'Stop' }
	$adSetParams = @{ ErrorAction = 'Stop' }
	if (-not [string]::IsNullOrWhiteSpace($Server)) {
		$adGetParams['Server'] = $Server
		$adSetParams['Server'] = $Server
	}

	$script:UpdatedCount = 0
	$script:SkippedCount = 0
}

process {
	Write-TSxLog -Message ('Processing identity: {0}' -f $Identity) -WriteVerbose

	try {
		$user = Get-ADUser -Identity $Identity -Properties UserPrincipalName @adGetParams
	}
	catch {
		Write-TSxLog -Message ('Failed to look up identity {0}: {1}' -f $Identity, $_.Exception.Message) -Level 'ERROR'
		Write-Warning ('Skipped {0}: {1}' -f $Identity, $_.Exception.Message)
		$script:SkippedCount++
		return
	}

	$currentUpn = $user.UserPrincipalName
	$prefix = if (-not [string]::IsNullOrWhiteSpace($currentUpn) -and $currentUpn.Contains('@')) {
		$currentUpn.Substring(0, $currentUpn.LastIndexOf('@'))
	}
	else {
		$user.SamAccountName
	}

	$newUpn = '{0}@{1}' -f $prefix, $NewUPNSuffix

	if ($currentUpn -eq $newUpn) {
		Write-TSxLog -Message ('{0} already has UPN {1}, skipping' -f $user.SamAccountName, $newUpn) -WriteVerbose
		$script:SkippedCount++
		return
	}

	$target = '{0} (current UPN: {1})' -f $user.SamAccountName, $(if ($currentUpn) { $currentUpn } else { '(none)' })
	if ($PSCmdlet.ShouldProcess($target, "Set UserPrincipalName to '$newUpn'")) {
		if ($Force.IsPresent -or $PSCmdlet.ShouldContinue("Set UserPrincipalName for '$($user.SamAccountName)' to '$newUpn'?", 'Confirm UPN change')) {
			try {
				Set-ADUser -Identity $user.ObjectGUID -UserPrincipalName $newUpn @adSetParams
				Write-TSxLog -Message ('Updated {0}: {1} -> {2}' -f $user.SamAccountName, $currentUpn, $newUpn)
				$script:UpdatedCount++

				if ($PassThru.IsPresent) {
					Get-ADUser -Identity $user.ObjectGUID -Properties UserPrincipalName @adGetParams |
						Select-Object SamAccountName, UserPrincipalName, Enabled
				}
			}
			catch {
				Write-TSxLog -Message ('Failed to update {0}: {1}' -f $user.SamAccountName, $_.Exception.Message) -Level 'ERROR'
				Write-Warning ('Failed to update {0}: {1}' -f $user.SamAccountName, $_.Exception.Message)
				$script:SkippedCount++
			}
		}
		else {
			Write-TSxLog -Message ('User declined update for {0}' -f $user.SamAccountName) -Level 'WARN'
			$script:SkippedCount++
		}
	}
	else {
		Write-TSxLog -Message ('WhatIf: skipped update for {0}' -f $user.SamAccountName) -Level 'WARN'
	}
}

end {
	Write-TSxLog -Message ('Updated {0} user(s), skipped {1} user(s)' -f $script:UpdatedCount, $script:SkippedCount)
	Write-TSxLog -Message ('{0} completed' -f $scriptName)
}
