function Add-TSxUiOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('INFO', 'WARN', 'ERROR', 'VERBOSE')]
        [string]$Level = 'INFO',

        [Parameter()]
        [object]$OutputTextBox
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return
    }

    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    if ($OutputTextBox -and -not $OutputTextBox.IsDisposed) {
        $OutputTextBox.AppendText($line + [Environment]::NewLine)
        $OutputTextBox.SelectionStart = $OutputTextBox.TextLength
        $OutputTextBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
}
