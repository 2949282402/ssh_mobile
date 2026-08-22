> Last updated: 2026-08-22

# Network V2 Architecture Freeze Gate

This is the canonical freeze-gate report. `PR48` (baseline) and `PR49`
(hardening/final-fix workstream) are internal labels, not repository metadata.

Branch: `agent/network-v2-final-20260819`

Baseline commit: `929a711cbf82de26a24f9aa4f8fa18c707c01f38`

Validation base commit: `b61347cbbb062a079ef1e6daa7f82c50123a799f` (working tree
changes are intentionally uncommitted)

## Gate decision

| Gate | Result | Evidence |
| --- | --- | --- |
| Network Contract | PASS | Frozen protocol fixtures, acceptance matrix, and owner selectors |
| Ownership | PASS | `OWNERSHIP_LOCK.md`; PeerSupervisor remains the connectivity owner and inbound operations bind to physical carriers |
| Protocol | PASS | `bash scripts/network_v2_acceptance.sh strict` passed, including the concrete Resolve → Offer integration selector |
| Allowed Cleanup | COMPLETED | Phase 4 SDK/domain cleanup is already present; only compatibility-alias retirement remains deferred |

## Acceptance evidence

- Strict contract checks: 17 passed, with 3 documented external/platform skips.
- Connectivity owner selector: 24/24 tests passed, including capability-aware
  Stage A, zero-call Stage A reuse, one-Resolve Stage B ordering, bounded
  active NOT_READY retry, and Stage C eligibility predicates.
- Relay v2 unit/golden selector: 37/37 tests passed. The concrete integration
  selector passed 1/1 with two real `RelayControlClient` instances and a local
  authenticated `/v2/control` WebSocket server.
- The final Linux mirror passed all 12 runnable jobs in 731 seconds. Its script
  explicitly skipped terminal-smoke, Windows, macOS, iOS, and daily App
  coverage jobs because they require separate hosts or the periodic gate.
- Domain coverage gates passed for front (95.78% lines), backend (82.1% filtered
  Go lines), and SDK (84.46% Dart / 84.32% Rust lines). The focused App client
  coverage gate was attempted with a bounded 2-minute VM-service wait and did
  not start tests in this WSL environment.

## Frozen Network V2 invariants

- PeerSupervisor is the sole connectivity-attempt owner.
- Stage A handles capability-compatible Direct reuse and fresh/configured Direct
  candidates; before Stage B, any other healthy ready path (including Relay) is
  also reused. Only when reuse and Direct both fail does Stage B enter one
  authoritative `Resolve → Offer` transaction using the same Resolve snapshot
  for candidate setup; Stage C reserves Relay only after Direct failure and all
  policy/budget gates pass.
- Candidate cache freshness is monotonic and invalidated by runtime epoch and
  configured Ready TTL changes.
- PathLease is the only operation lease; inbound Stream and Transfer work is
  bound to the physical carrier that delivered it.
- Relay authentication, role/token admission, nonce replay protection, expiry,
  and revocation fail closed.
- Native stop/dispose ordering, isolate exit, bounded terminal history, and C
  buffer ownership remain part of the accepted FFI contract.

## Phase 4 disposition

The following cleanup is complete and did not alter the frozen wire contract:

- overlapping Dart V2 boundaries and compatibility aliases remain documented;
- injected `NetworkV2CommandPort` ownership remains explicit;
- native service, RuntimeState, Relay, and Transfer boundaries use the current
  domain owners and typed ports;
- Relay/Transfer extraction avoids a dependency cycle.

Compatibility aliases remain deferred until an external-consumer migration
inventory authorizes their removal.

## Known environment limits

Windows desktop, macOS/Xcode, iOS/CocoaPods, physical mobile lifecycle, and
real Redis/MySQL cross-instance evidence require their native or deployment
hosts. The focused App client coverage gate also requires a working Flutter VM
Service in this environment. These are explicit follow-ups, not local product
failures.

**FREEZE_GATE: PASS FOR RUNNABLE OWNER GATES**
