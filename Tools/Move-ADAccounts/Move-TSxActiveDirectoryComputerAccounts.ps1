<#
.SYNOPSIS
Moves Active Directory computer accounts to a specified organizational unit.

.DESCRIPTION
Moves one or more Active Directory computer accounts to a target organizational unit.
Computer accounts can be specified by name or distinguished name, or piped in directly
from Get-TSxActiveDirectoryComputerAccounts.ps1. Accounts that already reside in the
target organizational unit are skipped. The script supports -WhatIf and -Confirm and
returns a result object for each processed computer account. All activity is logged to
a log file in $env:TEMP\Move-TSxActiveDirectoryComputerAccounts.

.PARAMETER Identity
Name, SAM account name or distinguished name of the computer accounts to move. Accepts
pipeline input and binds to the Name and DistinguishedName properties of objects returned
by Get-TSxActiveDirectoryComputerAccounts.ps1.

.PARAMETER TargetOU
Distinguished name of the organizational unit or container the computer accounts are
moved to.

.PARAMETER Server
Domain controller or domain name to use for the operation. Defaults to the closest
domain controller.

.PARAMETER Credential
Optional credential used for the Active Directory operations.

.PARAMETER PassThru
Returns the moved computer account objects from Active Directory instead of the default
result objects.

.EXAMPLE
.\Get-TSxActiveDirectoryComputerAccounts.ps1 -ComputerRole Client -InactiveDays 180 |
	.\Move-TSxActiveDirectoryComputerAccounts.ps1 -TargetOU 'OU=Stale,DC=corp,DC=viamonstra,DC=com'

Moves all client computer accounts that have not contacted Active Directory for 180 days
to the Stale organizational unit.

.EXAMPLE
.\Move-TSxActiveDirectoryComputerAccounts.ps1 -Identity 'PC0001', 'PC0002' -TargetOU 'OU=Workstations,DC=corp,DC=viamonstra,DC=com' -WhatIf

Shows which computer accounts would be moved without performing the move.

.EXAMPLE
.\Get-TSxActiveDirectoryComputerAccounts.ps1 -AccountState Disabled |
	.\Move-TSxActiveDirectoryComputerAccounts.ps1 -TargetOU 'OU=Disabled,DC=corp,DC=viamonstra,DC=com' -Verbose

Moves all disabled computer accounts to the Disabled organizational unit with verbose logging.

.NOTES
	FileName:    Move-TSxActiveDirectoryComputerAccounts.ps1
	Version:     1.0.0
	Author:      Mikael Nystrom
	Contact:     deploymentbunny@outlook.com
	Created:     2026-09-07
	Updated:     2026-09-07
	Twitter:     @mikael_nystrom

	Disclaimer:
	This script is provided "AS IS" with no warranties, confers no rights and
	is not supported by the author.
.LINK
	https://www.deploymentbunny.com
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
[OutputType([PSCustomObject])]
param(
	# Alias order decides pipeline binding: DistinguishedName wins over Name when both exist.
	[Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
	[ValidateNotNullOrEmpty()]
	[Alias('DistinguishedName', 'Name', 'ComputerName')]
	[string[]]$Identity,

	[Parameter(Mandatory = $true)]
	[ValidateNotNullOrEmpty()]
	[string]$TargetOU,

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string]$Server,

	[Parameter()]
	[System.Management.Automation.PSCredential]
	[System.Management.Automation.Credential()]
	$Credential,

	[Parameter()]
	[switch]$PassThru
)

begin {
	Set-StrictMode -Version Latest
	$ErrorActionPreference = 'Stop'

	$Script:LogRootPath = Join-Path $env:TEMP 'Move-TSxActiveDirectoryComputerAccounts'
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

	function Get-TSxMoveResult {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$Name,

			[Parameter(Mandatory = $true)]
			[AllowEmptyString()]
			[string]$SourceDistinguishedName,

			[Parameter(Mandatory = $true)]
			[AllowEmptyString()]
			[string]$TargetDistinguishedName,

			[Parameter(Mandatory = $true)]
			[ValidateSet('Moved', 'Skipped', 'WhatIf', 'Failed')]
			[string]$Status,

			[Parameter()]
			[AllowEmptyString()]
			[string]$Message = ''
		)

		[PSCustomObject]@{
			Name                    = $Name
			Status                  = $Status
			SourceDistinguishedName = $SourceDistinguishedName
			TargetDistinguishedName = $TargetDistinguishedName
			Message                 = $Message
		}
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

	$Script:AdCommonParameters = @{
		ErrorAction = 'Stop'
	}

	if ($PSBoundParameters.ContainsKey('Server')) {
		$Script:AdCommonParameters['Server'] = $Server
	}

	if ($null -ne $Credential) {
		$Script:AdCommonParameters['Credential'] = $Credential
	}

	Write-TSxLog -Message ('TargetOU: {0}' -f $TargetOU) -WriteVerbose
	Write-TSxLog -Message ('Server: {0}' -f $(if ($Script:AdCommonParameters.ContainsKey('Server')) { $Script:AdCommonParameters['Server'] } else { 'Closest domain controller' })) -WriteVerbose
	Write-TSxLog -Message ('Credential supplied: {0}' -f ($null -ne $Credential)) -WriteVerbose

	try {
		$targetObject = Get-ADObject -Identity $TargetOU @Script:AdCommonParameters
	}
	catch {
		Write-TSxLog -Level 'ERROR' -Message ('Target organizational unit not found: {0}' -f $_.Exception.Message)
		throw ("Target organizational unit '{0}' was not found: {1}" -f $TargetOU, $_.Exception.Message)
	}

	if ($targetObject.ObjectClass -notin @('organizationalUnit', 'container')) {
		Write-TSxLog -Level 'ERROR' -Message ('Target object is of type {0} and cannot hold computer accounts.' -f $targetObject.ObjectClass)
		throw ("Target '{0}' is of type '{1}' and is not an organizational unit or container." -f $TargetOU, $targetObject.ObjectClass)
	}

	$Script:TargetDistinguishedName = $targetObject.DistinguishedName
	$Script:MovedCount = 0
	$Script:SkippedCount = 0
	$Script:FailedCount = 0
}

process {
	foreach ($computerIdentity in $Identity) {
		if ([string]::IsNullOrWhiteSpace($computerIdentity)) {
			continue
		}

		$computerIdentity = $computerIdentity.Trim()

		try {
			if ($computerIdentity -match '^(CN|OU|DC)=') {
				$computerAccount = Get-ADComputer -Identity $computerIdentity @Script:AdCommonParameters
			}
			else {
				$computerAccount = Get-ADComputer -Filter 'Name -eq $computerIdentity' @Script:AdCommonParameters
			}
		}
		catch {
			$Script:FailedCount++
			Write-TSxLog -Level 'ERROR' -Message ('Failed to look up computer account {0}: {1}' -f $computerIdentity, $_.Exception.Message)
			Write-Error -Message ("Failed to look up computer account '{0}': {1}" -f $computerIdentity, $_.Exception.Message)
			Get-TSxMoveResult -Name $computerIdentity -SourceDistinguishedName '' -TargetDistinguishedName $Script:TargetDistinguishedName -Status 'Failed' -Message $_.Exception.Message
			continue
		}

		$computerAccount = @($computerAccount)

		if ($computerAccount.Count -eq 0) {
			$Script:FailedCount++
			Write-TSxLog -Level 'WARN' -Message ('Computer account not found: {0}' -f $computerIdentity)
			Write-Error -Message ("Computer account '{0}' was not found." -f $computerIdentity)
			Get-TSxMoveResult -Name $computerIdentity -SourceDistinguishedName '' -TargetDistinguishedName $Script:TargetDistinguishedName -Status 'Failed' -Message 'Computer account not found.'
			continue
		}

		if ($computerAccount.Count -gt 1) {
			$Script:FailedCount++
			Write-TSxLog -Level 'WARN' -Message ('Computer name {0} is ambiguous, {1} accounts found.' -f $computerIdentity, $computerAccount.Count)
			Write-Error -Message ("Computer name '{0}' matched {1} accounts. Use the distinguished name instead." -f $computerIdentity, $computerAccount.Count)
			Get-TSxMoveResult -Name $computerIdentity -SourceDistinguishedName '' -TargetDistinguishedName $Script:TargetDistinguishedName -Status 'Failed' -Message 'Multiple computer accounts matched the name.'
			continue
		}

		$computerAccount = $computerAccount[0]
		$currentParent = ($computerAccount.DistinguishedName -split '(?<!\\),', 2)[1]

		if ($currentParent -eq $Script:TargetDistinguishedName) {
			$Script:SkippedCount++
			Write-TSxLog -Message ('{0} is already located in the target organizational unit.' -f $computerAccount.Name) -WriteVerbose
			Get-TSxMoveResult -Name $computerAccount.Name -SourceDistinguishedName $computerAccount.DistinguishedName -TargetDistinguishedName $Script:TargetDistinguishedName -Status 'Skipped' -Message 'Already in target organizational unit.'
			continue
		}

		$action = 'Move computer account to {0}' -f $Script:TargetDistinguishedName
		if (-not $PSCmdlet.ShouldProcess($computerAccount.DistinguishedName, $action)) {
			Write-TSxLog -Message ('Move of {0} skipped due to WhatIf or Confirm.' -f $computerAccount.Name) -WriteVerbose
			Get-TSxMoveResult -Name $computerAccount.Name -SourceDistinguishedName $computerAccount.DistinguishedName -TargetDistinguishedName $Script:TargetDistinguishedName -Status 'WhatIf' -Message 'Move not performed.'
			continue
		}

		try {
			Move-ADObject -Identity $computerAccount.DistinguishedName -TargetPath $Script:TargetDistinguishedName @Script:AdCommonParameters
		}
		catch {
			$Script:FailedCount++
			Write-TSxLog -Level 'ERROR' -Message ('Failed to move {0}: {1}' -f $computerAccount.Name, $_.Exception.Message)
			Write-Error -Message ("Failed to move '{0}': {1}" -f $computerAccount.Name, $_.Exception.Message)
			Get-TSxMoveResult -Name $computerAccount.Name -SourceDistinguishedName $computerAccount.DistinguishedName -TargetDistinguishedName $Script:TargetDistinguishedName -Status 'Failed' -Message $_.Exception.Message
			continue
		}

		$Script:MovedCount++
		Write-TSxLog -Message ('Moved {0} from {1} to {2}.' -f $computerAccount.Name, $computerAccount.DistinguishedName, $Script:TargetDistinguishedName) -WriteVerbose

		if ($PassThru) {
			Get-ADComputer -Identity ('CN={0},{1}' -f $computerAccount.Name, $Script:TargetDistinguishedName) @Script:AdCommonParameters
		}
		else {
			Get-TSxMoveResult -Name $computerAccount.Name -SourceDistinguishedName $computerAccount.DistinguishedName -TargetDistinguishedName $Script:TargetDistinguishedName -Status 'Moved'
		}
	}
}

end {
	Write-TSxLog -Message ('Moved: {0}, Skipped: {1}, Failed: {2}' -f $Script:MovedCount, $Script:SkippedCount, $Script:FailedCount) -WriteVerbose
	Write-TSxLog -Message 'Script end.' -WriteVerbose
	Write-TSxLog -Message ('Log file: {0}' -f $Script:LogFilePath) -WriteVerbose
}
