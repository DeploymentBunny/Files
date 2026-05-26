function Get-TSxDefaultArchitecture {
    [CmdletBinding()]
    param()

    switch -Regex ($env:PROCESSOR_ARCHITECTURE) {
        'ARM64' { return 'arm64' }
        '64' { return 'x64' }
        default { return 'x86' }
    }
}
