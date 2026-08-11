> 最新更新时间：2026-08-11

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

- `network-core::connection` owns the capability vocabulary
  (`ReliableStream`, `ReliableMessage`, `UnreliableDatagram`) and maps TCP,
  UDP, WebSocket, Session-owned QUIC, and Relay to it.
- `ConnectionRouteSelector` selects the first candidate that satisfies a
  requested capability; candidate order remains the responsibility of the
  Session/Route owner, so this layer does not introduce another retry policy.
- `GenericConnection` wraps the existing `network-transport::Transport` and
  preserves its bounded framing, backpressure, error, and shutdown semantics.
  QUIC and Relay continue to use their existing Session-owned resources and are
  represented by profiles rather than copied into this wrapper.
- The existing channel route dispatch consumes the Connection profile before
  choosing QUIC or Relay, while the public client protocol remains unchanged.

## Consequences

Generic TCP/UDP/WebSocket primitives are now reachable through the native
Connection boundary without touching Flutter/client business code. Future
route owners can request a capability instead of depending on a concrete
transport. WebRTC remains a separate realtime subsystem and is intentionally
not folded into this ordinary transport abstraction.

## Verification

Native tests cover capability mapping, route fallback, TCP reliable-stream
round trips, UDP datagram limits, transport failure after shutdown, and the
existing WebSocket/TCP/UDP primitive loopbacks.
