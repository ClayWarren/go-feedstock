$ErrorActionPreference = 'Stop'
$results = [ordered]@{}
function Probe([string]$Name, [string[]]$GoArgs) {
    Write-Host "BEGIN_PROBE=$Name"
    & go @GoArgs
    $code = $LASTEXITCODE
    $script:results[$Name] = $code
    Write-Host "END_PROBE=$Name EXIT=$code"
}
$arch = & go env GOHOSTARCH
if ($LASTEXITCODE -ne 0 -or $arch -ne 'arm64') { throw 'Expected native ARM64 Go' }
where.exe go
where.exe git
Write-Host "SSL_CERT_FILE=$env:SSL_CERT_FILE SSL_CERT_DIR=$env:SSL_CERT_DIR"
$certArgs = @('test','-count=1','-v','-run=^Test(Go|System)Verify$/^SHA-384$','crypto/x509')
$vcsArgs = @('test','-count=1','-timeout=5m','-v','cmd/go/internal/modfetch/codehost','cmd/go/internal/vcweb')
Probe 'certificate-inherited' $certArgs
Probe 'vcs-inherited' $vcsArgs
$oldFile = $env:SSL_CERT_FILE
$oldDir = $env:SSL_CERT_DIR
$oldPath = $env:PATH
try {
    Remove-Item Env:SSL_CERT_FILE, Env:SSL_CERT_DIR -ErrorAction SilentlyContinue
    Probe 'certificate-system-store' $certArgs
    # No certificate store mutations. Only test-process environment isolation.
    $env:PATH = "$env:ProgramFiles\Git\bin;$oldPath"
    if (-not (Test-Path "$env:ProgramFiles\Git\bin\git.exe")) { throw 'Native Git missing' }
    where.exe git
    git version --build-options
    Probe 'vcs-native-git' $vcsArgs
    $names = & go tool dist test -list
    if ($LASTEXITCODE -ne 0) { throw 'Cannot list dist tests' }
    foreach ($name in @('os','cmd/go','cmd/gofmt')) {
        if ($names -notcontains $name) { throw "Missing dist test $name" }
    }
    Write-Host 'DIST_SELECTION_NAMES_VERIFIED=os,cmd/go,cmd/gofmt'
    if ((& go env CGO_ENABLED) -eq '1') {
        Probe 'cgo-badsymbol' @('test','-count=1','-timeout=5m','-v','-run=^TestBadSymbol$','cmd/cgo/internal/testerrors')
        Probe 'cgo-srcimporter' @('test','-count=1','-timeout=5m','-v','-run=^TestCgo$','go/internal/srcimporter')
        Probe 'cgo-shared-fixtures' @('test','-count=1','-timeout=5m','-v','-run=^Test(SO|SOVar)$','cmd/cgo/internal/testso')
    }
} finally {
    $env:SSL_CERT_FILE = $oldFile
    $env:SSL_CERT_DIR = $oldDir
    $env:PATH = $oldPath
    Write-Host ('PROBE_RESULTS=' + ($results | ConvertTo-Json -Compress))
}
# This is a fork-only diagnostic. A success is not a full Go suite result.
if ($results['certificate-system-store'] -ne 0 -or $results['vcs-native-git'] -ne 0) { exit 1 }
exit 0
