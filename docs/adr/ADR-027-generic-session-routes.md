> 最新更新时间：2026-08-19

# ADR-027：Generic Transports as Session Routes

## Status

Superseded for the active runtime by Network Protocol V2 Peer/Path ownership.

This ADR remains a historical record of generic route admission and carrier
shutdown rules. Current lifecycle truth belongs to `PeerSupervisor`,
`PeerPathManager`, and `PathLease`; the old `SessionManager` wording is not an
active contract.

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
- `prepare_generic_route` only constructs the command/inbound channels and a
  paused I/O driver Future. The driver and the GenericRoute receiver are
  registered as Session-scoped tasks by `RuntimeTaskSupervisor` under the
  canonical `generic-route-io` and `generic-route-receiver` task names.
- A GenericRoute remains in a staged `GenericRouteScope` until both tasks have
  reported ready. Session attach sends the commit signal while holding the
  Session write lock and only then transfers the unique driver/receiver owner
  into `ActiveRoute`; failed admission or attach drops the staged scope.
- `ActiveRoute` is a unique owner. Delivery and route-selection observers see
  only a non-closing `RouteView`, so route replacement, Session close, and
  Runtime shutdown cannot leave a detached socket owner behind. Generic close
  stops the receiver first, attempts a bounded graceful driver close, then
  cancels and joins the driver lease.
- Authentication continuity carries a non-Copy admission cleanup lease. A
  replacement Session cancels the old Session task group only after the new
  route commits; failed replacement schedules old-group cleanup and marks the
  new Session failed without rolling back the old Session.
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
- `peer::tests::session_close_stops_and_joins_generic_route_tasks`
- `peer::tests::generic_route_replacement_closes_old_owner_before_new_owner_remains`
- `peer::tests::failed_generic_attach_drops_staged_scope_without_orphan_tasks`
- `peer::tests::runtime_stop_joins_generic_route_tasks`
- `cargo fmt --all -- --check`
- `cargo clippy --workspace --all-targets --locked -- -D warnings`
- `cargo test --workspace --locked`
