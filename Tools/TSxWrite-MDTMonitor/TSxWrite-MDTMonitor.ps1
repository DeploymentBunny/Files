Function TSxWrite-MDTMonitor{
    Param(
    $MDTServerName,
    $MDTServerPort,
    $MessageID,    
    $MacAddress001,
    $OSDComputerName,
    $GUID,
    $TotalSteps,
    $CurrentStep,
    $ExtraInfo
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
}

$MDTServerName = 'SRVMDT01'
$MDTServerPort = '9800'
$MacAddress001 = ((Get-NetAdapter | Where-Object Status -EQ up)[0].MacAddress).Replace("-",":")
$OSDComputerName = "$Env:ComputerName"

$GUID = (New-Guid).Guid

# Beginning deployment.
$MessageID = '41016'
$TotalSteps = 2
$CurrentStep= 0
TSxWrite-MDTMonitor -MDTServerName $MDTServerName -MDTServerPort $MDTServerPort -MessageID $MessageID -MacAddress001 $MacAddress001 -OSDComputerName $OSDComputerName -GUID $GUID -TotalSteps $TotalSteps -CurrentStep $CurrentStep

# Deployment completed successfully.
$MessageID = '41015'
$TotalSteps = 2
$CurrentStep= 2
TSxWrite-MDTMonitor -MDTServerName $MDTServerName -MDTServerPort $MDTServerPort -MessageID $MessageID -MacAddress001 $MacAddress001 -OSDComputerName $OSDComputerName -GUID $GUID -TotalSteps $TotalSteps -CurrentStep $CurrentStep

# Deployment failed.
$MessageID = '41014'
$TotalSteps = 2
$CurrentStep= 2
TSxWrite-MDTMonitor -MDTServerName $MDTServerName -MDTServerPort $MDTServerPort -MessageID $MessageID -MacAddress001 $MacAddress001 -OSDComputerName $OSDComputerName -GUID $GUID -TotalSteps $TotalSteps -CurrentStep $CurrentStep

# Generic Warning
$MessageID = '41002'
$TotalSteps = 2
$CurrentStep= 2
$ExtraInfo = "Description of the warning"
TSxWrite-MDTMonitor -MDTServerName $MDTServerName -MDTServerPort $MDTServerPort -MessageID $MessageID -MacAddress001 $MacAddress001 -OSDComputerName $OSDComputerName -GUID $GUID -TotalSteps $TotalSteps -CurrentStep $CurrentStep -ExtraInfo $ExtraInfo

# Generic Error
$MessageID = '41003'
$TotalSteps = 2
$CurrentStep= 2
$ExtraInfo = "Description of the error"
TSxWrite-MDTMonitor -MDTServerName $MDTServerName -MDTServerPort $MDTServerPort -MessageID $MessageID -MacAddress001 $MacAddress001 -OSDComputerName $OSDComputerName -GUID $GUID -TotalSteps $TotalSteps -CurrentStep $CurrentStep -ExtraInfo $ExtraInfo


