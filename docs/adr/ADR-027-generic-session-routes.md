> 最新更新时间：2026-08-12

# ADR-027：Generic Transports as Session Routes

## Status

Accepted for native network v1.

## Context

The connection layer already described topology, transport, and capability,
but Session and Delivery still treated QUIC and Relay as the only concrete
carriers. TCP and WebSocket fallback could therefore pass primitive loopback
tests without being authenticated, visible in route events, or usable for
Delivery recovery.

## Decision

- `SessionManager` stores one composed `ActiveRoute` containing a
  `ConnectionProfile` and an active carrier. QUIC, generic TCP/WebSocket, and
  Relay are represented behind the same Session boundary.
- TCP and direct WebSocket routes perform an application handshake before
  admission. The handshake binds the pinned Ed25519 Device Identity and the
  logical Session binding; an unauthenticated socket is never an active route.
- Generic reliable routes use a bounded I/O owner with typed DataMessage and
  DeliveryAck frames. Delivery dispatch asks the current route for the
  ReliableMessage capability and does not branch on a concrete transport.
- UDP remains UnreliableDatagram-only. It cannot be selected for Acked,
  SessionBoundOrdered, or file-delivery semantics.
- Route replacement connects and authenticates the new carrier, atomically
  swaps the Session route, recovers pending Delivery state, and closes the old
  carrier afterward. SessionId and application E2EE state remain unchanged.
- Peer and route events carry composed topology and transport metadata while
  retaining the legacy flat route field as a compatibility projection.

## Consequences

TCP and direct WebSocket fallback are now production Session routes rather than
transport-only placeholders. The native runtime can preserve logical Session
state across generic-route reconnect and TCP → QUIC migration. File transfer
continues to use its existing QUIC/Relay stream dispatcher until a separate
stream-carrier migration adds resumable file framing to the generic carrier.

## Verification

- `tcp_fallback_authenticates_delivery_and_keeps_session_id`
- `websocket_fallback_authenticates_delivery_and_ack`
- `tcp_to_quic_migration_preserves_pending_delivery_and_session_id`
- `cargo fmt --all -- --check`
- `cargo clippy --workspace --all-targets --locked -- -D warnings`
- `cargo test --workspace --locked`
