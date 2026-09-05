# Exercise the actual Windows PowerShell 5.1 C# compiler, without opening stores.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
    $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
    throw 'This regression requires Windows PowerShell 5.1.'
}
$helper = Join-Path $PSScriptRoot '../recipe/windows/run_dist_tests.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($helper, [ref] $tokens, [ref] $errors)
if ($errors.Count) { throw ($errors | Out-String) }
$definition = @($ast.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq 'Initialize-GoWindowsApi'
})
if ($definition.Count -ne 1) { throw 'Expected one isolated native-API initializer.' }
. ([scriptblock]::Create($definition[0].Extent.Text))

$savedLibraryPath = [Environment]::GetEnvironmentVariable('LIB', 'Process')
$missingPath = Join-Path $env:RUNNER_TEMP ('go-lib-missing-' + [guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $missingPath) { throw 'The regression path must not exist.' }
try {
    [Environment]::SetEnvironmentVariable('LIB', $missingPath, 'Process')
    Initialize-GoWindowsApi
    if ([Environment]::GetEnvironmentVariable('LIB', 'Process') -cne $missingPath) {
        throw 'Native API compilation did not restore the inherited LIB value.'
    }
    if ([GoFeedstockTemporaryTrust].GetMethods().Name -notcontains 'IsWow64Process2') {
        throw 'The native API declarations did not compile.'
    }
    Write-Host 'PASS Windows PowerShell 5.1 API compilation with nonexistent inherited LIB; exact LIB restored.'
    Write-Host 'No certificate stores opened or native API methods invoked.'
} finally {
    [Environment]::SetEnvironmentVariable('LIB', $savedLibraryPath, 'Process')
}
