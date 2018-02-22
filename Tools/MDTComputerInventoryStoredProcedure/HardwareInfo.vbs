' //***************************************************************************
' // ***** Script Header *****
' //
' // Solution:  Custom Script for use with the Microsoft Deployment Toolkit
' // File:      hardwareinfo.vbs
' //
' // Usage: Modify CustomSettings.ini similar to this:
' //        [Settings]
' //        Priority=Init, Default
' //        Properties=MyCustomProperty, SkipHardwareInfo, ComputerSystemNumberOfProcessors, ComputerSystemNumberOfLogicalProcessors, ComputerSystemProductIdentifyingNumber, SMBIOSVersion, CPUName, DiskDriveCaptation
' //
' //        [Init]
' //        ComputerSystemNumberOfProcessors=#SetComputerSystemNumberOfProcessors()#
' //        ComputerSystemNumberOfLogicalProcessors=#SetComputerSystemNumberOfLogicalProcessors()#
' //        ComputerSystemProductIdentifyingNumber=#SetComputerSystemProductIdentifyingNumber()#
' //        SMBIOSVersion=#SetBIOSSMBIOSVersion()#
' //        CPUName=#SetCPUName()#
' //        DiskDriveCaptation=#SetDiskDriveCaptation()#
' //        DiskDriveSize=#SetDiskDriveSize()#
' // Version:   1.0
' // Author: Mikael Nystrom – http://deploymentbunny.com
' //***************************************************************************

Function UserExit(sType, sWhen, sDetail, bSkip)
    oLogging.CreateEntry "UserExit:HardwareInfo.vbs started: " & sType & " " & sWhen & " " & sDetail, LogTypeInfo
    UserExit = Success
End Function

Function SetComputerSystemNumberOfProcessors()
    oLogging.CreateEntry "UserExit:HardwareInfo.vbs – Getting ComputerSystemNumberOfProcessors", LogTypeInfo
    Dim objWMI
    Dim objResults
    Dim objInstance
    Dim NumberOfProcessors
    Dim NumberOfLogicalProcessors
	Dim ComboOfProcessors

    Set objWMI = GetObject("winmgmts:")
    Set objResults = objWMI.InstancesOf("Win32_ComputerSystem")
        If Err then
        oLogging.CreateEntry "Error querying FROM Win32_Processor: " & Err.Description & " (" & Err.Number & ")", LogTypeError
    Else
        For each objInstance in objResults
            If Not IsNull(objInstance.NumberOfProcessors) Then
                NumberOfProcessors = Trim(objInstance.NumberOfProcessors)
            End If
            If Not IsNull(objInstance.NumberOfLogicalProcessors) Then
                NumberOfLogicalProcessors = Trim(objInstance.NumberOfLogicalProcessors)
            End If
        Next
	End If
	
    	ComboOfProcessors = NumberOfProcessors + " : " + NumberOfLogicalProcessors
	SetComputerSystemNumberOfProcessors = ComboOfProcessors
	End Function

Function SetCPUName()
    oLogging.CreateEntry "UserExit:HardwareInfo.vbs – Getting CPUName", LogTypeInfo
    Dim objWMI
    Dim objResults
    Dim objInstance
    Dim Name
    Dim CPUName
   
    Set objWMI = GetObject("winmgmts:")
    Set objResults = objWMI.ExecQuery("SELECT * FROM Win32_Processor")
        If Err then
        oLogging.CreateEntry "Error querying FROM Win32_Processor: " & Err.Description & " (" & Err.Number & ")", LogTypeError
    Else
        For each objInstance in objResults
            If Not IsNull(objInstance.Name) Then
                    CPUName = Trim(objInstance.Name)
            End If
        Next
    End If
    SetCPUName = CPUName
End Function

Function SetBIOSSMBIOSVersion()
    oLogging.CreateEntry "UserExit:HardwareInfo.vbs – Getting BIOSSMBIOSVersion", LogTypeInfo
    Dim objWMI
    Dim objResults
    Dim objInstance
    Dim SMBIOSBIOSVersion
   
    Set objWMI = GetObject("winmgmts:")
    Set objResults = objWMI.ExecQuery("SELECT * FROM Win32_BIOS")
        If Err then
        oLogging.CreateEntry "Error querying Win32_ComputerSystem: " & Err.Description & " (" & Err.Number & ")", LogTypeError
    Else
        For each objInstance in objResults
            If Not IsNull(objInstance.SMBIOSBIOSVersion) Then
                    SMBIOSBIOSVersion = Trim(objInstance.SMBIOSBIOSVersion)
            End If
        Next
    End If
    SetBIOSSMBIOSVersion = SMBIOSBIOSVersion
End Function

Function SetFirstDiskDriveCaptation()
    oLogging.CreateEntry "UserExit:HardwareInfo.vbs – Getting DiskDriveCaptation", LogTypeInfo
    Dim objWMI
    Dim objResults
    Dim objInstance
    Dim Caption
   
    Set objWMI = GetObject("winmgmts:")
           Set objResults = objWMI.ExecQuery("SELECT * FROM Win32_DiskDrive where Index like '0'")
        If Err then
        oLogging.CreateEntry "Error querying Win32_DiskDrive: " & Err.Description & " (" & Err.Number & ")", LogTypeError
    Else
        For each objInstance in objResults
            If Not IsNull(objInstance.Caption) Then
                    Caption = Trim(objInstance.Caption)
            End If
        Next
    End If
    SetFirstDiskDriveCaptation = Caption
End Function

Function SetFirstDiskDriveSize()
    oLogging.CreateEntry "UserExit:HardwareInfo.vbs – Getting DiskDriveSize", LogTypeInfo
    Dim objWMI
    Dim objResults
    Dim objInstance
    Dim Size
	Dim SizeInGB
   
    Set objWMI = GetObject("winmgmts:")
           Set objResults = objWMI.ExecQuery("SELECT * FROM Win32_DiskDrive where Index like '0'")
        If Err then
        oLogging.CreateEntry "Error querying Win32_DiskDrive: " & Err.Description & " (" & Err.Number & ")", LogTypeError
    Else
        For each objInstance in objResults
            If Not IsNull(objInstance.Size) Then
                    Size = Trim(objInstance.Size)
            End If
        Next
    End If
	SizeInGB = FormatNumber((Size/1024/1024/1024),2)
    SetFirstDiskDriveSize = SizeInGB
End Function

Function SetFirstNetAdapterName()
    oLogging.CreateEntry "UserExit:HardwareInfo.vbs – Getting NetAdapterName", LogTypeInfo
    Dim objWMI
    Dim objResults
    Dim objInstance
    Dim Caption
   
    Set objWMI = GetObject("winmgmts:")
           Set objResults = objWMI.ExecQuery("Select * from Win32_PnPEntity Where ClassGuid like '{4d36e972-e325-11ce-bfc1-08002be10318}' and Manufacturer != 'Microsoft' and Status = 'Ok'")
        If Err then
        oLogging.CreateEntry "Error querying Win32_PnPEntity: " & Err.Description & " (" & Err.Number & ")", LogTypeError
    Else
        For each objInstance in objResults
            If Not IsNull(objInstance.Caption) Then
                Caption = (objInstance.Caption)
			Exit For
			End If
		Next
   	End If
	If Caption = "" Then
		Caption = "No Physical NIC"
    End If
    SetFirstNetAdapterName = Caption
End Function

Function SetGPUAdapterName()
    oLogging.CreateEntry "UserExit:HardwareInfo.vbs - Getting NetAdapterName", LogTypeInfo
    Dim objWMI
    Dim objResults
    Dim objInstance
    Dim Caption
   
    Set objWMI = GetObject("winmgmts:")
           Set objResults = objWMI.ExecQuery("Select * from Win32_PnPEntity Where ClassGuid = '{4d36e968-e325-11ce-bfc1-08002be10318}' and DeviceID like 'PCI%' and status like 'OK'")
        If Err then
        oLogging.CreateEntry "Error querying Win32_PnPEntity: " & Err.Description & " (" & Err.Number & ")", LogTypeError
    Else
        For each objInstance in objResults
            If Not IsNull(objInstance.Caption) Then
                Caption = (objInstance.Caption)
			Exit For
			End If
		Next
	End If
	If Caption = "" Then 
		Caption = "No Physical GPU"
    End If
    SetGPUAdapterName = Caption
End Function
