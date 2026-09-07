# Isolated Windows ARM64 no-CGo acceptance

This branch starts at upstream PR 339 head `8d88f8b` and extracts only the
no-CGo test fixes previously tested within `965c833`. The CGo build/test
scripts and experimental linker/shared-library patches are not carried over.

The sole added Go-source patch is the FIPS dist registration fix: external
variants require CGo, and the integrity-test filter names the actual test.
Its registration regression covers CGo on/off and compile-only mode. This
shared registration correction also applies when CGo is enabled; it is not a
claim that the unresolved native CGo package suite passes.

No version, build number, dependency, provider, generated CI matrix, or runtime
activation settings change. Temporary certificate provisioning stays limited
to an explicitly opted-in disposable native ARM64 GitHub runner, uses the
fingerprint-pinned upstream public fixture, respects distrust, and removes
only the entry it owns. Portable tests never open certificate stores.

Local checks: recipe lint, FIPS evidence parser/inventory tests, PowerShell
architecture-type regression, and mocked trust/environment lifetime tests.
Run the existing personal-fork `go-nocgo-arm64-validation.yml` workflow with
this branch's exact commit SHA. It builds and tests without publishing.

Previous native success of the larger branch is supporting evidence, not
acceptance of this newly separated patch set. A fresh run is required.
