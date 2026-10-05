<#
.SYNOPSIS
    Re-registers MOF files in the Windows WMI repository folder.

.DESCRIPTION
    Finds all .mof files in C:\Windows\System32\Wbem whose file names do not
    contain "uninstall", then runs mofcomp.exe once for each file.

.PARAMETER WbemPath
    Folder containing the MOF files. Defaults to the system Wbem folder.

.NOTES
    FileName:  Invoke-TSxReRegisterMOF.ps1
    Version:   1.0.0
    Author:    Mikael Nystrom
    Contact:   deploymentbunny@outlook.com
    Created:   2026-09-23
    Updated:   2026-09-23
    Twitter:   https://twitter.com/deploymentbunny
    Disclaimer: Use at your own risk. Test before production use.

.LINK
    https://www.deploymentbunny.com
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$WbemPath = (Join-Path $env:WINDIR 'System32\Wbem')
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )

    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 's'), $Level.ToUpper(), $Message
    if ($Level -eq 'Error') {
        Write-Error $line
    } elseif ($Level -eq 'Warning') {
        Write-Warning $line
    } else {
        Write-Verbose $line
    }
}

try {
    if (-not (Test-Path -LiteralPath $WbemPath -PathType Container)) {
        throw "Wbem folder was not found: $WbemPath"
    }

    $mofComp = Join-Path $WbemPath 'mofcomp.exe'
    if (-not (Test-Path -LiteralPath $mofComp -PathType Leaf)) {
        throw "mofcomp.exe was not found: $mofComp"
    }

    $mofFiles = @(Get-ChildItem -LiteralPath $WbemPath -Filter '*.mof' -File -ErrorAction Stop |
        Where-Object { $_.Name -notmatch 'uninstall' } |
        Sort-Object Name)

    if ($mofFiles.Count -eq 0) {
        Write-Log -Message "No eligible MOF files found in $WbemPath." -Level Warning
        return
    }

    Write-Log -Message ("Found {0} eligible MOF file(s) in {1}." -f $mofFiles.Count, $WbemPath)

    $failed = @()
    foreach ($mofFile in $mofFiles) {
        $description = "Compile MOF file $($mofFile.FullName)"
        if ($PSCmdlet.ShouldProcess($mofFile.FullName, 'Run mofcomp.exe')) {
            Write-Log -Message $description
            & $mofComp $mofFile.FullName
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) {
                $failed += $mofFile.FullName
                Write-Log -Message ("mofcomp.exe failed for {0} with exit code {1}." -f $mofFile.Name, $exitCode) -Level Warning
            } else {
                Write-Log -Message ("mofcomp.exe completed successfully for {0}." -f $mofFile.Name)
            }
        }
    }

    if ($failed.Count -gt 0) {
        Write-Log -Message ("MOF registration completed with {0} failure(s)." -f $failed.Count) -Level Warning
    } else {
        Write-Log -Message 'MOF registration completed successfully.'
    }
} catch {
    Write-Log -Message $_.Exception.Message -Level Error
}
