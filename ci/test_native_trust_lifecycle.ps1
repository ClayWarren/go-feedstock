# Native Windows PowerShell 5.1 integration check; never run on a workstation.
# Requires a disposable GitHub-hosted ARM64 runner and explicit opt-in.
param(
    [Parameter(Mandatory = $true)] [string] $HelperPath,
    [Parameter(Mandatory = $true)] [string] $GoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($MyInvocation.InvocationName -eq '.') { throw 'Run this test with -File; do not dot-source it.' }
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Native Windows is required; no certificate stores were opened.'
}
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1 -or
    $PSVersionTable.PSEdition -cne 'Desktop') {
    throw 'This integration check requires Windows PowerShell 5.1.'
}
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
    $env:GO_TEST_ALLOW_TEMPORARY_USER_ROOT -cne '1') {
    throw 'An explicitly opted-in disposable GitHub-hosted runner is required.'
}

# The production helper has no dot-source guard: loading the whole file would
# execute its full suite and exit. Dot-source ONLY its trusted function ASTs,
# just as its portable self-test does; never execute its top-level statements.
$tokens = $null
$parseErrors = $null
$helperAst = [Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path -LiteralPath $HelperPath).ProviderPath, [ref] $tokens, [ref] $parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($name in @('Get-CertificateSha256', 'Get-GoFixtureRoot',
    'Test-DisposableWindowsArm64Runner', 'Test-PinnedRootInStore',
    'Get-GoRootStoreState', 'Initialize-GoWindowsApi', 'Invoke-GoTestsWithRoot')) {
    $definition = @($helperAst.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq $name
    })
    if ($definition.Count -ne 1) { throw "Expected exactly one helper function: $name" }
    . ([scriptblock]::Create($definition[0].Extent.Text))
}
Initialize-GoWindowsApi
[ushort] $processMachine = 0
[ushort] $nativeMachine = 0
if (-not [GoFeedstockTemporaryTrust]::IsWow64Process2(
    [GoFeedstockTemporaryTrust]::GetCurrentProcess(), [ref] $processMachine, [ref] $nativeMachine)) {
    throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
}
if ($processMachine -ne 0 -or $nativeMachine -ne 0xaa64) {
    throw 'A native ARM64 process on Windows ARM64 is required; no stores were opened.'
}
if (-not (Test-DisposableWindowsArm64Runner)) { throw 'The shared runner guard rejected this environment.' }

function Assert-StoreState {
    param($Actual, $Expected)
    foreach ($name in @('UserRoot', 'MachineRoot', 'UserDisallowed', 'MachineDisallowed')) {
        if ($Actual.$name -ne $Expected.$name) { throw "Pinned-certificate state changed: $name" }
    }
}

function Invoke-NativeLifecycleCase {
    param([bool] $FailChild, [bool] $ExpectProvisioning)
    Assert-StoreState (Get-GoRootStoreState $certificate) $baseline
    $transaction = [pscustomobject]@{ Context = [IntPtr]::Zero; Adds = 0; Deletes = 0 }
    $store = [Security.Cryptography.X509Certificates.X509Store]::new(
        'Root', [Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    try {
        $status = Invoke-GoTestsWithRoot -AllowTemporaryRoot $ExpectProvisioning -ReadState {
            Get-GoRootStoreState $certificate
        } -AddRoot {
            $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            $context = [IntPtr]::Zero
            if (-not [GoFeedstockTemporaryTrust]::CertAddCertificateContextToStore(
                $store.StoreHandle, $certificate.Handle, 1, [ref] $context)) {
                throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
            }
            $transaction.Context = $context
            $transaction.Adds++
        } -RemoveRoot {
            # ADD_NEW owns this exact context. Never delete by thumbprint or
            # remove a pre-existing certificate to manufacture test coverage.
            $context = $transaction.Context
            $transaction.Context = [IntPtr]::Zero
            if (-not [GoFeedstockTemporaryTrust]::CertDeleteCertificateFromStore($context)) {
                throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
            }
            $transaction.Deletes++
        } -RunTests {
            $during = Get-GoRootStoreState $certificate
            if ($during.UserDisallowed -or $during.MachineDisallowed -or
                -not ($during.UserRoot -or $during.MachineRoot)) {
                throw 'The exact fixture root must be trusted while the child runs.'
            }
            if ($FailChild) {
                # A real native child failure, not a mocked exit status.
                & (Join-Path $PSHOME 'powershell.exe') -NoLogo -NoProfile -NonInteractive -Command 'exit 17'
                return $LASTEXITCODE
            }
            $output = @(& $goExecutable test -count=1 -v '-run=^Test(Go|System)Verify$/^SHA-384$' crypto/x509)
            $goStatus = $LASTEXITCODE
            $output | Out-Host
            if ($goStatus -ne 0) { return $goStatus }
            foreach ($test in @('TestGoVerify/SHA-384', 'TestSystemVerify/SHA-384')) {
                if (-not ($output -match ('^\s*--- PASS: ' + [regex]::Escape($test) + ' \('))) {
                    throw "The selected Go subtest did not report PASS: $test"
                }
            }
            return 0
        }
        $expectedStatus = 0
        if ($FailChild) { $expectedStatus = 17 }
        if ($status -ne $expectedStatus) { throw "Child status was $status; expected $expectedStatus." }
        # The shared helper preserves an already-failing child status even if
        # cleanup fails. Independently verify native cleanup, not just status.
        Assert-StoreState (Get-GoRootStoreState $certificate) $baseline
        $expectedCount = [int] $ExpectProvisioning
        if ($transaction.Adds -ne $expectedCount -or $transaction.Deletes -ne $expectedCount -or
            $transaction.Context -ne [IntPtr]::Zero) {
            throw "Unexpected native ownership counts: adds=$($transaction.Adds), deletes=$($transaction.Deletes)."
        }
        Write-Host "PASS native lifecycle: child=$status adds=$($transaction.Adds) deletes=$($transaction.Deletes); state restored."
    } finally {
        if ($transaction.Context -ne [IntPtr]::Zero) {
            [void] [GoFeedstockTemporaryTrust]::CertFreeCertificateContext($transaction.Context)
        }
        $store.Close()
    }
}

$certificate = $null
$savedEnvironment = @{}
try {
    # Scope these settings to this test process and restore them on completion.
    $settings = @{ CGO_ENABLED = '0'; GOENV = 'off'; GOTOOLCHAIN = 'local'; GOWORK = 'off' }
    foreach ($name in $settings.Keys) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $settings[$name], 'Process')
    }
    $rootDirectory = Get-Item -LiteralPath $GoRoot
    if (-not $rootDirectory.PSIsContainer) { throw '-GoRoot must be a Go directory.' }
    $goExecutable = Join-Path $rootDirectory.FullName 'bin/go.exe'
    if (-not (Test-Path -LiteralPath $goExecutable -PathType Leaf)) { throw 'The supplied GoRoot lacks bin/go.exe.' }
    $goEnvironment = @(& $goExecutable env GOHOSTOS GOHOSTARCH GOOS GOARCH CGO_ENABLED GOROOT)
    if ($LASTEXITCODE -ne 0 -or $goEnvironment.Count -ne 6 -or
        $goEnvironment[0] -cne 'windows' -or $goEnvironment[1] -cne 'arm64' -or
        $goEnvironment[2] -cne 'windows' -or $goEnvironment[3] -cne 'arm64' -or $goEnvironment[4] -cne '0') {
        throw 'The Go executable must have native windows/arm64 host and target with CGO_ENABLED=0.'
    }
    $reportedRoot = (Get-Item -LiteralPath $goEnvironment[5]).FullName.TrimEnd('\', '/')
    if (-not [string]::Equals($reportedRoot, $rootDirectory.FullName.TrimEnd('\', '/'),
        [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Go reports a different GOROOT; refusing to mix executable and fixture sources.'
    }
    $certificate = Get-GoFixtureRoot $rootDirectory.FullName
    $baseline = Get-GoRootStoreState $certificate
    if ($baseline.UserDisallowed -or $baseline.MachineDisallowed) {
        throw 'The pinned root is explicitly distrusted; no trust changes are permitted.'
    }
    if ($baseline.UserRoot -or $baseline.MachineRoot) {
        Invoke-NativeLifecycleCase -FailChild $false -ExpectProvisioning $false
        Write-Host 'NATIVE_TRUST_PROVISIONING=NOT_TESTED_EXISTING_ROOT; native verification passed without trust changes.'
    } else {
        Invoke-NativeLifecycleCase -FailChild $false -ExpectProvisioning $true
        Invoke-NativeLifecycleCase -FailChild $true -ExpectProvisioning $true
        Write-Host 'NATIVE_TRUST_PROVISIONING=PASS; real add/use/remove and child-failure cleanup verified.'
    }
} finally {
    if ($null -ne $certificate) { $certificate.Dispose() }
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
}
exit 0
