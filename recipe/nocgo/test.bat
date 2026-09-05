@echo on

rem Keep the established win-64 same-drive workaround for the Go test suite.
rem https://github.com/golang/go/issues/24846#issuecomment-381380628
rem Native win-arm64 runners provide TEMP and TMP with runner-owned ACLs.
if /I not "%target_platform%"=="win-arm64" (
  set "TMP=%PREFIX%\tmp"
  mkdir "%PREFIX%\tmp"
)


rem Diagnostics
where go
go env


if /I "%target_platform%"=="win-arm64" goto :win_arm64_tests


rem Run go's built-in tests
rem Expect FAIL, we run them to obtain logs
go tool dist test -k -v -no-rebuild -run=^^go_test:os$ || cmd /K "exit /b 0"
go tool dist test -k -v -no-rebuild -run=^^go_test:cmd/go$ || cmd /K "exit /b 0"
go tool dist test -k -v -no-rebuild -run=^^go_test:cmd/gofmt$ || cmd /K "exit /b 0"


rem Expect PASS
go tool dist test -v -no-rebuild -run=!^^go_test:os^|go_test:cmd/go^|go_test:cmd/gofmt$ || cmd /K "exit /b 0"
if errorlevel 1 exit 1

goto :done

:win_arm64_tests
setlocal DisableDelayedExpansion
rem cmd/dist resolves go and gofmt under GOROOT, while the conda package
rem exposes them from PREFIX\bin. Restore the canonical layout only in this
rem disposable test prefix.
set "GO_ROOT="
for /f "delims=" %%G in ('go env GOROOT') do set "GO_ROOT=%%G"
if not defined GO_ROOT exit /b 1
if not exist "%GO_ROOT%\bin" mkdir "%GO_ROOT%\bin"
if errorlevel 1 exit /b 1
copy /Y "%PREFIX%\bin\go.exe" "%GO_ROOT%\bin\go.exe"
if errorlevel 1 exit /b 1
copy /Y "%PREFIX%\bin\gofmt.exe" "%GO_ROOT%\bin\gofmt.exe"
if errorlevel 1 exit /b 1

rem vcweb changes USER and USERPROFILE for its fixtures. Use the runner's
rem native Git, not the build tooling's MSYS2 Git and its POSIX ownership view.
if not exist "%ProgramFiles%\Git\bin\git.exe" (
  echo Native Git for Windows is required for the ARM64 package tests.
  exit /b 1
)
set "PATH=%ProgramFiles%\Git\bin;%PATH%"
where git
git version --build-options
if errorlevel 1 exit /b 1
git --exec-path
if errorlevel 1 exit /b 1

rem Go 1.27 registers package names without the old go_test: prefix.
rem Assert exact diagnostic names using line-aware reads, before allowing
rem their failures. Print the list if an expected name is missing.
go tool dist test -list > dist_tests.txt
if errorlevel 1 exit /b 1
powershell -NoLogo -NoProfile -NonInteractive -Command ^
  "$ErrorActionPreference = 'Stop';" ^
  "$tests = @(Get-Content -LiteralPath 'dist_tests.txt');" ^
  "foreach ($name in @('os', 'cmd/go', 'cmd/gofmt')) {" ^
  "  if ($tests -cnotcontains $name) { $tests; throw ('Missing dist test: ' + $name) }" ^
  "}"
if errorlevel 1 exit /b 1

for /f "delims=" %%G in ('go env GOHOSTOS') do if /I not "%%G"=="windows" exit /b 1
for /f "delims=" %%G in ('go env GOHOSTARCH') do if /I not "%%G"=="arm64" exit /b 1
for /f "delims=" %%G in ('go env GOOS') do if /I not "%%G"=="windows" exit /b 1
for /f "delims=" %%G in ('go env GOARCH') do if /I not "%%G"=="arm64" exit /b 1
for /f "delims=" %%G in ('go env CGO_ENABLED') do if not "%%G"=="0" exit /b 1

go build -trimpath -o hello_win_arm64.exe "%~dp0hello_win_arm64.go"
if errorlevel 1 exit /b 1

hello_win_arm64.exe
if errorlevel 1 exit /b 1

powershell -NoLogo -NoProfile -NonInteractive -Command ^
  "$bytes = [IO.File]::ReadAllBytes('hello_win_arm64.exe');" ^
  "$peOffset = [BitConverter]::ToInt32($bytes, 0x3c);" ^
  "$machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4);" ^
  "if ($machine -ne 0xaa64) { Write-Error ('expected PE Machine AA64, got 0x{0:X4}' -f $machine); exit 1 }"
if errorlevel 1 exit /b 1

rem Run the focused native checks before the longer standard-library suite.
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0verify_fips_integrity.ps1"
if errorlevel 1 exit /b %ERRORLEVEL%

rem Preserve only the existing Windows diagnostic exceptions, using actual
rem package names. All remaining package and variant tests stay authoritative.
go tool dist test -k -v -no-rebuild os cmd/go cmd/gofmt
if errorlevel 1 echo Historical Windows diagnostic tests failed; see the log above.
rem The unchanged suite needs the upstream SHA-384 fixture's public root.
rem Opt in only on a disposable runner; the wrapper verifies native ARM64,
rem respects explicit distrust, and removes only a root it temporarily adds.
set "GO_TEST_ALLOW_TEMPORARY_USER_ROOT="
if "%GITHUB_ACTIONS%"=="true" if "%RUNNER_ENVIRONMENT%"=="github-hosted" set "GO_TEST_ALLOW_TEMPORARY_USER_ROOT=1"
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0..\windows\run_dist_tests.ps1"
if errorlevel 1 exit /b %ERRORLEVEL%

:done
exit /b 0
