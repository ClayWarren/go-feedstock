# Portable parser/inventory tests. Never execute the native entry point or Go.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$tokens = $null
$parseErrors = $null
$path = Join-Path $PSScriptRoot 'verify_fips_integrity.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref] $tokens, [ref] $parseErrors)
if ($parseErrors.Count -ne 0) { throw ($parseErrors | Out-String) }
foreach ($name in @('Assert-NoCgoFipsInventory', 'Assert-FipsIntegrityEvidence')) {
    $functions = @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $false) | Where-Object { $_.Name -ceq $name })
    if ($functions.Count -ne 1) { throw "Expected exactly one function $name." }
    Invoke-Expression $functions[0].Extent.Text
}

$script:checks = 0
function Assert-Rejected {
    param([string] $CaseLabel, [scriptblock] $Check)
    $rejected = $false
    try { & $Check } catch { $rejected = $true }
    if (-not $rejected) { throw "Negative case unexpectedly passed: $CaseLabel" }
    $script:checks++
}

$inventory = @('crypto/internal/fips140test:pie_internal', 'reflect:pie_internal',
    'crypto/...:purego', 'crypto/...:gofips140')
Assert-NoCgoFipsInventory $inventory
$script:checks++
foreach ($name in $inventory) {
    Assert-Rejected "missing $name" { Assert-NoCgoFipsInventory @($inventory | Where-Object { $_ -cne $name }) }
}
foreach ($variant in @('exe_external', 'pie_external')) {
    Assert-Rejected "unexpected $variant" {
        Assert-NoCgoFipsInventory ($inventory + "crypto/internal/fips140test:$variant")
    }
}

$package = 'crypto/internal/fips140test:pie_internal'
$good = @(
    'non-JSON build diagnostic',
    (@{ Action='start'; Package=$package } | ConvertTo-Json -Compress),
    (@{ Action='run'; Package=$package; Test='TestIntegrityCheck' } | ConvertTo-Json -Compress),
    (@{ Action='output'; Package=$package; Test='TestIntegrityCheck';
        Output="    check_test.go:33: running with GODEBUG=fips140=on:`n        check_test.go:26: verified`n" } | ConvertTo-Json -Compress),
    (@{ Action='pass'; Package=$package; Test='TestIntegrityCheck'; Elapsed=0.01 } | ConvertTo-Json -Compress),
    (@{ Action='pass'; Package=$package; Elapsed=0.02 } | ConvertTo-Json -Compress)
)
Assert-FipsIntegrityEvidence $good 0
$script:checks++
Assert-Rejected 'nonzero exit' { Assert-FipsIntegrityEvidence $good 1 }
Assert-Rejected 'empty output' { Assert-FipsIntegrityEvidence @() 0 }
Assert-Rejected 'missing run' { Assert-FipsIntegrityEvidence @($good[0..1] + $good[3..5]) 0 }
Assert-Rejected 'missing test pass' { Assert-FipsIntegrityEvidence @($good[0..3] + $good[5]) 0 }
Assert-Rejected 'missing package pass' { Assert-FipsIntegrityEvidence $good[0..4] 0 }
Assert-Rejected 'missing verified' { Assert-FipsIntegrityEvidence @($good[0..2] + $good[4..5]) 0 }
Assert-Rejected 'not verified' { Assert-FipsIntegrityEvidence @($good -replace ': verified', ': not verified') 0 }
Assert-Rejected 'wrong package' { Assert-FipsIntegrityEvidence @($good -replace ':pie_internal', ':exe_external') 0 }
Assert-Rejected 'unrewritten package' { Assert-FipsIntegrityEvidence @($good -replace ':pie_internal', '') 0 }
Assert-Rejected 'wrong test' { Assert-FipsIntegrityEvidence @($good -replace 'TestIntegrityCheck', 'TestIntegrityCheckFailure') 0 }
Assert-Rejected 'malformed JSON' { Assert-FipsIntegrityEvidence @($good + '{broken') 0 }
Assert-Rejected 'verified before run' { Assert-FipsIntegrityEvidence @($good[0..1] + $good[3] + $good[2] + $good[4..5]) 0 }
foreach ($action in @('skip', 'fail')) {
    foreach ($test in @('', 'TestIntegrityCheck')) {
        $bad = @{ Action=$action; Package=$package }
        if ($test -ne '') { $bad.Test = $test }
        Assert-Rejected "$action $test" { Assert-FipsIntegrityEvidence @($good + ($bad | ConvertTo-Json -Compress)) 0 }
    }
}
Write-Host "FIPS evidence parser/inventory self-tests passed: $script:checks checks. No Go command or certificate operation executed."
