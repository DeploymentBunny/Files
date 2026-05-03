Function Get-MDTOData{
    <#
    .Synopsis
        Function for getting MDTOdata
    .DESCRIPTION
        Queries the MDT Monitor service REST API on the specified server and returns
        deployment status for all computers tracked by MDT monitoring.
    .EXAMPLE
        Get-MDTOData -MDTMonitorServer MDTSERVER01
    .NOTES
        Created:     2016-03-07
        Version:     1.0
 
        Author - Mikael Nystrom
        Twitter: @mikael_nystrom
        Blog   : https://www.deploymentbunny.com
 
        Disclaimer:
        This script is provided "AS IS" with no warranties, confers no rights and
        is not supported by the author.
 
    .LINK
        https://www.deploymentbunny.com
    #>
    Param(
    $MDTMonitorServer
    ) 
    $URL = "http://" + $MDTMonitorServer + ":9801/MDTMonitorData/Computers"
    $Data = Invoke-RestMethod $URL
    foreach($property in ($Data.content.properties) ){
        $Hash =  [ordered]@{ 
            Name = $($property.Name); 
            PercentComplete = $($property.PercentComplete.�#text�); 
            Warnings = $($property.Warnings.�#text�); 
            Errors = $($property.Errors.�#text�); 
            DeploymentStatus = $( 
            Switch($property.DeploymentStatus.�#text�){ 
                1 { "Active/Running"} 
                2 { "Failed"} 
                3 { "Successfully completed"} 
                Default {"Unknown"} 
                }
            );
            StepName = $($property.StepName);
            TotalSteps = $($property.TotalStepS.'#text')
            CurrentStep = $($property.CurrentStep.'#text')
            DartIP = $($property.DartIP);
            DartPort = $($property.DartPort);
            DartTicket = $($property.DartTicket);
            VMHost = $($property.VMHost.'#text');
            VMName = $($property.VMName.'#text');
            LastTime = $($property.LastTime.'#text') -replace "T"," ";
            StartTime = $($property.StartTime.�#text�) -replace "T"," "; 
            EndTime = $($property.EndTime.�#text�) -replace "T"," "; 
            }
        New-Object PSObject -Property $Hash
    }
}
