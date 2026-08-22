> Last updated: 2026-08-22

# SDK Current State

The native transport runtime and Relay control/data path implement
transport-network v2. Any v1 label in the public bootstrap/compatibility surface
is a boundary label only; it is not a transport fallback and must not reintroduce
the retired v1 route/session owner model.

- `network_sdk` provides typed bootstrap, authenticated API, Session, event,
  and Feature-safe Realtime contracts.
- `network_transport` provides the single App-scoped native runtime and
  borrowed command/Realtime gateways.
- `ssh_mobile_network_native` runs native event polling on a helper isolate and
  exposes typed Protobuf commands and events.
- Rust owns authenticated QUIC, generic TCP/WebSocket carriers, UDP datagrams,
  WSS Relay integration, native WebRTC, `PeerSupervisor` lifecycle,
  `PeerPathManager` Direct/Relay physical carriers, Delivery/Recovery,
  application E2EE, and resumable file-transfer state. `ConnectionSessionStore`
  is security/admission-only; business operations select a carrier through a
  `PathLease`.
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
- Passive authenticated inbound admits a peer as Online without enabling
  maintenance. Environment changes refresh discovery while preserving healthy
  Relay/Realtime; only maintained peers schedule bounded Direct recovery after
  Relay is ready, using `1/2/4/8/15/30s` backoff plus jitter. Unleased idle paths
  are ephemeral and retire after 60 seconds.
- Direct and Relay physical paths may coexist. Direct selection wins when
  compatible, business `ensure` does not opt into maintenance, and hard path
  revocation closes streams bound to the revoked lease; normal retirement drains
  those leases instead of transparently migrating them.
- CandidatePayloadV2 validates candidate transport capabilities before direct
  probing. Relay candidates never enter a DirectProbe; resolved candidate cache
  freshness uses a monotonic clock, server-confirmed TTL, and
  `runtime_epoch`/same-epoch `revision` ordering with fingerprint consistency.
- E2EE policy is enforced end-to-end: Required installs a fresh application
  root after authenticated Noise/path admission, while Disabled is Direct
  identity-only and Relay Disabled is rejected before application crypto.
- Connectivity stages are authoritative and ordered: Stage A uses only fresh
  configured/cache Direct candidates; Stage B requires Resolve→Offer and a
  fixed four-second Direct window; Stage C can reserve Relay only when Resolve
  is READY, Direct failed, capabilities match, Required E2EE is active, and
  budget remains.
- `RuntimeState` owns the per-peer resolved candidate cache. Stage A reads only
  fresh cached/configured direct candidates and does not call Resolve/Offer;
  Stage B starts the existing Resolve→Offer gate after Stage A failure. Session
  teardown leaves bounded ReliableStream identity tombstones so an old
  `(peer_id, opener_device_id, stream_id)` handle cannot transparently write to
  a new Session.
- Generic reliable carriers carry Delivery frames; Delivery business state resumes
  across connections. File and stream operations acquire fresh path leases after
  loss, and SSH/Realtime explicitly close rather than transparently migrating a
  stale connection.
- Feature-facing Realtime does not expose native signaling or media resources;
  decoded media availability remains defined by the public package contract.

## Validation gates

Run the package-local checks required by each SDK contract:

```bash
(cd packages/infrastructure/network_sdk && flutter analyze --no-pub && flutter test --no-pub)
(cd packages/infrastructure/network_transport && flutter analyze --no-pub && flutter test --no-pub)
(cd packages/infrastructure/ssh_mobile_network_native && dart analyze && dart test)
(cd native/network_core && cargo fmt --all -- --check && cargo test --workspace --locked && cargo clippy --workspace --all-targets --locked -- -D warnings)
```

The public SDK coverage gate is independent from the daily regression gate:

```bash
bash scripts/sdk_coverage.sh
```

It measures the public Dart facades and public Rust SDK crates; internal
`network-core` and Relay implementation coverage remains part of the ordinary
Rust workspace checks. Cross-owner protocol and ABI acceptance is checked with:

```bash
bash scripts/network_v2_acceptance.sh strict
```

Do not copy test-run results here. Automated and device-dependent coverage is
tracked in the [network fault matrix](../../docs/NETWORK_FAULT_MATRIX.md).
