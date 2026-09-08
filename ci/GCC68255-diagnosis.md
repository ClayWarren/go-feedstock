# Fork-only GCC68255 reproduction

Base: `1790451611c870e99794413dd0ea9d54cf72782b` (Go 1.27.1).
Failure: run 34165618897, `cmd/cgo/internal/test:external-s`,
`TestGCC68255`: C global variable was not initialized.

This branch deliberately ends the ARM64 package-test entrypoint after a
focused diagnostic. A green run is **not full package acceptance**. Never
publish this branch or include its diagnostic hook/workflow in PR 339.
The existing clean review branch and all upstream source patches are unchanged.

The probe builds the unchanged CGo test package in external and external `-s`
modes, three times each. Each executable is checked for ARM64 PE architecture,
launched ten times for the exact inventoried test, then launched once for the
whole CGo test package. Executions use the package source working directory.
Failures are accumulated without preventing the other variant from running.

Retained evidence includes binaries, SHA256, linker temporary objects,
Go `-x -work` logs/work directories, PE headers/relocations, exact selected Go
compiler flags, and per-execution status/logs. Artifact upload runs on failure
and treats missing evidence as an error. Package uploads remain disabled.

Local checks: actionlint, PowerShell parsing, native stdout/stderr capture and
nonzero exit-status preservation on macOS. Windows execution is a separate gate.
