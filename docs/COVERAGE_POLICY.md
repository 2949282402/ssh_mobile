> Last updated: 2026-08-29

# Coverage policy

Coverage is a periodic review gate, not part of the ordinary local regression
loop. `bash scripts/bash/ci/full_test.sh --no-bootstrap` checks that the daily tests
pass without paying the Flutter instrumentation cost. After a refactor, a new
feature, or before review, run the four independent gates:

```bash
bash scripts/bash/coverage/front_coverage.sh
bash scripts/bash/coverage/backend_coverage.sh
bash scripts/bash/coverage/client_coverage.sh
bash scripts/bash/coverage/sdk_coverage.sh
```

Native Windows PowerShell 7 uses the same-relative-path counterparts under
`scripts\powershell\coverage\`. Agents select the tree from the actual host
and update every `.sh`/`.ps1` pair together.

Every gate requires at least 90% in its owner scope. A failure prints the
uncovered files/lines or functions so the next change can add a behavior test
for the missing boundary, error path, extreme value, or state transition.
Tests that only execute a line without checking an observable result are not
an acceptable way to satisfy this policy.

Coverage is evidence about exercised code, not the goal of TDD. Meet these
thresholds with tests that protect business contracts and meaningful boundaries;
do not add low-value getter, constructor, mock-interaction, or branch-only tests
solely to raise a percentage. The test-first development procedure is owned by
the [Maintenance Workflow](../.agents/skills/ssh-mobile-maintenance/references/workflow.md).

## New-file requirement

The 90% values below are aggregate owner baselines. Every newly added
hand-written production source file must have corresponding independent tests
in the owning test directory and reach at least 90% line coverage for that
file. Generated output, documentation,
configuration, test-only files, and platform boilerplate without coverable
business logic are excluded only when the owner validation report records the
reason. A new source file without this evidence is not ready for merge.

The Full App coverage gate passes the CI push base ref and `--source-root=lib`
to `apps/ssh_mobile_full/tool/check_coverage.dart`. The checker discovers files
added under that root with `git diff --diff-filter=A`, filters the documented
generated/test/third-party/platform paths, and requires every remaining source
to have an LCOV record and at least the active threshold on its own lines. The
focused client gate uses the same mechanism for
`lib/services/network/`. Local runs may set `FULL_TEST_COVERAGE_BASE_REF` or
`CLIENT_COVERAGE_BASE_REF`; an explicit `--source-manifest=<path>` is also
supported for owners whose source inventory is generated elsewhere.

`apps/ssh_mobile_full/lib/services/telemetry/telemetry_database/tables/telemetry_policy_states.dart`
is a documented per-file exclusion from this new-file requirement: it is a
hand-written Drift table whose declarative column and primary-key lines are
fully overridden by the generated `telemetry_database.g.dart` subclass at
runtime, so they carry no coverable business logic and cannot be exercised by a
test.

## Owner scopes

| Gate | Scope | Threshold |
| --- | --- | --- |
| `front_coverage.sh` | React/Vite `front/src`, with generated/test/bootstrap files excluded | Vitest statements, lines, functions, and branches: 90% each |
| `backend_coverage.sh` | Hand-written Go Relay and Admin code; generated protobuf/catalog and process-only `cmd/{relay,admin}/main.go` excluded | Go line coverage: 90%; hand-written `internal/telemetry` has its own 90% gate |
| `client_coverage.sh` | App-owned Network Protocol V2 boundary in `apps/ssh_mobile_full/lib/services/network/`, exercised by its codec, transfer, realtime, and runtime tests | Dart line coverage: 90% |
| `sdk_coverage.sh` | Dart `network_sdk`, `network_transport`, and `ssh_mobile_network_native` public libraries, plus the public Rust SDK crates (`network-ffi`, `network-identity`, `network-nat`, `network-protocol`, `network-quic`, `network-relay-proto`, `network-transfer`, `network-transport`, `network-webrtc`) | Each Dart package and the Rust public-crate aggregate: 90% lines |

Set `BACKEND_TELEMETRY_COVERAGE_MINIMUM` to override the telemetry sub-gate
independently; it defaults to `BACKEND_COVERAGE_MINIMUM` when unset. Both
backend scripts instrument the hand-written production packages with Go's
`-coverpkg` option, including tests under `relay/tests`, and reject an empty
telemetry profile before evaluating either threshold.

The client gate is intentionally a Network V2 client-boundary metric, not a
claim that every unrelated UI feature in the Full App has 90% coverage. The
Rust `network-core` implementation and Rust Relay implementation remain in the
ordinary Rust workspace test/clippy gate; their current workspace coverage is
reported separately because they are internal engines rather than public SDK
facades.

Docker-backed Relay MySQL/Redis and Analytics MySQL/Redis services are created
and removed by `backend_coverage.sh` when the corresponding test DSNs/URLs are
not supplied. Telemetry integration tests therefore do not silently skip when
the coverage gate bootstraps its own services. The client gate may take
longer under WSL because Flutter coverage compilation is serialized; use
`CLIENT_FLUTTER_COVERAGE_TIMEOUT=30m` (or a larger value) when the toolchain
cache is cold. The SDK Dart gate uses the native `dart test --coverage` runner,
so it does not require a Flutter VM Service.

If a WSL Flutter toolchain stays at `loading` without exposing a VM Service,
the client gate is environment-incomplete rather than a passing coverage
result. The script accepts an explicit Flutter runner, so this repository's
patched source-toolchain workaround can be used when available:

```bash
CLIENT_FLUTTER_BIN="$FLUTTER_SDK_ROOT/bin/flutter-dev" \
SSH_MOBILE_DISABLE_DART_PROFILING=1 \
bash scripts/bash/coverage/client_coverage.sh --no-bootstrap
```

Set `FLUTTER_SDK_ROOT` to the local source Flutter checkout before running the
command; the path is intentionally not fixed to a particular developer
machine.

Otherwise run it on Windows or CI with a working Flutter VM Service; ordinary
`flutter test` success must not be substituted for the periodic coverage gate.

For the native Windows fallback, start a native Windows PowerShell 7 (`pwsh.exe`) session and
configure the pinned SDK before running the client gate:

```powershell
. .\scripts\powershell\platform\configure_windows_toolchain.ps1 `
  -FlutterRoot 'D:\toolchains\flutter_windows_3.47.0\flutter'
$env:CLIENT_COVERAGE_MINIMUM = '90'
```

The configuration script validates Flutter 3.47.0/Dart 3.13.0 and Rust
1.97.1 MSVC, uses a native TEMP/TMP directory, and leaves the user PATH alone
unless `-PersistUserPath` is explicitly requested. Do not invoke this Windows
launcher from WSL, mix Windows and Linux package caches, or treat Windows
coverage as a Linux validation pass.

Build the Windows MSI from the same native PowerShell 7 session with
[`scripts/powershell/platform/build_windows_msi.ps1`](../scripts/powershell/platform/build_windows_msi.ps1). The builder
requires a native Windows working directory, selects the installed Windows SDK,
and moves MSBuild temporary files off any inherited WSL path. If WiX reports
LGHT0217 because the host cannot execute Windows Installer ICE actions, use the
explicit `-SuppressIceValidation` switch only with a separately recorded ICE
gap; still parse the resulting MSI with `dark.exe` or validate it on a host
with Windows Installer ICE support.
