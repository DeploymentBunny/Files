$samplePath = Join-Path $PSScriptRoot 'Sample.ps1'
$sampleText = Get-Content -LiteralPath $samplePath -Raw
$setupStart = $sampleText.IndexOf('$sampleRoot =')
$setupEnd = $sampleText.IndexOf('# Single node:')
$setupText = $sampleText.Substring($setupStart, $setupEnd - $setupStart)
$resolveBuilder = [scriptblock]::Create(('param($PSScriptRoot, $psISE)' + [Environment]::NewLine + $setupText + [Environment]::NewLine + '$builderPath'))

Describe 'Sample script path resolution' {
    It 'blocks whole-file execution before reaching the setup and examples' {
        $tokens = $null
        $parseErrors = $null
        $sampleAst = [System.Management.Automation.Language.Parser]::ParseFile($samplePath, [ref]$tokens, [ref]$parseErrors)
        $parseErrors.Count | Should Be 0
        $breakStatements = @($sampleAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.BreakStatementAst]
        }, $true))
        $breakStatements.Count | Should Be 1
        ($breakStatements[0].Extent.StartOffset -lt $setupStart) | Should Be $true
    }

    It 'resolves the builder beside a normally executed saved script' {
        & $resolveBuilder -PSScriptRoot $PSScriptRoot | Should Be (Join-Path $PSScriptRoot 'New-TsxAzureLab.ps1')
    }

    It 'resolves the builder from the saved ISE editor file for selection execution' {
        $editor = [pscustomobject]@{
            CurrentFile = [pscustomobject]@{ FullPath = $samplePath }
        }
        & $resolveBuilder -PSScriptRoot '' -psISE $editor | Should Be (Join-Path $PSScriptRoot 'New-TsxAzureLab.ps1')
    }

    It 'rejects an unsaved ISE editor file with an actionable error' {
        $editor = [pscustomobject]@{
            CurrentFile = [pscustomobject]@{ FullPath = 'Untitled1.ps1' }
        }
        { & $resolveBuilder -PSScriptRoot '' -psISE $editor } | Should Throw 'Save Sample.ps1'
    }

    It 'rejects a missing builder instead of using the working directory' {
        { & $resolveBuilder -PSScriptRoot $TestDrive } | Should Throw 'Lab builder not found'
    }
}
