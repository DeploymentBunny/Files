Function Connect-VIARDP {
    <#
    .Synopsis
        Connect-VIARDP
    .DESCRIPTION
        Connect-VIARDP
    .EXAMPLE
        Connect-VIARDP -Connection SERVER01
    .NOTES
        Created:	 July 15, 2016
        Version:	 1.0
    
        Updated:     Nov 25, 2016
        Version:     1.1

        Author - Mikael Nystrom
        Twitter: @mikael_nystrom
        Blog   : http://deploymentbunny.com

        Disclaimer:
        This script is provided 'AS IS' with no warranties, confers no rights and 
        is not supported by the author.
    .LINK
        http://www.deploymentbunny.com
    #>
    Param
    (
        [Parameter(Mandatory=$true,
                   ValueFromPipelineByPropertyName=$true,
                   Position=0)]
        $Connection
    )
    do
    {
        $ConTest = (Test-NetConnection -ComputerName $Connection -CommonTCPPort RDP).TcpTestSucceeded
    }
    until ($ConTest -eq "True")
    mstsc.exe /v:$Connection
}
