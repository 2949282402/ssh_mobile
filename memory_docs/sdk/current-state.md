> Last updated: 2026-08-19

# SDK Current State

The maintained public network contract remains development-stage v1 while the
transport-network v2 migration is developed as an additive native/Relay path;
the v1 wording here is a compatibility-state label, not a claim that v2 code is
absent.

- `network_sdk` provides typed bootstrap, authenticated API, Session, event,
  and Feature-safe Realtime contracts.
- `network_transport` provides the single App-scoped native runtime and
  borrowed command/Realtime gateways.
- `ssh_mobile_network_native` runs native event polling on a helper isolate and
  exposes typed Protobuf commands and events.
- Rust owns authenticated QUIC, generic TCP/WebSocket carriers, UDP datagrams,
  WSS Relay integration, native WebRTC, ConnectionSession routing, Delivery/Recovery,
  application E2EE, and resumable file-transfer state.
- A `ConnectionSession` is 1:1 with its transport Connection. Every new
  connection gets a new `SessionId` and Noise root; transport loss destroys the
  session, while Delivery and Transfer business state resumes by business ID.
- Discovery attempts preserve the full 128-bit `RuntimeEpoch`; revisions are ordered only within the same epoch, and late Answer candidates can still join the live Direct race.
- ReliableStream commands and events use `StreamHandle(opener_device_id, stream_id)` end-to-end, so reverse-direction streams with the same numeric ID remain distinct.
- Queue acceptance, native command completion, transport acknowledgement, and
  application acknowledgement remain distinct.
- Native command results are admitted through bounded exactly-once guards:
  duplicate or unknown terminal results are dropped, and peer connect intents
  coalesce concurrent requests while stale generations cannot complete a newer
  intent. Native path handles are borrowed through explicit leases and revoked
  handles cannot be reacquired.
- The typed `network_v2` contract keeps PeerState, E2EE policy, command terminal
  results, diagnostics, environment changes, and peer-scoped business IDs
  separate from the legacy wire adapter. Native Runtime event ingress is count+
  byte bounded; FFI and transport EventMux apply control/data fairness and
  overflow policy before events reach feature adapters.
- CandidatePayloadV2 validates candidate transport capabilities before direct
  probing. Relay candidates never enter a DirectProbe; resolved candidate cache
  freshness uses a monotonic clock, server-confirmed TTL, and
  `runtime_epoch`/same-epoch `revision` ordering with fingerprint consistency.
- `RuntimeState` owns the per-peer resolved candidate cache. Stage A reads only
  fresh cached/configured direct candidates and does not call Resolve/Offer;
  Stage B starts the existing Resolve→Offer gate after Stage A failure. Session
  teardown leaves bounded ReliableStream identity tombstones so an old
  `(peer_id, opener_device_id, stream_id)` handle cannot transparently write to
  a new Session.
- Generic reliable carriers carry Delivery frames; Delivery business state resumes
  across connections. File streaming continues
  through its current QUIC/Relay dispatcher until a separate stream-carrier migration.
- Feature-facing Realtime does not expose native signaling or media resources;
  decoded media availability remains defined by the public package contract.

Do not copy test-run results here. Automated and device-dependent coverage is
tracked in the [network fault matrix](../../docs/NETWORK_FAULT_MATRIX.md).
