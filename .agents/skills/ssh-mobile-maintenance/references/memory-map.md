> Last updated: 2026-08-15

# Memory Map

Use this map after identifying the files and behavior affected by the task.
Never load every Domain or Feature Memory by default.

## Required loading algorithm

1. Read the canonical maintenance Skill, then this map.
2. Collect every path explicitly named by the task. If the task names only
   behavior, use read-only search to locate the actual owning paths before routing.
3. For each path, walk from its directory toward the repository root and read
   every `AGENTS.md` encountered. A nearer contract supplements or tightens an
   outer contract; it cannot relax it. For a Workspace Member, also read its
   `README.md` for responsibility, public API, dependencies, database, lifecycle,
   and validation ownership.
4. Route every path to the Domains below. Read that Domain's overview and, when
   present, current state.
5. Add Domain architecture only for structure, dependency, ownership,
   lifecycle, storage, compatibility, or public-API changes.
6. Add Domain lessons only for a matching diagnostic, regression, or performance task.
7. Add Feature Memory only for the listed complex Features. It never replaces
   the package README/AGENTS contract.
8. Add precise ADRs and Architecture documents only when an escalation rule below applies.

A docs-only spelling, formatting, or link fix that changes no fact may stop
after the Skill, this map, and nearest `AGENTS.md`. Governance work also reads
the [Memory README](../../../../memory_docs/README.md) and
[maintenance rules](../../../../docs/agent/skill-memory-maintenance.md).

## Client routing

Default Client chain:

- [Client overview](../../../../memory_docs/client/overview.md)
- [Client current state](../../../../memory_docs/client/current-state.md)

Add [Client architecture](../../../../memory_docs/client/architecture.md) for
cross-package API/dependency, App/Module/Route scope, resource owner, database,
storage, or compatibility-bridge changes. Add
[Client lessons](../../../../memory_docs/client/lessons.md) only for a matching
regression or performance issue.

| Path or task | Additional scoped knowledge |
| --- | --- |
| `apps/ssh_mobile_full/**`, `apps/ssh_mobile_terminal/**` | Client default chain and nearest App/Feature contracts |
| `packages/core/**`, `packages/features/**` | Client default chain and the Workspace Member README/AGENTS |
| `packages/infrastructure/ssh_core/**` | Client default chain plus Client architecture for Manager/Pool/Lease/public-contract work |
| App Shell, startup, navigation, settings, logging, backup, platform runner | Client chain; add [startup design](../../../../docs/STARTUP_INITIALIZATION.md) when startup behavior changes |
| AI chat, Agent, Skills, LLM, tools, or AI App adapters | [AI Feature Memory](../../../../memory_docs/client/features/ai.md) and AI package contracts |
| SFTP UI, service, preview, cache, path history, or App SFTP adapters | [SFTP Feature Memory](../../../../memory_docs/client/features/sftp.md) and SFTP package contracts |
| LAN discovery, pairing, share, Receiver, Web Share, or App LAN adapters | [LAN Share Memory](../../../../memory_docs/client/features/lan-share.md) and LAN package contracts |
| MCP server, policy, approval queue, console, activity, or App MCP adapters | [MCP Feature Memory](../../../../memory_docs/client/features/mcp.md) and MCP package contracts |
| Client Telemetry, event tracking, storage state machine, upload dispatcher, or Developer telemetry card | [Client overview](../../../../memory_docs/client/overview.md) and [Telemetry ADR](../../../../docs/adr/ADR-033-telemetry-data-tracking-architecture.md) |

Conditional Client documents:

- AI trace/metrics persistence: [Agent Trace design](../../../../docs/AGENT_RUN_TRACE.md).
- Host key, credentials, tool execution, secret paths, or preview security:
  [security regression](../../../../docs/security_manual_regression.md).
- SFTP/monitoring large-data performance:
  [performance acceptance](../../../../docs/PERFORMANCE_ACCEPTANCE.md).
- Monitoring/System Administration integration:
  [integration design](../../../../docs/SYSTEM_ADMIN_MONITOR_INTEGRATION.md).
- UI accessibility, responsive behavior, or large-text regression:
  [mobile UI QA](../../../../docs/MOBILE_UI_QA.md).

Connection, Terminal, Monitoring/System Administration, Playbook, RAG, WebView,
Developer, and shared UI do not have initial Feature Memory. Use Client basics,
their nearest package contracts, and the focused documents above.

`ssh_core` remains Client infrastructure. Do not load SDK Memory merely because
the package is under `packages/infrastructure/`. Add SDK only if a real public
interface to `network_transport` or the native network runtime changes.

## SDK routing

Default SDK chain:

- [SDK overview](../../../../memory_docs/sdk/overview.md)
- [SDK current state](../../../../memory_docs/sdk/current-state.md)

Paths:

- `native/network_core/**`
- `packages/infrastructure/network_sdk/**`
- `packages/infrastructure/network_transport/**`
- `packages/infrastructure/ssh_mobile_network_native/**`
- `protocol/**`

Add [SDK architecture](../../../../memory_docs/sdk/architecture.md) for public
contract, App/native ownership, FFI, lifecycle, dependency, or wire-boundary
changes. Add [SDK lessons](../../../../memory_docs/sdk/lessons.md) for matching
recovery, ordering, routing, or crypto regressions.

Transport, candidate exchange, path selection, Connection/Session/Route,
Relay/direct migration, reconnect/resume, Delivery, transfer, E2EE, Realtime,
WebRTC, or native command/event work also reads
[Transport and Routing](../../../../memory_docs/sdk/features/transport-routing.md).

Every Dart SDK package path still requires its nearest README/AGENTS. The Rust
workspace currently has no nested AGENTS contract, so use the root rules, SDK
Memory, implementation, tests, and the precise ADR.

## Backend routing

`relay/**` loads:

- [Backend overview](../../../../memory_docs/backend/overview.md)
- [Backend current state](../../../../memory_docs/backend/current-state.md)
- the [Relay README](../../../../relay/README.md)

Enrollment, service authentication, administrator API, hub state, WebSocket
server lifecycle, Compose, and Caddy are Backend concerns. A wire frame, device
proof, opaque data-plane forwarding, Session route, or Client enrollment
contract change also loads SDK Memory. An administrator response consumed by
React also loads Front Memory.

## Front routing

`front/**` loads:

- [Front overview](../../../../memory_docs/front/overview.md)
- the [Front README](../../../../front/README.md)

Pure React presentation does not load Flutter Client Memory. Administrator API
schema, authentication, or session semantics also load Backend Memory.

## Cross-domain escalation

- Calling an unchanged public API does not load the provider's entire Domain.
  Changing API shape, semantics, errors, state, lifecycle, or ownership does.
- `network_transport` contracts and native-handle/gateway behavior are SDK.
  AppRuntime construction/disposal or App Shell result correlation is SDK + Client.
- Relay API/authentication/hub/deployment is Backend. Relay wire, Session route,
  opaque handshake, or E2EE is Backend + SDK + the exact ADR.
- Administrator DTO/API changes are Front + Backend.
- `protocol/**` changes are SDK + Backend; add Client when the change reaches a
  Feature-facing Dart contract.
- Multiple real touched paths load the union of their Domains. Do not let a
  primary directory hide a secondary Domain.
- Tests and documentation follow the Domain of the behavior they verify; their
  physical `test/` or `docs/` location is not a separate Domain.

## Architecture and ADR escalation

Read [Module Dependency](../../../../docs/architecture/MODULE_DEPENDENCY.md)
when package/workspace dependency boundaries change.

Read [Resource Ownership](../../../../docs/architecture/RESOURCE_OWNERSHIP.md)
when a database, session, native handle, timer, stream, controller, subscription,
or isolate owner/create/dispose rule changes.

Read the
[Compatibility Migration Inventory](../../../../docs/architecture/COMPATIBILITY_MIGRATION_INVENTORY.md)
when removing or changing a compatibility bridge. The broad
[Modular Refactor Plan](../../../../docs/architecture/MODULAR_REFACTOR_PLAN.md)
is a conditional architecture reference, not a default Feature-task input.

Read a precise ADR when changing wire/API semantics, Session/Connection/Route
lifetime, transport/path selection, reconnect/resume/recovery, Delivery ordering,
crypto/key lifecycle, Relay/direct selection, WebRTC media/data plane, or native
task ownership. Do not scan the whole ADR directory. ADR-011 was duplicated
between two Accepted files; it was disambiguated on 2026-08-15 by renumbering
file resume to ADR-030. Always cite the complete filename:

- [File resume ADR](../../../../docs/adr/ADR-030-file-resume.md)
- [Transfer Session route dispatch ADR](../../../../docs/adr/ADR-011-transfer-session-route-dispatch.md)
- [Telemetry & Observability ADR](../../../../docs/adr/ADR-033-telemetry-data-tracking-architecture.md)

## Common task simulations

1. **Flutter UI:** Client overview/current state + owning package contracts;
   add Client architecture only for shared ownership/public-boundary work.
2. **Rust QUIC:** SDK overview/current state + Transport and Routing + the
   precise QUIC/NAT/routing ADRs; add Client only for public FFI/Dart API changes.
3. **Backend API:** Backend overview/current state + Relay README; add Front for
   administrator-consumer changes or SDK for device/wire changes.
4. **Front Admin:** Front overview + Front README; add Backend only when the API,
   authentication, or session contract changes.
5. **Client↔SDK API:** Client and SDK overview/current state/architecture,
   both package contracts, ownership/dependency documents, and precise ADRs.
6. **Relay architecture:** Backend + SDK architecture/current state + Transport
   and Routing + Relay README + precise Relay/Session/E2EE ADRs; add Front only
   if the dashboard or administrator API changes.
7. **Telemetry & Observability:** Telemetry ADR-033 + Client/Backend/Front
   overviews + `contracts/telemetry/` catalog; add owning package contracts for
   UI or Storage work.

Code and tests remain authoritative for current behavior. Accepted ADRs remain
authoritative for architectural decisions.
