<#
.SYNOPSIS
Gets computer accounts from Active Directory with filtering on role, account state and last contact.

.DESCRIPTION
Queries Active Directory for computer accounts and returns them as objects that include
computer role (DomainController, MemberServer or Client), account state (Enabled/Disabled),
operating system information and the number of days since the account last contacted
Active Directory. Results can be filtered on computer role, on enabled or disabled accounts
and on accounts that have not contacted Active Directory within a given number of days.
All activity is logged to a log file in $env:TEMP\Get-TSxActiveDirectoryComputerAccounts.

.PARAMETER ComputerRole
Filters the result on computer role. Valid values are All, DomainController, MemberServer
and Client. Multiple values can be specified. Default is All.

.PARAMETER AccountState
Filters the result on account state. Valid values are All, Enabled and Disabled.
Default is All.

.PARAMETER InactiveDays
Only returns computer accounts that have not contacted Active Directory within the
specified number of days. Accounts that have never contacted Active Directory are
always included when this parameter is used.

.PARAMETER SearchBase
The Active Directory organizational unit or container to search in. Accepts either a
distinguished name, for example 'OU=Workstations,DC=corp,DC=viamonstra,DC=com', or the
name of an organizational unit or container, for example 'Workstations' or 'Computers',
which is then resolved to a distinguished name. Defaults to the whole domain.

.PARAMETER SearchScope
Scope of the Active Directory search. Valid values are Base, OneLevel and Subtree.
Default is Subtree.

.PARAMETER Server
Domain controller or domain name to query. Defaults to the closest domain controller.

.PARAMETER Credential
Optional credential used for the Active Directory query.

.EXAMPLE
.\Get-TSxActiveDirectoryComputerAccounts.ps1

Returns all computer accounts in the current domain.

.EXAMPLE
.\Get-TSxActiveDirectoryComputerAccounts.ps1 -ComputerRole Client -AccountState Enabled -InactiveDays 90

Returns all enabled client computer accounts that have not contacted Active Directory
for the last 90 days.

.EXAMPLE
.\Get-TSxActiveDirectoryComputerAccounts.ps1 -ComputerRole MemberServer, DomainController -Verbose

Returns all member servers and domain controllers with verbose logging.

.EXAMPLE
.\Get-TSxActiveDirectoryComputerAccounts.ps1 -SearchBase 'OU=Workstations,DC=corp,DC=viamonstra,DC=com' -AccountState Disabled

Returns all disabled computer accounts in the Workstations organizational unit.

.EXAMPLE
.\Get-TSxActiveDirectoryComputerAccounts.ps1 -SearchBase 'Computers' -SearchScope OneLevel

Resolves the container named Computers and returns the computer accounts directly below it.

.NOTES
	FileName:    Get-TSxActiveDirectoryComputerAccounts.ps1
	Version:     1.1.0
	Author:      Mikael Nystrom
	Contact:     deploymentbunny@outlook.com
	Created:     2026-09-07
	Updated:     2026-09-07
	Twitter:     @mikael_nystrom

	Version history:
	1.1.0 - SearchBase now accepts an organizational unit or container name in addition to a distinguished name.
	1.0.0 - Initial release.

	Disclaimer:
	This script is provided "AS IS" with no warranties, confers no rights and
	is not supported by the author.
.LINK
	https://www.deploymentbunny.com
#>
[CmdletBinding(SupportsShouldProcess = $true)]
[OutputType([PSCustomObject])]
param(
	[Parameter()]
	[ValidateSet('All', 'DomainController', 'MemberServer', 'Client')]
	[string[]]$ComputerRole = 'All',

	[Parameter()]
	[ValidateSet('All', 'Enabled', 'Disabled')]
	[string]$AccountState = 'All',

	[Parameter()]
	[ValidateRange(0, 36500)]
	[int]$InactiveDays,

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[Alias('SearchRoot', 'OU')]
	[string]$SearchBase,

	[Parameter()]
	[ValidateSet('Base', 'OneLevel', 'Subtree')]
	[string]$SearchScope = 'Subtree',

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string]$Server,

	[Parameter()]
	[System.Management.Automation.PSCredential]
	[System.Management.Automation.Credential()]
	$Credential
)

begin {
	Set-StrictMode -Version Latest
	$ErrorActionPreference = 'Stop'

	$Script:LogRootPath = Join-Path $env:TEMP 'Get-TSxActiveDirectoryComputerAccounts'
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

	function Get-TSxComputerRole {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[int]$PrimaryGroupId,

			[Parameter(Mandatory = $true)]
			[AllowEmptyString()]
			[AllowNull()]
			[string]$OperatingSystem
		)

		# PrimaryGroupID 516 = Domain Controllers, 521 = Read-only Domain Controllers
		if ($PrimaryGroupId -eq 516 -or $PrimaryGroupId -eq 521) {
			return 'DomainController'
		}

		if ($OperatingSystem -like '*Server*') {
			return 'MemberServer'
		}

		return 'Client'
	}

	function Resolve-TSxSearchBase {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$SearchBase,

			[Parameter(Mandatory = $true)]
			[hashtable]$AdParameters
		)

		$searchBaseValue = $SearchBase.Trim()

		if ($searchBaseValue -match '^(CN|OU|DC)=') {
			try {
				$adObject = Get-ADObject -Identity $searchBaseValue @AdParameters
			}
			catch {
				throw ("The search base '{0}' was not found: {1}" -f $searchBaseValue, $_.Exception.Message)
			}
		}
		else {
			# Single quotes are required so the AD filter engine binds $searchBaseValue safely.
			$adObject = @(Get-ADObject -Filter '(objectClass -eq "organizationalUnit" -or objectClass -eq "container") -and Name -eq $searchBaseValue' @AdParameters)

			if ($adObject.Count -eq 0) {
				throw ("No organizational unit or container named '{0}' was found." -f $searchBaseValue)
			}

			if ($adObject.Count -gt 1) {
				throw ("The name '{0}' matched {1} organizational units or containers. Use the distinguished name instead: {2}" -f $searchBaseValue, $adObject.Count, (($adObject.DistinguishedName) -join '; '))
			}

			$adObject = $adObject[0]
		}

		if ($adObject.ObjectClass -notin @('organizationalUnit', 'container', 'domainDNS', 'builtinDomain')) {
			throw ("The search base '{0}' is of type '{1}' and cannot contain computer accounts." -f $searchBaseValue, $adObject.ObjectClass)
		}

		return $adObject.DistinguishedName
	}

	if (-not (Test-Path -Path $Script:LogRootPath)) {
		New-Item -Path $Script:LogRootPath -ItemType Directory -Force | Out-Null
	}
	Write-TSxLog -Message 'Script start.' -WriteVerbose

	if (-not (Get-Module -Name ActiveDirectory -ListAvailable)) {
		Write-TSxLog -Level 'ERROR' -Message 'The ActiveDirectory PowerShell module is not available.'
		throw 'The ActiveDirectory PowerShell module is not available. Install RSAT Active Directory tools and try again.'
	}

	Import-Module -Name ActiveDirectory -ErrorAction Stop -Verbose:$false
}

process {
	if ($ComputerRole -contains 'All') {
		$roleFilter = @('DomainController', 'MemberServer', 'Client')
	}
	else {
		$roleFilter = @($ComputerRole)
	}

	$adParameters = @{
		Properties  = @('OperatingSystem', 'OperatingSystemVersion', 'LastLogonDate', 'PrimaryGroupID', 'Description', 'whenCreated')
		SearchScope = $SearchScope
		ErrorAction = 'Stop'
	}

	switch ($AccountState) {
		'Enabled' { $adParameters['Filter'] = 'Enabled -eq $true' }
		'Disabled' { $adParameters['Filter'] = 'Enabled -eq $false' }
		default { $adParameters['Filter'] = '*' }
	}

	if ($PSBoundParameters.ContainsKey('Server')) {
		$adParameters['Server'] = $Server
	}

	if ($null -ne $Credential) {
		$adParameters['Credential'] = $Credential
	}

	if ($PSBoundParameters.ContainsKey('SearchBase')) {
		$lookupParameters = @{ ErrorAction = 'Stop' }
		foreach ($key in @('Server', 'Credential')) {
			if ($adParameters.ContainsKey($key)) {
				$lookupParameters[$key] = $adParameters[$key]
			}
		}

		try {
			$adParameters['SearchBase'] = Resolve-TSxSearchBase -SearchBase $SearchBase -AdParameters $lookupParameters
		}
		catch {
			Write-TSxLog -Level 'ERROR' -Message ('Failed to resolve search base: {0}' -f $_.Exception.Message)
			throw
		}

		if ($adParameters['SearchBase'] -ne $SearchBase) {
			Write-TSxLog -Message ('Search base {0} resolved to {1}.' -f $SearchBase, $adParameters['SearchBase']) -WriteVerbose
		}
	}

	$inactiveLimit = $null
	if ($PSBoundParameters.ContainsKey('InactiveDays')) {
		$inactiveLimit = (Get-Date).AddDays(-$InactiveDays)
	}

	Write-TSxLog -Message ('ComputerRole: {0}' -f ($roleFilter -join ', ')) -WriteVerbose
	Write-TSxLog -Message ('AccountState: {0}' -f $AccountState) -WriteVerbose
	Write-TSxLog -Message ('InactiveDays: {0}' -f $(if ($null -ne $inactiveLimit) { $InactiveDays } else { 'Not used' })) -WriteVerbose
	Write-TSxLog -Message ('SearchBase: {0}' -f $(if ($adParameters.ContainsKey('SearchBase')) { $adParameters['SearchBase'] } else { 'Domain root' })) -WriteVerbose
	Write-TSxLog -Message ('SearchScope: {0}' -f $SearchScope) -WriteVerbose
	Write-TSxLog -Message ('Server: {0}' -f $(if ($adParameters.ContainsKey('Server')) { $adParameters['Server'] } else { 'Closest domain controller' })) -WriteVerbose
	Write-TSxLog -Message ('Credential supplied: {0}' -f ($null -ne $Credential)) -WriteVerbose

	$target = $(if ($adParameters.ContainsKey('SearchBase')) { $adParameters['SearchBase'] } else { 'the current domain' })
	if (-not $PSCmdlet.ShouldProcess($target, 'Query Active Directory for computer accounts')) {
		Write-TSxLog -Message 'Query skipped due to WhatIf.' -WriteVerbose
		return
	}

	try {
		$computerAccounts = @(Get-ADComputer @adParameters)
	}
	catch {
		Write-TSxLog -Level 'ERROR' -Message ('Failed to query Active Directory: {0}' -f $_.Exception.Message)
		throw
	}

	Write-TSxLog -Message ('Computer accounts returned from Active Directory: {0}' -f $computerAccounts.Count) -WriteVerbose

	$now = Get-Date
	$resultCount = 0

	foreach ($computerAccount in $computerAccounts) {
		$operatingSystem = $computerAccount.OperatingSystem
		$role = Get-TSxComputerRole -PrimaryGroupId $computerAccount.PrimaryGroupID -OperatingSystem $operatingSystem

		if ($roleFilter -notcontains $role) {
			continue
		}

		$lastLogonDate = $computerAccount.LastLogonDate

		if ($null -ne $inactiveLimit -and $null -ne $lastLogonDate -and $lastLogonDate -gt $inactiveLimit) {
			continue
		}

		$daysSinceLastContact = $null
		if ($null -ne $lastLogonDate) {
			$daysSinceLastContact = [int][math]::Floor(($now - $lastLogonDate).TotalDays)
		}

		$resultCount++

		[PSCustomObject]@{
			Name                   = $computerAccount.Name
			DNSHostName            = $computerAccount.DNSHostName
			ComputerRole           = $role
			Enabled                = $computerAccount.Enabled
			OperatingSystem        = $operatingSystem
			OperatingSystemVersion = $computerAccount.OperatingSystemVersion
			LastLogonDate          = $lastLogonDate
			DaysSinceLastContact   = $daysSinceLastContact
			WhenCreated            = $computerAccount.whenCreated
			Description            = $computerAccount.Description
			DistinguishedName      = $computerAccount.DistinguishedName
		}
	}

	Write-TSxLog -Message ('Computer accounts matching the filters: {0}' -f $resultCount) -WriteVerbose
}

end {
	Write-TSxLog -Message 'Script end.' -WriteVerbose
	Write-TSxLog -Message ('Log file: {0}' -f $Script:LogFilePath) -WriteVerbose
}
