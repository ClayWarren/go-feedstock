# Windows ARM64 CGo validation

This personal-fork branch starts from the green no-CGo validation at
`66c0fff`. It adds patch 0016 to choose external linking for ARM64 COFF
features that the internal linker cannot handle, while keeping supported
static-data COMDATs eligible for internal linking. The CGo test script
also uses the certificate-environment helper already validated by no-CGo.
This is a separate CGo experiment, not an upstream PR update.

The separate manual workflow on the fork's default branch takes an exact
source commit. It runs only `win_arm64_cgotruego_variant_strcgo`, with
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
The CGo package tests preserve the native compiler and binary-architecture
checks, explicit and automatic linking smoke tests, focused `runtime/cgo`
and `cmd/cgo/internal/test` checks, and the authoritative dist suite. They
also run the new linker regression tests explicitly. Existing `os`, `cmd/go`,
and `cmd/gofmt` diagnostics remain separately logged. CGo and FIPS variants
are not skipped to accommodate unsupported internal linking: any remaining
failure must be diagnosed from the native run.

Go 1.27 honors `SSL_CERT_FILE` and `SSL_CERT_DIR` on Windows, bypassing the
platform verifier when either is set. Pixi exports these for its own CA
bundle, so the native test wrapper temporarily clears both during the focused
certificate check and authoritative suite, then restores their exact values.
This is test-process isolation, not an activation or Go-default change.
The suite's upstream certificate-override tests remain enabled.

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
