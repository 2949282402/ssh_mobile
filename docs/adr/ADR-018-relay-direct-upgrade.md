> 最新更新时间：2026-08-11

# ADR-018：Relay-to-Direct Session Upgrade

## Status

Accepted for the native network v1 runtime.

## Context

A Relay route can be available before NAT candidates become reachable. Direct
probing must therefore improve a live Session without interrupting Relay data,
and a failed or incorrectly authenticated probe must not change the current
route.

## Decision

- A Relay-connected Session starts at most one native direct-upgrade task per
  `PeerId + SessionId`. The task stops when the Session is closed, replaced, or
  already direct.
- The task uses the current ranked candidate set and the same parallel,
  identity-bound QUIC checks as initial route selection. It never closes or
  replaces the shared Relay client while probing.
- A successful candidate must pass a short stable window. The Session manager
  then checks that the expected Session is still connected through Relay and
  atomically installs the authenticated QUIC Connection with
  `replace_route_if_current`.
- Only after the swap does the runtime recover Delivery messages, resume
  transfer Sessions, start direct receivers, and publish direct route metrics.
  A stale Session or failed guard closes the new Connection and leaves the
  previous Relay route unchanged.

## Consequences

Relay remains a working fallback while Direct is unavailable. A direct upgrade
does not create a new logical Session, so Delivery ACK state, transfer offsets,
and recovery epochs survive the route change. Existing direct-path metrics and
hysteresis continue to govern later direct candidate migration; no direct/
Relay oscillation is introduced by the background task itself.

## Verification

Native tests cover an atomic Relay-to-Direct promotion with a ready QUIC
Connection, direct probe/authentication failure while Relay remains eligible,
Session replacement guards, Delivery recovery, and transfer resume behavior.
