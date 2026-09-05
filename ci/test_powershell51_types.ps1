# Portable check for the native guards' PowerShell 5.1-compatible integer types.
# Syntax-only compatibility checks do not resolve type accelerator names.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-ArchitectureIntegerTypes {
    param([string] $Source)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Source, [ref] $tokens, [ref] $errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $types = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.TypeConstraintAst]
    }, $true) | ForEach-Object { $_.TypeName.FullName })
    # ushort in the embedded C# P/Invoke declaration is valid. Inspect only
    # PowerShell type nodes, not strings containing C# source.
    if ($types -contains 'ushort') {
        throw '[ushort] is not available in Windows PowerShell 5.1; use [System.UInt16].'
    }
    if (@($types | Where-Object { $_ -ceq 'System.UInt16' }).Count -ne 2) {
        throw 'Both architecture guard variables must use explicit System.UInt16 types.'
    }
}

$oldSource = '[ushort] $processMachine = 0; [ushort] $nativeMachine = 0'
$rejected = $false
try { Assert-ArchitectureIntegerTypes $oldSource } catch { $rejected = $true }
if (-not $rejected) { throw 'The old unsupported type aliases were not rejected.' }

foreach ($relativePath in @('test_native_trust_lifecycle.ps1', '../recipe/windows/run_dist_tests.ps1')) {
    $path = Join-Path $PSScriptRoot $relativePath
    Assert-ArchitectureIntegerTypes ([IO.File]::ReadAllText($path))
    Write-Host "PASS PowerShell 5.1 architecture types: $relativePath"
}
Write-Host 'PASS unsupported-alias regression; no Windows API or certificate operation executed.'
