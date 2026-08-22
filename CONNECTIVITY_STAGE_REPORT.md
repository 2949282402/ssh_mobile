> Last updated: 2026-08-22

# Network V2 Connectivity Stage Audit

Status: **Phase 1 historical findings closed where runnable; Stage A/B owner
gates pass; Stage C remains predicate-only**

This report keeps the original read-only audit scope while recording the final
fix round. `PR48` and `PR49` are internal workstream labels only; the canonical
document name is **Network V2 Connectivity Stage Audit**.

## Findings and disposition

| Finding | Disposition | Evidence |
| --- | --- | --- |
| Stage A could accept a direct path without checking the requested capability | Resolved | `stage_a_reuses_only_a_compatible_ready_direct_path` and `stage_a_compatible_ready_direct_path_makes_no_control_plane_calls` |
| Stage A forbidden control-plane calls were not counted | Resolved | The compatible-ready Stage A test asserts zero Resolve, Offer, and Reserve calls |
| Healthy Relay reuse could emit Offer before returning the existing session | Resolved | `reused_session_uses_route_profile_and_emits_connected` reuses the healthy Relay path before control and asserts zero Resolve/Offer/Reserve calls; `take_obsolete_closes_old_when_epoch_changed` retains the new-epoch close-old guard |
| Production Stage B issued Resolve → Resolve → Offer | Resolved | `RelayControlClient::begin_connectivity_attempt` performs one authoritative Resolve, holds the narrow target-binding gate through Offer enqueue, and returns the same Resolve snapshot to the coordinator |
| Rust owner tests could pass through a control-plane stub without exercising a socket | Resolved | `network-relay/tests/relay_control_client_integration.rs` uses two concrete `RelayControlClient`s and a loopback `/v2/control` WebSocket server |
| Full Direct-failure → Relay eligibility flow | Still open | Stage C has predicate coverage, but no complete local flow proves Direct failure, READY/E2EE/resource eligibility, reservation, and Relay data admission together |

## Current runnable evidence

- `cargo test -p network-core 'connect::connectivity_attempt::tests::' --locked`:
  24/24 passed, including one bounded active NOT_READY retry, exact
  `Resolve → Offer → Reserve` ordering, and the one Resolve/Offer call-count
  assertion.
- `cargo test -p network-relay --locked`: 37/37 passed.
- The concrete integration selector passed 1/1 and the server recorded exactly
  `Resolve → Offer` for the attempt.
- `bash scripts/network_v2_acceptance.sh strict` passed: 17 contract checks,
  3 documented environment skips, the selected Rust/Go/Dart owner suites, and
  the concrete integration selector.

## Remaining evidence

Stage C remains a deliberate predicate-only boundary in this working tree.
Real Redis/MySQL cross-instance behavior, physical-device lifecycle behavior,
and native platform CI remain environment-dependent and are recorded in the
final acceptance report rather than inferred from the local owner tests.
