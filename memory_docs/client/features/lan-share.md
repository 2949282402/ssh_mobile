> Last updated: 2026-08-25

# LAN Share Feature Memory

## Ownership and state

`packages/features/feature_lan_share/` owns discovery, pairing,
HTTPS/WebSocket/Web Share transfer, Relay enrollment and orchestration,
transfer history, non-secret pairing metadata, and `lan_share.db`.
`LanShareModule` owns its database, repository, Receiver, and Feature-scoped
network resources. `LanReceiverCoordinator` owns LAN listener/discovery,
pairing, native Facade creation, and ViewModel lifecycle. Its internal
`LanRelayCoordinator` independently owns enrollment, credential refresh, Relay
event subscription, typed retry policy, and bounded timers while only borrowing
the Receiver-created Facade. It consumes pure Dart settings, logging,
enrollment, and capability Ports rather than concrete Flutter storage or
`NetworkRuntime`; the Receiver composition boundary supplies those adapters.
AppRuntime and NetworkRuntime retain ownership of injected App-scoped
capabilities.

One receiver-owned `LanShareViewModel` is exposed through the Feature Scope and
is reused by the LAN page plus pairing/chat routes. Receiver activation is
explicit and configuration-controlled, not an import or app-start side effect.

## Pairing and transfer invariants

- Device-list taps and QR scans enter the same short-lived invitation flow.
  Invitations request navigation; they do not establish trust.
- Pairing is reciprocal and role-independent. Both PIN directions must verify,
  simultaneous invitations merge, and a role transition preserves typed input.
- PINs, bearer tokens, keys, and Relay credentials never enter logs, preferences,
  the Feature database, or exports.
- Post-pair endpoints authenticate the peer and pin its certificate identity.
  Remote `localPath` input is ignored; receive and recall cleanup stay inside
  the LAN sandbox.
- Native and WebShare upload metadata is consumed exactly once before the first
  asynchronous body read. Pending and active leases share one capacity budget;
  replay or metadata reuse cannot create parallel untracked writes. Bodies,
  names, sizes, and preview decoding remain bounded. A failed upload releases
  its exact lease, deletes partial data, and records failure.
- Desktop export selects a destination directory and copies through bounded
  streams; it never materializes an accepted multi-gigabyte file in memory.
- Temporary remote-pair verification is bound to the pairing generation. An
  unpair/cache reset invalidates an in-flight verification, and the pinned HTTP
  response has an overall size/time deadline with the client closed in
  `finally`. TLS-context and static-X25519 first creation are single-flight, and
  a cached TLS context is bound to exactly one local device identity.
- LAN client endpoints use structured host/port URI construction, certificate
  pinning, direct connections, and disabled redirects. Advertising restart
  releases the previous mDNS/UDP generation; callbacks and delayed sends retain
  the socket identity they were created with.
- LAN HTTPS and native reliable file transfer use separate listening ports.
  Receiver configuration binds native transport ephemerally and advertises the
  confirmed port through discovery and authenticated capabilities; senders do
  not reuse the HTTPS port as a native endpoint.
- Final Receiver release awaits Discovery/WebShare first and Transfer second.
  Each service serializes in-flight starts/stops, closes sockets/servers before
  event streams, and rejects late publication after shutdown begins. The
  ViewModel drains keep-alive, history migration, and persistence operations;
  cleanup continues across individual release failures.
- Direct is preferred and Relay is fallback; history records the route actually used.

Typed network contracts, native command/event semantics, route migration,
wire changes, and E2EE belong to the [SDK domain](../../sdk/overview.md), not
this Client Memory. Relay server authentication and deployment belong to the
[Backend domain](../../backend/overview.md).

Package contracts:

- [LAN Share README](../../../packages/features/feature_lan_share/README.md)
- [LAN Share AGENTS](../../../packages/features/feature_lan_share/AGENTS.md)
