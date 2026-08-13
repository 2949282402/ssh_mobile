> Last updated: 2026-08-13

# Validation Matrix

Choose the smallest set that exercises the changed owner and its public
consumers. Run broader gates when ownership, dependency, lifecycle, protocol,
generated artifacts, or shared behavior changes.

## Environment

This repository is developed and validated inside the WSL Linux environment.
Run every build, test, analyze, format, lint, and validation command with the
Linux toolchain inside WSL — never with Windows-hosted toolchains or launchers:
Windows `dart`/`flutter`/`go`/`cargo`/`node`, `.bat`/`.cmd` launchers,
`powershell.exe`, `cmd.exe`, or any Windows binary reached through a mounted
Windows drive. Prefer the Linux `go`/`cargo`/`flutter`/`dart`/`node` on the WSL
PATH. When a required check cannot run under the WSL Linux toolchain, report the
exact command and reason instead of falling back to a Windows binary.

## Always

```bash
git diff --check
git status --short
```

Review the final diff for unrelated work, secrets, generated noise, stale
documentation, and accidental public API/dependency changes.

## Agent knowledge and documentation

After a canonical Skill change:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\sync_agent_skills.ps1 -Mode SyncFromAgents
powershell -ExecutionPolicy Bypass -File .\scripts\sync_agent_skills.ps1 -Mode Check
```

After the Agent documentation checker exists, run:

```bash
dart format --output=none --set-exit-if-changed tool test/tool
dart analyze tool/check_agent_docs.dart test/tool/agent_docs_check_test.dart
dart run test/tool/agent_docs_check_test.dart
dart run tool/check_agent_docs.dart
dart run test/tool/ci_workflow_test.dart
```

Docs-only facts also require the owning package or Domain source to be checked;
a Markdown link check cannot establish semantic correctness.

## Flutter/Dart Workspace Member

From the owning package or App, use its README/AGENTS commands. The usual gate is:

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test --no-pub
```

Use `dart analyze`/`dart test` for pure Dart packages. Run a focused test first,
then the package suite. For cross-workspace changes:

```bash
dart pub get
dart run melos run format
dart run melos run analyze
dart run melos run test
```

## Architecture and ownership

Run the relevant repository checks for Feature dependencies, `/src/` imports,
service locators, resource ownership, or compatibility changes:

```bash
dart run tool/architecture_check.dart
dart run tool/check_file_sizes.dart
dart run tool/check_module_dependencies.dart
dart run tool/check_resource_owners.dart
```

The file-size command is a review report, not a mechanical split gate.

## Generated Dart and assets

After a Drift/model change, run the owning package's `build_runner` command and
verify the committed generated file. From the Full App:

```bash
dart run build_runner build
git diff --exit-code -- lib/services/app_log_database.g.dart
```

After icon-source changes:

```bash
dart run tool/generate_app_icons.dart
git diff --exit-code -- assets android ios macos web windows/runner/resources/app_icon.ico
```

Edit generator inputs, never only generated output.

## Rust network SDK

From `native/network_core/`, select focused crate tests first, then as needed:

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
```

Protocol, FFI, Session, Delivery, crypto, route, Relay, or WebRTC changes also
require the affected Dart package checks and the precise fault/ADR review.

## Relay and Front

From `relay/` for Go changes:

```bash
gofmt -w ./cmd ./internal
go test ./...
go vet ./...
```

From `front/` for React/TypeScript changes:

```bash
npm ci
npm run typecheck
npm run lint
npm run test:run
npm run build
```

Only run commands actually provided by the current package manifest. API/schema
changes validate both producer and consumer.

## Platform and product gates

Use Full App `flutter analyze`/`flutter test` for shared Flutter behavior.
Validate the Terminal-only dependency crop from `apps/ssh_mobile_terminal/`
when its manifest, composition, or lifecycle changes. Run Android, Windows,
macOS, iOS, installer, or device checks only when the changed platform or user
request requires them.

`INSTALL_FAILED_USER_RESTRICTED` after a successful Android build means the
device blocked installation; it is not a Gradle compile failure. Release builds
keep cleartext traffic disabled; debug/profile exceptions are local testing
configuration, not a production-policy change.

## Reporting a blocked check

Record the exact command, where it was run, the first actionable failure, and
whether the problem is product code, test code, toolchain/environment, or an
out-of-scope device/service. Never translate “not run” into “passed.”
