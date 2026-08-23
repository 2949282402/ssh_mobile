> Last updated: 2026-08-23

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
bash scripts/full_test.sh --no-bootstrap
```

For App-local checks, run the required commands from the Full App directory:

```bash
cd apps/ssh_mobile_full
flutter analyze
flutter test
```

The periodic client Network V2 boundary gate is separate:

```bash
bash scripts/client_coverage.sh --no-bootstrap
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
[`scripts/configure_windows_toolchain.ps1`](../../scripts/configure_windows_toolchain.ps1)
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
