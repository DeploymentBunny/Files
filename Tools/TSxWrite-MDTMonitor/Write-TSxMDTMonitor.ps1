<#
.SYNOPSIS
    Sends deployment status events to the MDT Monitor service.

.DESCRIPTION
    Write-TSxMDTMonitor posts deployment status events to the MDT Monitoring web service via HTTP.
    It supports standard MDT message IDs for deployment lifecycle events such as beginning deployment,
    successful completion, failure, warnings, and errors.

.PARAMETER MDTServerName
    The hostname or IP address of the MDT server running the monitoring service.

.PARAMETER MDTServerPort
    The TCP port the MDT monitoring service is listening on (default: 9800).

.PARAMETER MessageID
    The MDT monitoring message ID. Supported values:
      41002 - Warning
      41003 - Error
      41014 - Deployment failed
      41015 - Deployment completed successfully
      41016 - Beginning deployment

.PARAMETER MacAddress001
    The MAC address of the primary network adapter (colon-separated format).

.PARAMETER OSDComputerName
    The name of the computer being deployed.

.PARAMETER GUID
    A unique identifier (GUID) for the deployment instance.

.PARAMETER TotalSteps
    The total number of steps in the deployment task sequence.

.PARAMETER CurrentStep
    The current step number in the deployment task sequence.

.PARAMETER ExtraInfo
    Optional additional information appended to warning or error log messages.

.EXAMPLE
    .\Write-TSxMDTMonitor.ps1 -MDTServerName 'SRVMDT01' -MDTServerPort '9800' -MessageID '41016' `
        -MacAddress001 '00:11:22:33:44:55' -OSDComputerName 'PC001' -GUID (New-Guid).Guid `
        -TotalSteps 10 -CurrentStep 1

.NOTES
    Author: DeploymentBunny
    Date:   2026-04-28
#>
Param(
    $MDTServerName,
    $MDTServerPort,
    $MessageID,
    $MacAddress001,
    $OSDComputerName,
    $GUID,
    $TotalSteps,
    $CurrentStep,
    $ExtraInfo,
    $StepName,
    $DartIP,
    $DartPort,
    $DartTicket,
    $VMHost,
    $VMName
)

switch ($MessageID)
{
    '41002' {
        $severity = 2
        $LogMessage = "Warning for computer $OSDComputerName :" + $ExtraInfo
    }
    '41003' {
        $severity = 3
        $LogMessage = "Error for computer $OSDComputerName :" + $ExtraInfo
    }
    '41014' {
        $severity = 3
        $LogMessage = "Deployment failed."
    }
    '41015' {
        $severity = 1
        $LogMessage = "Deployment completed successfully."
    }
    '41016' {
        $severity = 1
        $LogMessage = "Beginning deployment."
    }
    Default {
    }
}

$MDTServer = $MDTServerName + ":" + $MDTServerPort
Invoke-WebRequest "http://$MDTServer/MDTMonitorEvent/PostEvent?uniqueID=&computerName=$OSDComputerName&messageID=$MessageID&severity=$severity&stepName=$stepName&currentStep=$CurrentStep&totalSteps=$totalSteps&id=$GUID,$MacAddress001&message=$LogMessage&dartIP=$dartIP&dartPort=$dartPort&dartTicket=$dartTicket&vmHost=$vmHost&vmName=$vmName"


