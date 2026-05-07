[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogPath = (Join-Path -Path $env:TEMP -ChildPath 'Get-TSxWindowsUpdates.log')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:OutputTextBox = $null

function Start-TSxLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $parentPath = Split-Path -Path $FilePath -Parent
    if (-not (Test-Path -Path $parentPath)) {
        $null = New-Item -Path $parentPath -ItemType Directory -Force
    }

    if (-not (Test-Path -Path $FilePath)) {
        $null = New-Item -Path $FilePath -ItemType File -Force
    }

    $script:ScriptLogFilePath = $FilePath
}

function Write-TSxLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = '[{0}] [{1}] {2}' -f $timestamp, $Level, $Message
    Add-Content -Path $script:ScriptLogFilePath -Value $entry
    Write-Verbose $Message

    if ($script:OutputTextBox) {
        $script:OutputTextBox.AppendText($entry + [Environment]::NewLine)
        $script:OutputTextBox.SelectionStart = $script:OutputTextBox.TextLength
        $script:OutputTextBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Get-TSxDefaultArchitecture {
    [CmdletBinding()]
    param()

    switch -Regex ($env:PROCESSOR_ARCHITECTURE) {
        'ARM64' { return 'arm64' }
        '64' { return 'x64' }
        default { return 'x86' }
    }
}

$scriptRoot = Split-Path -Path $PSCommandPath -Parent
$listScriptPath = Join-Path -Path $scriptRoot -ChildPath 'Get-TSxLatestWindowsUpdateList.ps1'
$downloadScriptPath = Join-Path -Path $scriptRoot -ChildPath 'Save-TSxWindowsUpdateFromCatalog.ps1'

if (-not (Test-Path -Path $listScriptPath)) {
    throw ('List script not found: {0}' -f $listScriptPath)
}

if (-not (Test-Path -Path $downloadScriptPath)) {
    throw ('Download script not found: {0}' -f $downloadScriptPath)
}

$scriptName = Split-Path -Path $PSCommandPath -Leaf
Start-TSxLog -FilePath $LogPath
Write-TSxLog -Message ('{0} started' -f $scriptName)
Write-TSxLog -Message ('Log path: {0}' -f $LogPath)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Get-TSxWindowsUpdates'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1180, 760)
$form.MinimumSize = New-Object System.Drawing.Size(1000, 680)

$labelOS = New-Object System.Windows.Forms.Label
$labelOS.Location = New-Object System.Drawing.Point(12, 16)
$labelOS.Size = New-Object System.Drawing.Size(120, 20)
$labelOS.Text = 'Operating System'

$textOS = New-Object System.Windows.Forms.TextBox
$textOS.Location = New-Object System.Drawing.Point(138, 12)
$textOS.Size = New-Object System.Drawing.Size(320, 23)
$textOS.Text = 'Windows 11 24H2'

$labelArchitecture = New-Object System.Windows.Forms.Label
$labelArchitecture.Location = New-Object System.Drawing.Point(470, 16)
$labelArchitecture.Size = New-Object System.Drawing.Size(80, 20)
$labelArchitecture.Text = 'Architecture'

$comboArchitecture = New-Object System.Windows.Forms.ComboBox
$comboArchitecture.Location = New-Object System.Drawing.Point(556, 12)
$comboArchitecture.Size = New-Object System.Drawing.Size(110, 23)
$comboArchitecture.DropDownStyle = 'DropDownList'
[void]$comboArchitecture.Items.AddRange(@('x64', 'arm64', 'x86'))
$comboArchitecture.SelectedItem = Get-TSxDefaultArchitecture

$buttonSearch = New-Object System.Windows.Forms.Button
$buttonSearch.Location = New-Object System.Drawing.Point(678, 10)
$buttonSearch.Size = New-Object System.Drawing.Size(90, 27)
$buttonSearch.Text = 'Search'

$buttonSelectAll = New-Object System.Windows.Forms.Button
$buttonSelectAll.Location = New-Object System.Drawing.Point(780, 10)
$buttonSelectAll.Size = New-Object System.Drawing.Size(90, 27)
$buttonSelectAll.Text = 'Select All'

$buttonClearSelection = New-Object System.Windows.Forms.Button
$buttonClearSelection.Location = New-Object System.Drawing.Point(882, 10)
$buttonClearSelection.Size = New-Object System.Drawing.Size(90, 27)
$buttonClearSelection.Text = 'Clear'

$labelPath = New-Object System.Windows.Forms.Label
$labelPath.Location = New-Object System.Drawing.Point(12, 48)
$labelPath.Size = New-Object System.Drawing.Size(120, 20)
$labelPath.Text = 'Download Path'

$textPath = New-Object System.Windows.Forms.TextBox
$textPath.Location = New-Object System.Drawing.Point(138, 44)
$textPath.Size = New-Object System.Drawing.Size(630, 23)
$textPath.Text = (Join-Path -Path $env:TEMP -ChildPath 'TSxCatalogDownloads')

$buttonBrowse = New-Object System.Windows.Forms.Button
$buttonBrowse.Location = New-Object System.Drawing.Point(780, 42)
$buttonBrowse.Size = New-Object System.Drawing.Size(90, 27)
$buttonBrowse.Text = 'Browse...'

$checkWhatIf = New-Object System.Windows.Forms.CheckBox
$checkWhatIf.Location = New-Object System.Drawing.Point(882, 46)
$checkWhatIf.Size = New-Object System.Drawing.Size(120, 20)
$checkWhatIf.Text = 'WhatIf download'
$checkWhatIf.Checked = $true

$buttonDownload = New-Object System.Windows.Forms.Button
$buttonDownload.Location = New-Object System.Drawing.Point(1010, 42)
$buttonDownload.Size = New-Object System.Drawing.Size(140, 27)
$buttonDownload.Text = 'Download Selected'

$progressDownloads = New-Object System.Windows.Forms.ProgressBar
$progressDownloads.Location = New-Object System.Drawing.Point(12, 74)
$progressDownloads.Size = New-Object System.Drawing.Size(1138, 18)
$progressDownloads.Anchor = 'Top,Left,Right'
$progressDownloads.Style = 'Continuous'
$progressDownloads.Minimum = 0
$progressDownloads.Maximum = 100
$progressDownloads.Value = 0

$splitMain = New-Object System.Windows.Forms.SplitContainer
$splitMain.Location = New-Object System.Drawing.Point(12, 98)
$splitMain.Size = New-Object System.Drawing.Size(1138, 540)
$splitMain.Anchor = 'Top,Bottom,Left,Right'
$splitMain.Orientation = 'Horizontal'
$splitMain.SplitterDistance = 390

$gridUpdates = New-Object System.Windows.Forms.DataGridView
$gridUpdates.Dock = 'Fill'
$gridUpdates.AllowUserToAddRows = $false
$gridUpdates.AllowUserToDeleteRows = $false
$gridUpdates.ReadOnly = $false
$gridUpdates.SelectionMode = 'FullRowSelect'
$gridUpdates.MultiSelect = $true
$gridUpdates.AutoGenerateColumns = $false

$colSelect = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colSelect.Name = 'Select'
$colSelect.HeaderText = 'Select'
$colSelect.DataPropertyName = 'Select'
$colSelect.Width = 60

$colLastUpdated = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colLastUpdated.Name = 'LastUpdated'
$colLastUpdated.HeaderText = 'Last Updated'
$colLastUpdated.DataPropertyName = 'LastUpdated'
$colLastUpdated.Width = 100

$colKB = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colKB.Name = 'KB'
$colKB.HeaderText = 'KB'
$colKB.DataPropertyName = 'KB'
$colKB.Width = 100

$colTitle = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colTitle.Name = 'Title'
$colTitle.HeaderText = 'Title'
$colTitle.DataPropertyName = 'Title'
$colTitle.Width = 500

$colSize = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colSize.Name = 'Size'
$colSize.HeaderText = 'Size'
$colSize.DataPropertyName = 'Size'
$colSize.Width = 90

$colClassification = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colClassification.Name = 'Classification'
$colClassification.HeaderText = 'Classification'
$colClassification.DataPropertyName = 'Classification'
$colClassification.Width = 110

$colUpdateId = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colUpdateId.Name = 'UpdateId'
$colUpdateId.HeaderText = 'UpdateId'
$colUpdateId.DataPropertyName = 'UpdateId'
$colUpdateId.Width = 170

$colArchitecture = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colArchitecture.Name = 'Architecture'
$colArchitecture.HeaderText = 'Arch'
$colArchitecture.DataPropertyName = 'Architecture'
$colArchitecture.Width = 60

[void]$gridUpdates.Columns.Add($colSelect)
[void]$gridUpdates.Columns.Add($colLastUpdated)
[void]$gridUpdates.Columns.Add($colKB)
[void]$gridUpdates.Columns.Add($colTitle)
[void]$gridUpdates.Columns.Add($colSize)
[void]$gridUpdates.Columns.Add($colClassification)
[void]$gridUpdates.Columns.Add($colUpdateId)
[void]$gridUpdates.Columns.Add($colArchitecture)

$textOutput = New-Object System.Windows.Forms.RichTextBox
$textOutput.Dock = 'Fill'
$textOutput.ReadOnly = $true
$textOutput.WordWrap = $false
$textOutput.Font = New-Object System.Drawing.Font('Consolas', 9)
$script:OutputTextBox = $textOutput

[void]$splitMain.Panel1.Controls.Add($gridUpdates)
[void]$splitMain.Panel2.Controls.Add($textOutput)

$statusBar = New-Object System.Windows.Forms.StatusStrip
$statusBar.Dock = 'Bottom'
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = 'Ready'
[void]$statusBar.Items.Add($statusLabel)

[void]$form.Controls.Add($labelOS)
[void]$form.Controls.Add($textOS)
[void]$form.Controls.Add($labelArchitecture)
[void]$form.Controls.Add($comboArchitecture)
[void]$form.Controls.Add($buttonSearch)
[void]$form.Controls.Add($buttonSelectAll)
[void]$form.Controls.Add($buttonClearSelection)
[void]$form.Controls.Add($labelPath)
[void]$form.Controls.Add($textPath)
[void]$form.Controls.Add($buttonBrowse)
[void]$form.Controls.Add($checkWhatIf)
[void]$form.Controls.Add($buttonDownload)
[void]$form.Controls.Add($progressDownloads)
[void]$form.Controls.Add($splitMain)
[void]$form.Controls.Add($statusBar)

$bindingTable = New-Object System.Data.DataTable
[void]$bindingTable.Columns.Add('Select', [bool])
[void]$bindingTable.Columns.Add('LastUpdated', [string])
[void]$bindingTable.Columns.Add('KB', [string])
[void]$bindingTable.Columns.Add('Title', [string])
[void]$bindingTable.Columns.Add('Size', [string])
[void]$bindingTable.Columns.Add('Classification', [string])
[void]$bindingTable.Columns.Add('UpdateId', [string])
[void]$bindingTable.Columns.Add('Architecture', [string])

$gridUpdates.DataSource = $bindingTable

$buttonBrowse.Add_Click({
        $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderDialog.Description = 'Select download destination folder'
        $folderDialog.SelectedPath = $textPath.Text
        if ($folderDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $textPath.Text = $folderDialog.SelectedPath
        }
    })

$buttonSearch.Add_Click({
        try {
            $osText = $textOS.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($osText)) {
                [System.Windows.Forms.MessageBox]::Show('Operating System is required.', 'Validation', 'OK', 'Warning') | Out-Null
                return
            }

            $architecture = [string]$comboArchitecture.SelectedItem
            if ([string]::IsNullOrWhiteSpace($architecture)) {
                [System.Windows.Forms.MessageBox]::Show('Architecture is required.', 'Validation', 'OK', 'Warning') | Out-Null
                return
            }

            $statusLabel.Text = 'Searching updates...'
            [System.Windows.Forms.Application]::DoEvents()
            Write-TSxLog -Message ('Searching updates for {0} ({1})' -f $osText, $architecture)

            $searchOutput = @(& $listScriptPath -OperatingSystem $osText -Architecture $architecture -LogPath $LogPath -Verbose 4>&1)
            $updates = @()
            foreach ($outputItem in $searchOutput) {
                if ($outputItem -is [System.Management.Automation.VerboseRecord]) {
                    Write-TSxLog -Message $outputItem.Message
                }
                elseif ($outputItem -is [System.Management.Automation.WarningRecord]) {
                    Write-TSxLog -Level 'WARN' -Message $outputItem.Message
                }
                elseif ($outputItem -is [System.Management.Automation.ErrorRecord]) {
                    throw $outputItem.Exception
                }
                else {
                    $updates += $outputItem
                }
            }

            $bindingTable.Rows.Clear()
            foreach ($update in $updates) {
                $row = $bindingTable.NewRow()
                $row['Select'] = $false
                $row['LastUpdated'] = if ($update.LastUpdated) { ([datetime]$update.LastUpdated).ToString('yyyy-MM-dd') } else { '' }
                $row['KB'] = [string]$update.KB
                $row['Title'] = [string]$update.Title
                $row['Size'] = [string]$update.Size
                $row['Classification'] = [string]$update.Classification
                $row['UpdateId'] = [string]$update.UpdateId
                $row['Architecture'] = [string]$update.Architecture
                [void]$bindingTable.Rows.Add($row)
            }

            Write-TSxLog -Message ('Search returned {0} update(s)' -f $updates.Count)
            $statusLabel.Text = ('Found {0} updates' -f $updates.Count)
        }
        catch {
            Write-TSxLog -Level 'ERROR' -Message $_.Exception.Message
            $statusLabel.Text = 'Search failed'
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Search Failed', 'OK', 'Error') | Out-Null
        }
    })

$buttonSelectAll.Add_Click({
        foreach ($row in $bindingTable.Rows) {
            $row['Select'] = $true
        }
        $statusLabel.Text = 'All updates selected'
    })

$buttonClearSelection.Add_Click({
        foreach ($row in $bindingTable.Rows) {
            $row['Select'] = $false
        }
        $statusLabel.Text = 'Selection cleared'
    })

$buttonDownload.Add_Click({
        try {
            $downloadPath = $textPath.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($downloadPath)) {
                [System.Windows.Forms.MessageBox]::Show('Download path is required.', 'Validation', 'OK', 'Warning') | Out-Null
                return
            }

            $selectedRows = @($bindingTable.Rows | Where-Object { $_['Select'] -eq $true })
            if ($selectedRows.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show('Select at least one update to download.', 'Validation', 'OK', 'Warning') | Out-Null
                return
            }

            $selectedUpdates = @(
                foreach ($row in $selectedRows) {
                    if ([string]::IsNullOrWhiteSpace([string]$row['UpdateId'])) {
                        continue
                    }

                    [pscustomobject]@{
                        UpdateId     = [string]$row['UpdateId']
                        KB           = [string]$row['KB']
                        Architecture = [string]$row['Architecture']
                        Title        = [string]$row['Title']
                    }
                }
            )

            $selectedUpdateCount = @($selectedUpdates).Count
            if ($selectedUpdateCount -eq 0) {
                [System.Windows.Forms.MessageBox]::Show('No valid selected updates found (missing UpdateId).', 'Validation', 'OK', 'Warning') | Out-Null
                return
            }

            Write-TSxLog -Message ('Starting download for {0} selected update(s)' -f $selectedUpdateCount)
            $statusLabel.Text = ('Downloading {0} updates...' -f $selectedUpdateCount)
            $progressDownloads.Value = 0
            $progressDownloads.Maximum = $selectedUpdateCount
            [System.Windows.Forms.Application]::DoEvents()

            if ($PSCmdlet.ShouldProcess($downloadPath, ('Download {0} selected update(s)' -f $selectedUpdateCount))) {
                $downloadResults = @()
                $currentIndex = 0
                foreach ($selectedUpdate in $selectedUpdates) {
                    $currentIndex++
                    $statusLabel.Text = ('Downloading update {0} of {1}...' -f $currentIndex, $selectedUpdateCount)

                    $singleDownloadOutput = @($selectedUpdate | & $downloadScriptPath -Path $downloadPath -LogPath $LogPath -WhatIf:$checkWhatIf.Checked -Verbose 4>&1)
                    foreach ($outputItem in $singleDownloadOutput) {
                        if ($outputItem -is [System.Management.Automation.VerboseRecord]) {
                            Write-TSxLog -Message $outputItem.Message
                        }
                        elseif ($outputItem -is [System.Management.Automation.WarningRecord]) {
                            Write-TSxLog -Level 'WARN' -Message $outputItem.Message
                        }
                        elseif ($outputItem -is [System.Management.Automation.ErrorRecord]) {
                            throw $outputItem.Exception
                        }
                        else {
                            $downloadResults += $outputItem
                        }
                    }

                    $progressDownloads.Value = $currentIndex
                    [System.Windows.Forms.Application]::DoEvents()
                }

                Write-TSxLog -Message ('Download process returned {0} result(s)' -f $downloadResults.Count)
                $statusLabel.Text = ('Done. Processed {0} updates.' -f $downloadResults.Count)
                [System.Windows.Forms.MessageBox]::Show(('Processed {0} update(s).' -f $downloadResults.Count), 'Completed', 'OK', 'Information') | Out-Null
            }
        }
        catch {
            Write-TSxLog -Level 'ERROR' -Message $_.Exception.Message
            $statusLabel.Text = 'Download failed'
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Download Failed', 'OK', 'Error') | Out-Null
        }
        finally {
            if ($progressDownloads.Maximum -gt 0 -and $progressDownloads.Value -ge $progressDownloads.Maximum) {
                $statusLabel.Text = $statusLabel.Text
            }
        }
    })

[void]$form.ShowDialog()