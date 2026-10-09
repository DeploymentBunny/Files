#requires -Version 5.1

<#
.SYNOPSIS
    Lists Active Directory objects added, changed or removed since a given time.

.DESCRIPTION
    Queries live objects using whenCreated/whenChanged and retained deleted
    objects using whenChanged. Returns one row per object: Removed takes
    precedence over Added, and Added takes precedence over Changed.

    This is a current-state report, not an audit trail. With
    -IncludeAttributeChanges, replication metadata identifies attributes
    with a latest originating change at or after the requested start time.
    It does not identify previous values or the person making the change.
    whenChanged is local to the queried domain controller; replication and
    later updates to deleted objects can affect the reported timestamp.
    Removed timestamps are therefore approximate, not proven deletion times.
    Objects already purged from AD cannot be reported. Deleted-object access
    requires appropriate permissions; failed queries terminate the script.

    Requires the ActiveDirectory PowerShell module (RSAT). The default scope
    is the selected domain controller's domain, not the entire forest.
    The script is read-only and emits objects suitable for Export-Csv or
    Out-GridView. All output timestamps are UTC.

.PARAMETER Since
    Inclusive start date/time. A value without a timezone is interpreted in
    the local timezone. Cannot be combined with DaysAgo.

.PARAMETER DaysAgo
    Number of 24-hour periods to look back from the start of the run.
    Defaults to 7. Cannot be combined with Since.

.PARAMETER Server
    Optional domain controller or domain to query. Queries are pinned to
    the domain controller returned by Get-ADRootDSE for a consistent view.

.PARAMETER SearchBase
    Optional OU/container distinguished name within the selected domain.
    Searches the entire subtree. Removed objects are matched using their
    lastKnownParent because their current DN is in Deleted Objects.
    If an OU was moved or renamed, retained lastKnownParent values may no
    longer match the current OU path.

.PARAMETER IncludeAttributeChanges
    Queries replication metadata for each reported object on the same DC.
    Adds ChangedAttributes (semicolon-separated names, suitable for CSV),
    AttributeChanges (nested detail objects), and AttributeMetadataStatus.
    Details contain AttributeName, LastOriginatingChangeTimeUtc, Version,
    OriginatingDirectoryServerIdentity (the originating DC's NTDS Settings
    DN, not necessarily its hostname), and IsLinkValue.

    All retained linked-value metadata is requested, including group member
    links. Multiple details can therefore have the same attribute name.
    This is not a complete change history or proof of a specific operation
    such as enabling/disabling an account. Added objects include attribute
    initialization; Removed objects may have stripped metadata.
    NoRecentMetadata means no retained metadata matches the cutoff, not
    that the object did not change. Unavailable means no metadata was returned
    and generates a warning. Query failures terminate the script.
    This option adds one query per reported object and can take longer.

.EXAMPLE
    .\Get-TSxActiveDirectoryChanges.ps1 -DaysAgo 3

.EXAMPLE
    .\Get-TSxActiveDirectoryChanges.ps1 -Since '2026-10-01T08:30:00' -Server 'dc01.contoso.com'

.EXAMPLE
    .\Get-TSxActiveDirectoryChanges.ps1 -DaysAgo 7 -SearchBase 'OU=Users,DC=contoso,DC=com' |
        Export-Csv -Path '.\ADChanges.csv' -NoTypeInformation -Encoding UTF8

.EXAMPLE
    .\Get-TSxActiveDirectoryChanges.ps1 -DaysAgo 30 |
        Where-Object ChangeType -eq 'Removed' | Out-GridView

.EXAMPLE
    .\Get-TSxActiveDirectoryChanges.ps1 -DaysAgo 7 -IncludeAttributeChanges |
        Select-Object ChangeType, Name, ChangeTimeUtc, ChangedAttributes, AttributeMetadataStatus |
        Export-Csv -Path '.\ADAttributeChanges.csv' -NoTypeInformation -Encoding UTF8

.EXAMPLE
    $changes = .\Get-TSxActiveDirectoryChanges.ps1 -DaysAgo 7 -IncludeAttributeChanges
    $changes | Where-Object Name -eq 'jdoe' | Select-Object -ExpandProperty AttributeChanges

.NOTES
    FileName:    Get-TSxActiveDirectoryChanges.ps1
    Version:     1.1.0
    Author:      Mikael Nystrom
    Contact:     deploymentbunny@outlook.com
    Created:     2026-10-09
    Updated:     2026-10-09

.LINK
    https://www.deploymentbunny.com
#>

[CmdletBinding(DefaultParameterSetName = 'DaysAgo')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Since')]
    [Alias('StartDate')]
    [datetime]$Since,

    [Parameter(ParameterSetName = 'DaysAgo')]
    [ValidateRange(1, 2147483647)]
    [int]$DaysAgo = 7,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Server,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SearchBase,

    [Parameter()]
    [switch]$IncludeAttributeChanges
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TSxADPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    # AD may omit unset attributes entirely, especially on tombstones.
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { $property.Value }
}

$queryTimeUtc = [datetime]::UtcNow
$sinceUtc = if ($PSCmdlet.ParameterSetName -eq 'Since') {
    $Since.ToUniversalTime()
}
else {
    $queryTimeUtc.AddDays(-$DaysAgo)
}
if ($sinceUtc -gt $queryTimeUtc) {
    throw 'Since must not be in the future.'
}

Import-Module ActiveDirectory -ErrorAction Stop
$rootParams = @{ ErrorAction = 'Stop' }
if ($PSBoundParameters.ContainsKey('Server')) { $rootParams.Server = $Server }
$rootDse = Get-ADRootDSE @rootParams
$domainBase = [string]$rootDse.defaultNamingContext
$domainController = [string]$rootDse.dnsHostName
if ([string]::IsNullOrWhiteSpace($domainBase) -or [string]::IsNullOrWhiteSpace($domainController)) {
    throw 'The selected server did not return a domain naming context and domain controller hostname.'
}

if (-not $PSBoundParameters.ContainsKey('SearchBase')) { $SearchBase = $domainBase }
$comparison = [System.StringComparison]::OrdinalIgnoreCase
if (-not ($SearchBase.Equals($domainBase, $comparison) -or $SearchBase.EndsWith(",$domainBase", $comparison))) {
    throw "SearchBase must be within the selected domain '$domainBase'. Use -Server to select another domain."
}

# LDAP generalized time must be UTC and culture-independent.
$ldapSince = $sinceUtc.ToString("yyyyMMddHHmmss.0'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
$adParams = @{
    Server = $domainController
    SearchScope = 'Subtree'
    Properties = @('whenCreated', 'whenChanged', 'isDeleted', 'lastKnownParent', 'msDS-LastKnownRDN', 'sAMAccountName')
    ErrorAction = 'Stop'
}

Write-Verbose ("Querying {0} from {1:o} (UTC); SearchBase: {2}" -f $domainController, $sinceUtc, $SearchBase)
$liveObjects = @(Get-ADObject @adParams -SearchBase $SearchBase `
    -LDAPFilter "(&(!(isDeleted=TRUE))(|(whenCreated>=$ldapSince)(whenChanged>=$ldapSince)))")

# Deleted objects have moved out of their original OU, so search the domain root.
$deletedObjects = @(Get-ADObject @adParams -SearchBase $domainBase -IncludeDeletedObjects `
    -LDAPFilter "(&(isDeleted=TRUE)(whenChanged>=$ldapSince))")

$report = @(
    foreach ($object in @($liveObjects) + @($deletedObjects)) {
        $isDeleted = ((Get-TSxADPropertyValue -Object $object -Name 'isDeleted') -eq $true)
        $lastKnownParent = [string](Get-TSxADPropertyValue -Object $object -Name 'lastKnownParent')
        if ($isDeleted -and -not $SearchBase.Equals($domainBase, $comparison)) {
            if (-not ($lastKnownParent.Equals($SearchBase, $comparison) -or $lastKnownParent.EndsWith(",$SearchBase", $comparison))) {
                continue
            }
        }

        $created = Get-TSxADPropertyValue -Object $object -Name 'whenCreated'
        $changed = Get-TSxADPropertyValue -Object $object -Name 'whenChanged'
        $createdUtc = if ($null -ne $created) { ([datetime]$created).ToUniversalTime() } else { $null }
        $changedUtc = if ($null -ne $changed) { ([datetime]$changed).ToUniversalTime() } else { $null }
        $changeType = if ($isDeleted) { 'Removed' } elseif ($null -ne $createdUtc -and $createdUtc -ge $sinceUtc) { 'Added' } else { 'Changed' }
        $changeTimeUtc = if ($changeType -eq 'Added') { $createdUtc } else { $changedUtc }

        # LDAP filtering is second-granular; retain the exact requested boundary.
        if ($null -eq $changeTimeUtc) {
            throw "Object '$($object.DistinguishedName)' has no timestamp for '$changeType'."
        }
        if ($changeTimeUtc -lt $sinceUtc) { continue }

        $lastKnownRdn = [string](Get-TSxADPropertyValue -Object $object -Name 'msDS-LastKnownRDN')
        $name = if ($isDeleted -and -not [string]::IsNullOrWhiteSpace($lastKnownRdn)) {
            $lastKnownRdn
        }
        else { [string]$object.Name }

        $entry = [pscustomobject]@{
            ChangeType = $changeType
            ChangeTimeUtc = $changeTimeUtc
            Name = $name
            ObjectClass = $object.ObjectClass
            ObjectGUID = $object.ObjectGUID
            SamAccountName = Get-TSxADPropertyValue -Object $object -Name 'sAMAccountName'
            DistinguishedName = $object.DistinguishedName
            LastKnownParent = $lastKnownParent
            WhenCreatedUtc = $createdUtc
            WhenChangedUtc = $changedUtc
            DomainController = $domainController
            SinceUtc = $sinceUtc
            QueryTimeUtc = $queryTimeUtc
        }
        if ($IncludeAttributeChanges) {
            Write-Verbose ("Querying replication metadata for '{0}'" -f $object.DistinguishedName)
            $metadataParams = @{
                Object = $object.DistinguishedName
                Server = $domainController
                ShowAllLinkedValues = $true
                IncludeDeletedObjects = $isDeleted
                ErrorAction = 'Stop'
            }
            try {
                $metadata = @(Get-ADReplicationAttributeMetadata @metadataParams)
            }
            catch {
                throw "Failed to query replication metadata for '$($object.DistinguishedName)' on '${domainController}': $($_.Exception.Message)"
            }
            $attributeChanges = @(
                foreach ($attribute in $metadata) {
                    $originatingTime = Get-TSxADPropertyValue -Object $attribute -Name 'LastOriginatingChangeTime'
                    if ($null -eq $originatingTime) {
                        throw "Replication metadata for '$($object.DistinguishedName)' attribute '$($attribute.AttributeName)' has no originating change timestamp."
                    }
                    $originatingTimeUtc = ([datetime]$originatingTime).ToUniversalTime()
                    if ($originatingTimeUtc -lt $sinceUtc) { continue }

                    [pscustomobject]@{
                        AttributeName = $attribute.AttributeName
                        LastOriginatingChangeTimeUtc = $originatingTimeUtc
                        Version = $attribute.Version
                        OriginatingDirectoryServerIdentity = Get-TSxADPropertyValue -Object $attribute -Name 'LastOriginatingChangeDirectoryServerIdentity'
                        IsLinkValue = Get-TSxADPropertyValue -Object $attribute -Name 'IsLinkValue'
                    }
                }
            )
            $attributeChanges = @($attributeChanges | Sort-Object -Property LastOriginatingChangeTimeUtc, AttributeName)
            $metadataStatus = if ($metadata.Count -eq 0) { 'Unavailable' } elseif ($attributeChanges.Count -eq 0) { 'NoRecentMetadata' } else { 'Available' }
            if ($metadata.Count -eq 0) {
                Write-Warning "No replication metadata returned for '$($object.DistinguishedName)' on '$domainController'; attribute change details are unavailable."
            }
            $entry | Add-Member -NotePropertyName ChangedAttributes -NotePropertyValue (($attributeChanges | ForEach-Object { $_.AttributeName } | Sort-Object -Unique) -join '; ')
            $entry | Add-Member -NotePropertyName AttributeChanges -NotePropertyValue $attributeChanges
            $entry | Add-Member -NotePropertyName AttributeMetadataStatus -NotePropertyValue $metadataStatus
        }
        $entry
    }
)

Write-Verbose ("Found {0} object(s): Added={1}, Changed={2}, Removed={3}" -f $report.Count,
    @($report | Where-Object ChangeType -eq 'Added').Count,
    @($report | Where-Object ChangeType -eq 'Changed').Count,
    @($report | Where-Object ChangeType -eq 'Removed').Count)
$report | Sort-Object -Property ChangeTimeUtc, ChangeType, DistinguishedName
