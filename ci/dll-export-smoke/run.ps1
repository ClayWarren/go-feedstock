$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $IsWindows -or
    [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'Arm64' -or
    [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() -ne 'Arm64') {
    throw 'This diagnostic requires native Windows ARM64 and native PowerShell.'
}

$results = Join-Path $PSScriptRoot 'results'
New-Item -ItemType Directory -Path $results -ErrorAction Stop | Out-Null
Start-Transcript -Path (Join-Path $results 'transcript.txt') | Out-Null

function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    Write-Host ('COMMAND: ' + $Program + ' ' + ($Arguments -join ' '))
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}

function Assert-Arm64PE {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
        throw "Not a PE file: $Path"
    }
    $offset = [BitConverter]::ToInt32($bytes, 0x3c)
    if ($offset -lt 0 -or $offset + 6 -gt $bytes.Length -or
        [BitConverter]::ToUInt32($bytes, $offset) -ne 0x4550 -or
        [BitConverter]::ToUInt16($bytes, $offset + 4) -ne 0xaa64) {
        throw "Expected ARM64 PE machine AA64: $Path"
    }
    Write-Host "PASS PE machine AA64: $Path"
}

try {
    $compiler = (Get-Command clang.exe -CommandType Application).Source
    $dumpbin = (Get-Command dumpbin.exe -CommandType Application).Source
    $mslink = (Get-Command link.exe -CommandType Application).Source
    $lld = (Get-Command lld-link.exe -CommandType Application).Source
    Write-Host "Source revision: $env:GITHUB_SHA"
    Write-Host "Compiler: $compiler"
    Write-Host "Microsoft LINK: $mslink"
    Write-Host "LLD: $lld"
    Assert-Arm64PE $compiler
    Invoke-Checked $compiler @('--version')
    $target = (& $compiler -dumpmachine | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $target -notmatch '^aarch64.*windows-msvc') {
        throw "Unexpected compiler target: $target"
    }
    # Ordinary C source only. No Go source, generated directives, or binary edits.
    $common = @('-pthread', '-fno-caret-diagnostics', '-Qunused-arguments',
                '-fmessage-length=0', '-gno-record-gcc-switches')
    foreach ($linker in @('link', 'lld')) {
        $linkFlags = @()
        if ($linker -eq 'lld') { $linkFlags = @('-fuse-ld=lld') }
        foreach ($variant in @('plain', 'exported')) {
            $source = Join-Path $PSScriptRoot ($variant + '.c')
            $dll = Join-Path $results ($linker + '-' + $variant + '.dll')
            $arguments = $common + @('-shared', $source, '-o', $dll) + $linkFlags
            $driver = & $compiler @arguments '-###' 2>&1
            if ($LASTEXITCODE -ne 0) { throw 'Compiler driver inspection failed.' }
            $driver | Out-File (Join-Path $results ($linker + '-' + $variant + '-driver.txt'))
            $driver | ForEach-Object { Write-Host $_ }
            $driverText = $driver | Out-String
            if ($linker -eq 'lld' -and $driverText -notmatch 'lld-link') { throw 'LLD was not selected.' }
            if ($linker -eq 'link' -and ($driverText -match 'lld-link' -or $driverText -notmatch 'link.exe')) {
                throw 'Microsoft LINK was not selected.'
            }
            Invoke-Checked $compiler $arguments
            Assert-Arm64PE $dll
            $exports = & $dumpbin /exports $dll
            if ($LASTEXITCODE -ne 0) { throw 'Export inspection failed.' }
            $exports | Out-File (Join-Path $results ($linker + '-' + $variant + '-exports.txt'))
            $exports | ForEach-Object { Write-Host $_ }
            $exportText = $exports | Out-String
            foreach ($symbol in @('demo_value', 'demo_answer')) {
                $present = $exportText -match ('\b' + $symbol + '\b')
                if ($present -ne ($variant -eq 'exported')) { throw "Unexpected visibility of $symbol in $dll" }
            }
        }
        $consumer = Join-Path $results ($linker + '-consumer.exe')
        Invoke-Checked $compiler ($common + @((Join-Path $PSScriptRoot 'consumer.c'), '-o', $consumer) + $linkFlags)
        Assert-Arm64PE $consumer
        Invoke-Checked $consumer @((Join-Path $results ($linker + '-plain.dll')),
                                   (Join-Path $results ($linker + '-exported.dll')))
    }
    'PASS: native ARM64 DLL export controls passed for Microsoft LINK and LLD.' |
        Tee-Object -FilePath (Join-Path $results 'result.txt')
} finally {
    Stop-Transcript | Out-Null
}
