<#
 ##################################################################################
 #  Script name: DownloadAll.ps1
 #  Created:		2012-12-26
 #  version:		v1.0
 #  Author:      Mikael Nystrom
 #  Homepage:    http://deploymentbunny.com/
 ##################################################################################
 
 ##################################################################################
 #  Disclaimer:
 #  -----------
 #  This script is provided "AS IS" with no warranties, confers no rights and 
 #  is not supported by the authors or DeploymentBunny.
 ##################################################################################
#>
Param(
    [Parameter(mandatory=$false,HelpMessage="Name and path of XML file")]
    [ValidateNotNullOrEmpty()]
    $DownloadFile = '.\download.xml',

    [Parameter(mandatory=$False,HelpMessage="Name and path of download folder")]
    [ValidateNotNullOrEmpty()]
    $DownloadFolder = 'C:\Downloads'
)
Function Logit()
{
    $TextBlock1 = $args[0]
    $TextBlock2 = $args[1]
    $TextBlock3 = $args[2]
    $Stamp = Get-Date
    Write-Host "[$Stamp] [$Section - $TextBlock1]"
}

# Main
$Section = "Main"
Logit "DownLoadFolder - $DownLoadFolder"
Logit "DownloadFile - $DownloadFile"

#Read content
$Section = "Reading datafile"
Logit "Reading from $DownloadFile"
[xml]$Data = Get-Content $DownloadFile
$TotalNumberOfObjects = $Data.Download.DownloadItem.Count

# Start downloading
$Section = "Downloading"
Logit "Downloading $TotalNumberOfObjects objects"
$Count = (0)
foreach($DataRecord in $Data.Download.DownloadItem)
    {
    $FullName = $DataRecord.FullName
    $Count = ($Count + 1)
    $Source = $DataRecord.Source
    $DestinationFolder = $DataRecord.DestinationFolder
    $DestinationFile = $DataRecord.DestinationFile
    Logit "Working on $FullName ($Count/$TotalNumberOfObjects)"
    $DestinationFolder = $DownloadFolder + "\" + $DestinationFolder
    $Destination = $DestinationFolder + "\" + $DestinationFile
    $Downloaded = Test-Path $Destination
    if($Downloaded -like 'True'){}
        else
        {
            Logit "$DestinationFile needs to be downloaded."
            Logit "Creating $DestinationFolder"
            New-Item -Path $DestinationFolder -ItemType Directory -Force | Out-Null
            Logit "Downloading $Destination"
        Try
        {
            Start-BitsTransfer -Destination $Destination -Source $Source -Description "Download $FullName" -ErrorAction Continue
        }
        Catch
        {
            $ErrorMessage = $_.Exception.Message
            Logit "Fail: $ErrorMessage"
        }
    }
}

# Start Proccessing downloaded files
$Section = "Process files"
Logit "Checking $TotalNumberOfObjects objects"
$Count = (0)
foreach($DataRecord in $Data.Download.DownloadItem){
    $CommandType = $DataRecord.CommandType
        if($CommandType -like 'NONE')
        {}
        else
        {
            $FullName = $DataRecord.FullName
            $Count = ($Count + 1)
            $Source = $DataRecord.Source
            $Command = $DataRecord.Command
            $CommandLineSwitches = $DataRecord.CommandLineSwitches
            $VerifyAfterCommand = $DataRecord.VerifyAfterCommand
            $DestinationFolder = $DataRecord.DestinationFolder
            $DestinationFile = $DataRecord.DestinationFile
            $DestinationFolder = $DownLoadFolder + "\" + $DestinationFolder
            $Destination = $DestinationFolder + "\" + $DestinationFile
            $CheckFile = $DestinationFolder + "\" + $VerifyAfterCommand
            Logit "Working on $FullName ($Count/$TotalNumberOfObjects)"
            Logit "Looking for $CheckFile"
            $CommandDone = Test-Path $CheckFile
        if($CommandDone -like 'True')
        {
             Logit "$FullName is already done"
        }
            else
        {
            Logit "$FullName needs to be fixed."
            #Selecting correct method to extract data 
            Switch($CommandType){
                EXEType01{
                    $Command = $DestinationFolder + "\" + $Command
                    $DownLoadProcess = Start-Process """$Command""" -ArgumentList ($CommandLineSwitches + " " + """$DestinationFolder""") -Wait
                    $DownLoadProcess.HasExited
                    $DownLoadProcess.ExitCode
                }
                NONE{
                }
                default{
                }
            }
        }
    }
}

#Done
$Section = "Finish"
Logit "All Done"