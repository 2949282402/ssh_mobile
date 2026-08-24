> Last updated: 2026-08-24

# SDK Current State

The native transport runtime and Relay control/data path implement
transport-network v2. Any v1 label in the public bootstrap/compatibility surface
is a boundary label only; it is not a transport fallback and must not reintroduce
the retired v1 route/session owner model.

- `network_sdk` provides typed bootstrap, authenticated API, Session, event,
  and Feature-safe Realtime contracts.
- The bootstrap `RefreshRequest` requires an integer Unix-seconds timestamp.
  LAN Share and the real Dart/Rust E2E callers sign
  `POST\n/v1/devices/refresh\n<timestamp>\n<nonce>` exactly; the retired
  timestamp-less transcript has no SDK or Relay compatibility fallback
  ([ADR-031](../../docs/adr/ADR-031-relay-refresh-proof-freshness.md)).
- The Rust `network-relay` shared WebSocket request builder gives every Control
  and RelayData upgrade an independent positive Unix-seconds
  `X-Relay-Timestamp`, 32-byte nonce, and Ed25519 signature over
  `GET\n<path>\n<timestamp>\n<nonce>` with no trailing newline. Both physical
  paths use the hard-cut contract; no timestamp-less builder remains.
- `network_transport` provides the single App-scoped native runtime and
  borrowed command/Realtime gateways.
- `ssh_mobile_network_native` runs native event polling on a helper isolate and
  exposes typed Protobuf commands and events through a narrow facade; command
  encoding, envelope dispatch, Peer/Delivery/Transfer/Realtime/Stream mapping,
  and FFI boundary validation are separate stateless owners.
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
- ReliableStream framing/preamble/token codec, logical stream manager, and SSH
  gateway/FFI adapter are independent owners. The manager alone retains the
  path lease and bounded buffer; the gateway only pumps opaque bytes to local
  sshd and does not interpret SSH protocol.
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
  configured/cache Direct candidates and can reuse any already healthy,
  capability-compatible path before control; Stage B requires one Resolve→Offer
  transaction and a fixed four-second Direct window; Stage C can reserve Relay
  only when Resolve is READY, Direct failed, capabilities match, Required E2EE
  is active, and budget remains.
- Candidate snapshot decoding, cache projection, and deterministic Direct
  ranking are owned separately from the coordinator. Stage B authoritative
  status and Stage C Relay eligibility are pure closed-gate decisions; the
  coordinator retains bounded execution, Session cleanup, and route attachment.
- `RuntimeState` owns the per-peer resolved candidate cache. A healthy existing
  path is reused by its physical path owner without opening a target-less Offer;
  when a new/replacement transport is needed, Stage B starts the authoritative
  Resolve→Offer gate. Session teardown leaves bounded ReliableStream identity
  tombstones so an old `(peer_id, opener_device_id, stream_id)` handle cannot
  transparently write to a new Session.
- Generic reliable carriers carry Delivery frames; Delivery business state resumes
  across connections. File and stream operations acquire fresh path leases after
  loss, and SSH/Realtime explicitly close rather than transparently migrating a
  stale connection.
- Outbound generic connection races, inbound QUIC/TCP acceptance, and receiver
  supervision have independent lifecycle owners. Accept/handshake tasks remain
  runtime-scoped; bidi/channel/generic readers remain Session-scoped and retire
  only the exact lost route before deciding whether the Session is finished.
- Native event classification/backpressure/fairness is owned by bounded event
  lanes rather than `RuntimeState`. Session-scoped weak path projections are
  owned by a dedicated store that applies topology replacement and exact stale
  cleanup; it never extends carrier lifetime or replaces admission storage.
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
