> Last updated: 2026-08-30

# Validation Matrix

Choose the smallest set that exercises the changed owner and its public
consumers. Run broader gates when ownership, dependency, lifecycle, protocol,
generated artifacts, or shared behavior changes.

## Environment

Select validation from the actual host. Linux and WSL run
`scripts/bash/**/*.sh`; native Windows runs `scripts/powershell/**/*.ps1` in
PowerShell 7. Never cross-launch Windows tools from WSL or require Bash from
native Windows. Keep platform caches and temporary directories isolated.

Windows-native validation is a separate, explicit environment rather than a
WSL escape hatch:

- Keep WSL as the source of truth for Linux CI and ordinary
  format/analyze/test/build checks. Do not invoke `powershell.exe`, `cmd.exe`,
  Windows `.bat`/`.cmd` launchers, or Windows `dart`/`flutter`/`cargo`/`go`/`node`
  binaries from those WSL checks.
- Use a native Windows PowerShell 7 (`pwsh.exe`) session or a `windows-latest` CI job only
  for checks that genuinely need Windows, such as the App client coverage run
  when the WSL Flutter VM Service is unavailable. Report that result as a
  Windows check; it does not turn a skipped WSL check into a Linux pass.
- Keep the Windows toolchain aligned with the repository pins (currently
  Flutter 3.47.0/Dart 3.13.0 and Rust 1.97.1 MSVC). Run
  [`scripts/powershell/platform/configure_windows_toolchain.ps1`](../../../../scripts/powershell/platform/configure_windows_toolchain.ps1)
  from native PowerShell 7 with an explicit `-FlutterRoot`; its default is
  process-scoped and `-PersistUserPath` is the only option that changes the
  user PATH.
- Keep OS-specific `PATH`, `PUB_CACHE`, `.dart_tool`, Cargo/Rustup caches, and
  temporary directories isolated. Native Windows coverage must use a native
  `TEMP`/`TMP` path and clear an inherited WSL `TMPDIR`; never share Linux
  build artifacts or package caches with Windows tooling.

## Always

```bash
git diff --check
git status --short
```

Review the final diff for unrelated work, secrets, generated noise, stale
documentation, and accidental public API/dependency changes.

## New production source files

Every newly added hand-written production source file requires corresponding
independent tests in the owning test directory and at least 90% file-level
line coverage. This file-level rule applies alongside the aggregate owner
thresholds in the coverage scripts. Generated output, documentation, configuration,
test-only files, and platform boilerplate without coverable business logic may
be excluded only when the owner report records the reason; otherwise the
change is incomplete.

Hand-written production files over 500 lines require a reviewable split by
functional or responsibility boundary. The split must not be a mechanically
numbered sequence such as `part_01`/`file_01`, and cohesive code must not be
over-split merely to reduce the line count. Repository-owned test suites and
fixtures use dedicated `test/` or `tests/` roots; Go `_test.go`, Rust
`#[cfg(test)]`/`src/tests`, and colocated TypeScript `.test`/`.spec` files are
the documented language-native same-package exceptions.

## Repository local CI

Run the aggregate only when the user explicitly mentions or requests local CI.
For routine bug fixes and scoped feature work, run focused package tests and
targeted gates (`--only`/`-Only`) only when the user requests them or they are
needed for the requested change. Local CI is opt-in: do not run the aggregate
as an automatic PR prerequisite. GitHub Actions is the CI authority for a
user-requested PR; push/open the PR to trigger its independent parallel jobs.

Use the aggregate for the actual host:

```bash
bash scripts/bash/ci/full_test.sh
# Native Windows PowerShell 7:
# & .\scripts\powershell\ci\full_test.ps1
```

For repeat runs with unchanged dependencies, `--no-bootstrap` avoids redundant
dependency installation. The script's default WSL profile keeps known
platform/toolchain gaps explicit; a `GAP` is incomplete validation, not a
passing check. When tests, package membership, project structure, CI jobs,
generated checks, exclusions, timeouts, or Linux environment assumptions
change, update both aggregate scripts in the same change and run the affected
jobs with `--only`/`-Only` before broader validation. Same-relative-path
`.sh`/`.ps1` pairs must keep behavior and exit semantics aligned.

When the user explicitly requests local CI and it is blocked by a host,
toolchain, container, permission, or local-resource problem, preserve the
`GAP`/timeout evidence and do not repeatedly extend the local run. For a
user-requested PR, complete the minimum preflight, push the branch, and use the
independent parallel jobs in
[`.github/workflows/flutter.yml`](../../../../.github/workflows/flutter.yml) as
the authoritative CI surface. After the PR/CI handoff, do not poll or
interpret GitHub results unless the user asks; the user reports the outcomes
and decides whether merging is allowed. Never report an unexecuted or
incomplete check as `PASS`.

## Formatting

All changed code must be formatted before completion; the CI pipeline enforces
the same gates, so submitting unformatted code fails the build. Run the owning
package's format gate (its README/AGENTS lists the exact command) and the
CI-mirrored checks below:

```bash
# Dart/Flutter workspace — format the changed lib/test/tool dirs (CI mirrors
# this in apps/ssh_mobile_full and via melos on the SDK packages):
dart format --output=none --set-exit-if-changed <changed dirs>
dart run melos run format   # repo-wide Dart workspace formatting
# Rust:
cargo fmt --all -- --check
# Go:
gofmt -l <changed dirs>   # fix any listed files with gofmt -w
# Front (TypeScript/React):
npm run lint   # plus the package's prettier/format command if present
```

If a changed file is not formatted, fix it with the formatter (`dart format`,
`cargo fmt`, `gofmt -w`, the front prettier command) and re-run the gate until
clean. Do not commit unformatted code, and never bypass the gate with a
no-op/`--set-exit-if-changed` false pass.

## Agent knowledge and documentation

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

## Test-first evidence

For observable or automatable behavior changes, run the new focused test before
production edits and keep the failure output long enough to verify that Red
corresponds to the intended contract. After Green, rerun that test and the
owning package suite. Add the existing contract, integration, acceptance, race,
storage, or platform gate
when the behavior crosses an owner boundary; a mocked unit test does not replace
that evidence. The procedure and exceptions are canonical in
[Maintenance Workflow](workflow.md).

Documentation-only workflow changes do not fabricate Red/Green evidence. They
use the Agent knowledge checks above plus the always-required final diff checks.

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
