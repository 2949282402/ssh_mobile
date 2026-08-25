> 最新更新时间：2026-08-25

# ADR-032：LAN Control Protocol V2 breaking boundary

## Status

Accepted for the development-phase LAN Share breaking refactor. This ADR
records the boundary, security decisions, and current implementation evidence.

## Context

LAN Share historically mixed pairing state, discovery, endpoint reachability,
native peer registration, Relay enrollment and HTTP file upload. It also used
fragmented Secure Storage values and a `pending_remote` pairing state. The
current refactor must make LAN Control independent from the Native Network V2
wire contract while removing ambiguous ownership and route fallback.

## Decisions

### Independent version domains

`LAN Control Protocol V2` owns discovery, pairing, capabilities, authenticated
control HTTP and text/clipboard control. `Native Network Protocol V2` owns peer
registry, Connection/Session, route eligibility, E2EE, binary transfer and
Realtime. LAN Control V2 does not imply Native Network Protocol V3.

This is a breaking-only development contract:

- no V1/V2 dual path, deprecated wrapper, old pairing migration, or old LAN
  binary fallback;
- a non-current LAN pairing/trust schema is cleared and requires new pairing;
- `POST /api/lan/upload` is not a supported binary endpoint once the refactor
  closes; image/video/audio/file payloads use Network V2 Transfer only.

### Five independent state domains

Peer Trust, Discovery, Reachability, Route Availability, and Relay
Enrollment/Authorization are separate state domains. A boolean such as
`paired`/`online` must not represent more than one of them. Dynamic Discovery
endpoints and runtime-generation native ports are not persisted in Trust.

`LanPeerTrustRecord` is the only durable peer trust shape. An accepted record
atomically contains the certificate fingerprint, inbound/outbound access
tokens, 32-byte X25519 public key, 32-byte Network Identity public key, origin,
creation time and explicit `PeerRouteAuthorization`. Local PIN pairing creates
`localDirect=true, relay=false`; Relay authorization is an explicit state
transition based on a verified peer identity. Local Relay enrollment never
grants every trusted peer, and Relay disconnect never deletes local trust.

### App Scope network ownership

`AppRuntimeFactory` loads/creates the App-owned Ed25519/X25519
`NetworkIdentityBundle`, creates and configures one `NetworkRuntime` exactly
once per App process, and creates the shared `NetworkFacade`. LAN, SSH, SFTP,
Realtime and Relay borrow this App Scope runtime. `LanShareModule` and
`LanReceiverCoordinator` may stop their own HTTP/Discovery/Transfer resources
and subscriptions, but never start/stop/dispose/reconfigure the shared native
runtime or Facade.

### Explicit peer lifecycle and route filtering

Native peer lifecycle is explicit:

```text
Trust restore/register → connect → transfer/respond → disconnect
explicit unpair → delete Trust → removePeer → close/cancel active work
```

`removePeer` is not triggered by LAN timeout, Discovery loss, Relay
disconnect, route change, App background, or Feature deactivate. The sole
`LanNativePeerRegistry` owner maps persisted Trust to `registerPeer`, restores
trusted inbound peers with an empty endpoint, updates dynamic direct endpoints,
and maps explicit unpair to `removePeer`.

Route eligibility is closed before native path selection: Direct requires
`localDirect`; Relay requires peer `relay` authorization, valid local Relay
enrollment/configuration, remote capability and a native route. Unauthorized
Relay cannot be selected and Local Direct Trust cannot silently upgrade it.

### Text and clipboard

The Feature-facing `NetworkFacade.sendMessage` boundary remains unavailable in
this scoped refactor. Text and clipboard therefore use the existing
authenticated LAN HTTPS control path with application E2E. No temporary native
message implementation, plaintext fallback, or per-message E2E disable switch
is permitted.

## Implementation audit (2026-08-25)

The working tree currently provides the following pieces:

- App Shell identity loading, shared Facade construction and explicit
  `SessionClient`/`NetworkFacade.removePeer` API, with AppRuntime and adapter
  lifecycle tests;
- `allowDirect`/`allowRelay` fields through the Dart/native peer configuration;
- V2 transcript identity binding, atomic Trust Record/store, discovery-only
  presentation models, a registry implementation and regular-file Network V2
  transfer coordinator;
- removal of `/api/lan/upload` and rejection of binary metadata on the HTTPS
  control path.

The breaking refactor implementation is complete for the scoped LAN Control V2
boundary: V1 pairing/trust helpers and the legacy `LanDevice` aggregate are
removed; ViewModel forget delegates to the Coordinator/Registry explicit
`removePeer` chain; and AppRuntime exactly-once plus dual-runtime/device-restart
transfer and Relay authorization acceptance is covered by the current
App/Feature/SDK/native tests. The Feature-facing `NetworkFacade.sendMessage`
boundary remains intentionally unavailable in this scope, so authenticated HTTPS
+ application E2E remains the text/clipboard decision.

## Verification

The acceptance suite must include:

- App runtime configure/activate/deactivate/reactivate/dispose exactly-once
  counts, plus SSH/SFTP/Realtime/Relay shared-runtime regressions;
- dual-runtime/device-restart transfer, V2 pairing contract and storage safety;
- atomic Trust Record validation, schema reset, identity conflict and no
  half-pair persistence;
- registry restore with an empty endpoint, endpoint invalidation without trust
  deletion, explicit unpair/remove, and route authorization gates;
- rejection/absence of old LAN Control V1 and `/api/lan/upload`, and no native
  binary fallback;
- authenticated HTTPS + application E2E text/clipboard behavior under the
  accepted unavailable `NetworkFacade.sendMessage` boundary.

The package and cross-owner commands are:

```bash
(cd packages/features/feature_lan_share && dart format --output=none --set-exit-if-changed lib test && flutter analyze --no-pub && flutter test --no-pub)
(cd packages/infrastructure/network_sdk && flutter test --no-pub test/network_facade_v2_refactor_test.dart test/network_sdk_contract_test.dart test/network_v2_contract_test.dart test/network_v2_facade_test.dart)
(cd apps/ssh_mobile_full && flutter test --no-pub test/app/network_runtime_ownership_v2_test.dart test/services/network/network_identity_service_test.dart test/services/network/network_protocol_v2_codec_test.dart test/features/lan_share/lan_e2e_encryption_test.dart test/features/lan_share/lan_pairing_v2_contract_test.dart test/features/lan_share/lan_storage_safety_v2_test.dart)
(cd native/network_core && cargo test -p network-core --locked --lib two_runtimes -- --test-threads=1 && cargo test -p network-core --locked --lib receiver_runtime_restart_restores_direct_trust_without_repairing -- --test-threads=1 && cargo test -p network-core --locked --lib peer_runtime_restart_replaces_session_and_keeps_e2ee_delivery -- --test-threads=1 && cargo test -p network-core --locked --lib network_v2_route_auth -- --test-threads=1)
bash scripts/bash/ci/full_test.sh --only lan-network-v2-targeted
```

The PowerShell CI entry point must select the same test paths under the same
`lan-network-v2-targeted` job name.
