<#
.SYNOPSIS

.DESCRIPTION

.LINK
    http://syscenramblings.wordpress.com
.NOTES
    FileName: New-TSxCATemplate.ps1
    Author: Peter Lofgren
    Contact: @Lofgren Peter
    Created: 2023-02-25

    Version - 0.0.3 - 2026-09-25

    License Info:
    MIT License
    Copyright (c) 2023 TRUESEC

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.


.EXAMPLE
New-TSXCATemplate.ps1
#>

Function Get-RandomHex {
    param ([int]$Length)
    $Hex = '0123456789ABCDEF'
    [string]$Return = $null
    For ($i = 1; $i -le $length; $i++) {
        $Return += $Hex.Substring((Get-Random -Minimum 0 -Maximum 16), 1)
    }
    Return $Return
}
Function IsUniqueOID {
    param ($cn, $TemplateOID, $Server, $ConfigNC)
    $Search = Get-ADObject -Server $Server `
        -SearchBase "CN=OID,CN=Public Key Services,CN=Services,$ConfigNC" `
        -Filter { cn -eq $cn -and msPKI-Cert-Template-OID -eq $TemplateOID }
    If ($Search) { $False } Else { $True }
}
Function New-TemplateOID {
    Param($Server, $ConfigNC)
    <#
    OID CN/Name                                                         [10000000-99999999].[32 hex characters (MD5hash)]
    OID msPKI-Cert-Template-OID    [Forest base OID].[1000000-99999999].[10000000-99999999]  <--- second number same as first number in OID name
    #>
    do {
        $OID_Part_1 = Get-Random -Minimum 10000000 -Maximum 99999999
        $OID_Part_2 = Get-Random -Minimum 10000000 -Maximum 99999999
        $OID_Part_3 = Get-RandomHex -Length 32
        $OID_Forest = Get-ADObject -Server $Server `
            -Identity "CN=OID,CN=Public Key Services,CN=Services,$ConfigNC" `
            -Properties msPKI-Cert-Template-OID |
        Select-Object -ExpandProperty msPKI-Cert-Template-OID
        $msPKICertTemplateOID = "$OID_Forest.$OID_Part_1.$OID_Part_2"
        $Name = "$OID_Part_2.$OID_Part_3"
    } until (IsUniqueOID -cn $Name -TemplateOID $msPKICertTemplateOID -Server $Server -ConfigNC $ConfigNC)
    Return @{
        TemplateOID  = $msPKICertTemplateOID
        TemplateName = $Name
    }
}
Function Get-ADCSTemplate {
    param(
        [parameter(Position = 0)]
        [string]
        $DisplayName,

        [string]
        $Server = (Get-ADDomainController -Discover -ForceDiscover -Writable).HostName[0]
    )
    If ($PSBoundParameters.ContainsKey('DisplayName')) {
        $LDAPFilter = "(&(objectClass=pKICertificateTemplate)(displayName=$DisplayName))"
    }
    Else {
        $LDAPFilter = '(objectClass=pKICertificateTemplate)'
    }

    $ConfigNC = $((Get-ADRootDSE -Server $Server).configurationNamingContext)
    $TemplatePath = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigNC"
    Get-ADObject -SearchScope Subtree -SearchBase $TemplatePath -LDAPFilter $LDAPFilter -Properties * -Server $Server
}
Function Set-ADCSTemplateACL {
    param(
        [parameter(Mandatory)]
        [string]$DisplayName,
        [string]$Server = (Get-ADDomainController -Discover -ForceDiscover -Writable).HostName[0],
        [ValidateSet('Allow', 'Deny')]
        [string]$Type = 'Allow',
        [string[]]$Identity,
        [switch]$Enroll,
        [switch]$AutoEnroll
    )
    ## Potential issue here that the AD: drive may not be targetting the selected DC in the -SERVER parameter
    $TemplatePath = "AD:\" + (Get-ADCSTemplate -DisplayName $DisplayName -Server $Server).DistinguishedName
    $acl = Get-ACL $TemplatePath
    $InheritedObjectType = [GUID]'00000000-0000-0000-0000-000000000000'

    # Remove System
    $RemoveRule = $acl.Access | Where-Object { $_.IdentityReference -eq "NT AUTHORITY\SYSTEM" }
    $acl.RemoveAccessRule($RemoveRule)

    ForEach ($Group in $Identity) {
        $account = New-Object System.Security.Principal.NTAccount($Group)
        $sid = $account.Translate([System.Security.Principal.SecurityIdentifier])

        If ($Type -ne 'Deny') {
            # Read, but only if Allow
            $ObjectType = [GUID]'00000000-0000-0000-0000-000000000000'
            $ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule `
                $sid, 'GenericRead', $Type, $ObjectType, 'None', $InheritedObjectType
            $acl.AddAccessRule($ace)
        }

        If ($Enroll) {
            $ObjectType = [GUID]'0e10c968-78fb-11d2-90d4-00c04f79dc55'
            $ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule `
                $sid, 'ExtendedRight', $Type, $ObjectType, 'None', $InheritedObjectType
            $acl.AddAccessRule($ace)
        }

        If ($AutoEnroll) {
            $ObjectType = [GUID]'a05b8cc2-17bc-4802-a710-e7c15ab866a2'
            $ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule `
                $sid, 'ExtendedRight', $Type, $ObjectType, 'None', $InheritedObjectType
            $acl.AddAccessRule($ace)
        }
    }
    $ACL.SetAccessRuleProtection($True, $False)
    Set-ACL $TemplatePath -AclObject $acl
}
Function New-ADCSTemplate {
    param(
        [parameter(Mandatory)]
        [string]$DisplayName, # name in JSON export is ignored
        [parameter(Mandatory)]
        [ValidateSet('AuthenticatedSession', 'KerberosAuthentication', 'WebServer', 'WorkstationAuthentication')]
        [string]$Template,
        [string]$Server = (Get-ADDomainController -Discover -ForceDiscover -Writable).HostName[0],
        [string[]]$Identity, # = "$((Get-ADDomain).NetBIOSName)\Domain Computers",
        [switch]$AutoEnroll,
        [switch]$Publish
    )
    ### Put GroupName and AutoEnroll into a parameter set

    # Manually import AD module to get AD: drive used later for permissions
    Import-Module ActiveDirectory -Verbose:$false

    $ConfigNC = $((Get-ADRootDSE -Server $Server).configurationNamingContext)

    #region CREATE OID
    <#
    CN                              : 14891906.F2AC4390685318BD1D950A66EDB50FF4
    DisplayName                     : TemplateNameHere
    DistinguishedName               : CN=14891906.F2AC4390685318BD1D950A66EDB50FF4,CN=OID,CN=Public Key Services,CN=Services,CN=Configuration,DC=contoso,DC=com
    dSCorePropagationData           : {1/1/1601 12:00:00 AM}
    flags                           : 1
    instanceType                    : 4
    msPKI-Cert-Template-OID         : 1.3.6.1.4.1.311.21.8.11489019.14294623.5588661.594850.12204198.151.6616009.14891906
    Name                            : 14891906.F2AC4390685318BD1D950A66EDB50FF4
    ObjectCategory                  : CN=ms-PKI-Enterprise-Oid,CN=Schema,CN=Configuration,DC=contoso,DC=com
    ObjectClass                     : msPKI-Enterprise-Oid
    #>
    $OID = New-TemplateOID -Server $Server -ConfigNC $ConfigNC
    $TemplateOIDPath = "CN=OID,CN=Public Key Services,CN=Services,$ConfigNC"
    $oa = @{
        'DisplayName'             = $DisplayName
        'flags'                   = [System.Int32]'1'
        'msPKI-Cert-Template-OID' = $OID.TemplateOID
    }
    New-ADObject -Path $TemplateOIDPath -OtherAttributes $oa -Name $OID.TemplateName -Type 'msPKI-Enterprise-Oid' -Server $Server
    #endregion

    #region CREATE TEMPLATE
    # https://docs.microsoft.com/en-us/powershell/dsc/securemof#certificate-requirements
    # https://blogs.technet.microsoft.com/option_explicit/2012/04/09/pki-certificates-and-the-x-509-standard/
    # https://technet.microsoft.com/en-us/library/cc776447(v=ws.10).aspx
    
    
    
    $import = Get-TemplateJSON -Template $Template | ConvertFrom-Json


    $oa = @{ 'msPKI-Cert-Template-OID' = $OID.TemplateOID }
    ForEach ($prop in ($import | Get-Member -MemberType NoteProperty)) {
        Switch ($prop.Name) {
            { $_ -in 'flags',
                'msPKI-Certificate-Name-Flag',
                'msPKI-Enrollment-Flag',
                'msPKI-Minimal-Key-Size',
                'msPKI-Private-Key-Flag',
                'msPKI-Template-Minor-Revision',
                'msPKI-Template-Schema-Version',
                'msPKI-RA-Signature',
                'pKIMaxIssuingDepth',
                'pKIDefaultKeySpec',
                'revision'
            } {
                #write-host $_,$import.$_
                $oa.Add($_, [System.Int32]$import.$_)
                break
            }

            { $_ -in 'msPKI-Certificate-Application-Policy',
                'pKICriticalExtensions',
                'pKIDefaultCSPs',
                'pKIExtendedKeyUsage',
                'msPKI-RA-Application-Policies',
                'msPKI-Supersede-Templates'
            } {
                #write-host $_,$import.$_
                $oa.Add($_, [Microsoft.ActiveDirectory.Management.ADPropertyValueCollection]$import.$_)
                break
            }
            { $_ -in 'pKIExpirationPeriod',
                'pKIKeyUsage',
                'pKIOverlapPeriod'
            } {
                #write-host $_,$import.$_
                $oa.Add($_, [System.Byte[]]$import.$_)
                break
            }

        }
    }
    $TemplatePath = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigNC"
    New-ADObject -Path $TemplatePath -OtherAttributes $oa -Name $DisplayName.Replace(' ', '') `
        -DisplayName $DisplayName -Type pKICertificateTemplate -Server $Server
    #endregion

    #region PERMISSIONS
    ## Potential issue here that the AD: drive may not be targetting the selected DC in the -SERVER parameter
    If ($PSBoundParameters.ContainsKey('Identity')) {
        If ($AutoEnroll) {
            Set-ADCSTemplateACL -DisplayName $DisplayName -Server $Server -Type Allow -Identity $Identity -Enroll -AutoEnroll
        }
        Else {
            Set-ADCSTemplateACL -DisplayName $DisplayName -Server $Server -Type Allow -Identity $Identity -Enroll
        }
    }
    else {
        Set-ADCSTemplateACL -DisplayName $DisplayName -Server $Server
    }
    #endregion

    #region ISSUE
    If ($Publish) {
        ### WARNING: Issues on all available CAs. Test in your environment.
        $EnrollmentPath = "CN=Enrollment Services,CN=Public Key Services,CN=Services,$ConfigNC"
        $CAs = Get-ADObject -SearchBase $EnrollmentPath -SearchScope OneLevel -Filter * -Server $Server
        ForEach ($CA in $CAs) {
            Set-ADObject -Identity $CA.DistinguishedName -Add @{certificateTemplates = $DisplayName.Replace(' ', '') } -Server $Server
        }
    }
    #endregion
}
Function Remove-ADCSTemplate {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [parameter(Mandatory)]
        [string]$DisplayName,
        [string]$Server = (Get-ADDomainController -Discover -ForceDiscover -Writable).HostName[0]
    )
    if ($pscmdlet.ShouldProcess($DisplayName, 'Remove certificate template')) {
        $ConfigNC = $((Get-ADRootDSE -Server $Server).configurationNamingContext)

        $Template = Get-ADCSTemplate -DisplayName $DisplayName -Server $Server

        #region REMOVE ISSUE IF IT EXISTS
        $EnrollmentPath = "CN=Enrollment Services,CN=Public Key Services,CN=Services,$ConfigNC"
        $CAs = Get-ADObject -SearchBase $EnrollmentPath -SearchScope OneLevel -Filter * -Server $Server
        ForEach ($CA in $CAs) {
            Set-ADObject -Identity $CA.DistinguishedName -Remove @{certificateTemplates = $Template.cn } -Server $Server -Confirm:$false
        }
        #endregion

        #region REMOVE TEMPLATE
        Remove-ADObject -Identity $Template.distinguishedName -Server $Server -Confirm:$false
        #endregion

        #region REMOVE OID
        $TemplateOIDPath = "CN=OID,CN=Public Key Services,CN=Services,$ConfigNC"
        Get-ADObject -SearchBase $TemplateOIDPath -LDAPFilter "(DisplayName=$DisplayName)" -Server $Server | Remove-ADObject -Confirm:$false
        #endregion
    }
}
Function New-ADCSDrive {
    param(
        [string]$Server = (Get-ADDomainController -Discover -ForceDiscover -Writable).HostName[0]
    )
    $ConfigNC = $((Get-ADRootDSE -Server $Server).configurationNamingContext)
    New-PSDrive -Name ADCS -PSProvider ActiveDirectory -Root "CN=Public Key Services,CN=Services,$ConfigNC" -Server $Server -Scope Global
}
Function Export-ADCSTemplate {
    param(
        [parameter(Mandatory)]
        [string]$DisplayName,
        [string]$Server = (Get-ADDomainController -Discover -ForceDiscover -Writable).HostName[0],
        [switch]$Detailed   # Detailed output is not required for export/import. Use for documentation/backup purposes.
    )
    If ($Detailed) {
        Get-ADCSTemplate -DisplayName $DisplayName -Server $Server |
        ConvertTo-Json
    }
    Else {
        Get-ADCSTemplate -DisplayName $DisplayName -Server $Server |
        Select-Object -Property name, displayName, objectClass, flags, revision, *pki* |
        ConvertTo-Json
    }
}

Function Get-TemplateJSON {
    [CmdletBinding(ConfirmImpact = 'Low')]
    param(
        [parameter(Mandatory)]
        [ValidateSet('AuthenticatedSession', 'KerberosAuthentication', 'WebServer', 'WorkstationAuthentication')]
        [string]$Template
    )

    switch ($Template) {
        "WebServer" {
            $json = @"
{
    "name":  "Custom-WebServer",
    "displayName":  "Custom-WebServer",
    "objectClass":  "pKICertificateTemplate",
    "flags":  131649,
    "revision":  100,
    "msPKI-Cert-Template-OID":  "1.3.6.1.4.1.311.21.8.826822.7751382.12796080.1124008.5112584.221.16351314.9657499",
    "msPKI-Certificate-Application-Policy":  [
                                                 "1.3.6.1.5.5.7.3.1"
                                             ],
    "msPKI-Certificate-Name-Flag":  1,
    "msPKI-Enrollment-Flag":  2,
    "msPKI-Minimal-Key-Size":  2048,
    "msPKI-Private-Key-Flag":  84279568,
    "msPKI-RA-Signature":  0,
    "msPKI-Template-Minor-Revision":  2,
    "msPKI-Template-Schema-Version":  4,
    "pKICriticalExtensions":  [
                                  "2.5.29.15"
                              ],
    "pKIDefaultCSPs":  [
                           "2,Microsoft DH SChannel Cryptographic Provider",
                           "1,Microsoft RSA SChannel Cryptographic Provider"
                       ],
    "pKIDefaultKeySpec":  1,
    "pKIExpirationPeriod":  [
                                0,
                                128,
                                114,
                                14,
                                93,
                                194,
                                253,
                                255
                            ],
    "pKIExtendedKeyUsage":  [
                                "1.3.6.1.5.5.7.3.1"
                            ],
    "pKIKeyUsage":  [
                        160,
                        0
                    ],
    "pKIMaxIssuingDepth":  0,
    "pKIOverlapPeriod":  [
                             0,
                             128,
                             166,
                             10,
                             255,
                             222,
                             255,
                             255
                         ]
}

"@
        }
        "AuthenticatedSession" {
            $json = @"
            {
    "name":  "Custom-AuthenticatedSession",
    "displayName":  "Custom-AuthenticatedSession",
    "objectClass":  "pKICertificateTemplate",
    "flags":  131616,
    "revision":  100,
    "msPKI-Cert-Template-OID":  "1.3.6.1.4.1.311.21.8.826822.7751382.12796080.1124008.5112584.221.15940983.4002162",
    "msPKI-Certificate-Application-Policy":  [
                                                 "1.3.6.1.5.5.7.3.4",
                                                 "1.3.6.1.5.5.7.3.2"
                                             ],
    "msPKI-Certificate-Name-Flag":  -2113929216,
    "msPKI-Enrollment-Flag":  32,
    "msPKI-Minimal-Key-Size":  2048,
    "msPKI-Private-Key-Flag":  84279568,
    "msPKI-RA-Application-Policies":  [
                                          "msPKI-Asymmetric-Algorithm`PZPWSTR`RSA`msPKI-Hash-Algorithm`PZPWSTR`SHA1`msPKI-Key-Usage`DWORD`2`msPKI-Symmetric-Algorithm`PZPWSTR`3DES`msPKI-Symmetric-Key-Length`DWORD`168`"
                                      ],
    "msPKI-RA-Signature":  0,
    "msPKI-Template-Minor-Revision":  3,
    "msPKI-Template-Schema-Version":  4,
    "pKICriticalExtensions":  [
                                  "2.5.29.15"
                              ],
    "pKIDefaultCSPs":  [
                           "2,Microsoft DH SChannel Cryptographic Provider",
                           "1,Microsoft RSA SChannel Cryptographic Provider"
                       ],
    "pKIDefaultKeySpec":  1,
    "pKIExpirationPeriod":  [
                                0,
                                64,
                                57,
                                135,
                                46,
                                225,
                                254,
                                255
                            ],
    "pKIExtendedKeyUsage":  [
                                "1.3.6.1.5.5.7.3.4",
                                "1.3.6.1.5.5.7.3.2"
                            ],
    "pKIKeyUsage":  [
                        128,
                        0
                    ],
    "pKIMaxIssuingDepth":  0,
    "pKIOverlapPeriod":  [
                             0,
                             128,
                             166,
                             10,
                             255,
                             222,
                             255,
                             255
                         ]
}

"@
        }
        "KerberosAuthentication" {
            $json = @"
            {
    "name":  "Custom-KerberosAuthentication",
    "displayName":  "Custom-KerberosAuthentication",
    "objectClass":  "pKICertificateTemplate",
    "flags":  131168,
    "revision":  100,
    "msPKI-Cert-Template-OID":  "1.3.6.1.4.1.311.21.8.826822.7751382.12796080.1124008.5112584.221.15792196.61145733",
    "msPKI-Certificate-Application-Policy":  [
                                                 "1.3.6.1.5.5.7.3.2",
                                                 "1.3.6.1.5.5.7.3.1",
                                                 "1.3.6.1.4.1.311.20.2.2",
                                                 "1.3.6.1.5.2.3.5"
                                             ],
    "msPKI-Certificate-Name-Flag":  -2009071616,
    "msPKI-Enrollment-Flag":  32,
    "msPKI-Minimal-Key-Size":  2048,
    "msPKI-Private-Key-Flag":  84279568,
    "msPKI-RA-Application-Policies":  [
                                          "msPKI-Asymmetric-Algorithm`PZPWSTR`RSA`msPKI-Hash-Algorithm`PZPWSTR`SHA256`msPKI-Key-Usage`DWORD`16777215`msPKI-Symmetric-Algorithm`PZPWSTR`3DES`msPKI-Symmetric-Key-Length`DWORD`168`"
                                      ],
    "msPKI-RA-Signature":  0,
    "msPKI-Supersede-Templates":  [
                                      "DomainController",
                                      "DomainControllerAuthentication",
                                      "KerberosAuthentication"
                                  ],
    "msPKI-Template-Minor-Revision":  4,
    "msPKI-Template-Schema-Version":  4,
    "pKICriticalExtensions":  [
                                  "2.5.29.15",
                                  "2.5.29.17"
                              ],
    "pKIDefaultCSPs":  [
                           "2,Microsoft DH SChannel Cryptographic Provider",
                           "1,Microsoft RSA SChannel Cryptographic Provider"
                       ],
    "pKIDefaultKeySpec":  1,
    "pKIExpirationPeriod":  [
                                0,
                                64,
                                57,
                                135,
                                46,
                                225,
                                254,
                                255
                            ],
    "pKIExtendedKeyUsage":  [
                                "1.3.6.1.5.5.7.3.2",
                                "1.3.6.1.5.5.7.3.1",
                                "1.3.6.1.4.1.311.20.2.2",
                                "1.3.6.1.5.2.3.5"
                            ],
    "pKIKeyUsage":  [
                        160,
                        0
                    ],
    "pKIMaxIssuingDepth":  0,
    "pKIOverlapPeriod":  [
                             0,
                             128,
                             166,
                             10,
                             255,
                             222,
                             255,
                             255
                         ]
}

"@
        }
        "WorkstationAuthentication" {
            $json = @"
            {
    "name":  "Custom-WorkstationAuthentication",
    "displayName":  "Custom-WorkstationAuthentication",
    "objectClass":  "pKICertificateTemplate",
    "flags":  131680,
    "revision":  100,
    "msPKI-Cert-Template-OID":  "1.3.6.1.4.1.311.21.8.826822.7751382.12796080.1124008.5112584.221.11945342.4574677",
    "msPKI-Certificate-Application-Policy":  [
                                                 "1.3.6.1.5.5.7.3.2"
                                             ],
    "msPKI-Certificate-Name-Flag":  134217728,
    "msPKI-Enrollment-Flag":  32,
    "msPKI-Minimal-Key-Size":  2048,
    "msPKI-Private-Key-Flag":  84279568,
    "msPKI-RA-Application-Policies":  [
                                          "msPKI-Asymmetric-Algorithm`PZPWSTR`RSA`msPKI-Hash-Algorithm`PZPWSTR`SHA1`msPKI-Key-Usage`DWORD`16777215`msPKI-Symmetric-Algorithm`PZPWSTR`3DES`msPKI-Symmetric-Key-Length`DWORD`168`"
                                      ],
    "msPKI-RA-Signature":  0,
    "msPKI-Template-Minor-Revision":  2,
    "msPKI-Template-Schema-Version":  4,
    "pKICriticalExtensions":  [
                                  "2.5.29.15"
                              ],
    "pKIDefaultCSPs":  [
                           "2,Microsoft DH SChannel Cryptographic Provider",
                           "1,Microsoft RSA SChannel Cryptographic Provider"
                       ],
    "pKIDefaultKeySpec":  1,
    "pKIExpirationPeriod":  [
                                0,
                                64,
                                57,
                                135,
                                46,
                                225,
                                254,
                                255
                            ],
    "pKIExtendedKeyUsage":  [
                                "1.3.6.1.5.5.7.3.2"
                            ],
    "pKIKeyUsage":  [
                        160,
                        0
                    ],
    "pKIMaxIssuingDepth":  0,
    "pKIOverlapPeriod":  [
                             0,
                             128,
                             166,
                             10,
                             255,
                             222,
                             255,
                             255
                         ]
}

"@
        }
    }
    $json
}

Function New-ADSIADGroup {

    [CmdletBinding(ConfirmImpact = 'Low')]
    param(
        [parameter(Mandatory)]
        [string]$Name,
        [parameter(Mandatory = $false)]
        $Description,
        [parameter(Mandatory)]
        [ValidateSet('Global', 'DomainLocal', 'Universal')]
        [string]$GroupScope = 'Global',

        [parameter(Mandatory = $false)]
        [string]$Path

    )

    $adGroupType = @{
        Global      = 0x00000002
        DomainLocal = 0x00000004
        Universal   = 0x00000008
        Security    = 0x80000000
    }
    
    
    If ($PSBoundParameters.ContainsKey('Path')) {
        $DistinguishedName = "CN=$Name,$Path"
    }
    else {
        $dc = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.name
        $ad = [ADSI]"LDAP://$dc"
        #OU containing the AD group
        $path = "CN=Computers,$($ad.distinguishedName)"
        #Full distinguished name of AD group		
        $DistinguishedName = "CN=$Name,$adGroupOU"
        
    }

    #check if exists
    $group = ([ADSISearcher] "(distinguishedName=$DistinguishedName)").FindOne()

    if ($null -eq $group) {	
        #get OU
        $adsiADGroup = [adsi]("LDAP://$path")
        #create group in OU
        $newGroup = $adsiADGroup.Create('group', "CN=$Name")
        #Make it a global security group
        $newGroup.put('grouptype', ($adGroupType.$GroupScope -bor $adGroupType.Security))
        $newGroup.put('samaccountname', $Name)
        $newGroup.put('Description', $Description)
        $newGroup.SetInfo()	
    }
    else {
        Write-Warning "Group already exists"
    }
}


#Export-ADCSTemplate -DisplayName Custom-KerberosAuthentication | Out-File .\Custom-KerberosAuthentication.json
#Export-ADCSTemplate -DisplayName Custom-WorkstationAuthentication | Out-File .\Custom-WorkstationAuthentication.json
#Export-ADCSTemplate -DisplayName Custom-WebServer | Out-File .\Custom-WebServer.json
#Export-ADCSTemplate -DisplayName Custom-AuthenticatedSession | Out-File .\Custom-AuthenticatedSession.json

New-ADCSTemplate -DisplayName "Custom-KerberosAuthentication" -Template KerberosAuthentication -Identity "$($env:USERDNSDOMAIN)\Enterprise Read-only Domain Controllers", "ENTERPRISE DOMAIN CONTROLLERS" -AutoEnroll -Publish
New-ADCSTemplate -DisplayName "Custom-WorkstationAuthentication" -Template WorkstationAuthentication -Identity "$($env:USERDNSDOMAIN)\Domain Computers" -AutoEnroll -Publish

$GroupName = "Domain PKI Custom-WebServer"
New-ADSIADGroup -Name $GroupName -GroupScope Global -Description "Allows enrollment to Custom-WebServer certificate template"
Write-Warning "Group $GroupName create in Users contianer, ensure it is moved to the correct location"
New-ADCSTemplate -DisplayName "Custom-WebServer" -Template WebServer -Identity "$($env:USERDNSDOMAIN)\$GroupName" -AutoEnroll -Publish

New-ADCSTemplate -DisplayName "Custom-AuthenticatedSession" -Template AuthenticatedSession -Identity "$($env:USERDNSDOMAIN)\Domain Users" -AutoEnroll

Set-ADCSTemplateACL -DisplayName "Custom-AuthenticatedSession" -Type Deny -Identity "$($env:USERDNSDOMAIN)\Domain Admins" -Enroll -AutoEnroll
Set-ADCSTemplateACL -DisplayName "Custom-AuthenticatedSession" -Type Deny -Identity "$($env:USERDNSDOMAIN)\Enterprise Admins" -Enroll -AutoEnroll

