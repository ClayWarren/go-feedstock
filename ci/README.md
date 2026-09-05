# Windows ARM64 no-CGo validation

This personal-fork branch validates patch 0015 and the Windows no-CGo
certificate-fixture prerequisite on top of diagnostic baseline `71907d0`.
It does not include patch 0016 or the pending CGo test-script changes, and
does not claim to solve the CGo internal-linker limitations.

The separate manual workflow on the fork's default branch takes an exact
source commit. It runs only `win_arm64_cgofalsego_variant_strnocgo`, with
both build and target platforms set to `win-arm64`, and uploads disabled.
The recipe remains version 1.27.1, build 4. Generated CI files are unchanged.

The workflow first checks the trust-helper lifetime using the official,
SHA-256-pinned Windows ARM64 Go 1.27.1 bootstrap. The script requires native
Windows PowerShell 5.1 on an explicitly opted-in GitHub-hosted ARM64 runner.
It uses only Go's fingerprint-pinned public certificate fixture and never
removes existing trust or overrides explicit distrust. If the root is absent,
it verifies real add/use/remove on success and after a native child exits 17.
If already trusted, it makes no store changes and explicitly reports that
provisioning and failure-cleanup coverage were not exercised.

The package then builds through the unchanged conda-forge harness. Its
win-64 build-service tools may run under emulation; the Go compiler and Go
tests must independently prove native ARM64 host, target, and execution.
The no-CGo package tests preserve the authoritative dist suite and add
positive FIPS inventory and actual integrity-test evidence. Existing
`os`, `cmd/go`, and `cmd/gofmt` diagnostics remain separately logged.

Run the portable mocked lifetime tests without accessing certificate stores:

```powershell
pwsh -NoProfile -File recipe/windows/test_run_dist_tests.ps1 -GoRoot /path/to/go-source
```

Native-only lifecycle test, on the disposable runner with the documented
runtime opt-in, never on a developer workstation:

```powershell
powershell -NoProfile -File ci/test_native_trust_lifecycle.ps1 -HelperPath recipe/windows/run_dist_tests.ps1 -GoRoot C:\path\to\go
```

An upload-validation infrastructure failure after successful tests is
separate from a native test failure. No conda packages are published by
this manual workflow.
