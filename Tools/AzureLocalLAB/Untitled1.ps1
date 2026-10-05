$builderPath; Get-Item -LiteralPath $builderPath | Select-Object FullName, LastWriteTime; Select-String -LiteralPath $builderPath -Pattern 'BREAK', 'Checking prerequisites', 'Preview complete'

Select-String -LiteralPath $builderPath -Pattern 'break|return|exit|Write-Host|ShouldProcess'; & $builderPath @threeNodeLab -WhatIf -Verbose -ErrorAction Stop; Write-Host 'Invocation returned'

Write-Host 'Querying Hyper-V...'; Get-VM -ErrorAction Stop | Select-Object Name, State; Write-Host 'Hyper-V query completed'
