$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-TSxActiveDirectoryChanges.ps1'

Describe 'Active Directory object change report' {
    function Get-ADRootDSE {
        [CmdletBinding()]
        param([string]$Server)
    }

    function Get-ADObject {
        [CmdletBinding()]
        param(
            [string]$Server, [string]$SearchBase, [string]$SearchScope,
            [string[]]$Properties, [string]$LDAPFilter, [switch]$IncludeDeletedObjects
        )
    }

    function Get-ADReplicationAttributeMetadata {
        [CmdletBinding()]
        param(
            [string]$Object, [string]$Server,
            [switch]$ShowAllLinkedValues, [switch]$IncludeDeletedObjects
        )
    }

    function New-TestADObject {
        param(
            [string]$Name = 'TestObject',
            [datetime]$Created = $script:cutoff.AddDays(-10),
            [datetime]$Changed = $script:cutoff.AddHours(1),
            [bool]$Deleted = $false,
            [string]$Parent = 'OU=Users,DC=contoso,DC=com'
        )
        [pscustomobject]@{
            Name = $Name
            ObjectClass = 'user'
            ObjectGUID = [guid]::NewGuid()
            sAMAccountName = $Name
            DistinguishedName = "CN=$Name,$Parent"
            whenCreated = $Created
            whenChanged = $Changed
            isDeleted = $Deleted
            lastKnownParent = if ($Deleted) { $Parent } else { $null }
            'msDS-LastKnownRDN' = if ($Deleted) { $Name } else { $null }
        }
    }

    BeforeEach {
        $script:cutoff = [datetime]::SpecifyKind([datetime]'2026-01-01T12:30:00', [DateTimeKind]::Utc)
        $script:live = @()
        $script:deleted = @()
        $script:queries = @()
        $script:denyDeleted = $false
        $script:metadata = @()
        $script:metadataQueries = @()
        $script:denyMetadata = $false
        $script:metadataWarnings = @()
        Mock Write-Warning { param($Message) $script:metadataWarnings += $Message }
        Mock Import-Module {} -ParameterFilter { $Name -eq 'ActiveDirectory' }
        Mock Get-ADRootDSE {
            [pscustomobject]@{
                defaultNamingContext = 'DC=contoso,DC=com'
                dnsHostName = 'dc01.contoso.com'
            }
        }
        Mock Get-ADObject {
            $script:queries += [pscustomobject]@{
                Server = $Server
                SearchBase = $SearchBase
                SearchScope = $SearchScope
                Properties = $Properties
                LDAPFilter = $LDAPFilter
                Deleted = [bool]$IncludeDeletedObjects
            }
            if ($IncludeDeletedObjects) {
                if ($script:denyDeleted) { throw 'Deleted objects access denied.' }
                $script:deleted
            }
            else { $script:live }
        }
        Mock Get-ADReplicationAttributeMetadata {
            $script:metadataQueries += [pscustomobject]@{
                Object = $Object
                Server = $Server
                ShowAllLinkedValues = [bool]$ShowAllLinkedValues
                IncludeDeletedObjects = [bool]$IncludeDeletedObjects
            }
            if ($script:denyMetadata) { throw 'Replication metadata access denied.' }
            $script:metadata
        }
    }

    It 'classifies additions, changes and removals with one row per object' {
        $script:live = @(
            (New-TestADObject -Name 'New' -Created $script:cutoff -Changed $script:cutoff.AddHours(2)),
            (New-TestADObject -Name 'Edited')
        )
        $script:deleted = @(New-TestADObject -Name 'Deleted' -Created $script:cutoff -Deleted $true)
        $result = @(. $scriptPath -Since $script:cutoff)
        $result.Count | Should Be 3
        ($result | Where-Object Name -eq 'New').ChangeType | Should Be 'Added'
        ($result | Where-Object Name -eq 'New').ChangeTimeUtc | Should Be $script:cutoff
        ($result | Where-Object Name -eq 'Edited').ChangeType | Should Be 'Changed'
        ($result | Where-Object Name -eq 'Deleted').ChangeType | Should Be 'Removed'
        @($result[0].PSObject.Properties).Count | Should Be 13
        $result[0].ChangeTimeUtc.Kind | Should Be 'Utc'
        $result[0].DomainController | Should Be 'dc01.contoso.com'
        $script:metadataQueries.Count | Should Be 0
    }

    It 'uses UTC LDAP filters and pins both queries to the resolved DC' {
        . $scriptPath -Since $script:cutoff -Server 'contoso.com'
        $script:queries.Count | Should Be 2
        $script:queries[0].LDAPFilter | Should Be '(&(!(isDeleted=TRUE))(|(whenCreated>=20260101123000.0Z)(whenChanged>=20260101123000.0Z)))'
        $script:queries[1].LDAPFilter | Should Be '(&(isDeleted=TRUE)(whenChanged>=20260101123000.0Z))'
        foreach ($query in $script:queries) {
            $query.Server | Should Be 'dc01.contoso.com'
            $query.SearchScope | Should Be 'Subtree'
        }
        $script:queries[1].Deleted | Should Be $true
        Assert-MockCalled Get-ADRootDSE -Times 1 -Exactly -Scope It -ParameterFilter { $Server -eq 'contoso.com' }
    }

    It 'uses DaysAgo as a rolling interval and defaults to seven days' {
        $script:live = @(New-TestADObject -Changed ([datetime]::UtcNow))
        $result = @(. $scriptPath -DaysAgo 3)
        ($result[0].QueryTimeUtc - $result[0].SinceUtc).TotalDays | Should Be 3
        $defaultResult = @(. $scriptPath)
        ($defaultResult[0].QueryTimeUtc - $defaultResult[0].SinceUtc).TotalDays | Should Be 7
    }

    It 'converts a local start time to UTC' {
        $local = [datetime]::SpecifyKind([datetime]'2026-01-01T12:30:00', [DateTimeKind]::Local)
        . $scriptPath -Since $local
        $expected = $local.ToUniversalTime().ToString("yyyyMMddHHmmss.0'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
        $script:queries[1].LDAPFilter | Should Be "(&(isDeleted=TRUE)(whenChanged>=$expected))"
    }

    It 'preserves the inclusive boundary and rejects second-rounded false positives' {
        $since = $script:cutoff.AddMilliseconds(500)
        $script:live = @(
            (New-TestADObject -Name 'Before' -Changed $script:cutoff),
            (New-TestADObject -Name 'Boundary' -Changed $since)
        )
        $result = @(. $scriptPath -Since $since)
        $result.Count | Should Be 1
        $result[0].Name | Should Be 'Boundary'
    }

    It 'finds deleted objects under an OU using lastKnownParent rather than current DN' {
        $script:deleted = @(
            (New-TestADObject -Name 'Direct' -Deleted $true),
            (New-TestADObject -Name 'Nested' -Deleted $true -Parent 'OU=Nested,OU=Users,DC=contoso,DC=com'),
            (New-TestADObject -Name 'Other' -Deleted $true -Parent 'OU=Other,DC=contoso,DC=com'),
            (New-TestADObject -Name 'Lookalike' -Deleted $true -Parent 'OU=NotUsers,DC=contoso,DC=com'),
            (New-TestADObject -Name 'UnknownParent' -Deleted $true -Parent '')
        )
        foreach ($object in $script:deleted) {
            $object.DistinguishedName = "CN=$($object.Name),CN=Deleted Objects,DC=contoso,DC=com"
        }
        $result = @(. $scriptPath -Since $script:cutoff -SearchBase 'ou=users,dc=contoso,dc=com')
        $result.Count | Should Be 2
        ($result.Name -contains 'Direct') | Should Be $true
        ($result.Name -contains 'Nested') | Should Be $true
        $script:queries[0].SearchBase | Should Be 'ou=users,dc=contoso,dc=com'
        $script:queries[1].SearchBase | Should Be 'DC=contoso,DC=com'
        $result[0].Name | Should Not Match 'Deleted Objects'
    }

    It 'includes retained deleted objects with stripped optional attributes at domain scope' {
        $object = New-TestADObject -Name 'Tombstone' -Deleted $true -Parent ''
        $object.PSObject.Properties.Remove('whenCreated')
        $object.PSObject.Properties.Remove('sAMAccountName')
        $object.PSObject.Properties.Remove('lastKnownParent')
        $object.PSObject.Properties.Remove('msDS-LastKnownRDN')
        $script:deleted = @($object)
        $result = @(. $scriptPath -Since $script:cutoff)
        $result.Count | Should Be 1
        $result[0].Name | Should Be 'Tombstone'
        $result[0].ChangeType | Should Be 'Removed'
    }

    It 'handles non-account live objects with absent optional attributes' {
        $object = New-TestADObject -Name 'OrganizationalUnit'
        $object.ObjectClass = 'organizationalUnit'
        foreach ($name in @('sAMAccountName', 'isDeleted', 'lastKnownParent', 'msDS-LastKnownRDN')) {
            $object.PSObject.Properties.Remove($name)
        }
        $script:live = @($object)
        $result = @(. $scriptPath -Since $script:cutoff)
        $result.Count | Should Be 1
        $result[0].ChangeType | Should Be 'Changed'
        $result[0].SamAccountName | Should BeNullOrEmpty
    }

    It 'emits no success-stream text when there are no results' {
        @(. $scriptPath -Since $script:cutoff).Count | Should Be 0
    }

    It 'reports recent attributes and retained linked metadata with UTC timestamps and a CSV-friendly summary' {
        $script:live = @(New-TestADObject)
        $script:metadata = @(
            [pscustomobject]@{
                AttributeName = 'description'
                LastOriginatingChangeTime = $script:cutoff.ToLocalTime()
                Version = 3
                LastOriginatingChangeDirectoryServerIdentity = 'CN=NTDS Settings,CN=DC02'
                IsLinkValue = $false
            },
            [pscustomobject]@{
                AttributeName = 'member'
                LastOriginatingChangeTime = $script:cutoff.AddHours(1)
                Version = 2
                LastOriginatingChangeDirectoryServerIdentity = 'CN=NTDS Settings,CN=DC03'
                IsLinkValue = $true
            },
            [pscustomobject]@{
                AttributeName = 'member'
                LastOriginatingChangeTime = $script:cutoff.AddHours(2)
                Version = 1
                LastOriginatingChangeDirectoryServerIdentity = 'CN=NTDS Settings,CN=DC03'
                IsLinkValue = $true
            },
            [pscustomobject]@{
                AttributeName = 'oldAttribute'
                LastOriginatingChangeTime = $script:cutoff.AddSeconds(-1)
                Version = 10
            }
        )
        $result = @(. $scriptPath -Since $script:cutoff -IncludeAttributeChanges)
        $result.Count | Should Be 1
        $result[0].ChangedAttributes | Should Be 'description; member'
        $result[0].AttributeMetadataStatus | Should Be 'Available'
        $result[0].AttributeChanges.Count | Should Be 3
        $detail = $result[0].AttributeChanges[0]
        $detail.LastOriginatingChangeTimeUtc | Should Be $script:cutoff
        $detail.LastOriginatingChangeTimeUtc.Kind | Should Be 'Utc'
        $detail.Version | Should Be 3
        $detail.OriginatingDirectoryServerIdentity | Should Be 'CN=NTDS Settings,CN=DC02'
        $result[0].AttributeChanges[1].IsLinkValue | Should Be $true
        $script:metadataQueries.Count | Should Be 1
        $script:metadataQueries[0].Server | Should Be 'dc01.contoso.com'
        $script:metadataQueries[0].Object | Should Be $script:live[0].DistinguishedName
        $script:metadataQueries[0].ShowAllLinkedValues | Should Be $true
        $script:metadataQueries[0].IncludeDeletedObjects | Should Be $false
        $csv = $result | Select-Object Name, ChangedAttributes | ConvertTo-Csv -NoTypeInformation
        ($csv -join "`n") | Should Match 'description; member'
    }

    It 'queries retained deleted metadata and skips deleted objects outside the requested OU' {
        $script:deleted = @(
            (New-TestADObject -Name 'InScope' -Deleted $true),
            (New-TestADObject -Name 'OutOfScope' -Deleted $true -Parent 'OU=Other,DC=contoso,DC=com')
        )
        $script:metadata = @([pscustomobject]@{
            AttributeName = 'isDeleted'
            LastOriginatingChangeTime = $script:cutoff
            Version = 1
        })
        $result = @(. $scriptPath -Since $script:cutoff -IncludeAttributeChanges -SearchBase 'OU=Users,DC=contoso,DC=com')
        $result.Count | Should Be 1
        $result[0].ChangeType | Should Be 'Removed'
        $result[0].ChangedAttributes | Should Be 'isDeleted'
        $script:metadataQueries.Count | Should Be 1
        $script:metadataQueries[0].IncludeDeletedObjects | Should Be $true
    }

    It 'distinguishes no recent metadata from unavailable metadata without discarding the object' {
        $script:live = @(New-TestADObject)
        $script:metadata = @([pscustomobject]@{
            AttributeName = 'description'
            LastOriginatingChangeTime = $script:cutoff.AddSeconds(-1)
            Version = 1
        })
        $result = @(. $scriptPath -Since $script:cutoff -IncludeAttributeChanges)
        $result[0].AttributeMetadataStatus | Should Be 'NoRecentMetadata'
        $result[0].AttributeChanges.Count | Should Be 0
        $result[0].ChangedAttributes | Should BeNullOrEmpty
        $script:metadataWarnings.Count | Should Be 0
        $script:metadata = @()
        $result = @(. $scriptPath -Since $script:cutoff -IncludeAttributeChanges)
        $result[0].AttributeMetadataStatus | Should Be 'Unavailable'
        $script:metadataWarnings.Count | Should Be 1
        $script:metadataWarnings[0] | Should Match 'details are unavailable'
    }

    It 'terminates with object context when replication metadata fails' {
        $script:live = @(New-TestADObject)
        $script:denyMetadata = $true
        { . $scriptPath -Since $script:cutoff -IncludeAttributeChanges } |
            Should Throw "Failed to query replication metadata for 'CN=TestObject,OU=Users,DC=contoso,DC=com'"
    }

    It 'rejects metadata missing its originating timestamp instead of silently omitting it' {
        $script:live = @(New-TestADObject)
        $script:metadata = @([pscustomobject]@{ AttributeName = 'description'; Version = 1 })
        { . $scriptPath -Since $script:cutoff -IncludeAttributeChanges } |
            Should Throw 'has no originating change timestamp'
    }

    It 'fails explicitly when deleted objects cannot be queried' {
        $script:live = @(New-TestADObject)
        $script:denyDeleted = $true
        { . $scriptPath -Since $script:cutoff } | Should Throw 'Deleted objects access denied'
    }

    It 'rejects future dates, non-positive days, conflicting inputs and another domain scope' {
        { . $scriptPath -Since ([datetime]::UtcNow.AddDays(1)) } | Should Throw 'future'
        { . $scriptPath -DaysAgo 0 } | Should Throw
        { . $scriptPath -DaysAgo -1 } | Should Throw
        { . $scriptPath -Since $script:cutoff -DaysAgo 1 } | Should Throw
        { . $scriptPath -Since $script:cutoff -SearchBase 'DC=other,DC=com' } | Should Throw 'selected domain'
    }
}
