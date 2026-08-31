> Last updated: 2026-08-30

# Validation Matrix

Choose the smallest gate covering the changed owner and public consumers; widen
only for a changed dependency, lifecycle, protocol, generated artifact, or
shared boundary. Run only commands actually available on the host.

## Host and always-on checks

- Linux/WSL uses `scripts/bash/**/*.sh`; native Windows uses the matching
  `scripts/powershell/**/*.ps1` in PowerShell 7. Never cross-launch toolchains.
- Keep OS-specific PATH, `PUB_CACHE`, `.dart_tool`, Cargo/Rustup caches, build
  artifacts, and temporary directories separate. Windows coverage clears WSL
  `TMPDIR` and uses native TEMP/TMP. Windows pins are Flutter 3.47.0/Dart 3.13.0
  and Rust 1.97.1 MSVC; configure with
  [`configure_windows_toolchain.ps1`](../../../../scripts/powershell/platform/configure_windows_toolchain.ps1)
  and an explicit `-FlutterRoot` (only `-PersistUserPath` changes user PATH).
- `INSTALL_FAILED_USER_RESTRICTED` after a successful Android build means device
  policy blocked installation, not a Gradle compile failure. Release builds keep
  cleartext traffic disabled; debug/profile exceptions are local test settings.
- Always run `git diff --check` and `git status --short`, then inspect the final
  diff for unrelated work, secrets, generated noise, stale docs/paths, and
  accidental API/dependency changes.

## Source, tests, and coverage rules

Every new hand-written production file needs an independent test in the owning
test directory and at least 90% file-level line coverage. Generated output,
documentation, configuration, test-only files, and coverageless platform
boilerplate may be excluded only with an owner-report reason. Production files
over 500 lines require a responsibility-based split, never numbered chunks or
mechanical over-splitting. Tests/fixtures use `test/`/`tests/` with Go `_test.go`,
Rust `#[cfg(test)]`/`src/tests`, and TypeScript `.test`/`.spec` exceptions.

Observable behavior follows the test-first procedure in
[Maintenance Workflow](workflow.md). Documentation-only workflow changes use
documentation checks, not fabricated Red/Green evidence.

## Repository CI and PR handoff

Local aggregate CI is opt-in: run it only when the user explicitly mentions or
requests local CI. Otherwise use the owning package's focused format/analyze/
test gates only when requested or needed for the change. GitHub Actions is the
authoritative CI for a user-requested PR; its jobs are independent and parallel.

```bash
bash scripts/bash/ci/full_test.sh
# native Windows PowerShell 7:
# & .\scripts\powershell\ci\full_test.ps1
```

Use `--no-bootstrap`/`-NoBootstrap` for repeat runs. If an explicit local run
hits host/toolchain/container/permission/resource limits, retain the `GAP` or
timeout and stop; it is not PASS. After the minimum preflight, push/open the
requested PR; do not poll or interpret GitHub results unless the user asks, and
do not approve/merge. The user reports CI results and decides merging. Changes
to tests, package membership, structure, CI jobs, generated checks, exclusions,
timeouts, or environment assumptions require synchronized same-relative `.sh`/
`.ps1` updates and affected `--only`/`-Only` checks.

## Language and owner gates

Formatting commands:

```bash
dart format --output=none --set-exit-if-changed <changed dirs>
dart run melos run format                 # workspace when broadly affected
cargo fmt --all -- --check                # Rust
gofmt -l <changed dirs>                   # Go; fix with gofmt -w
npm run lint                              # Front, plus manifest formatter
```

Use the owning README/AGENTS for the package analyze/test command. Typical Dart
package gates are `dart analyze` or `flutter analyze`, plus `dart test` or
`flutter test`; run focused tests
before the package suite. Cross-workspace changes may use `dart pub get` and the
Melos format/analyze/test commands. Native Flutter/Android/Windows/macOS/iOS or
device gates run only when that boundary or the user requires them.

Architecture/ownership/dependency/compatibility changes may require:

```bash
dart run tool/architecture_check.dart
dart run tool/check_file_sizes.dart
dart run tool/check_module_dependencies.dart
dart run tool/check_resource_owners.dart
dart run tool/compatibility_check.dart
```

For Drift/model changes run the owning `build_runner` and review committed
generated output. For icon-source changes run `dart run tool/generate_app_icons.dart`
and review generated platform assets. Edit generator inputs, never only output.

## Domain commands

Rust (`native/network_core/`):

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
```

Protocol, FFI, Session, Delivery, crypto, route, Relay, or WebRTC changes also
run affected Dart checks and exact contract/ADR review. Relay (`relay/`) uses
`gofmt`, `go test ./...`, `go vet ./...`; Front (`front/`) uses only manifest-
provided `npm ci`, `npm run typecheck`, `npm run lint`, `npm run test:run`, and
`npm run build` as applicable. API/schema changes validate both producer and
consumer.

## Agent documentation and coverage gates

When Agent knowledge changes, run the documentation checker suite:

```bash
dart format --output=none --set-exit-if-changed tool test/tool
dart analyze tool/check_agent_docs.dart test/tool/agent_docs_check_test.dart
dart run test/tool/agent_docs_check_test.dart
dart run tool/check_agent_docs.dart
dart run test/tool/ci_workflow_test.dart
```

For large refactors, coverage changes, or release review, use independent owner
gates from the repository root:

```bash
bash scripts/bash/coverage/front_coverage.sh
bash scripts/bash/coverage/backend_coverage.sh
bash scripts/bash/coverage/client_coverage.sh
bash scripts/bash/coverage/sdk_coverage.sh
```

Native Windows uses matching `scripts\powershell\coverage\` files. Each gate
enforces 90% for its documented scope; `coverage_test.sh`/`.ps1` remain client
aliases. Scope, Docker services, and the WSL Flutter workaround are in
[`docs/COVERAGE_POLICY.md`](../../../../docs/COVERAGE_POLICY.md). The Windows
MSI/client coverage procedure is summarized in
[`client/current-state.md`](../../../../memory_docs/client/current-state.md): use
native PowerShell 7/paths, pinned SDKs, native TEMP/TMP, and keep any WiX ICE
gap explicit; `-SuppressIceValidation` is an explicit host-gap escape hatch.

## Reporting gaps

For every blocked or omitted check record the exact command, host/path, first
actionable failure, and whether it is product, test, toolchain/environment, or
out-of-scope service. Never translate “not run” into “passed”.
