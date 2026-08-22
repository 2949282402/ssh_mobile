> Last updated: 2026-08-21

# PR49 Architecture Freeze Gate

This gate records the decision between Network V2 acceptance and SDK
architecture cleanup. It is based on branch `agent/network-v2-final-20260819`
at baseline commit `929a711cbf82de26a24f9aa4f8fa18c707c01f38`.

## Gate decision

| Gate | Result | Evidence |
| --- | --- | --- |
| Network Contract | PASS | `docs/NETWORK_V2_PR48_BASELINE.md`, the eight Phase 1 audits, and `COORDINATOR_REVIEW.md` |
| Ownership | PASS | `OWNERSHIP_LOCK.md`; PeerSupervisor remains the connectivity owner and inbound operations bind to physical carriers |
| Protocol | PASS | `bash scripts/network_v2_acceptance.sh strict` passed: 17 Python checks, 3 documented skips, all selected Rust/Go/Dart owner suites, and the final strict matrix check |
| Allowed Cleanup | YES | Network V2 acceptance is green; Phase 4 SDK cleanup may begin under the migration strategy below |

## Acceptance evidence

- Strict protocol and matrix checks: 17 passed, 3 skipped because they require
  external service or platform coverage.
- Rust selected suites passed, including capability-aware connectivity,
  PathLease/carrier binding, candidate-cache invalidation, delivery, stream,
  relay, protocol, and FFI ABI coverage.
- Go Relay strict selectors passed, including fail-closed nonce handling,
  revocation admission, credential expiry, configured presence TTL, and role /
  token binding.
- `network_transport` event-mux tests passed 8/8; `network_sdk` V2 contract
  tests passed 8/8; native facade tests passed 17/17.
- `git diff --check` passed after the Phase 2 integration.

## Frozen Network V2 invariants

- PeerSupervisor is the sole connectivity-attempt owner.
- Stage A reuses only a fresh, capability-compatible direct path; Stage B
  orders Resolve → Offer → Direct probing within the four-second window before
  Relay reservation; no transparent migration is introduced.
- Candidate cache freshness is monotonic and invalidated by runtime epoch and
  configured Ready TTL changes.
- PathLease is the only operation lease; inbound Stream and Transfer work is
  bound to the physical carrier that delivered it.
- Relay authentication, role/token admission, nonce replay protection, expiry,
  and revocation fail closed.
- Native stop/dispose ordering, isolate exit, bounded terminal history, and C
  buffer ownership remain part of the accepted FFI contract.

## Deferred architecture risks

The following are explicitly deferred to Phase 4 and are not protocol changes:

- Overlapping Dart V2 boundary and compatibility aliases.
- Ownership of the injected `NetworkV2CommandPort` lifecycle.
- Domain extraction boundaries around native service, RuntimeState, relay, and
  transfer code.
- Relay/Transfer typed interfaces needed to avoid a dependency cycle.

Each cleanup must follow: define interface → move implementation → update
callers → add regression tests → remove the old path. No SDK cleanup may alter
the frozen wire contract or introduce transparent connection migration.

## Known environment limits

The repository-wide baseline records external fetch/toolchain failures in the
full gate (Docker Hub token EOF, `vuln.go.dev` fetch EOF, and the protocol Dart
dependency handshake). Real Redis/MySQL cross-instance runs and physical mobile
lifecycle runs also remain environment-dependent. These limits do not change
the local strict Network V2 acceptance result; they remain required evidence
for the final Phase 8 merge decision.

**FREEZE_GATE: PASS**

Network V2 cleanup is authorized. Protocol changes, ownership broadening, and
mechanical SDK file splitting remain out of scope.
