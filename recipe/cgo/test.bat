@echo on

rem Some of the windows build hosts can be a bit slow.  Allow the tests to run longer on windows under cgo.
set "GO_TEST_TIMEOUT_SCALE=4"

rem Keep the established win-64 same-drive workaround for the Go test suite.
rem https://github.com/golang/go/issues/24846#issuecomment-381380628
rem Native win-arm64 runners provide TEMP and TMP with runner-owned ACLs.
if /I not "%target_platform%"=="win-arm64" (
  set "TMP=%PREFIX%\tmp"
  mkdir "%PREFIX%\tmp"
)


rem Batch equivalent to backticks
rem   https://stackoverflow.com/questions/2768608/batch-equivalent-of-bash-backticks#2768660
rem for /f "usebackq tokens=*" %%a in (`go env GOEXE`) do file hello%%a | grep '{{ conda_gofile }}'


rem Diagnostics
where go
go env


if /I "%target_platform%"=="win-arm64" goto :win_arm64_tests


rem Run go's built-in tests
rem Expect FAIL, we run them to obtain logs
go tool dist test -k -v -no-rebuild -run=^^go_test:os$ || cmd /K "exit /b 0"
go tool dist test -k -v -no-rebuild -run=^^go_test:cmd/go$ || cmd /K "exit /b 0"
go tool dist test -k -v -no-rebuild -run=^^go_test:cmd/gofmt$  || cmd /K "exit /b 0"


rem Expect PASS
go tool dist test -v -no-rebuild -run=!^^go_test:os^|go_test:cmd/go^|go_test:cmd/gofmt$  || cmd /K "exit /b 0"
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
for /f "delims=" %%G in ('go env CGO_ENABLED') do if not "%%G"=="1" exit /b 1
for /f "delims=" %%G in ('go env CC') do if /I not "%%~nxG"=="clang.exe" exit /b 1

where clang.exe
if errorlevel 1 exit /b 1
clang.exe --version
if errorlevel 1 exit /b 1
for /f "delims=" %%G in ('clang.exe -dumpmachine') do set "CLANG_TARGET=%%G"
echo %CLANG_TARGET% | findstr /R /I "^aarch64.*windows-msvc" >nul
if errorlevel 1 exit /b 1

rem Test the installed conda defaults exactly as a consumer receives them.
set "CGO_LDFLAGS="
set "GO_CGO_LDFLAGS="
for /f "delims=" %%G in ('go env CGO_LDFLAGS') do set "GO_CGO_LDFLAGS=%%G"
echo %GO_CGO_LDFLAGS% | findstr /L /C:"-fuse-ld=lld" >nul
if errorlevel 1 exit /b 1

rem Go invokes the final external linker through CC, not LD. Verify that the
rem computed defaults select lld-link before exercising Go's external linker.
clang.exe %CFLAGS% -### "%~dp0lld_probe.c" %GO_CGO_LDFLAGS% -o lld_probe.exe 2> lld_driver.log
if errorlevel 1 exit /b 1
type lld_driver.log
findstr /I /C:"lld-link" lld_driver.log >nul
if errorlevel 1 exit /b 1
clang.exe %CFLAGS% "%~dp0lld_probe.c" %GO_CGO_LDFLAGS% -o lld_probe.exe
if errorlevel 1 exit /b 1
lld_probe.exe
if errorlevel 1 exit /b 1

go build -x -trimpath -ldflags="-linkmode=external -v" -o hello_win_arm64_external.exe "%~dp0hello_win_arm64.go" > hello_external.log 2>&1
set "GO_BUILD_STATUS=%ERRORLEVEL%"
type hello_external.log
if not "%GO_BUILD_STATUS%"=="0" exit /b %GO_BUILD_STATUS%
findstr /L /C:"-pthread" hello_external.log >nul
if errorlevel 1 exit /b 1
findstr /L /C:"-fuse-ld=lld" hello_external.log >nul
if errorlevel 1 exit /b 1
findstr /L /C:"fix_debug_gdb_scripts.ld" hello_external.log >nul
if not errorlevel 1 exit /b 1
findstr /L /C:"-mthreads" hello_external.log >nul
if not errorlevel 1 exit /b 1
hello_win_arm64_external.exe
if errorlevel 1 exit /b 1

rem Keep the focused upstream CGo checks unmasked.
go test -count=1 runtime/cgo
if errorlevel 1 exit /b 1
go test -count=1 cmd/cgo/internal/test
if errorlevel 1 exit /b 1
go test -count=1 -run=^^Test8694$ -v cmd/cgo/internal/test
if errorlevel 1 exit /b 1
go test -count=1 -ldflags="-linkmode=external" cmd/cgo/internal/test
if errorlevel 1 exit /b 1

go build -trimpath -o hello_win_arm64.exe "%~dp0hello_win_arm64.go"
if errorlevel 1 exit /b 1
hello_win_arm64.exe
if errorlevel 1 exit /b 1

go build -trimpath -buildmode=pie -o hello_win_arm64_pie.exe "%~dp0hello_win_arm64.go"
if errorlevel 1 exit /b 1
hello_win_arm64_pie.exe
if errorlevel 1 exit /b 1

powershell -NoLogo -NoProfile -NonInteractive -Command ^
  "$files = @('lld_probe.exe', 'hello_win_arm64.exe', 'hello_win_arm64_external.exe', 'hello_win_arm64_pie.exe');" ^
  "foreach ($file in $files) {" ^
  "  $bytes = [IO.File]::ReadAllBytes($file);" ^
  "  $peOffset = [BitConverter]::ToInt32($bytes, 0x3c);" ^
  "  $machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4);" ^
  "  if ($machine -ne 0xaa64) { Write-Error ('{0}: expected PE Machine AA64, got 0x{1:X4}' -f $file, $machine); exit 1 }" ^
  "}"
if errorlevel 1 exit /b 1

rem Run the focused native checks before the longer standard-library suite.
rem Preserve only the existing Windows diagnostic exceptions, using actual
rem package names. All remaining package and variant tests stay authoritative.
go tool dist test -k -v -no-rebuild os cmd/go cmd/gofmt
if errorlevel 1 echo Historical Windows diagnostic tests failed; see the log above.
go tool dist test -k -v -no-rebuild "-run=!^(os|cmd/go|cmd/gofmt)$"
if errorlevel 1 (
  rem Compare the explicit-root verifier with Windows system trust, without
  rem modifying certificate stores or masking the authoritative suite failure.
  go test -count=1 -v "-run=^Test(Go|System)Verify$/^SHA-384$" crypto/x509
  certutil -store -v Root A8985D3A65E5E5C4B2D7D66D40C6DD2FB19C5436
  certutil -user -store -v Root A8985D3A65E5E5C4B2D7D66D40C6DD2FB19C5436
  exit /b 1
)

:done
exit /b 0
