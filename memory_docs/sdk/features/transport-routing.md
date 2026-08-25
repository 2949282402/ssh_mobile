> Last updated: 2026-08-25

# Transport and Routing

`PeerSupervisor` owns mutable peer connectivity and `PeerPathManager` owns the
concrete Direct/Relay carriers. Features request business capabilities through
typed Dart contracts; they do not select sockets, routes, or protocol
implementations directly. A selected operation borrows a `PathLease` and
releases that lease when the operation ends.

| Carrier | Topology | Current role |
| --- | --- | --- |
| QUIC | Direct | Authenticated primary reliable carrier and stream transport |
| TCP | Direct | Authenticated generic reliable-message carrier |
| WebSocket | Direct | Authenticated generic reliable-message carrier |
| WSS /v2/control | Relay | Control plane (auth/heartbeat/discovery/resolve/signaling/reservation) |
| WSS /v2/relay/{id} | Relay | Reservation-scoped opaque encrypted data plane (RelayDataFrame) |
| UDP | Direct | Unreliable datagrams only |
| WebRTC | Direct or ICE Relay | Native Realtime Session route |

Routing invariants:

- Topology and transport are separate metadata.
- Peer Trust and route authorization are separate from Discovery and Relay
  enrollment. A Direct candidate is eligible only when the peer's persisted
  authorization permits `localDirect`; a Relay candidate is eligible only when
  peer Relay authorization, local enrollment/configuration, remote capability,
  and native route availability all pass. Relay disconnect never revokes peer
  trust or changes this authorization.
- A carrier is authenticated before admission to a ConnectionSession and
  publication by the owning `PeerPathManager`.
- Reliable Delivery, Transfer, and Stream operations ask the path manager for a
  compatible lease rather than branching on a concrete transport.
- UDP is not eligible for acknowledged, ordered, or file-delivery semantics.
- A ConnectionSession is 1:1 with its transport connection (design §18): it is
  created fresh with a new SessionId + new Noise root on every new connection
  and destroyed on transport loss. There is no route migration and no
  session-identity / crypto-root continuity across connections.
- Business state is the only cross-connection continuity (design §19-20):
  Delivery recovers by MessageId, Transfer resumes by transfer_id +
  confirmed_offset. A peer runtime restart or transport loss simply triggers a
  new Resolve → new Connection → new ConnectionSession; SSH/WebRTC build new ConnectionSessions
  (no transparent recovery).

- `E2eePolicy::Required` creates fresh application crypto for each new
  connection. `E2eePolicy::Disabled` is identity-only Direct and is rejected
  for Relay.
- Stage A uses fresh cached/configured Direct candidates and can reuse an
  already healthy, capability-compatible path before opening the control
  transaction. When a new or replacement transport is required, Stage B
  performs authoritative Resolve→Offer with a fixed four-second Direct window.
  Stage C reserves Relay only after READY, Direct failure, capability
  compatibility, Required E2EE, and budget checks; a reusable path must not emit
  an unsolicited target-less Offer.

- Direct candidate races use `(candidate_id, endpoint, generation)` as the attempt key; TCP and WebSocket race concurrently when the route supports WebSocket, and a late Answer candidate can join before the Direct deadline.
- Relay Data reservations use a one-shot `Ready` per pair. Replacing or disconnecting either side closes the old pair and requires a fresh Connect → Ready handshake.

Implementation entry points:

- [Rust Connection model](../../../native/network_core/crates/network-core/src/connection.rs)
- [Rust Session owner](../../../native/network_core/crates/network-core/src/session.rs)
- [Rust peer routing](../../../native/network_core/crates/network-core/src/peer.rs)
- [Dart transport facade](../../../packages/infrastructure/network_transport/README.md)
- [Go Relay boundary](../../../relay/README.md)

Detailed rationale:

- [Path quality and migration ADR](../../../docs/adr/ADR-014-path-quality-and-migration.md)
- [Generic Connection ADR](../../../docs/adr/ADR-019-generic-connection-layer.md)
- [Generic Session routes ADR](../../../docs/adr/ADR-027-generic-session-routes.md)
- [Forward-secret Session E2EE ADR](../../../docs/adr/ADR-028-forward-secret-session-e2ee.md)
