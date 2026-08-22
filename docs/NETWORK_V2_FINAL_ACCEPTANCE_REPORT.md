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

Validation base commit: `85663c93fd1881ad32a1924f6ca51623d6373640`; the final-fix
changes are captured in the subsequent functional commits on this branch.

## Required final-deliverable fields

```text
Architecture: COMPLETED — current App, Runtime lifecycle, Relay, and Transfer owners remain in place
Cutover: PARTIAL — runnable owner cutover is complete; native/client/deployment validation remains host-dependent
Legacy Retirement: DEFERRED (non-blocking) — compatibility aliases remain until an external-consumer inventory authorizes removal
SDK Architecture Cleanup: COMPLETED
API Compatibility: PASS — no frozen public SDK or wire-contract change
Performance: PASS (local smoke only) — production benchmark evidence is deferred and non-blocking for runnable owner gates
Tests: PARTIAL — strict owner selectors, workspace tests, and concrete Stage B integration pass; the coverage-enabled App aggregate stalled in WSL and native-platform/client-VM evidence remains host-dependent
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
| 8. Final validation | PASS WITH ENVIRONMENT GAP | Strict acceptance, workspace tests, concrete Relay integration, and front/backend/SDK coverage gates pass; the coverage-enabled App aggregate stalled in WSL and native platform jobs remain open |

## Final-fix evidence

- `cargo test -p network-core 'connect::connectivity_attempt::tests::' --locked`:
  24/24 passed, including Stage A zero-control-call assertions, one bounded
  active NOT_READY retry, and exact `Resolve → Offer → Reserve` ordering with
  one Resolve and one Offer, plus epoch-hint fencing of pre-control reuse.
- `cargo test -p network-relay --locked`: 39/39 passed.
- `cargo test -p network-relay --features test-support --test relay_control_client_integration --locked -- --test-threads=1`: 4/4 passed with real clients, authenticated Ready/presence, discovery, heartbeat, Offer forwarding, Answer routing, cleanup retries, and concurrent target isolation.
- `bash scripts/network_v2_acceptance.sh strict`: passed with an initial 17-case
  contract inventory containing 3 test-defined architecture-guard skips, then
  a final strict pass of all 17 cases; selected Rust/Go/Dart owner suites and
  the concrete integration selector also passed.
- `bash scripts/full_test.sh --no-bootstrap --with-coverage --serial`: attempted;
  front/native/SDK/Relay/protocol/workspace jobs passed, but the App Flutter
  shard stalled loading tests in WSL and the retry was stopped. This aggregate
  gate remains an environment gap, not a product PASS.

## Coverage evidence

- `bash scripts/front_coverage.sh`: 48 tests; 95.78% line coverage.
- `bash scripts/backend_coverage.sh`: Docker-backed MySQL/Redis run; 82.1%
  filtered Go line coverage.
- `bash scripts/sdk_coverage.sh`: 90.67% Dart and 90.81% Rust SDK line
  coverage.
- `CLIENT_FLUTTER_COVERAGE_TIMEOUT=2m bash scripts/client_coverage.sh
  --no-bootstrap`: not accepted; the Flutter VM Service did not become ready in
  WSL before the bounded timeout, and no client tests ran.

## SDK test completion

The SDK surface retains explicit regression coverage in
`packages/infrastructure/network_sdk/test/` and the native facade tests. The
strict selector and SDK coverage gate passed the runnable Dart/Rust owner
suites. Compatibility aliases remain deferred and non-blocking until an
external-consumer migration inventory authorizes removal.

## Remaining risks and environment evidence

- Execute `terminal-smoke-build`/Windows on a Windows host, and macOS/Xcode
  `macos-build`/`ios-build` on a macOS host with CocoaPods.
- Run the focused App client coverage gate and aggregate full test where the
  Flutter VM Service is available; both reproduce a WSL startup gap here.
- Run real Redis/MySQL cross-instance, physical-device lifecycle, and broader
  transport fault-injection coverage for release acceptance.
- Stage C is complete only to the executable eligibility-predicate coverage;
  the complete local Direct-failure → READY/E2EE/resource-eligible →
  reservation/data integration flow remains deferred.

`git diff --check` passed, and the functional commits contain no unrelated
staged or generated changes; this report records the committed validation
state.
