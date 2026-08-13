> Last updated: 2026-08-13

# LAN Share Feature Memory

## Ownership and state

`packages/features/feature_lan_share/` owns discovery, pairing,
HTTPS/WebSocket/Web Share transfer, Relay enrollment and orchestration,
transfer history, non-secret pairing metadata, and `lan_share.db`.
`LanShareModule` owns its database, repository, Receiver, timers, and
Feature-scoped network resources. AppRuntime and NetworkRuntime retain ownership
of injected App-scoped capabilities.

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
- Pending state, bodies, names, sizes, and preview decoding are bounded. A
  failed upload releases reservations, deletes partial data, and records failure.
- Direct is preferred and Relay is fallback; history records the route actually used.

Typed network contracts, native command/event semantics, route migration,
wire changes, and E2EE belong to the [SDK domain](../../sdk/overview.md), not
this Client Memory. Relay server authentication and deployment belong to the
[Backend domain](../../backend/overview.md).

Package contracts:

- [LAN Share README](../../../packages/features/feature_lan_share/README.md)
- [LAN Share AGENTS](../../../packages/features/feature_lan_share/AGENTS.md)
