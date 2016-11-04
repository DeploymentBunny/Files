<#
.Synopsis
   Create-VIAComputerName
.DESCRIPTION
   Create-VIAComputerName
.PARAMETER ComputerPrefix
   String that defines the prefix of the computername to be generated    
.PARAMETER LowNumber
    Integer the defines the starting number
.PARAMETER HigNumber
    Integer the defines the ending number
.EXAMPLE
   Create-VIAComputerName -ComputerPrefix SERVER- -LowNumber 1 -HigNumber 10

   The command will return the following
   SERVER-001
   SERVER-002
   SERVER-003
   SERVER-004
   SERVER-005
   SERVER-006
   SERVER-007
   SERVER-008
   SERVER-009
   SERVER-010
.NOTES
    Created:	 Nov 4, 2016
    Version:	 1.0

    Author - Mikael Nystrom
    Twitter: @mikael_nystrom
    Blog   : http://deploymentbunny.com

    Disclaimer:
    This script is provided "AS IS" with no warranties, confers no rights and 
    is not supported.
.LINK
    http://www.deploymentbunny.com
#>
function Create-VIAComputerName
{
    Param
    (
        [Parameter(Mandatory=$true,ValueFromPipelineByPropertyName=$true,Position=0)]
        [String]
        $ComputerPrefix,

        [Parameter(Mandatory=$true,ValueFromPipelineByPropertyName=$true,Position=1)]
        [int]
        $LowNumber,

        [Parameter(Mandatory=$true,ValueFromPipelineByPropertyName=$true,Position=2)]
        [int]
        $HigNumber
    )

    $Servers = $($LowNumber..$HigNumber| ForEach-Object {"$ComputerPrefix{0:D3}" -f $_})
    Return $Servers
}


