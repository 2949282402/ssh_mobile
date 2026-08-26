> Last updated: 2026-08-25

# LAN Share Feature Memory

## Ownership and state

`packages/features/feature_lan_share/` owns LAN Control Protocol V2 discovery,
pairing, capabilities, authenticated HTTPS/WebSocket control, Web Share,
Relay enrollment/orchestration, transfer history, non-secret metadata, and
`lan_share.db`. Binary payloads have one formal data plane: Native Network
Protocol V2 Transfer. Per the accepted V2 control-plane decision, text/clipboard
use authenticated HTTPS + application E2E.
`LanShareModule` owns its database, repository, Receiver, TrustStore, and the
single Feature peer-registry owner. `LanReceiverCoordinator` owns LAN listener,
discovery, pairing-session and ViewModel lifecycle, but only borrows the shared
AppRuntime `NetworkFacade`; it never creates, starts, stops, disposes, or
reconfigures `NetworkRuntime`. Its internal `LanRelayCoordinator` independently
owns enrollment, credential refresh, Relay event subscription, typed retry
policy, and bounded timers while only borrowing the shared Facade. AppRuntime
and NetworkRuntime retain ownership of App-scoped identity/capabilities.

One receiver-owned `LanShareViewModel` is exposed through the Feature Scope and
is reused by the LAN page plus pairing/chat routes. Receiver activation is
explicit and configuration-controlled, not an import or app-start side effect.

## Pairing and transfer invariants

- Device-list taps and QR scans enter the same short-lived invitation flow.
  Invitations request navigation; they do not establish trust.
- Pairing is reciprocal and role-independent. Both PIN directions must verify,
  simultaneous invitations merge, and a role transition preserves typed input.
- LAN Control V2 is breaking-only: no old pairing schema migration, V1/V2 dual
  path, deprecated compatibility adapter, or HTTP binary fallback. A non-current
  schema is cleared and requires new pairing.
- Trust, Discovery, Reachability, Route Availability, and Relay
  Enrollment/Authorization are independent state domains. PINs, bearer tokens,
  keys, and Relay credentials never enter logs, preferences, the Feature database,
  or exports.
- A complete `LanPeerTrustRecord` atomically contains certificate fingerprint,
  inbound/outbound access tokens, 32-byte X25519 and Network Identity public keys,
  origin, and explicit `PeerRouteAuthorization`. Local PIN creates direct trust
  with Relay authorization false; local Relay enrollment never grants every peer.
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
- Every Receiver native-runtime generation restores all valid trusted peers with
  pinned 32-byte Network Identity and X25519 keys before advertising its native
  endpoint, through one `LanNativePeerRegistry` owner and `endpointAddress=''`.
  Missing or malformed trust material fails closed; capabilities can verify
  pinned identities but never overwrite them. Pairing success synchronizes the
  live registry at the Coordinator boundary, independent of whether the LAN page
  is open. Explicit unpair deletes Trust and calls `removePeer`; route loss does
  not.
- Incoming native transfer offers use a Coordinator-owned stable broadcast
  stream whose internal Facade subscription is replaced across deactivate and
  reactivate. Paired text, clipboard, and file sends have no plaintext toggle:
  missing E2E capability fails the send.
- Final Receiver release awaits Discovery/WebShare first and Transfer second.
  Each service serializes in-flight starts/stops, closes sockets/servers before
  event streams, and rejects late publication after shutdown begins. The
  ViewModel drains keep-alive, history migration, and persistence operations;
  cleanup continues across individual release failures.
- Direct is preferred and Relay is fallback only after peer Relay authorization,
  local enrollment/configuration, remote capability and native route checks all
  pass; history records the route actually used. There is no Relay-only peer
  creation flow in this refactor.

Typed network contracts, native command/event semantics, route migration,
wire changes, and E2EE belong to the [SDK domain](../../sdk/overview.md), not
this Client Memory. Relay server authentication and deployment belong to the
[Backend domain](../../backend/overview.md).

## Implementation audit snapshot (2026-08-25)

The following is a deliberately explicit handoff for the active breaking
refactor; code and tests remain authoritative:

| Area | Observed implementation |
| --- | --- |
| App owner | `AppRuntimeFactory` loads App identity, creates the shared Facade, and configures it before LAN Module activation; AppRuntime and adapter tests cover one App-scoped gateway/facade setup and idempotent dispose. |
| Trust | Pairing server/client bind both static identities and write one complete V2 record; V1 pairing/trust helpers are removed and cannot re-enter the persistence path. |
| Registry | Receiver restore, endpoint invalidation and route authorization use the registry; ViewModel forget delegates to the Coordinator/Registry explicit remove chain. |
| Binary | `/api/lan/upload` is no longer exposed; HTTP metadata rejects binary and regular-file Network V2 transfer is owned by `LanNativeTransferCoordinator`. |
| ViewModel | File send and explicit unpair delegate to the transfer coordinator; text/clipboard/history remain ViewModel responsibilities, using the separated discovery/trust/route models. |
| Text/clipboard | `NetworkFacade.sendMessage` remains the stable unavailable boundary for this refactor; current HTTPS + application E2E is the accepted path. |

AppRuntime exactly-once, dual-runtime/device-restart transfer, V2 pairing/storage
safety, and explicit peer removal are covered by the current App/Feature/SDK/native
tests and paired CI selectors.

Package contracts:

- [LAN Share README](../../../packages/features/feature_lan_share/README.md)
- [LAN Share AGENTS](../../../packages/features/feature_lan_share/AGENTS.md)
