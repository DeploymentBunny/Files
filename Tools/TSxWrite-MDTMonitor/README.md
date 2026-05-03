# Write-TSxMDTMonitor

Sends deployment status events to the MDT Monitor service via HTTP.

## Usage

Run the script directly, passing parameters on the command line:

```powershell
.\Write-TSxMDTMonitor.ps1 -MDTServerName 'SRVMDT01' -MDTServerPort '9800' -MessageID '41016' `
    -MacAddress001 '00:11:22:33:44:55' -OSDComputerName 'PC001' -GUID (New-Guid).Guid `
    -TotalSteps 10 -CurrentStep 1
```

### Parameters

| Parameter       | Description |
|-----------------|-------------|
| MDTServerName   | Hostname or IP of the MDT server |
| MDTServerPort   | Port of the MDT monitoring service (default: 9800) |
| MessageID       | MDT message ID (see below) |
| MacAddress001   | MAC address of the primary NIC (colon-separated) |
| OSDComputerName | Name of the computer being deployed |
| GUID            | Unique deployment identifier |
| TotalSteps      | Total number of task sequence steps |
| CurrentStep     | Current step number |
| ExtraInfo       | Additional info for warning/error messages |
| StepName        | Name of the current task sequence step |
| DartIP          | DART IP address |
| DartPort        | DART port |
| DartTicket      | DART ticket |
| VMHost          | Virtual machine host name |
| VMName          | Virtual machine name |

### Message IDs

| MessageID | Description |
|-----------|-------------|
| 41002     | Warning |
| 41003     | Error |
| 41014     | Deployment failed |
| 41015     | Deployment completed successfully |
| 41016     | Beginning deployment |

### Examples

#### Beginning deployment

```powershell
.\Write-TSxMDTMonitor.ps1 -MDTServerName 'SRVMDT01' -MDTServerPort '9800' -MessageID '41016' `
    -MacAddress001 '00:11:22:33:44:55' -OSDComputerName 'PC001' -GUID (New-Guid).Guid `
    -TotalSteps 2 -CurrentStep 0
```

#### Deployment completed successfully

```powershell
.\Write-TSxMDTMonitor.ps1 -MDTServerName 'SRVMDT01' -MDTServerPort '9800' -MessageID '41015' `
    -MacAddress001 '00:11:22:33:44:55' -OSDComputerName 'PC001' -GUID $GUID `
    -TotalSteps 2 -CurrentStep 2
```

#### Deployment failed

```powershell
.\Write-TSxMDTMonitor.ps1 -MDTServerName 'SRVMDT01' -MDTServerPort '9800' -MessageID '41014' `
    -MacAddress001 '00:11:22:33:44:55' -OSDComputerName 'PC001' -GUID $GUID `
    -TotalSteps 2 -CurrentStep 2
```

#### Generic Warning

```powershell
.\Write-TSxMDTMonitor.ps1 -MDTServerName 'SRVMDT01' -MDTServerPort '9800' -MessageID '41002' `
    -MacAddress001 '00:11:22:33:44:55' -OSDComputerName 'PC001' -GUID $GUID `
    -TotalSteps 2 -CurrentStep 2 -ExtraInfo "Description of the warning"
```

#### Generic Error

```powershell
.\Write-TSxMDTMonitor.ps1 -MDTServerName 'SRVMDT01' -MDTServerPort '9800' -MessageID '41003' `
    -MacAddress001 '00:11:22:33:44:55' -OSDComputerName 'PC001' -GUID $GUID `
    -TotalSteps 2 -CurrentStep 2 -ExtraInfo "Description of the error"
```

