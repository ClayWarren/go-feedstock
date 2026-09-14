# Fork-only diagnostic. Keep the exact binaries for inspection after a failure.
param([string] $DiagnosticDir = 'C:\go-cgo-diagnostics')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}
New-Item -ItemType Directory -Force -Path $DiagnosticDir | Out-Null
$go = (Get-Command go -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
& $go env GOOS GOARCH CC CGO_CFLAGS CGO_LDFLAGS |
    Set-Content (Join-Path $DiagnosticDir 'compiler-environment.txt')
$result = 0
foreach ($mode in @('auto', 'external', 'internal')) {
    $exe = Join-Path $DiagnosticDir "cgotest-$mode-pie.exe"
    $buildArgs = @('test', '-c', '-buildmode=pie', '-o', $exe)
    if ($mode -ne 'auto') { $buildArgs += "-ldflags=-linkmode=$mode" }
    if ($mode -eq 'internal') { $buildArgs += '-tags=internal,internal_pie' }
    $buildArgs += 'cmd/cgo/internal/test'
    $ErrorActionPreference = 'Continue'
    & $go @buildArgs 2>&1 | Tee-Object (Join-Path $DiagnosticDir "build-$mode.log") | Out-Host
    $status = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($status -ne 0) { $result = $status; continue }
    & $go tool nm $exe | Set-Content (Join-Path $DiagnosticDir "symbols-$mode.txt")
    foreach ($run in @('isolated', 'suite')) {
        $testArgs = @('-test.v', '-test.count=1')
        if ($run -eq 'isolated') { $testArgs = @('-test.v', '-test.count=20', '-test.run=^TestGCC68255$') }
        $ErrorActionPreference = 'Continue'
        & $exe @testArgs 2>&1 | Tee-Object (Join-Path $DiagnosticDir "$mode-$run.log") | Out-Host
        $status = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($status -ne 0) { $result = $status }
    }
}
exit $result
