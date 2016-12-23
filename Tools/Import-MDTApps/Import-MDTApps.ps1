#Import Apps
Param(
    [parameter(mandatory=$True,HelpMessage='Name of Appfolder')] 
    $ImportFolder = "C:\MDTApps",

    [parameter(mandatory=$True,HelpMessage='Name of MDTfolder')] 
    $MDTFolder = "C:\DeploymentShare"

)

#Load the MDT PS Module
try
    {
        Import-Module "C:\Program Files\Microsoft Deployment Toolkit\bin\MicrosoftDeploymentToolkit.psd1"
    }
    catch
    {
        Write-Error 'The MDT PS module could not be loaded correctly, exit'
        Exit
    }

if (!(test-path DS001:))
    {
         New-PSDrive -Name "DS001" -PSProvider MDTProvider -Root $MDTFolder
    }

Function Import-MDTAppBulk{
        import-MDTApplication -path "DS001:\Applications" `
        -enable "True"  `
        -Name $InstallLongAppName  `
        -ShortName $InstallLongAppName  `
        -Version ""  `
        -Publisher ""  `
        -Language ""  `
        -CommandLine $CommandLine  `
        -WorkingDirectory ".\Applications\$InstallLongAppName"  `
        -ApplicationSourcePath $InstallFolder  `
        -DestinationFolder $InstallLongAppName
}
$SearchFolders = get-childitem -Path $ImportFolder
Foreach ($SearchFolder in $SearchFolders){
    foreach ($InstallFile in (Get-ChildItem -Path $SearchFolder.FullName *.wsf)){
        $Install = $InstallFile.Name
        $InstallFolder = $InstallFile.DirectoryName
        $InstallLongAppName = $InstallFolder | Split-Path -Leaf
        $InstallerType = $InstallFilet.Extension
        $CommandLine = "cscript.exe $Install"
        Write-Verbose "Installer is $Install"
        Write-Verbose "InstallFolder is $InstallFolder"
        Write-Verbose "InstallLongAppName is $InstallLongAppName"
        Write-Verbose "InstallCommand is $CommandLine"
        Write-Verbose ""
        . Import-MDTAppBulk
    }
    foreach ($InstallFile in (Get-ChildItem -Path $SearchFolder.FullName *.exe)){
        $Install = $InstallFile.Name
        $InstallFolder = $InstallFile.DirectoryName
        $InstallLongAppName = $InstallFolder | Split-Path -Leaf
        $InstallerType = $InstallFilet.Extension
        $CommandLine = "$Install /q"
        Write-Verbose "Installer is $Install"
        Write-Verbose "InstallFolder is $InstallFolder"
        Write-Verbose "InstallLongAppName is $InstallLongAppName"
        Write-Verbose "InstallCommand is $CommandLine"
        Write-Verbose ""
        . Import-MDTAppBulk
    }
    foreach ($InstallFile in (Get-ChildItem -Path $SearchFolder.FullName *.msi)){
        $Install = $InstallFile.Name
        $InstallFolder = $InstallFile.DirectoryName
        $InstallLongAppName = $InstallFolder | Split-Path -Leaf
        $InstallerType = $InstallFilet.Extension
        $CommandLine = "msiexec.exe /i $Install /qn"
        Write-Verbose "Installer is $Install"
        Write-Verbose "InstallFolder is $InstallFolder"
        Write-Verbose "InstallLongAppName is $InstallLongAppName"
        Write-Verbose "InstallCommand is $CommandLine"
        Write-Verbose ""
        . Import-MDTAppBulk
    }
    foreach ($InstallFile in (Get-ChildItem -Path $SearchFolder.FullName *.msu)){
        $Install = $InstallFile.Name
        $InstallFolder = $InstallFile.DirectoryName
        $InstallLongAppName = $InstallFolder | Split-Path -Leaf
        $InstallerType = $InstallFilet.Extension
        $CommandLine = "wusa.exe $Install /Quiet /NoRestart"
        Write-Verbose "Installer is $Install"
        Write-Verbose "InstallFolder is $InstallFolder"
        Write-Verbose "InstallLongAppName is $InstallLongAppName"
        Write-Verbose "InstallCommand is $CommandLine"
        Write-Verbose ""
        . Import-MDTAppBulk

    }
    foreach ($InstallFile in (Get-ChildItem -Path $SearchFolder.FullName *.ps1)){
        $Install = $InstallFile.Name
        $InstallFolder = $InstallFile.DirectoryName
        $InstallLongAppName = $InstallFolder | Split-Path -Leaf
        $InstallerType = $InstallFilet.Extension
        $CommandLine = "PowerShell.exe -ExecutionPolicy ByPass -File $Install"
        Write-Verbose "Installer is $Install"
        Write-Verbose "InstallFolder is $InstallFolder"
        Write-Verbose "InstallLongAppName is $InstallLongAppName"
        Write-Verbose "InstallCommand is $CommandLine"
        Write-Verbose ""
        . Import-MDTAppBulk

    }
}
