Param(
    $XMLFile = 'http://localhost/ApprovedModelList/VIAApprovedModel.xml',
    $Model = 'Surface Pro 4',
    $OperatingSystem = 'Windows10x64'
)

Function Check-VIAApprovedModel{
    Param(
        $XMLFile,
        $Model,
        $OperatingSystem
    )
    
    [xml]$XMLData = (New-Object System.Net.WebClient).DownloadString($XMLFile)
    #[xml]$XMLData = Get-Content $XMLFile -ErrorAction Stop
    $ModelData = $XMLData.Models.Model | Where-Object Name -EQ $Model

    if(!($ModelData.$OperatingSystem -eq 'True')){
        RETURN $False
    }else{
        RETURN $ModelData.$OperatingSystem
    }
}

$result = Check-VIAApprovedModel -XMLFile $xmlfile -Model $Model -OperatingSystem $OperatingSystem
if($result -eq $True){
    Write-Host - "Approved"
    Exit 0
}else{
    Write-Host - "Not Approved"
    Exit 1
}
