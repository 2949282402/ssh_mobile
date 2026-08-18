> Last updated: 2026-08-16

# Transport and Routing

Rust selects and owns concrete carriers behind a logical Session. Features
request capabilities through typed Dart contracts and do not select sockets or
protocol implementations directly.

| Carrier | Topology | Current role |
| --- | --- | --- |
| QUIC | Direct | Authenticated primary reliable Session and stream carrier |
| TCP | Direct | Authenticated generic reliable-message carrier |
| WebSocket | Direct | Authenticated generic reliable-message carrier |
| WSS /v2/control | Relay | Control plane (auth/heartbeat/discovery/resolve/signaling/reservation) |
| WSS /v2/relay/{id} | Relay | Reservation-scoped opaque encrypted data plane (RelayDataFrame) |
| UDP | Direct | Unreliable datagrams only |
| WebRTC | Direct or ICE Relay | Native Realtime Session route |

Routing invariants:

- Topology and transport are separate metadata.
- A carrier is authenticated before admission to a Session.
- Reliable Delivery asks the active route for a capability rather than
  branching on a concrete transport.
- UDP is not eligible for acknowledged, ordered, or file-delivery semantics.
- A ConnectionSession is 1:1 with its transport connection (design §18): it is
  created fresh with a new SessionId + new Noise root on every new connection
  and destroyed on transport loss. There is no route migration and no
  session-identity / crypto-root continuity across connections.
- Business state is the only cross-connection continuity (design §19-20):
  Delivery recovers by MessageId, Transfer resumes by transfer_id +
  confirmed_offset. A peer runtime restart or transport loss simply triggers a
  new Resolve → new Connection → new Session; SSH/WebRTC build new sessions
  (no transparent recovery).

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
