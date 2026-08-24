> Last updated: 2026-08-23

# Network V2 Final Acceptance Report

Status: **PASS WITH LOCAL ENVIRONMENT GAP — runnable local gates, Stage A/B/C
evidence, and final GitHub CI pass; WSL aggregate coverage and deployment
evidence remain explicit follow-ups**

This report records the PR48 local audit, freeze, test-evidence, and validation
sequence on branch `agent/network-v2-final-20260819`. The frozen wire contract,
public Dart/Rust contracts, FFI ABI, and file-layout boundaries were not
changed. All new instrumentation is confined to independent test files; no
production test hook or observer was added.

`FINAL_CLOSURE_BASE_SHA: 926967e08ed2abb638bf13596fa4d25595c75da9`
`CODE_VALIDATION_HEAD: 2253282f3afa7dc64ff38e5604eb2f272518969b`
`CI_HEAD: 2253282f3afa7dc64ff38e5604eb2f272518969b`
`PR_HEAD_SHA: 2253282f3afa7dc64ff38e5604eb2f272518969b (code/CI head before this docs sync)`
`GitHub CI RUN: 32639926098 — all listed checks PASS for CI_HEAD`

## Required final-deliverable fields

```text
Architecture: COMPLETED — current App, Runtime lifecycle, Relay, and Transfer owners remain in place
Cutover: COMPLETED — Network V2 ownership and runnable cutover are complete; deployment/physical-device evidence remains host-dependent
Legacy Retirement: DEFERRED (non-blocking) — compatibility aliases remain until an external-consumer inventory authorizes removal
SDK Architecture Cleanup: COMPLETED
API Compatibility: PASS — no frozen public SDK or wire-contract change
Performance: PASS (local smoke only) — production benchmark is `DEFERRED — NON-BLOCKING`
Tests: PASS WITH ENVIRONMENT GAP — strict owner selectors, lifecycle tests, Stage C order/count evidence, workspace tests, concrete Relay integration, and final CI pass; the coverage-enabled App aggregate stalled in WSL
Platform CI: PASS — Android, Windows, macOS, iOS, Linux owner jobs, App coverage/static/unit shards, E2E, SDK, Relay, Protocol, and Architecture all passed for CI_HEAD
```

## Phase results

| Phase | Result | Evidence |
| --- | --- | --- |
| 0. Baseline | CONFIRMED | PR #48 baseline is `926967e08ed2abb638bf13596fa4d25595c75da9`; code validation and CI are bound to `2253282f3afa7dc64ff38e5604eb2f272518969b` |
| 1. Connectivity audit | CLOSED WHERE RUNNABLE | `CONNECTIVITY_STAGE_REPORT.md` records Stage A/B/C local evidence and the retained platform/deployment gaps |
| 2. Coordinator review | PASS (runnable owner gates) | `COORDINATOR_REVIEW.md`; the double-Resolve defect and stub-only confidence gap are closed |
| 3. Architecture freeze | PASS (runnable owner gates) | `FREEZE_GATE_REPORT.md`; protocol, ownership, and PathLease invariants remain frozen |
| 4. SDK migration | COMPLETED | V2 domain ports/adapters, App Shell owners, `RuntimeLifecycleState`, typed Rust Relay/Transfer ports, and ownership-scoped tests are present |
| 5. Compatibility and graph | PASS | `SDK_API_COMPATIBILITY_REPORT.md`, `architecture_dependency_graph.md`, and `OWNERSHIP_LOCK.md` |
| 6. Dead code | PASS WITH DEFERRED ALIASES | `DEAD_CODE_REPORT.md`; compatibility aliases remain intentionally retained |
| 7. Performance | PASS (local smoke) | `PERFORMANCE_REGRESSION_REPORT.md`; production benchmark is deferred and non-blocking |
| 8. Final validation | PASS WITH LOCAL ENVIRONMENT GAP | Strict acceptance, E2E memory/MySQL, workspace tests, concrete Relay integration, SDK/transport/FFI, app static/unit shards, and final platform CI pass; the coverage-enabled App aggregate stalled in WSL |

## Final-fix evidence

- `cargo test -p network-core 'connect::connectivity_attempt::tests::' --locked`:
  63/63 passed, including Stage A zero-control-call assertions, bounded active
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
- GitHub Actions run `32639926098`: every listed check passed for `CI_HEAD`,
  including app coverage/static/unit shards, Android/Windows/macOS/iOS,
  client-backend memory/MySQL, and all Rust/Go/Protocol/SDK/Architecture jobs.

## Coverage evidence

- The full aggregate reached and passed its front/native/SDK/Relay/protocol/
  workspace quality stages. Its App coverage shard did not expose a Flutter VM
  Service in WSL; no coverage PASS is claimed for that shard.
- The SDK, transport, native FFI, and app static/unit no-coverage selectors all
  passed independently.
- The final CI App coverage job passed and is labeled as CI evidence; it does
  not turn the WSL aggregate loading stall into a Linux local PASS.

## SDK test completion

The SDK surface retains explicit regression coverage in
`packages/infrastructure/network_sdk/test/`,
`packages/infrastructure/network_transport/test/`, and the native facade tests.
The strict selector and SDK/transport/FFI gates passed the runnable Dart/Rust
owner suites. Compatibility aliases remain deferred and non-blocking until an
external-consumer migration inventory authorizes removal.

## Remaining risks and environment evidence

- Physical-device lifecycle remains a follow-up even though the final
  Windows/macOS/iOS/Android CI build jobs passed.
- Run the focused App client coverage gate and aggregate full test where the
  Flutter VM Service is available; both reproduce a WSL startup gap here.
- Run real Redis/MySQL cross-instance, physical-device lifecycle, and broader
  transport fault-injection coverage for release acceptance.
- Stage C local evidence is complete in the independent connectivity test and
  existing RelayData owner tests. A multi-process deployment flow, physical
  devices, and cross-instance services remain release-environment evidence.

`git diff --check` passed for the code-validation head; this report is the
follow-up docs sync bound to the code/CI head above and does not change Draft
status.
