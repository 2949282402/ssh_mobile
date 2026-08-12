> 最新更新时间：2026-08-12

# ADR-019：Generic Transport Connection Layer

## Status

Accepted for the native network v1 runtime.

## Context

The TCP, UDP, and WebSocket primitives already had bounded framing and
loopback coverage, but `network-core` selected routes directly by concrete
implementation. That made it difficult to express whether a route provides a
reliable stream, reliable message, or unreliable datagram without changing
business commands.

## Decision

- `network-core::connection` owns a composed `Route`:
  `RouteTopology::{Direct, Relay}` × `RouteTransport::{Quic, Tcp, Udp,
  WebSocket}`. This prevents transport/topology enum multiplication.
- The existing flat `RouteType` is only the wire/event projection for routes
  already represented by the v1 client contract; generic routes stay composed
  inside the native route owner.
- `ConnectionRouteSelector` selects the first available candidate that
  satisfies a requested capability. Candidate order remains the responsibility
  of the Session/Route owner, so this layer adds no retry policy.
- Route candidates carry explicit availability. A blocked QUIC candidate can
  therefore fall back to TCP for `ReliableStream`; a blocked UDP candidate can
  promote a reliable-message intent to WebSocket/WSS.
- `ConnectionCapability` keeps UDP limited to `UnreliableDatagram`; Acked,
  Ordered, and File delivery cannot silently select a UDP route.
- `GenericConnection` wraps the existing `network-transport::Transport` and
  preserves its bounded framing, backpressure, error, and shutdown semantics.
- `SessionManager` owns a composed `ActiveRoute` and a bounded generic carrier.
  TCP and direct WebSocket carriers are admitted only after the application
  Ed25519/Session-binding handshake; the generic carrier exposes only reliable
  message frames, while UDP remains datagram-only.
- Existing channel dispatch consumes the current route capability through
  `SessionManager::send_channel_frame`; it no longer selects QUIC or Relay by
  concrete route. SessionId, Delivery, Recovery, and application E2EE remain
  outside the transport wrapper and therefore survive route replacement.

## Consequences

Generic TCP/UDP/WebSocket primitives are now reachable through the native
Connection boundary without touching Flutter/client business code. Authenticated
TCP and direct WebSocket routes are real Session carriers with bounded send and
receive ownership, Delivery recovery, reconnect, and atomic QUIC migration.
Future route owners can request a capability instead of depending on a concrete
transport. WebRTC remains a separate realtime subsystem and is intentionally
not folded into this ordinary transport abstraction.

## Verification

- Route policy tests cover a blocked QUIC candidate selecting direct TCP for
  `ReliableStream` and a blocked UDP candidate selecting relay WebSocket/WSS
  for a reliable-message intent; UDP is rejected for that capability.
- Generic TCP, UDP, and WebSocket loopbacks retain their bounded framing,
  datagram boundaries, binary-message semantics, and close behavior.
- Native integration tests authenticate TCP and WebSocket fallback routes,
  complete Delivery application ACKs, reconnect TCP with the same SessionId,
  and migrate a pending Delivery from TCP to QUIC without changing that ID.
- Session tests confirm SessionId survives route replacement, while existing
  Delivery Recovery tests continue to use the same logical Session boundary.
- Clippy and the native workspace test gate remain required.
