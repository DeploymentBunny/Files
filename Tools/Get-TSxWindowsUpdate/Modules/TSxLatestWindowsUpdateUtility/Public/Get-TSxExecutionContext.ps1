function Get-TSxExecutionContext {
    [CmdletBinding()]
    param()

    # UI wrapper jobs stamp this environment variable before invoking list/download scripts.
    if ($env:TSX_EXECUTION_CONTEXT -eq 'Wrapper') {
        return 'Wrapper'
    }

    if ($Host.Name -match 'ISE') {
        return 'ISE'
    }

    return 'CommandLine'
}
