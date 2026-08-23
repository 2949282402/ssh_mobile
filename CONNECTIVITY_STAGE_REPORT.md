> Last updated: 2026-08-23

# Network V2 Connectivity Stage Audit

Status: **Stage A/B/C local evidence PASS; external deployment and platform
evidence remain explicitly out of scope**

This report keeps the original read-only audit scope while recording the PR48
local closure evidence. `PR48` is an internal workstream label only; the
canonical document name is **Network V2 Connectivity Stage Audit**.

`FINAL_CLOSURE_BASE_SHA: 926967e08ed2abb638bf13596fa4d25595c75da9`
`LOCAL_VALIDATION_HEAD: 6441a0d6415bb2df2c897afec922f82056867489`

## Findings and disposition

| Finding | Disposition | Evidence |
| --- | --- | --- |
| Stage A could accept a direct path without checking the requested capability | Resolved | `stage_a_reuses_only_a_compatible_ready_direct_path` and `stage_a_compatible_ready_direct_path_makes_no_control_plane_calls` |
| Stage A forbidden control-plane calls were not counted | Resolved | The compatible-ready Stage A test asserts zero Resolve, Offer, and Reserve calls |
| Healthy Relay reuse could emit Offer before returning the existing session | Resolved | `reused_session_uses_route_profile_and_emits_connected` reuses the healthy Relay path before control and asserts zero Resolve/Offer/Reserve calls; `take_obsolete_closes_old_when_epoch_changed` retains the new-epoch close-old guard |
| Production Stage B issued Resolve → Resolve → Offer | Resolved | `RelayControlClient::begin_connectivity_attempt` performs one authoritative Resolve, holds the narrow target-binding gate through Offer enqueue, and returns the same Resolve snapshot to the coordinator |
| Rust owner tests could pass through a control-plane stub without exercising a socket | Resolved | `network-relay/tests/relay_control_client_integration.rs` uses two concrete `RelayControlClient`s and a loopback `/v2/control` WebSocket server |
| Full Direct-failure → Relay eligibility flow | Resolved for local Stage C evidence | The independent connectivity test records `Resolve → Offer → Direct failure → Reserve`, asserts `Resolve=1`, `Offer=1`, `Reserve=1`, and reuses RelayData owner tests for pairing, opaque payload/ACK, and close coverage |

## Current runnable evidence

- `cargo test -p network-core 'connect::connectivity_attempt::tests::' --locked`:
  61/61 passed, including Stage A zero-control reuse, bounded active
  `NOT_READY` retry, cancellation/timeout reconnect isolation, and the
  independent Stage C order/count evidence.
- `cargo test -p network-relay --locked`: 45/45 passed, including tracker
  lease/drop, stale-owner cleanup, and RelayData owner tests.
- The concrete integration selector passed 7/7 with real control clients and
  target-isolated cleanup.
- `bash scripts/network_v2_acceptance.sh strict` passed on the final retry:
  all 17 contract checks completed (with the documented test-defined skips),
  and the selected Rust/Go/Dart owner suites passed. A transient realtime
  environment-order race was reproduced once and cleared by the serial
  realtime selector; it did not reproduce on the final strict run.

## Remaining evidence

The Stage C evidence is intentionally test-only: it lives in
`native/network_core/crates/network-core/src/tests/connectivity_attempt.rs` and
does not add observers, hooks, or `#[cfg(test)]` fields to production modules.
Real Redis/MySQL cross-instance behavior, physical-device lifecycle behavior,
and native platform CI remain environment-dependent and are recorded in the
final acceptance report rather than inferred from the local owner tests.
