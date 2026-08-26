> Last updated: 2026-08-25

# Client Current State

`apps/ssh_mobile_full/` is the maintained complete application.
`apps/ssh_mobile_terminal/` validates the minimal Terminal-only dependency crop.

Maintained package owners cover:

- Core application, UI, and Connection contracts;
- Connection, Terminal, SFTP, Monitoring, System Administration, LAN Share,
  Playbook, RAG, MCP, AI, WebView, and Developer Features;
- App-scoped SSH infrastructure.

Legacy Full App paths remain only where a current consumer still requires a
compatibility export, adapter, or bridge. Their disposition is tracked by the
[compatibility inventory](../../docs/architecture/COMPATIBILITY_MIGRATION_INVENTORY.md);
new implementation goes to the owning package.

Feature/Core persistence is split by owner. There is no shared business
database, and a production database-open failure must not silently fall back to
an in-memory database.

Network runtime and public network-contract work is routed through the
[SDK domain](../sdk/current-state.md), even when `AppRuntime` creates the
App-scoped facade.

## Validation gates

The daily App regression gate runs from the repository root and intentionally
does not collect Flutter coverage:

```bash
bash scripts/bash/ci/full_test.sh --no-bootstrap
```

For App-local checks, run the required commands from the Full App directory:

```bash
cd apps/ssh_mobile_full
flutter analyze
flutter test
```

The periodic client Network V2 boundary gate is separate:

```bash
bash scripts/bash/coverage/client_coverage.sh --no-bootstrap
```

It covers the App-owned Network V2 service boundary, not every unrelated Full
App UI feature. If a WSL Flutter runner cannot expose its VM Service, configure
`CLIENT_FLUTTER_BIN` to a working source runner and use the documented
`SSH_MOBILE_DISABLE_DART_PROFILING=1` workaround in
[`docs/COVERAGE_POLICY.md`](../../docs/COVERAGE_POLICY.md); an ordinary
`flutter test` pass is not a coverage pass.

## Windows toolchain boundary

WSL is the default owner of Linux validation. A native Windows run is an
explicit platform check, not a way to bypass a blocked or failing WSL check.
Use Windows only for behavior that requires Windows, or for the client
coverage fallback when the WSL Flutter VM Service cannot start; record the
result as Windows evidence and keep the WSL gap visible.

Windows must use the same repository pins as CI: Flutter 3.47.0 with Dart
3.13.0 and Rust 1.97.1 MSVC. Configure the selected SDK through
[`scripts/powershell/platform/configure_windows_toolchain.ps1`](../../scripts/powershell/platform/configure_windows_toolchain.ps1)
from native PowerShell 7 (`pwsh.exe`). The script rejects Windows PowerShell
5.1 and WSL UNC working directories, keeps PATH/TEMP/TMP/Rust overrides
process-scoped unless `-PersistUserPath` is explicitly supplied, and refuses to
continue when the versions do not match.

The Windows MSI builder follows the same PowerShell 7/native-path boundary and
selects a native Windows SDK temporary directory before invoking MSBuild. Its
`-SuppressIceValidation` option is an explicit host-gap escape hatch, not a
replacement for ICE validation on a normal Windows Installer host.

Never invoke Windows `.exe`/`.bat`/`.cmd` toolchains from WSL validation scripts,
and never share Linux/Windows `PATH`, `PUB_CACHE`, `.dart_tool`, Cargo/Rustup
caches, or build artifacts. Native Windows coverage must use a native TEMP/TMP
directory and remove an inherited WSL `TMPDIR` before starting Flutter.

### Windows MSI packaging and client validation

Run this workflow from a native Windows checkout in `pwsh.exe`. The placeholders
below are intentionally machine-independent: `<native-repo>` is the Windows
checkout, `<flutter-root>` is the pinned Flutter SDK root, and `<native-temp>`
is a native Windows temporary directory.

1. Configure the pinned toolchain and bootstrap the workspace:

   ```powershell
   Set-Location '<native-repo>'
   . .\scripts\powershell\platform\configure_windows_toolchain.ps1 `
     -FlutterRoot '<flutter-root>' `
     -TempRoot '<native-temp>'
   & '<flutter-root>\bin\flutter.bat' pub get
   ```

   The configuration script validates Flutter 3.47.0, Dart 3.13.0, and Rust
   1.97.1 MSVC. Omit `-TempRoot` to use the default native system temporary
   directory. Keep the resulting environment in the same PowerShell process
   for the remaining commands.

2. Run the focused client Network V2 tests and inspect coverage:

   ```powershell
   Set-Location '<native-repo>\apps\ssh_mobile_full'
   & '<flutter-root>\bin\flutter.bat' test --no-pub --no-test-assets `
     --coverage --coverage-path '<native-temp>\client-windows-lcov.info' `
     --reporter expanded `
     test/services/network/network_protocol_v2_codec_test.dart `
     test/services/network/transfer_transport_test.dart `
     test/app/realtime_feature_adapters_test.dart `
     test/app/app_runtime_test.dart
   & '<flutter-root>\bin\dart.bat' run tool/check_coverage.dart `
     --minimum=80 --details `
     --file='<native-temp>\client-windows-lcov.info' `
     --include=lib/services/network/
   ```

   This is the Windows counterpart of `scripts/bash/coverage/client_coverage.sh` and covers
   the App-owned Network V2 boundary. The owner gate remains 80%; every new
   hand-written production file must also meet the repository's 90% file-level
   coverage requirement with an independent test file.

3. Build and package the Windows MSI from the repository root:

   ```powershell
   Set-Location '<native-repo>'
   & .\scripts\powershell\platform\build_windows_msi.ps1 `
     -Flutter '<flutter-root>\bin\flutter.bat' `
     -Version '1.0.0'
   ```

   The builder runs `flutter build windows`, stages the App-owned release
   output, and writes
   `build\windows_msi\out\SSH_Mobile_Windows_v<version>_setup.msi`. It
   downloads/caches WiX 3.14.1 when no usable WiX v3 tools are installed. If a
   host reports WiX `LGHT0217` because Windows Installer ICE actions cannot run,
   use the explicit `-SuppressIceValidation` switch, record that host gap, and
   perform the structural check below; normal Windows Installer hosts should
   keep ICE validation enabled.

4. Validate the MSI without installing system-wide. Use `dark.exe` from the
   installed or cached WiX toolset to decompile and extract the package:

   ```powershell
   & '<wix-root>\dark.exe' -nologo `
     -x '<native-temp>\msi-dark' `
     -o '<native-temp>\SSH_Mobile_Windows.wxs' `
     '<native-repo>\build\windows_msi\out\SSH_Mobile_Windows_v1.0.0_setup.msi'
   ```

   Require exit code 0, a generated WXS file, a non-empty extracted file set,
   and a non-zero MSI size/hash. Do not reuse WSL caches or temporary paths, and
   inspect/stop only processes owned by this workflow before handing off.
