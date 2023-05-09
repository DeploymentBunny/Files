Function Get-TSxiLOInfo {
    param(
        $ComputerName,
        [switch]$ResolveName
    )
    $XML = New-Object XML
    if($ResolveName){
        $HostName = Resolve-DnsName -Name $ComputerName
    }
    else{
        $HostName = "NA"
    }

    $XML.Load("http://$ComputerName/xmldata?item=All")
    New-Object PSObject -Property @{
        iLOName = $($HostName.NameHost);
        iLOIP = $($ComputerName);
        ServerType = $($XML.RIMP.HSI.SPN);
        SerialNumber = $($XML.RIMP.HSI.SBSN);
        ProductID = $($XML.RIMP.HSI.PRODUCTID);
        UUID = $($XML.RIMP.HSI.cUUID);
        Nic01 = $($XML.RIMP.HSI.NICS.NIC[0].MACADDR);
        Nic02 = $($XML.RIMP.HSI.NICS.NIC[1].MACADDR);
        ILOType = $($XML.RIMP.MP.PN);
        iLOFirmware = $($XML.RIMP.MP.FWRI)
    }
}
