# Native no-CGo evidence for the FIPS internal-PIE dist registration.
# Go 1.27 cmd/dist/testjson.go appends ":pie_internal" to Package.
# Keep this focused proof separate from the unchanged authoritative dist suite.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-NoCgoFipsInventory {
    param([string[]] $Names)
    foreach ($name in @(
        'crypto/internal/fips140test:pie_internal',
        'reflect:pie_internal',
        'crypto/...:purego',
        'crypto/...:gofips140'
    )) {
        if ($Names -cnotcontains $name) { throw "Missing no-CGo dist test: $name" }
    }
    foreach ($name in @(
        'crypto/internal/fips140test:exe_external',
        'crypto/internal/fips140test:pie_external'
    )) {
        if ($Names -ccontains $name) { throw "Unexpected no-CGo dist test: $name" }
    }
}

function Assert-FipsIntegrityEvidence {
    param([string[]] $Lines, [int] $ExitCode)
    if ($ExitCode -ne 0) { throw "FIPS internal-PIE dist command exited with $ExitCode." }
    $expectedPackage = 'crypto/internal/fips140test:pie_internal'
    $expectedTest = 'TestIntegrityCheck'
    $runs = 0
    $passes = 0
    $packagePasses = 0
    $verified = $false
    foreach ($line in $Lines) {
        # dist may preserve non-JSON build diagnostics. They are retained in
        # the logs but cannot establish test execution or verification.
        if (-not $line.TrimStart().StartsWith('{')) { continue }
        try { $testEvent = $line | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "Malformed JSON in FIPS dist output: $line" }
        if ($null -eq $testEvent.PSObject.Properties['Package'] -or
            $testEvent.Package -cne $expectedPackage) { continue }
        if ($null -eq $testEvent.PSObject.Properties['Action']) {
            throw 'FIPS dist event has no Action.'
        }
        $action = [string] $testEvent.Action
        if ($action -ceq 'skip' -or $action -ceq 'fail') {
            throw "FIPS dist reported $action instead of executing a successful integrity check."
        }
        $test = ''
        if ($null -ne $testEvent.PSObject.Properties['Test']) { $test = [string] $testEvent.Test }
        if ($test -ne '' -and $test -cne $expectedTest) {
            throw "Unexpected test in the anchored FIPS dist variant: $test"
        }
        if ($test -ceq $expectedTest) {
            if ($action -ceq 'run') {
                $runs++
                if ($runs -ne 1 -or $passes -ne 0) { throw 'Unexpected integrity-test run ordering.' }
            } elseif ($action -ceq 'pass') {
                $passes++
                if ($runs -ne 1 -or $passes -ne 1 -or -not $verified) {
                    throw 'Integrity test passed without an earlier run and verified message.'
                }
            } elseif ($action -ceq 'output' -and $null -ne $testEvent.PSObject.Properties['Output']) {
                # TestIntegrityCheck logs this only when check.Verified is true.
                # It can appear in the logged fips140=on subprocess output.
                if ([string] $testEvent.Output -cmatch '(?m)^\s*check_test\.go:\d+:\s+verified\s*$') {
                    if ($runs -ne 1 -or $passes -ne 0) { throw 'Verified message is outside the integrity test run.' }
                    $verified = $true
                }
            }
        } elseif ($action -ceq 'pass') {
            $packagePasses++
            if ($passes -ne 1) { throw 'FIPS package passed before the integrity test.' }
        }
    }
    if ($runs -ne 1 -or $passes -ne 1 -or $packagePasses -ne 1 -or -not $verified) {
        throw 'Missing TestIntegrityCheck run/pass, verified output, or FIPS package pass evidence.'
    }
}

function Invoke-FipsIntegrityDist {
    param([string] $GoExecutable)
    $stdoutPath = Join-Path (Get-Location).Path 'fips_integrity.stdout.jsonl'
    $stderrPath = Join-Path (Get-Location).Path 'fips_integrity.stderr.log'
    $stdoutLog = $null
    $stderrLog = $null
    $process = [Diagnostics.Process]::new()
    $lines = [Collections.Generic.List[string]]::new()
    try {
        $encoding = [Text.UTF8Encoding]::new($false)
        $stdoutLog = [IO.StreamWriter]::new($stdoutPath, $false, $encoding)
        $stderrLog = [IO.StreamWriter]::new($stderrPath, $false, $encoding)
        $stdoutLog.AutoFlush = $true
        $stderrLog.AutoFlush = $true
        $process.StartInfo.FileName = $GoExecutable
        $process.StartInfo.Arguments = 'tool dist test -json -no-rebuild crypto/internal/fips140test:pie_internal'
        $process.StartInfo.WorkingDirectory = (Get-Location).Path
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        $process.StartInfo.CreateNoWindow = $true
        Write-Host ('Running: ' + $GoExecutable + ' ' + $process.StartInfo.Arguments)
        if (-not $process.Start()) { throw 'Could not start the FIPS dist command.' }
        # Drain both streams concurrently without PowerShell background event
        # callbacks or native-stderr ErrorRecord semantics (PowerShell 5.1).
        $stdoutRead = $process.StandardOutput.ReadLineAsync()
        $stderrRead = $process.StandardError.ReadLineAsync()
        while ($null -ne $stdoutRead -or $null -ne $stderrRead) {
            $pending = [Collections.Generic.List[Threading.Tasks.Task]]::new()
            if ($null -ne $stdoutRead) { $pending.Add($stdoutRead) }
            if ($null -ne $stderrRead) { $pending.Add($stderrRead) }
            [void] [Threading.Tasks.Task]::WaitAny($pending.ToArray())
            if ($null -ne $stdoutRead -and $stdoutRead.IsCompleted) {
                $line = $stdoutRead.GetAwaiter().GetResult()
                if ($null -eq $line) { $stdoutRead = $null }
                else {
                    $stdoutLog.WriteLine($line)
                    $lines.Add($line)
                    Write-Host $line
                    $stdoutRead = $process.StandardOutput.ReadLineAsync()
                }
            }
            if ($null -ne $stderrRead -and $stderrRead.IsCompleted) {
                $line = $stderrRead.GetAwaiter().GetResult()
                if ($null -eq $line) { $stderrRead = $null }
                else {
                    $stderrLog.WriteLine($line)
                    Write-Host $line
                    $stderrRead = $process.StandardError.ReadLineAsync()
                }
            }
        }
        $process.WaitForExit()
        Assert-FipsIntegrityEvidence -Lines $lines.ToArray() -ExitCode $process.ExitCode
    } finally {
        if ($null -ne $stdoutLog) { $stdoutLog.Dispose() }
        if ($null -ne $stderrLog) { $stderrLog.Dispose() }
        $process.Dispose()
    }
    Write-Host 'Native no-CGo FIPS internal-PIE evidence passed: TestIntegrityCheck ran, verified, and passed.'
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'FIPS native evidence requires Windows ARM64.'
    }
    if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
        $PSNativeCommandUseErrorActionPreference = $false
    }
    $goExecutable = (Get-Command go -CommandType Application -ErrorAction Stop).Source
    $goEnvironment = @(& $goExecutable env GOHOSTOS GOHOSTARCH GOOS GOARCH CGO_ENABLED)
    if ($LASTEXITCODE -ne 0 -or $goEnvironment.Count -ne 5 -or
        $goEnvironment[0] -cne 'windows' -or $goEnvironment[1] -cne 'arm64' -or
        $goEnvironment[2] -cne 'windows' -or $goEnvironment[3] -cne 'arm64' -or
        $goEnvironment[4] -cne '0') {
        throw 'FIPS evidence requires a windows/arm64 Go host and target with CGO_ENABLED=0.'
    }
    Assert-NoCgoFipsInventory -Names @(Get-Content -LiteralPath 'dist_tests.txt')
    Invoke-FipsIntegrityDist -GoExecutable $goExecutable
} catch {
    Write-Error -ErrorAction Continue $_
    exit 1
}
exit 0
