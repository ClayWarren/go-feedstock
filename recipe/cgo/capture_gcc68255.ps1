# Personal-fork diagnosis only, not package acceptance or an upstream patch.
[CmdletBinding()]
param([string]$EvidenceRoot = 'C:\bld\go-gcc68255-evidence')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT' -or $env:target_platform -ne 'win-arm64') {
    throw 'This diagnostic requires the native Windows ARM64 package test environment.'
}
New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
$results = [Collections.Generic.List[object]]::new()
$failed = $false
$savedTmp = $env:GOTMPDIR
function Invoke-Captured([string]$Executable, [string[]]$Arguments, [string]$Log) {
    # Windows PowerShell 5.1 can wrap redirected native stderr in error
    # records. Go -x intentionally writes stderr; use the process exit code.
    $ErrorActionPreference = 'Continue'
    & $Executable @Arguments *> $Log
    return $LASTEXITCODE
}
$goRoot = (& go env GOROOT).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve GOROOT' }
Push-Location (Join-Path $goRoot 'src/cmd/cgo/internal/test')
try {
    & go env GOHOSTOS GOHOSTARCH GOOS GOARCH CGO_ENABLED CC CGO_CFLAGS CGO_LDFLAGS |
        Out-File (Join-Path $EvidenceRoot 'toolchain.txt') -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw 'go env failed' }
    & clang.exe --version | Out-File (Join-Path $EvidenceRoot 'clang.txt') -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw 'clang version failed' }
    $dumpbin = Get-ChildItem 'C:\Program Files\Microsoft Visual Studio' -Filter dumpbin.exe -Recurse |
        Where-Object { $_.FullName -match 'Hostarm64\\arm64\\dumpbin.exe$' } | Select-Object -First 1
    if ($null -eq $dumpbin) { throw 'Native ARM64 dumpbin missing' }
    foreach ($build in 1..3) {
        foreach ($variant in @('external', 'external-s')) {
            $dir = Join-Path $EvidenceRoot "$variant-$build"
            New-Item -ItemType Directory -Path $dir | Out-Null
            $env:GOTMPDIR = Join-Path $dir 'work'
            New-Item -ItemType Directory -Path $env:GOTMPDIR | Out-Null
            $linktmp = Join-Path $dir 'link'
            New-Item -ItemType Directory -Path $linktmp | Out-Null
            $exe = Join-Path $dir 'test.exe'
            $flags = "-linkmode=external -v -tmpdir=$linktmp"
            if ($variant -eq 'external-s') { $flags += ' -s' }
            # Preserve the real test package, generated C, host objects and link
            # inputs. Do not change C flags, fixture source, or assertions.
            $status = Invoke-Captured 'go' @('test', '-c', '-x', '-work', "-ldflags=$flags", '-o', $exe, 'cmd/cgo/internal/test') (Join-Path $dir 'build.log')
            $results.Add([pscustomobject]@{ variant=$variant; build=$build; phase='build'; run=0; status=$status })
            if ($status -ne 0) { $failed = $true; continue }
            $bytes = [IO.File]::ReadAllBytes($exe)
            $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
            if ([BitConverter]::ToUInt16($bytes, $peOffset + 4) -ne 0xaa64) { throw 'Non-ARM64 test executable' }
            $status = Invoke-Captured $dumpbin.FullName @('/headers', '/relocations', $exe) (Join-Path $dir 'exe.dumpbin.txt')
            if ($status -ne 0) { throw 'dumpbin failed' }
            $status = Invoke-Captured $exe @('-test.list', '^TestGCC68255$') (Join-Path $dir 'inventory.txt')
            if ($status -ne 0 -or @(Get-Content (Join-Path $dir 'inventory.txt')) -cnotcontains 'TestGCC68255') {
                throw 'Missing TestGCC68255; refuse a false-green filtered run'
            }
            foreach ($run in 1..10) {
                $status = Invoke-Captured $exe @('-test.run', '^TestGCC68255$', '-test.v', '-test.count=1', '-test.timeout=1m') (Join-Path $dir "focused-$run.log")
                $results.Add([pscustomobject]@{ variant=$variant; build=$build; phase='focused'; run=$run; status=$status })
                if ($status -ne 0) { $failed = $true }
            }
            # Also test ordering/interference from the other tests in this
            # package, in a fresh process using the exact same executable.
            $status = Invoke-Captured $exe @('-test.v', '-test.count=1', '-test.timeout=5m') (Join-Path $dir 'package.log')
            $results.Add([pscustomobject]@{ variant=$variant; build=$build; phase='package'; run=1; status=$status })
            if ($status -ne 0) { $failed = $true }
            Get-FileHash -Algorithm SHA256 $exe | Format-List |
                Out-File (Join-Path $dir 'sha256.txt') -Encoding utf8
            $results | ConvertTo-Json | Out-File (Join-Path $EvidenceRoot 'results.json') -Encoding utf8
        }
    }
} finally {
    Pop-Location
    $env:GOTMPDIR = $savedTmp
    $results | ConvertTo-Json | Out-File (Join-Path $EvidenceRoot 'results.json') -Encoding utf8
    $results | Format-Table -AutoSize
}
if ($failed) { exit 1 }
Write-Host 'Focused reproduction passed; this is NOT full package acceptance.'
