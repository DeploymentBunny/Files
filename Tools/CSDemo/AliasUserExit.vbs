'//----------------------------------------------------------------------------
'// Solution: Sample Files
'// Purpose: Custom Script for assign friendly Make and Model alias and to extend hardware inventory
'// Version: 1.4 - Feb 26, 2012 - Johan Arwidmark & Mikael Nystrom
'//
'// This script is based of Microsoft Sample Code from the deployment guys blog
'// (http://blogs.technet.com/b/deploymentguys) and as such we need to have a 
'// copyright statement. Special thanks goes to Ben Hunter, Michael Murgolo and Steven Markegene. 
'//
'// COPYRIGHT STATEMENT
'// This script is provided "AS IS" with no warranties, confers no rights and 
'// is not supported by the authors or Deployment Artist. 
'//----------------------------------------------------------------------------
' //            
' // Usage:     Modify CustomSettings.ini similar to this:
' //              [Settings]
' //              Priority=SetAlias, Default 
' //              Properties=ModelAlias,MakeAlias,MacAlias,SMBIOSBIOSVersion
' // 
' //              [SetAlias]
' //              UserExit=AliasUserExit.vbs
' //              MakeAlias=#SetMakeAlias()#
' //              ModelAlias=#SetModelAlias()#
' //              SMBIOSBIOSVersion=#SetSMBIOSBIOSVersion()#
' //              MacAlias=#SetMacAlias()#
' // ***** End Header *****

Function UserExit(sType, sWhen, sDetail, bSkip)

    oLogging.CreateEntry "UserExit: started: " & sType & " " & sWhen & " " & sDetail, LogTypeInfo
    UserExit = Success

End Function

Function SetMakeAlias()

    oLogging.CreateEntry "UserExit: Running function SetMakeAlias ", LogTypeInfo
    sMake = oEnvironment.Item("Make")
    SetMakeAlias = ""
    oLogging.CreateEntry "UserExit: Make is now " & sMake, LogTypeInfo

    Select Case sMake

        Case "Dell Computer Corporation", "Dell Inc.", "Dell Computer Corp."
		SetMakeAlias = "Dell"

        Case "Matsushita Electric Industrial Co.,Ltd."
		SetMakeAlias = "Panasonic"	

        Case "VMware, Inc."
		SetMakeAlias = "VMware"

	Case "SAMSUNG ELECTRONICS CO., LTD."
		SetMakeAlias = "Samsung"
			
	Case "Microsoft Corporation"
		SetMakeAlias = "Microsoft"

        Case Else
		SetMakeAlias = sMake
	        oLogging.CreateEntry "UserExit: Alias rule not found.  MakeAlias will be set to Make value." , LogTypeInfo
    End Select
    oLogging.CreateEntry "UserExit: MakeAlias has been set to " & SetMakeAlias, LogTypeInfo
    oLogging.CreateEntry "UserExit: Departing...", LogTypeInfo

End Function

Function SetModelAlias()

    oLogging.CreateEntry "UserExit: Running function SetModelAlias", LogTypeInfo
    sMake = oEnvironment.Item("Make")
    sModel = oEnvironment.Item("Model")
    SetModelAlias = ""
    sCSPVersion = ""
    sBIOSVersion = ""
    oLogging.CreateEntry "UserExit: Make is now " & sMake, LogTypeInfo
    oLogging.CreateEntry "UserExit: Model is now " & sModel, LogTypeInfo

    Set colComputerSystemProduct = objWMI.ExecQuery("SELECT * FROM Win32_ComputerSystemProduct")
    If Err then
        oLogging.CreateEntry "Error querying Win32_ComputerSystemProduct: " & Err.Description & " (" & Err.Number & ")", LogTypeError
    Else
        For Each objComputerSystemProduct in colComputerSystemProduct
            If not IsNull(objComputerSystemProduct.Version) then
                sCSPVersion = Trim(objComputerSystemProduct.Version)
                oLogging.CreateEntry "UserExit: Win32_ComputerSystemProduct Version: " & sCSPVersion, LogTypeInfo
            End If
        Next
    End if

    Set colBIOS = objWMI.ExecQuery("SELECT * FROM Win32_BIOS")
    If Err then
        oLogging.CreateEntry "Error querying Win32_BIOS: " & Err.Description & " (" & Err.Number & ")", LogTypeError
    Else
        For Each objBIOS in colBIOS
            If not IsNull(objBIOS.Version) then
                sBIOSVersion = Trim(objBIOS.Version)
                oLogging.CreateEntry "UserExit: Win32_BIOS Version: " & sBIOSVersion, LogTypeInfo
            End If
        Next
    End if


    ' Check by Make
    
    Select Case sMake

        Case "Dell Computer Corporation", "Dell Inc.", "Dell Computer Corp."
            ' Use Model with spaces removed
            ' SetModelAlias = Replace(sModel, " ", "")
	    SetModelAlias = sModel

        Case "Hewlett-Packard"
            ' Use Model with spaces removed
            ' SetModelAlias = Replace(sModel, " ", "")
	    Select Case sModel
		Case "HP Compaq nw8240 (PY442EA#AK8)"
		    SetModelAlias = "HP Compaq nw8240"
                Case Else
                    SetModelAlias = sModel 
                    oLogging.CreateEntry "UserExit: Alias rule not found.  ModelAlias set to Model value." , LogTypeInfo
            End Select

        Case "HP"
            ' Use Model with spaces removed
            ' SetModelAlias = Replace(sModel, " ", "")
            SetModelAlias = sModel

        Case "IBM"
            ' Use Model with spaces removed
            ' SetModelAlias = Replace(sModel, " ", "")
	    Select Case sModel
		Case "---[HS22]---"
		    SetModelAlias = "IBMHS22"
                Case Else
                    SetModelAlias = sModel 
                    oLogging.CreateEntry "UserExit: Alias rule not found.  ModelAlias set to Model value." , LogTypeInfo
            End Select

        Case "LENOVO"
            ' Check by Version property of the Win32_ComputerSystemProduct WMI class first
            If Not sCSPVersion = "" Then
                Select Case sCSPVersion
                    Case "ThinkPad T61p"
                        SetModelAlias = "ThinkPad T61"
                    Case Else
                    ' Use Version with spaces removed
                    ' SetModelAlias = Replace(sCSPVersion, " ", "")
                    SetModelAlias = sModel
                End Select
            End If
            ' Check by first 4 characters of the Model
            If SetModelAlias = "" Then 
                sModelSubString = Left(sModel,4)
                Select Case sModelSubString
                    Case "1706"
                        SetModelAlias = "ThinkPad X60"
                    Case Else
                        SetModelAlias = sModel
                        oLogging.CreateEntry "UserExit: Alias rule not found.  ModelAlias set to Model value." , LogTypeInfo
                End Select
            End If

        Case "Matsushita Electric Industrial Co.,Ltd."
            'Panasonic Toughbook models
            If Left(sModel,2) = "CF" Then 
                SetModelAlias = Left(sModel,5)
            Else
                SetModelAlias = sModel 
                oLogging.CreateEntry "UserExit: Alias rule not found.  ModelAlias set to Model value." , LogTypeInfo
            End If

        Case "Microsoft Corporation"

            Select Case sBIOSVersion
                Case "VRTUAL - 1000831"
                    SetModelAlias = "Hyper-V2008BetaorRC0"
                Case "VRTUAL - 5000805", "BIOS Date: 05/05/08 20:35:56  Ver: 08.00.02"
                    SetModelAlias = "Hyper-V2008RTM"
                Case "VRTUAL - 3000919" 
                    SetModelAlias = "Hyper-V2008R2"
                Case "VRTUAL - 9001114" 
                    SetModelAlias = "Hyper-V2012BETA"
                Case "A M I  - 2000622"
                    SetModelAlias = "VS2005R2SP1orVPC2007"
                Case "A M I  - 9000520"
                    SetModelAlias = "VS2005R2"
                Case "A M I  - 9000816", "A M I  - 6000901"
                    SetModelAlias = "WindowsVirtualPC"
                Case "A M I  - 8000314"
                    SetModelAlias = "VS2005orVPC2004"
                Case Else
                    SetModelAlias = sModel 
                    oLogging.CreateEntry "UserExit: Alias rule not found.  ModelAlias set to Model value." , LogTypeInfo
            End Select

        Case "Xen"
            Select Case sCSPVersion
                Case "4.1.2"
                    SetModelAlias = "XenServer602"
                Case Else
                    SetModelAlias = "XenServer" 
                    oLogging.CreateEntry "UserExit: Alias rule not found.  ModelAlias set to Model value." , LogTypeInfo
            End Select

        Case "VMware, Inc."
            SetModelAlias = "VMware"

        Case Else
            If Instr(sModel, "(") > 2 Then 
                SetModelAlias = Trim(Left(sModel, Instr(sModel, "(") - 2)) 
            Else 
                SetModelAlias = sModel 
                oLogging.CreateEntry "UserExit: Alias rule not found.  ModelAlias set to Model value." , LogTypeInfo
            End if 
    End Select

    oLogging.CreateEntry "UserExit: ModelAlias has been set to " & SetModelAlias, LogTypeInfo
    oLogging.CreateEntry "UserExit: Departing...", LogTypeInfo

End Function

Function SetSMBIOSBIOSVersion() 
    oLogging.CreateEntry "UserExit: Running function SetSMBIOSBIOSVersion", LogTypeInfo
    Dim objWMI
    Dim objResults
    Dim objInstance
    Dim SMBIOSBIOSVersion
    
    Set objWMI = GetObject("winmgmts:") 
    Set objResults = objWMI.ExecQuery("SELECT * FROM Win32_BIOS")
        If Err then
        oLogging.CreateEntry "Error querying Win32_BIOS: " & Err.Description & " (" & Err.Number & ")", LogTypeError
    Else
        For each objInstance in objResults 
            If Not IsNull(objInstance.SMBIOSBIOSVersion) Then 
                    SMBIOSBIOSVersion = Trim(objInstance.SMBIOSBIOSVersion) 
            End If 
        Next
    End If
    SMBIOSBIOSVersion = Replace(SMBIOSBIOSVersion, " ", "")
    SMBIOSBIOSVersion = Replace(SMBIOSBIOSVersion, ".", "")
    SetSMBIOSBIOSVersion = SMBIOSBIOSVersion    
    oLogging.CreateEntry "UserExit: SMBIOSBIOSVersion has been set to " & SMBIOSBIOSVersion, LogTypeInfo
    oLogging.CreateEntry "UserExit: Departing...", LogTypeInfo
End Function

Function SetMacAlias()
    oLogging.CreateEntry "UserExit: Running function SetMacAlias ", LogTypeInfo
    sMac = oEnvironment.Item("MacAddress001")
    SetMacAlias = ""
    oLogging.CreateEntry "UserExit: MacAddress001 is now " & sMac, LogTypeInfo
    SetMacAlias = Replace(sMac, ":", "")
    oLogging.CreateEntry "UserExit: SetMacAlias has been set to " & sMac, LogTypeInfo
    oLogging.CreateEntry "UserExit: Departing...", LogTypeInfo
End Function
