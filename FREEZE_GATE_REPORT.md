> Last updated: 2026-08-23

# Network V2 Architecture Freeze Gate

This is the canonical freeze-gate report. `PR48` is an internal workstream
label, not repository metadata.

Branch: `agent/network-v2-final-20260819`

Baseline commit: `926967e08ed2abb638bf13596fa4d25595c75da9`

`FINAL_CLOSURE_BASE_SHA: 926967e08ed2abb638bf13596fa4d25595c75da9`
`LOCAL_VALIDATION_HEAD: 6441a0d6415bb2df2c897afec922f82056867489`

## Gate decision

| Gate | Result | Evidence |
| --- | --- | --- |
| Network Contract | PASS | Frozen protocol fixtures, acceptance matrix, and owner selectors |
| Ownership | PASS | `OWNERSHIP_LOCK.md`; PeerSupervisor remains the connectivity owner and inbound operations bind to physical carriers |
| Protocol | PASS | Strict acceptance plus `protoc`, Relay V2 contract, `buf lint`, and scoped `buf breaking` passed |
| Connectivity Stage A/B/C | PASS | Focused lifecycle tests and independent Stage C order/count evidence passed |
| Allowed Cleanup | COMPLETED | Phase 4 SDK/domain cleanup is already present; only compatibility-alias retirement remains deferred |

## Acceptance evidence

- Strict contract checks: the final strict run completed all 17 checks with
  the documented test-defined skips.
- Connectivity owner selector: 61/61 tests passed, including capability-aware
  Stage A, zero-call reuse, bounded active `NOT_READY` retry, cancellation and
  timeout reconnect isolation, and Stage C `Resolve → Offer → Direct failure →
  Reserve` counts/order.
- Relay v2 unit/golden selector: 45/45 tests passed. The concrete integration
  selector passed 7/7 with real control clients and target-isolated cleanup.
- `cargo fmt`, workspace check/clippy/tests, Go fmt/test/race/vet/vuln, SDK,
  transport, native FFI, and app static/no-coverage shards all passed locally.
- Memory/MySQL client-backend E2E both passed. The coverage-enabled aggregate
  reached the App Flutter shard but remained at `loading` without a VM Service
  in WSL; it is an environment gap, not a PASS.

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

Compatibility aliases remain deferred, and their retirement is non-blocking,
until an external-consumer migration inventory authorizes their removal.

## Known environment limits

Windows desktop, macOS/Xcode, iOS/CocoaPods, physical mobile lifecycle, and
real Redis/MySQL cross-instance evidence require their native or deployment
hosts. The focused and aggregate App coverage gates require a working Flutter
VM Service; both expose the WSL startup stall here. A native Windows PowerShell
7 or CI run may provide separate coverage evidence for this environment gap,
but cannot be relabeled as WSL/Linux PASS.

**FREEZE_GATE: PASS FOR RUNNABLE OWNER GATES; COVERAGE AGGREGATE ENVIRONMENT GAP**
