> Last updated: 2026-08-22

# Network V2 Final Acceptance Report

Status: **PASS for runnable Linux owner gates and the Stage B final fix —
native-platform, client-VM, and deployment evidence remain explicit
follow-ups**

This report records the Network V2 audit, freeze, SDK migration, final-fix, and
validation sequence on branch `agent/network-v2-final-20260819`. The frozen wire
contract and public Dart/FFI SDK surface were not changed. The additive
`ConnectivityAttemptStart`/`begin_connectivity_attempt` symbols are internal
Rust `network-relay` adapter APIs used by `network-core`, not public SDK entry
points. `PR48` (baseline) and `PR49`
(hardening/final-fix workstream) are internal labels only; canonical document
names use the `Network V2` titles and stable filenames in this repository.

Validation base commit: `b61347cbbb062a079ef1e6daa7f82c50123a799f` with the
final-fix changes intentionally uncommitted in the working tree.

## Required final-deliverable fields

```text
Architecture: COMPLETED — current App, Runtime lifecycle, Relay, and Transfer owners remain in place
Cutover: PARTIAL — runnable owner cutover is complete; native/client/deployment validation remains host-dependent
Legacy Retirement: DEFERRED — compatibility aliases remain until an external-consumer inventory authorizes removal
SDK Architecture Cleanup: COMPLETED
API Compatibility: PASS — no frozen public SDK or wire-contract change
Performance: PASS (local smoke only) — production benchmark evidence remains pending
Tests: PASS — runnable Linux mirror, strict owner selectors, and concrete Stage B integration; native-platform/client-VM evidence remains host-dependent
```

## Phase results

| Phase | Result | Evidence |
| --- | --- | --- |
| 0. Baseline | HISTORICAL | `docs/NETWORK_V2_PR48_BASELINE.md` records commit `929a711` and its known gaps |
| 1. Eight audits | CLOSED WHERE RUNNABLE | The audit files remain historical snapshots; `CONNECTIVITY_STAGE_REPORT.md` records the Stage B and Stage A closure and the retained Stage C gap |
| 2. Coordinator review | PASS (runnable owner gates) | `COORDINATOR_REVIEW.md`; the double-Resolve defect and stub-only confidence gap are closed |
| 3. Architecture freeze | PASS (runnable owner gates) | `FREEZE_GATE_REPORT.md`; protocol, ownership, and PathLease invariants remain frozen |
| 4. SDK migration | COMPLETED | V2 domain ports/adapters, App Shell owners, `RuntimeLifecycleState`, typed Rust Relay/Transfer ports, and ownership-scoped tests are present |
| 5. Compatibility and graph | PASS | `SDK_API_COMPATIBILITY_REPORT.md`, `architecture_dependency_graph.md`, and `OWNERSHIP_LOCK.md` |
| 6. Dead code | PASS WITH DEFERRED ALIASES | `DEAD_CODE_REPORT.md`; compatibility aliases remain intentionally retained |
| 7. Performance | PASS (local smoke) | `PERFORMANCE_REGRESSION_REPORT.md`; Stage C and production performance claims remain qualified |
| 8. Final validation | PASS (Linux/runnable selectors) | Strict acceptance, concrete Relay integration, full Linux mirror, and front/backend/SDK coverage gates pass; App client VM and native platform jobs remain open |

## Final-fix evidence

- `cargo test -p network-core 'connect::connectivity_attempt::tests::' --locked`:
  24/24 passed, including Stage A zero-control-call assertions, one bounded
  active NOT_READY retry, and exact `Resolve → Offer → Reserve` ordering with
  one Resolve and one Offer, plus epoch-hint fencing of pre-control reuse.
- `cargo test -p network-relay --locked`: 37/37 passed.
- `cargo test -p network-relay --features test-support --test relay_control_client_integration --locked -- --test-threads=1`: 1/1 passed with two real clients, authenticated Ready/presence, discovery, heartbeat, Offer forwarding, and Answer routing.
- `bash scripts/network_v2_acceptance.sh strict`: passed with 17 contract checks,
  3 documented skips, selected Rust/Go/Dart owner suites, and the concrete
  integration selector.
- `bash scripts/full_test.sh --no-bootstrap --no-coverage --serial`: passed all
  12 runnable Linux jobs in 731 seconds; its terminal-smoke, Windows, macOS,
  and iOS jobs were explicitly skipped by the script.

## Coverage evidence

- `bash scripts/front_coverage.sh`: 48 tests; 95.78% line coverage.
- `bash scripts/backend_coverage.sh`: Docker-backed MySQL/Redis run; 82.1%
  filtered Go line coverage.
- `bash scripts/sdk_coverage.sh`: 84.46% Dart and 84.32% Rust SDK line
  coverage.
- `CLIENT_FLUTTER_COVERAGE_TIMEOUT=2m bash scripts/client_coverage.sh
  --no-bootstrap`: not accepted; the Flutter VM Service did not become ready in
  WSL before the bounded timeout, and no client tests ran.

## SDK test completion

The SDK surface retains explicit regression coverage in
`packages/infrastructure/network_sdk/test/` and the native facade tests. The
strict selector and SDK coverage gate passed the runnable Dart/Rust owner
suites. Compatibility aliases remain until an external-consumer migration
inventory authorizes removal.

## Remaining risks and environment evidence

- Execute `terminal-smoke-build`/Windows on a Windows host, and macOS/Xcode
  `macos-build`/`ios-build` on a macOS host with CocoaPods.
- Run the focused App client coverage gate where the Flutter VM Service is
  available; the Linux mirror intentionally leaves this periodic job skipped.
- Run real Redis/MySQL cross-instance, physical-device lifecycle, and broader
  transport fault-injection coverage for release acceptance.
- Stage C still has predicate coverage rather than a complete local
  Direct-failure → READY/E2EE/resource-eligible → reservation/data integration
  flow.

`git diff --check` passed, and the final worktree/diff review found no
unrelated staged or generated changes; the working tree remains intentionally
uncommitted for handoff.
