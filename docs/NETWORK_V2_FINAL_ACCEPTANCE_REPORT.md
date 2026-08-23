> Last updated: 2026-08-23

# Network V2 Final Acceptance Report

Status: **PASS WITH ENVIRONMENT GAP — runnable local gates and Stage A/B/C
evidence pass; WSL App coverage and native-platform/deployment evidence remain
explicit follow-ups**

This report records the PR48 local audit, freeze, test-evidence, and validation
sequence on branch `agent/network-v2-final-20260819`. The frozen wire contract,
public Dart/Rust contracts, FFI ABI, and file-layout boundaries were not
changed. All new instrumentation is confined to independent test files; no
production test hook or observer was added.

`FINAL_CLOSURE_BASE_SHA: 926967e08ed2abb638bf13596fa4d25595c75da9`
`LOCAL_VALIDATION_HEAD: 6441a0d6415bb2df2c897afec922f82056867489`

`GitHub CI: NOT RE-RUN for LOCAL_VALIDATION_HEAD; any prior required CI result
belongs only to FINAL_CLOSURE_BASE_SHA. No push, PR-body, or Draft/Ready change
was performed.`

## Required final-deliverable fields

```text
Architecture: COMPLETED — current App, Runtime lifecycle, Relay, and Transfer owners remain in place
Cutover: PARTIAL — runnable owner cutover is complete; native/client/deployment validation remains host-dependent
Legacy Retirement: DEFERRED (non-blocking) — compatibility aliases remain until an external-consumer inventory authorizes removal
SDK Architecture Cleanup: COMPLETED
API Compatibility: PASS — no frozen public SDK or wire-contract change
Performance: PASS (local smoke only) — production benchmark is `DEFERRED — NON-BLOCKING`
Tests: PASS WITH ENVIRONMENT GAP — strict owner selectors, lifecycle tests, Stage C order/count evidence, workspace tests, and concrete Relay integration pass; the coverage-enabled App aggregate stalled in WSL and native-platform/client-VM evidence remains host-dependent
```

## Phase results

| Phase | Result | Evidence |
| --- | --- | --- |
| 0. Baseline | CONFIRMED | PR #48 baseline is `926967e08ed2abb638bf13596fa4d25595c75da9`; local validation is bound to `6441a0d6415bb2df2c897afec922f82056867489` |
| 1. Connectivity audit | CLOSED WHERE RUNNABLE | `CONNECTIVITY_STAGE_REPORT.md` records Stage A/B/C local evidence and the retained platform/deployment gaps |
| 2. Coordinator review | PASS (runnable owner gates) | `COORDINATOR_REVIEW.md`; the double-Resolve defect and stub-only confidence gap are closed |
| 3. Architecture freeze | PASS (runnable owner gates) | `FREEZE_GATE_REPORT.md`; protocol, ownership, and PathLease invariants remain frozen |
| 4. SDK migration | COMPLETED | V2 domain ports/adapters, App Shell owners, `RuntimeLifecycleState`, typed Rust Relay/Transfer ports, and ownership-scoped tests are present |
| 5. Compatibility and graph | PASS | `SDK_API_COMPATIBILITY_REPORT.md`, `architecture_dependency_graph.md`, and `OWNERSHIP_LOCK.md` |
| 6. Dead code | PASS WITH DEFERRED ALIASES | `DEAD_CODE_REPORT.md`; compatibility aliases remain intentionally retained |
| 7. Performance | PASS (local smoke) | `PERFORMANCE_REGRESSION_REPORT.md`; production benchmark is deferred and non-blocking |
| 8. Final validation | PASS WITH ENVIRONMENT GAP | Strict acceptance, E2E memory/MySQL, workspace tests, concrete Relay integration, SDK/transport/FFI, and app static/unit shards pass; the coverage-enabled App aggregate stalled in WSL and native platform jobs remain open |

## Final-fix evidence

- `cargo test -p network-core 'connect::connectivity_attempt::tests::' --locked`:
  61/61 passed, including Stage A zero-control-call assertions, bounded active
  `NOT_READY` retry, cancellation/timeout reconnect tests, and independent
  Stage C `Resolve → Offer → Direct failure → Reserve` evidence with exact
  Resolve/Offer/Reserve counts.
- `cargo test -p network-relay --locked`: 45/45 passed, including RelayData
  owner coverage.
- `cargo test -p network-relay --features test-support --test relay_control_client_integration --locked -- --test-threads=1`: 7/7 passed with real clients, authenticated Ready/presence, discovery, heartbeat, Offer forwarding, Answer routing, cleanup retries, and concurrent target isolation.
- `bash scripts/network_v2_acceptance.sh strict`: passed with an initial 17-case
  contract inventory containing 3 test-defined architecture-guard skips, then
  a final strict pass of all 17 cases; selected Rust/Go/Dart owner suites and
  the concrete integration selector also passed.
- `bash scripts/full_test.sh --no-bootstrap --with-coverage --serial`: attempted;
  front/native/SDK/Relay/protocol/workspace/app-static jobs passed, but the App
  coverage shard remained at `loading` without a Flutter VM Service in WSL and
  was stopped. This aggregate gate remains an environment gap, not a product
  PASS.
- `CLIENT_BACKEND_E2E_STORAGE=memory bash scripts/client_backend_e2e.sh strict`
  and the MySQL equivalent: both passed.
- Exact protocol commands (`protoc`, `relay_v2_contract.sh`, `buf lint`, and
  scoped `buf breaking`): passed.

## Coverage evidence

- The full aggregate reached and passed its front/native/SDK/Relay/protocol/
  workspace quality stages. Its App coverage shard did not expose a Flutter VM
  Service in WSL; no coverage PASS is claimed for that shard.
- The SDK, transport, native FFI, and app static/unit no-coverage selectors all
  passed independently.
- Native Windows PowerShell 7 or CI may provide separate client coverage
  evidence for this environment gap; such evidence must remain labeled as
  Windows/CI and cannot turn the WSL result into a Linux PASS.

## SDK test completion

The SDK surface retains explicit regression coverage in
`packages/infrastructure/network_sdk/test/`,
`packages/infrastructure/network_transport/test/`, and the native facade tests.
The strict selector and SDK/transport/FFI gates passed the runnable Dart/Rust
owner suites. Compatibility aliases remain deferred and non-blocking until an
external-consumer migration inventory authorizes removal.

## Remaining risks and environment evidence

- Execute `terminal-smoke-build`/Windows on a Windows host, and macOS/Xcode
  `macos-build`/`ios-build` on a macOS host with CocoaPods.
- Run the focused App client coverage gate and aggregate full test where the
  Flutter VM Service is available; both reproduce a WSL startup gap here.
- Run real Redis/MySQL cross-instance, physical-device lifecycle, and broader
  transport fault-injection coverage for release acceptance.
- Stage C local evidence is complete in the independent connectivity test and
  existing RelayData owner tests. A multi-process deployment flow, physical
  devices, and cross-instance services remain release-environment evidence.

`git diff --check` passed for the code-validation head; the docs/memory sync is
local-only and no remote PR or CI state was changed.
