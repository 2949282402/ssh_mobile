> Last updated: 2026-08-21

# Network V2 Final Acceptance Report

Status: **PASS for the runnable Linux gate — implementation, strict acceptance,
coverage, and architecture cleanup are green; native platform jobs remain
host-dependent**

This report records the requested Network V2 audit, freeze, SDK migration, and
validation sequence on branch `agent/network-v2-final-20260819`. The frozen
wire contract was not changed. The remaining open item is execution evidence,
not an identified Network V2 or SDK correctness failure.

## Required final-deliverable fields

```text
Architecture: COMPLETED — App, Runtime lifecycle, Relay, and Transfer domain/function boundaries landed
Cutover: PARTIAL
Legacy Retirement: DEFERRED
SDK Architecture Cleanup: COMPLETED
API Compatibility: PASS
Performance: PASS
Tests: PASS — runnable Linux full gate and Flutter coverage passed; native platform jobs require their CI hosts
```

The V2 contract/facade is domain-oriented. The App `NetworkService` has been
split into lifecycle, command, event, Peer, Relay, Route, and Transfer owners;
Rust lifecycle resources now sit behind `RuntimeLifecycleState`, Relay/Transfer
calls cross typed Runtime ports, Relay regression tests are isolated in
`relay_tests.rs`, and the Relay and Transfer field groups are owned by
`RelayDomainState`/`TransferDomainState`. Relay production ownership is split
across `relay_control.rs`, `relay_data.rs`, and `relay_transfer.rs`; Transfer
operation/IO ownership is isolated in `transfer_operations.rs`. Legacy
compatibility aliases remain documented and retained until an external-consumer
migration authorizes their removal.

## Phase results

| Phase | Result | Evidence |
| --- | --- | --- |
| 0. Baseline | PASS | `docs/NETWORK_V2_PR48_BASELINE.md` records the baseline commit, test matrix, and known gaps |
| 1. Eight audits | PASS | `AUDIT_REPORT.md`, `LEGACY_AUDIT_REPORT.md`, `PATH_LEASE_REPORT.md`, `CONNECTIVITY_STAGE_REPORT.md`, `CANDIDATE_CACHE_REPORT.md`, `RELAY_SECURITY_REPORT.md`, `FFI_ABI_REPORT.md`, and `CI_DOCUMENTATION_REPORT.md` |
| 2. Coordinator review | PASS | `COORDINATOR_REVIEW.md`; resolved bugs have executable owner tests and remaining gaps are integration/environment scoped |
| 3. Architecture freeze | PASS | `FREEZE_GATE_REPORT.md`; Network V2 contract, ownership, and protocol gates are frozen |
| 4. SDK migration | PASS | V2 domain ports/adapters, App Shell service owners, `RuntimeLifecycleState`, typed Rust Relay/Transfer ports, Relay test ownership, Relay/Transfer state aggregates, and production operation modules are split by ownership without changing the public surface |
| 5. Compatibility and graph | PASS | `SDK_API_COMPATIBILITY_REPORT.md`, `architecture_dependency_graph.md`, and `OWNERSHIP_LOCK.md` |
| 6. Dead code | PASS | `DEAD_CODE_REPORT.md`; compatibility aliases remain intentionally retained |
| 7. Performance | PASS | `PERFORMANCE_REGRESSION_REPORT.md`; deterministic local smoke checks show no regression signal |
| 8. Final validation | PASS (Linux) | Strict acceptance, both App coverage shards, the App coverage threshold, and all runnable Linux jobs pass; platform jobs require their native CI hosts |

## SDK test completion

The new SDK surface has explicit regression coverage in
`packages/infrastructure/network_sdk/test/network_v2_facade_test.dart`:

- 23 tests cover facade lifecycle idempotence/retry/stopping/disposal and
  owner-resource preservation.
- Domain routing covers Connection, Identity, Transfer, Realtime, and Relay
  adapters, including exact request forwarding, typed failure preservation, and
  owner event-stream identity.
- Command tracking covers capacity, duplicate registration, unknown and
  mismatched results, duplicate completion, explicit cancellation, and
  cancel-all behavior.
- Value/event coverage includes copied bounded payloads, exact and overflow
  limits, UTF-8 byte limits, stream IDs, diagnostics/environment assertions,
  event lanes/priorities, and public error-precedence fallbacks.

Validation result: `dart format` passed, `flutter analyze --no-pub` passed, and
the complete SDK suite passed **74/74 tests**. Strict Network V2 acceptance now
executes both SDK V2 test files and passed.

The plan's generic `dart analyze` command also passed. Generic `dart test` is
not the owner command for this Flutter package: it has no `package:test`
dependency and the package contract requires `flutter test --no-pub`; running
`dart test` therefore exits with the explicit missing-package diagnostic rather
than silently substituting a different runner.

## Repository gate evidence

`bash scripts/full_test.sh --no-bootstrap --with-coverage --serial` completed
with every selected runnable Linux job passing, including:

- front-quality, native-network-quality, sdk-dart-quality, and relay-quality;
- protocol-v2-contract, architecture-check, app-static-quality,
  workspace-core-quality, and workspace-features-quality;
- both App unit shards and the Android build after installing the pinned Rust
  toolchain's Android targets.

The two App coverage shards completed in 1330s and 1083s, and the coverage
threshold check passed. The local gate now clears HTTP(S) proxy variables only
for Flutter test processes so their loopback VM service is not sent through a
WSL proxy; dependency bootstrap and artifact downloads retain the caller's
proxy environment. The App timeout is 30 minutes by default because coverage
instrumentation is substantially slower in this WSL checkout.

## Remaining Risks

The following remain CI/environment follow-ups rather than silently waived
acceptance items:

- execute Windows, macOS, and iOS platform jobs on their native toolchains;
- run real Redis/MySQL cross-instance, physical-device lifecycle, and broader
  transport fault-injection coverage.

The following compatibility work remains intentionally deferred:

- retire public compatibility aliases only after the external-consumer
  migration inventory proves that removal is safe.

`git diff --check` and final worktree/diff review are required before handoff.
