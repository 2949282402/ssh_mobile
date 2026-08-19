> Last updated: 2026-08-19

# SDK Current State

The maintained network contract is development-stage v1.

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
- Generic reliable carriers carry Delivery frames; Delivery business state resumes
  across connections. File streaming continues
  through its current QUIC/Relay dispatcher until a separate stream-carrier migration.
- Feature-facing Realtime does not expose native signaling or media resources;
  decoded media availability remains defined by the public package contract.

Do not copy test-run results here. Automated and device-dependent coverage is
tracked in the [network fault matrix](../../docs/NETWORK_FAULT_MATRIX.md).
