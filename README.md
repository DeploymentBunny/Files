# Deployment Bunny Script Collection

Welcome to the Deployment Bunny Script Collection. 
This repository contains deployment and infrastructure automation scripts.
Blog: http://www.deploymentbunny.com
Twitter: @mikael_nystrom

## Summary

- Top-level folder: Tools
- Total folders under Tools: 96
- Total script files under Tools: 117

## Disk Performance Benchmark Tools

This repository includes two scripts for running DiskSpd benchmarks and viewing results.

### Script 1: Measure-DiskPerf.ps1

- Path: Tools/Measure-DiskPerf/Measure-DiskPerf.ps1
- Purpose: Runs DiskSpd tests for three random read/write mixes and builds CSV, JSON, XML, PNG, and HTML output.

Supported workload patterns:

- Random 60% Read / 40% Write
- Random 70% Read / 30% Write
- Random 80% Read / 20% Write

Default values:

- TargetPath: %TEMP%
- Duration: 120 seconds
- BlockSizeKB: 4
- Threads: 2
- OutputPath: %TEMP%\DiskSpdResults
- DiskSpdPath: diskspd.exe

Input behavior:

- Folder path: creates a timestamped test file in that folder.
- File path: uses that exact file path.
- Drive letter only (for example C or C:): normalizes to C:\.

Main parameters:

- TargetPath: local folder, UNC folder, local file, or UNC file.
- Duration: benchmark duration in seconds.
- BlockSizeKB: block size in kilobytes.
- Threads: threads per target and queue depth.
- OutputPath: output folder for all artifacts.
- DiskSpdPath: full path to diskspd.exe, or executable name if available in PATH.

Generated artifacts:

- DiskSpd_*.xml: raw XML output for each run.
- Graph_IOPS_*.png: IOPS over time graph.
- Graph_Latency_*.png: latency distribution graph.
- DiskSpd_Summary_*.csv: tabular summary.
- DiskSpd_Summary_*.json: JSON summary.
- DiskSpd_Report_*.html: consolidated report.

Example:

- .\Tools\Measure-DiskPerf\Measure-DiskPerf.ps1 -TargetPath 'D:\Bench' -Duration 60 -BlockSizeKB 4 -Threads 2

### Script 2: Measure-DiskPerfwUI.ps1

- Path: Tools/Measure-DiskPerf/Measure-DiskPerfwUI.ps1
- Purpose: Windows Forms launcher for Measure-DiskPerf.ps1.

UI capabilities:

- Select target path (local folder or UNC path).
- Select diskspd.exe path.
- Configure duration, block size, threads, and output folder.
- Run the benchmark script with selected values.
- Optionally open the latest HTML report after the run.
- Save and restore last used settings in %LOCALAPPDATA%\DeploymentBunny.
- Write a per-run log file in %TEMP%.

Settings file:

- %LOCALAPPDATA%\DeploymentBunny\Measure-DiskPerfwUI.settings.json

Log file naming:

- %TEMP%\Measure-DiskPerfwUI_yyyyMMdd_HHmmss.log

Example:

- .\Tools\Measure-DiskPerf\Measure-DiskPerfwUI.ps1

Prerequisites for both scripts:

- Windows PowerShell 5.1 or newer.
- DiskSpd installed and available by full path or PATH.
- Write access to the selected output folder.
- For chart images: System.Windows.Forms.DataVisualization assembly available on the host.

## Folders And Scripts

### Tools

- Description: Contains scripts and related files for Tools tasks.
- Scripts: None detected in this folder

### Tools/Action - Update Defender Signatures

- Description: Contains scripts and related files for Action Update Defender Signatures tasks.
- Scripts:
  - Tools/Action - Update Defender Signatures/Action-UpdateDefender.ps1: Script for Action UpdateDefender.

### Tools/Action-CleanupBeforeSysprep

- Description: Contains scripts and related files for Action CleanupBeforeSysprep tasks.
- Scripts:
  - Tools/Action-CleanupBeforeSysprep/Action-CleanupBeforeSysprep.wsf: Script for Action CleanupBeforeSysprep.

### Tools/Add-ComputerToMDTDatabase

- Description: Contains scripts and related files for Add ComputerToMDTDatabase tasks.
- Scripts:
  - Tools/Add-ComputerToMDTDatabase/Add-ComputerToMDTDataBase.ps1: Script for Add ComputerToMDTDataBase.

### Tools/Apply - LGPO for Windows Server 2019

- Description: Contains scripts and related files for Apply LGPO for Windows Server 2019 tasks.
- Scripts:
  - Tools/Apply - LGPO for Windows Server 2019/ApplyLGPO.ps1: Script for ApplyLGPO.
  - Tools/Apply - LGPO for Windows Server 2019/Invoke-Install.ps1: Script for Invoke Install.

### Tools/CheckSecureBoot

- Description: Contains scripts and related files for CheckSecureBoot tasks.
- Scripts:
  - Tools/CheckSecureBoot/CheckSecureBoot.ps1: Script for CheckSecureBoot.

### Tools/Check-VIAApprovedModel

- Description: Contains scripts and related files for Check VIAApprovedModel tasks.
- Scripts:
  - Tools/Check-VIAApprovedModel/Check-VIAApprovedModel.ps1: Script for Check VIAApprovedModel.

### Tools/CheckWindowsClientSecurityBaseline

- Description: Assesses and remediates Windows 10/11 client security controls against a defined baseline. Supports checks for UEFI, Secure Boot, TPM, BitLocker, VBS, Credential Guard, HVCI, WDAC, LSA protection, WDigest, SMB1, NTLM hardening, Firewall, Multicast Name Resolution (LLMNR), and more.
- Scripts:
  - Tools/CheckWindowsClientSecurityBaseline/Check-WindowsClientSecurityBaseline.ps1: Evaluates core security controls and returns True/False/Unknown/NA results per check. Supports -FalseOnly to return only non-True results.
  - Tools/CheckWindowsClientSecurityBaseline/Remediate-WindowsClientSecurityBaseline.ps1: Applies configurable remediation for findings from the baseline assessment. Supports -HardenRecommended preset and -AutoFromBaseline automation.

### Tools/Configure - Windows Client

- Description: Contains scripts and related files for Configure Windows Client tasks.
- Scripts:
  - Tools/Configure - Windows Client/Configure-WindowsClient.ps1: Script for Configure WindowsClient.

### Tools/Configure - Windows Server

- Description: Contains scripts and related files for Configure Windows Server tasks.
- Scripts:
  - Tools/Configure - Windows Server/Configure-WindowsServer.ps1: Script for Configure WindowsServer.

### Tools/Configure-DisableServicesforWindowsServer

- Description: Contains scripts and related files for Configure DisableServicesforWindowsServer tasks.
- Scripts:
  - Tools/Configure-DisableServicesforWindowsServer/Configure-DisableServicesforWindowsServer.ps1: Script for Configure DisableServicesforWindowsServer.

### Tools/Configure-HPBIOS

- Description: Contains scripts and related files for Configure HPBIOS tasks.
- Scripts:
  - Tools/Configure-HPBIOS/Configure-HPBIOS.ps1: Script for Configure HPBIOS.

### Tools/Configure-HPILO

- Description: Contains scripts and related files for Configure HPILO tasks.
- Scripts:
  - Tools/Configure-HPILO/Configure-HPILO.ps1: Script for Configure HPILO.

### Tools/Configure-ResetHPILO

- Description: Contains scripts and related files for Configure ResetHPILO tasks.
- Scripts:
  - Tools/Configure-ResetHPILO/Reset-HPILO.ps1: Script for Reset HPILO.

### Tools/Connect-VIARDP

- Description: Contains scripts and related files for Connect VIARDP tasks.
- Scripts:
  - Tools/Connect-VIARDP/ConnectVIARDP.psm1: Script for ConnectVIARDP.

### Tools/Convert-TSxWIMToVHD

- Description: Converts WIM images to VHD/VHDX format, with helper scripts for WIM index info and a Windows Forms UI launcher.
- Scripts:
  - Tools/Convert-TSxWIMToVHD/Convert-TSxWIM2VHD.ps1: Script for Convert TSxWIM2VHD.
  - Tools/Convert-TSxWIMToVHD/Convert-TSxWIM2VHDUI.ps1: Script for Convert TSxWIM2VHD UI.
  - Tools/Convert-TSxWIMToVHD/Get-TSxWimIndexInfo.ps1: Script for Get TSxWimIndexInfo.
  - Tools/Convert-TSxWIMToVHD/Get-TSxWIMInfo.ps1: Script for Get TSxWIMInfo.

### Tools/Convert-WIM2VHD

- Description: Contains scripts and related files for Convert WIM2VHD tasks.
- Scripts:
  - Tools/Convert-WIM2VHD/Convert-WIM2VHD.ps1: Script for Convert WIM2VHD.

### Tools/Convert-WindowsEdition

- Description: Contains scripts and related files for Convert WindowsEdition tasks.
- Scripts:
  - Tools/Convert-WindowsEdition/Convert-WindowsEdition.ps1: Script for Convert WindowsEdition.

### Tools/Create-ADUserDemo

- Description: Contains scripts and related files for Create ADUserDemo tasks.
- Scripts:
  - Tools/Create-ADUserDemo/ImportUsers.ps1: Script for ImportUsers.

### Tools/Create-MDTEvents

- Description: Contains scripts and related files for Create MDTEvents tasks.
- Scripts:
  - Tools/Create-MDTEvents/CreateEvent.ps1: Script for CreateEvent.

### Tools/Create-VIAComputerName

- Description: Contains scripts and related files for Create VIAComputerName tasks.
- Scripts:
  - Tools/Create-VIAComputerName/Create-VIAComputerName.ps1: Script for Create VIAComputerName.

### Tools/CSDemo

- Description: Contains scripts and related files for CSDemo tasks.
- Scripts:
  - Tools/CSDemo/AliasUserExit.vbs: Script for AliasUserExit.
  - Tools/CSDemo/test.cmd: Script for test.

### Tools/CSDemo/Samples

- Description: Contains scripts and related files for Samples tasks.
- Scripts: None detected in this folder

### Tools/CSDemo/Scripts

- Description: Contains scripts and related files for Scripts tasks.
- Scripts:
  - Tools/CSDemo/Scripts/AliasUserExit.vbs: Script for AliasUserExit.

### Tools/Custom-ZTITatoo

- Description: Contains scripts and related files for Custom ZTITatoo tasks.
- Scripts:
  - Tools/Custom-ZTITatoo/ViaMonstraTatoo.wsf: Script for ViaMonstraTatoo.

### Tools/Disable-InternetAccess

- Description: Contains scripts and related files for Disable InternetAccess tasks.
- Scripts:
  - Tools/Disable-InternetAccess/Disable-InternetAccess.ps1: Script for Disable InternetAccess.

### Tools/Disable-ServerApps

- Description: Contains scripts and related files for Disable ServerApps tasks.
- Scripts:
  - Tools/Disable-ServerApps/Disable-ServerApps.ps1: Script for Disable ServerApps.

### Tools/Enable-NestedHyperV

- Description: Contains scripts and related files for Enable NestedHyperV tasks.
- Scripts:
  - Tools/Enable-NestedHyperV/EnableNestedHyperV.ps1: Script for EnableNestedHyperV.
  - Tools/Enable-NestedHyperV/EnableNestedHyperVSimple.ps1: Script for EnableNestedHyperVSimple.
  - Tools/Enable-NestedHyperV/GetNestedHyperVRedniness.PS1: Script for GetNestedHyperVRedniness.

### Tools/Export-Import Roles and Features Fore Windows Server

- Description: Exports, imports, copies, and deploys Windows Server roles and features, with a Windows Forms UI launcher.
- Scripts:
  - Tools/Export-Import Roles and Features Fore Windows Server/Copy-WindowsRolesAndFeatures.ps1: Script for Copy WindowsRolesAndFeatures.
  - Tools/Export-Import Roles and Features Fore Windows Server/Deploy-WindowsRolesAndFeatures.ps1: Script for Deploy WindowsRolesAndFeatures.
  - Tools/Export-Import Roles and Features Fore Windows Server/Export-WindowsRolesAndFeatures.ps1: Script for Export WindowsRolesAndFeatures.
  - Tools/Export-Import Roles and Features Fore Windows Server/Import-WindowsRolesAndFeatures.ps1: Script for Import WindowsRolesAndFeatures.
  - Tools/Export-Import Roles and Features Fore Windows Server/Invoke-WindowsRolesAndFeaturesUI.ps1: Script for Invoke WindowsRolesAndFeaturesUI.

### Tools/Export-ModernDriverPackage

- Description: Contains scripts and related files for Export ModernDriverPackage tasks.
- Scripts:
  - Tools/Export-ModernDriverPackage/Export-ModernDriverPackage.ps1: Script for Export ModernDriverPackage.

### Tools/GenOSDStatus

- Description: Contains scripts and related files for GenOSDStatus tasks.
- Scripts:
  - Tools/GenOSDStatus/GenOSDStatus.ps1: Script for GenOSDStatus.

### Tools/GenOSDStatusV2

- Description: Contains scripts and related files for GenOSDStatusV2 tasks.
- Scripts:
  - Tools/GenOSDStatusV2/GenOSDStatusV2.ps1: Script for GenOSDStatusV2.

### Tools/Get-ADHealthCheck

- Description: Contains scripts and related files for Get ADHealthCheck tasks.
- Scripts:
  - Tools/Get-ADHealthCheck/Get-ADHealthCheck.ps1: Script for Get ADHealthCheck.

### Tools/Get-AllC++Runtimes

- Description: Contains scripts and related files for Get AllC++Runtimes tasks.
- Scripts:
  - Tools/Get-AllC++Runtimes/Get-Downloads.ps1: Script for Get Downloads.
  - Tools/Get-AllC++Runtimes/RunMe.ps1: Script for RunMe.

### Tools/Get-DHCPHealthCheck

- Description: Contains scripts and related files for Get DHCPHealthCheck tasks.
- Scripts:
  - Tools/Get-DHCPHealthCheck/Get-DHCPHealthCheck.ps1: Script for Get DHCPHealthCheck.

### Tools/GetILOInfo

- Description: Contains scripts and related files for GetILOInfo tasks.
- Scripts:
  - Tools/GetILOInfo/GetILOInfo.psm1: Script for GetILOInfo.

### Tools/Get-MDTOdata

- Description: Contains scripts and related files for Get MDTOdata tasks.
- Scripts:
  - Tools/Get-MDTOdata/GetMDTOdata.ps1: Script for GetMDTOdata.

### Tools/Get-ReliabilityStabilityMetrics

- Description: Contains scripts and related files for Get ReliabilityStabilityMetrics tasks.
- Scripts:
  - Tools/Get-ReliabilityStabilityMetrics/Get-ReliabilityStabilityMetrics.ps1: Script for Get ReliabilityStabilityMetrics.

### Tools/Get-TSxEdgeEnterpriseMSIAndInstall

- Description: Contains scripts and related files for Get TSxEdgeEnterpriseMSIAndInstall tasks.
- Scripts:
  - Tools/Get-TSxEdgeEnterpriseMSIAndInstall/Get-TSxEdgeEnterpriseMSIAndInstall.ps1: Script for Get TSxEdgeEnterpriseMSIAndInstall.

### Tools/Get-TSxLatestWindowsUpdate

- Description: Contains scripts and related files for Get TSxLatestWindowsUpdate tasks.
- Scripts: None detected in this folder

### Tools/Get-TSxMSEdgeNow

- Description: Contains scripts and related files for Get TSxMSEdgeNow tasks.
- Scripts:
  - Tools/Get-TSxMSEdgeNow/Get-TSxMSEdgeNow.ps1: Script for Get TSxMSEdgeNow.

### Tools/Get-VIAActiveDiffDisk

- Description: Contains scripts and related files for Get VIAActiveDiffDisk tasks.
- Scripts:
  - Tools/Get-VIAActiveDiffDisk/GetVIAActiveDiffDisk.ps1: Script for GetVIAActiveDiffDisk.

### Tools/Get-VIADisconnectedVHDs

- Description: Contains scripts and related files for Get VIADisconnectedVHDs tasks.
- Scripts:
  - Tools/Get-VIADisconnectedVHDs/GetVIADisconnectedVHDs.psm1: Script for GetVIADisconnectedVHDs.

### Tools/Get-VIASCVMMDiskInfo

- Description: Contains scripts and related files for Get VIASCVMMDiskInfo tasks.
- Scripts:
  - Tools/Get-VIASCVMMDiskInfo/GetVIASCVMMDiskInfo.psm1: Script for GetVIASCVMMDiskInfo.

### Tools/Get-VIAUnimportedvmcxFiles

- Description: Contains scripts and related files for Get VIAUnimportedvmcxFiles tasks.
- Scripts:
  - Tools/Get-VIAUnimportedvmcxFiles/GetVIAUnimportedvmcxFiles.psm1: Script for GetVIAUnimportedvmcxFiles.

### Tools/Get-VMHealthCheck

- Description: Contains scripts and related files for Get VMHealthCheck tasks.
- Scripts:
  - Tools/Get-VMHealthCheck/Get-VMHealthCheck.ps1: Script for Get VMHealthCheck.

### Tools/Get-WIMInfo

- Description: Contains scripts and related files for Get WIMInfo tasks.
- Scripts:
  - Tools/Get-WIMInfo/Get-WimInfo.ps1: Script for Get WimInfo.

### Tools/Get-WindowsClientHealthLogs

- Description: Contains scripts and related files for Get WindowsClientHealthLogs tasks.
- Scripts:
  - Tools/Get-WindowsClientHealthLogs/Get-WindowsClientHealthLogs.ps1: Script for Get WindowsClientHealthLogs.

### Tools/Get-WSUSHealthCheck

- Description: Contains scripts and related files for Get WSUSHealthCheck tasks.
- Scripts:
  - Tools/Get-WSUSHealthCheck/Get-WSUSHealthCheck.ps1: Script for Get WSUSHealthCheck.

### Tools/IdentityLifeCyleWoops

- Description: Contains scripts and related files for IdentityLifeCyleWoops tasks.
- Scripts:
  - Tools/IdentityLifeCyleWoops/GetAdminCount.ps1: Script for GetAdminCount.
  - Tools/IdentityLifeCyleWoops/GetAllUsersEnabledAndPasswordNeverExpires.ps1: Script for GetAllUsersEnabledAndPasswordNeverExpires.
  - Tools/IdentityLifeCyleWoops/GetAllUsersintheDomainAdminGroup.ps1: Script for GetAllUsersintheDomainAdminGroup.

### Tools/IMF-ConfigMgrImport

- Description: Contains scripts and related files for IMF ConfigMgrImport tasks.
- Scripts:
  - Tools/IMF-ConfigMgrImport/IMF-ConfigMgrImport.ps1: Script for IMF ConfigMgrImport.

### Tools/Import-MDTApps

- Description: Contains scripts and related files for Import MDTApps tasks.
- Scripts:
  - Tools/Import-MDTApps/Import-MDTApps.ps1: Script for Import MDTApps.

### Tools/Install - Acrobat Reader DC en

- Description: Contains scripts and related files for Install Acrobat Reader DC en tasks.
- Scripts:
  - Tools/Install - Acrobat Reader DC en/Install-AcrobatReaderDC.ps1: Script for Install AcrobatReaderDC.

### Tools/Install - C++ Runtime v14 framework package for Desktop Bridge

- Description: Contains scripts and related files for Install C++ Runtime v14 framework package for Desktop Bridge tasks.
- Scripts:
  - Tools/Install - C++ Runtime v14 framework package for Desktop Bridge/Install-C++Runtimev14.ps1: Script for Install C++Runtimev14.

### Tools/Install - Dell command update en

- Description: Contains scripts and related files for Install Dell command update en tasks.
- Scripts:
  - Tools/Install - Dell command update en/Install-Dell_command_update.ps1: Script for Install Dell command update.

### Tools/Install - Microsoft BGInfo - x86-x64

- Description: Contains scripts and related files for Install Microsoft BGInfo x86 x64 tasks.
- Scripts:
  - Tools/Install - Microsoft BGInfo - x86-x64/Install-MicrosoftBGInfox86x64.wsf: Script for Install MicrosoftBGInfox86x64.

### Tools/Install - Microsoft BGInfo - x86-x64/Source

- Description: Contains scripts and related files for Source tasks.
- Scripts: None detected in this folder

### Tools/Install - Microsoft Visual C++

- Description: Contains scripts and related files for Install Microsoft Visual C++ tasks.
- Scripts:
  - Tools/Install - Microsoft Visual C++/Install-MicrosoftVisualC++x86x64.wsf: Script for Install MicrosoftVisualC++x86x64.

### Tools/Install - Mozilla Firefox

- Description: Contains scripts and related files for Install Mozilla Firefox tasks.
- Scripts:
  - Tools/Install - Mozilla Firefox/Install-MozillaFirefox.ps1: Script for Install MozillaFirefox.

### Tools/Install - Notepad++

- Description: Contains scripts and related files for Install Notepad++ tasks.
- Scripts:
  - Tools/Install - Notepad++/Install-NPP.ps1: Script for Install NPP.

### Tools/Install - NuGet Provider

- Description: Contains scripts and related files for Install NuGet Provider tasks.
- Scripts:
  - Tools/Install - NuGet Provider/Install-NuGet.ps1: Script for Install NuGet.

### Tools/Install - Office 365 ProPlus

- Description: Contains scripts and related files for Install Office 365 ProPlus tasks.
- Scripts:
  - Tools/Install - Office 365 ProPlus/Install-Office365.ps1: Script for Install Office365.

### Tools/Install - Office 365 ProPlus Project

- Description: Contains scripts and related files for Install Office 365 ProPlus Project tasks.
- Scripts:
  - Tools/Install - Office 365 ProPlus Project/Install-Office365Project.ps1: Script for Install Office365Project.

### Tools/Install - Office 365 ProPlus Project/Source

- Description: Contains scripts and related files for Source tasks.
- Scripts: None detected in this folder

### Tools/Install - Office 365 ProPlus Visio

- Description: Contains scripts and related files for Install Office 365 ProPlus Visio tasks.
- Scripts:
  - Tools/Install - Office 365 ProPlus Visio/Install-Office365Visio.ps1: Script for Install Office365Visio.

### Tools/Install - Office 365 ProPlus Visio/Source

- Description: Contains scripts and related files for Source tasks.
- Scripts: None detected in this folder

### Tools/Install - Office 365 ProPlus/Source

- Description: Contains scripts and related files for Source tasks.
- Scripts: None detected in this folder

### Tools/Install - PDF Creator

- Description: Contains scripts and related files for Install PDF Creator tasks.
- Scripts:
  - Tools/Install - PDF Creator/Install-PDFCreator.ps1: Script for Install PDFCreator.

### Tools/Install - Putty

- Description: Contains scripts and related files for Install Putty tasks.
- Scripts:
  - Tools/Install - Putty/Install-Putty.ps1: Script for Install Putty.

### Tools/Install - RSAT

- Description: Contains scripts and related files for Install RSAT tasks.
- Scripts:
  - Tools/Install - RSAT/Install-RSAT.ps1: Script for Install RSAT.

### Tools/Install - VLCPlayer

- Description: Contains scripts and related files for Install VLCPlayer tasks.
- Scripts:
  - Tools/Install - VLCPlayer/Install-VLCPlayer.ps1: Script for Install VLCPlayer.

### Tools/Install - VSCode

- Description: Contains scripts and related files for Install VSCode tasks.
- Scripts:
  - Tools/Install - VSCode/Install-VSCode.ps1: Script for Install VSCode.

### Tools/Install - Windows Terminal

- Description: Contains scripts and related files for Install Windows Terminal tasks.
- Scripts:
  - Tools/Install - Windows Terminal/Install-WindowsTerminal.ps1: Script for Install WindowsTerminal.

### Tools/Install-BIOSUpgrade

- Description: Contains scripts and related files for Install BIOSUpgrade tasks.
- Scripts:
  - Tools/Install-BIOSUpgrade/Install-BIOSUpgrade.ps1: Script for Install BIOSUpgrade.

### Tools/Install-HPBIOSCmdlets

- Description: Contains scripts and related files for Install HPBIOSCmdlets tasks.
- Scripts:
  - Tools/Install-HPBIOSCmdlets/Install-HPBIOSCmdlets-x64.ps1: Script for Install HPBIOSCmdlets x64.

### Tools/Install-HPSUM

- Description: Contains scripts and related files for Install HPSUM tasks.
- Scripts:
  - Tools/Install-HPSUM/Install-HPSUM.ps1: Script for Install HPSUM.

### Tools/Install-RSATToolsfor1809

- Description: Contains scripts and related files for Install RSATToolsfor1809 tasks.
- Scripts:
  - Tools/Install-RSATToolsfor1809/Install-RSATToolsfor1809.ps1: Script for Install RSATToolsfor1809.

### Tools/Install-Wrapper

- Description: Contains scripts and related files for Install Wrapper tasks.
- Scripts:
  - Tools/Install-Wrapper/Invoke-Install.ps1: Script for Invoke Install.

### Tools/Install-X86-X64-C++

- Description: Contains scripts and related files for Install X86 X64 C++ tasks.
- Scripts:
  - Tools/Install-X86-X64-C++/Install-MicrosoftVisualC++x86x64.wsf: Script for Install MicrosoftVisualC++x86x64.

### Tools/Invoke-WSUSMaint

- Description: Contains scripts and related files for Invoke WSUSMaint tasks.
- Scripts:
  - Tools/Invoke-WSUSMaint/Invoke-WSUSMaint.ps1: Script for Invoke WSUSMaint.

### Tools/MassUpgradeWindows10

- Description: Contains scripts and related files for MassUpgradeWindows10 tasks.
- Scripts:
  - Tools/MassUpgradeWindows10/Invoke-ComputerCleanup.ps1: Script for Invoke ComputerCleanup.
  - Tools/MassUpgradeWindows10/Invoke-ComputerCompatScan.ps1: Script for Invoke ComputerCompatScan.
  - Tools/MassUpgradeWindows10/Invoke-ComputerPrep.ps1: Script for Invoke ComputerPrep.
  - Tools/MassUpgradeWindows10/Invoke-ComputerUpgrade.ps1: Script for Invoke ComputerUpgrade.
  - Tools/MassUpgradeWindows10/Invoke-ImageDownload.ps1: Script for Invoke ImageDownload.

### Tools/MDTComputerInventoryStoredProcedure

- Description: Contains scripts and related files for MDTComputerInventoryStoredProcedure tasks.
- Scripts:
  - Tools/MDTComputerInventoryStoredProcedure/HardwareInfo.vbs: Script for HardwareInfo.

### Tools/Measure-DiskPerf

- Description: Contains scripts and related files for Measure DiskPerf tasks.
- Scripts:
  - Tools/Measure-DiskPerf/Measure-DiskPerf.ps1: Script for Measure DiskPerf.
  - Tools/Measure-DiskPerf/Measure-DiskPerfwUI.ps1: Script for Measure DiskPerf with UI.

### Tools/MonitorMDT

- Description: Contains scripts and related files for MonitorMDT tasks.
- Scripts:
  - Tools/MonitorMDT/MonitorMDT.ps1: Script for MonitorMDT.

### Tools/NANORefImageModule

- Description: Contains scripts and related files for NANORefImageModule tasks.
- Scripts:
  - Tools/NANORefImageModule/NANORefImageModule.psm1: Script for NANORefImageModule.
  - Tools/NANORefImageModule/NewNANORefImage.ps1: Script for NewNANORefImage.

### Tools/New-HyperVM

- Description: Contains scripts and related files for New HyperVM tasks.
- Scripts:
  - Tools/New-HyperVM/New-HyperVM.ps1: Script for New HyperVM.

### Tools/OptimizeVHDs

- Description: Contains scripts and related files for OptimizeVHDs tasks.
- Scripts:
  - Tools/OptimizeVHDs/OptimizeVHDs.ps1: Script for OptimizeVHDs.
  - Tools/OptimizeVHDs/OptimizeV⁮IAVHD.ps1: Script for OptimizeV⁮IAVHD.

### Tools/RemoveVMwUI

- Description: Contains scripts and related files for RemoveVMwUI tasks.
- Scripts:
  - Tools/RemoveVMwUI/RemoveVMwUI.ps1: Script for RemoveVMwUI.

### Tools/RemoveVMwUI2

- Description: Contains scripts and related files for RemoveVMwUI2 tasks.
- Scripts:
  - Tools/RemoveVMwUI2/RemoveVMwUI2.ps1: Script for RemoveVMwUI2.

### Tools/RestPSFiles

- Description: Contains scripts and related files for RestPSFiles tasks.
- Scripts:
  - Tools/RestPSFiles/Install and Configure RestPS.ps1: Script for Install and Configure RestPS.
  - Tools/RestPSFiles/Install Choclaty and NSSM.ps1: Script for Install Choclaty and NSSM.
  - Tools/RestPSFiles/Install NuGet and PowerShellGet.ps1: Script for Install NuGet and PowerShellGet.
  - Tools/RestPSFiles/Make RestPS a Services.ps1: Script for Make RestPS a Services.
  - Tools/RestPSFiles/Start RestPS.ps1: Script for Start RestPS.
  - Tools/RestPSFiles/StartRestPS.ps1: Script for StartRestPS.
  - Tools/RestPSFiles/Test RestPS.ps1: Script for Test RestPS.

### Tools/Running-ParJobs

- Description: Contains scripts and related files for Running ParJobs tasks.
- Scripts:
  - Tools/Running-ParJobs/Running-ParJobs.ps1: Script for Running ParJobs.

### Tools/Save-AllRunningVMs

- Description: Contains scripts and related files for Save AllRunningVMs tasks.
- Scripts:
  - Tools/Save-AllRunningVMs/Save-TSxAllRunningVMs.ps1: Script for Save TSxAllRunningVMs.
  - Tools/Save-AllRunningVMs/Resume-TSxAllRunningVMs.ps1: Script for Resume TSxAllRunningVMs.

### Tools/Set-TSxTimesync

- Description: Contains scripts and related files for Set TSxTimesync tasks.
- Scripts:
  - Tools/Set-TSxTimesync/Set-TSxTimesync.ps1: Script for Set TSxTimesync.

### Tools/Start-VIADeDupJob

- Description: Runs Windows Data Deduplication maintenance jobs (Optimization, Garbage Collection, Scrubbing) on all dedup-enabled volumes. Includes a Windows Forms UI launcher with local and remote server support.
- Scripts:
  - Tools/Start-VIADeDupJob/Invoke-TSxDeDupJob.ps1: Command-line script that runs dedup jobs sequentially per volume and supports -Report mode to show active jobs.
  - Tools/Start-VIADeDupJob/Invoke-TSxDeDupJobUI.ps1: Windows Forms UI launcher for local and remote execution of Invoke-TSxDeDupJob.ps1.

### Tools/Test-ModernDriverPackage

- Description: Contains scripts and related files for Test ModernDriverPackage tasks.
- Scripts:
  - Tools/Test-ModernDriverPackage/Test-ModernDriverPackage.ps1: Script for Test ModernDriverPackage.

### Tools/TSxWrite-MDTMonitor

- Description: Contains scripts and related files for TSxWrite MDTMonitor tasks.
- Scripts:
  - Tools/TSxWrite-MDTMonitor/TSxWrite-MDTMonitor.ps1: Script for TSxWrite MDTMonitor.

