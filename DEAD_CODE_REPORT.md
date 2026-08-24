> Last updated: 2026-08-21

# PR49 Dead Code Retirement Report

Status: **PASS — no unsafe unreachable production code was removed**

The audit searched the Network V2 SDK, App network adapter, Rust network-core,
Relay, compatibility inventory, and maintained V2 documentation for
`deprecated`, `legacy`, `old`, `compat`, and `unused` markers. Reachability was
checked with the repository compatibility and architecture tools before
classifying each candidate.

## Retained compatibility surfaces

| Candidate | Decision | Reason |
| --- | --- | --- |
| `network_clients.dart` typedefs (`NetworkResult`, `NetworkService`, `PeerConfig`, and related names) | Retain | They are exported public aliases; App Shell and tests still use them, and the API compatibility gate forbids removing them in this migration |
| `SessionClient` / `NetworkService` boundary | Retain | `NativeNetworkService` implements it and `NetworkFacade` consumes it; it remains the App-owned adapter boundary, not an unused duplicate implementation |
| `NetworkV2CommandPort.dispose()` | Retain | It is an owner-only lifecycle operation for the App/native adapter; the V2 facade no longer calls it as a borrower |
| `NetworkRouteType` and flat route projections | Retain | Existing App/Feature diagnostics and event consumers use the compatibility projection while the richer V2 route metadata remains available |
| V2 zero-revision event handling | Retain | `revision == 0` is an explicitly documented forward/legacy input shape and has a regression test; removing it would break older event producers |

## Retired or superseded paths

- No duplicate V2 facade implementation remains after moving the command port and
  facade implementation into the domain-oriented library parts.
- No Dart Relay data-plane implementation or `/v1/connect` transport path is
  active; Relay README and server tests record the removed route boundary.
- Compatibility-import inventory is fully closed: `dart run
  tool/compatibility_check.dart` reports 0 references for every closed module,
  and `dart run tool/architecture_check.dart` passes.

## Historical documentation

Older V1 ADRs, `docs/NETWORK_PLATFORM_IMPLEMENTATION_PLAN.md`, and the V1
control-plane architecture document are retained as historical design records.
`docs/NETWORK_V2_STALE_V1_AUDIT.md` marks their authority boundary: current
implementation, README/AGENTS, V2 protocol contracts, and accepted V2 ADRs are
authoritative. These documents are not executable code and deleting them would
remove architecture history rather than retire a dead path.

## Follow-up removal conditions

The retained aliases and flat projections may be deleted only after a separate
API migration proves zero external consumers, updates the compatibility
inventory, and passes the public API gate. No such removal is authorized in
PR49 because it would be a breaking change.
