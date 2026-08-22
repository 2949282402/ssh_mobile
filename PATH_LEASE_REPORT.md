> Last updated: 2026-08-21

# PathHandle / PathLease Audit

Status: BLOCKED

Scope: `connect/path.rs`, `ready_index.rs`, `delivery.rs`, `transfer.rs`, and
`stream.rs`. This was a read-only audit; no implementation files were changed.

## Findings

- PASS: `PathHandle` represents physical path identity and `PathLease` carries
  an explicit operation lifetime (`connect/path.rs:606-635,892-968`).
- PASS: Lease accounting uses an independent `leases` field; `Arc::strong_count`
  is used only for weak-index cleanup and is not treated as a lease count
  (`connect/path.rs:674,795-859,1002,1080`).
- PASS: `DeliverySendAttempt` represents one message send attempt and prevents
  stale attempt results from settling a newer attempt
  (`delivery.rs:259-268,646-740,791-834`).
- PASS: An outbound Stream holds one lease from StreamOpen through StreamClose
  without transparent migration (`stream.rs:395-415,532-578,1165-1439`).
- BUG: `handle_incoming_file_after_offer` performs a complete inbound transfer
  over QUIC streams without acquiring/holding a `PathLease`
  (`transfer.rs:752-974`). Drain or hard revoke can therefore close the path
  without a lease-bound transfer lifetime.
- BUG: `bind_inbound_attempt` reacquires the current best path instead of
  binding the physical path that carried the StreamOpen
  (`stream.rs:1146-1163,1477-1572`). With Direct and Relay coexisting, a Relay
  stream can be bound to Direct.
- ARCHITECTURE RISK: Relay transfer sends retain `_lease` but do not carry the
  selected physical Relay path into the send operation
  (`transfer.rs:238-262`); path replacement can separate I/O from lease
  lifetime.
- TEST GAP: `ReadySessionIndex` lacks integration coverage for draining,
  non-acquirable, closed, and re-acquired paths
  (`connect/ready_index.rs:48-70,149-272`). `PathProjection::is_alive` can still
  report true for Draining (`connect/path.rs:651-653`).

## Required Changes

- Pass the actual inbound transfer `PathHandle` or acquired lease and retain it
  through terminal state.
- Bind inbound streams to the physical path identity from StreamOpen; test
  Direct/Relay coexistence, revoke, and close.
- Bind Relay transfer I/O to the selected physical path rather than rereading a
  global current path.
- Add ReadySessionIndex draining/close/reacquisition integration tests and make
  acquirability explicit.

## Risk

The unit suite passes but inbound path identity and transfer lease lifetime are
not proven. A path can drain or be revoked while an operation is still using
it, or a stream can be associated with the wrong carrier.
