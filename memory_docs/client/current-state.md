> Last updated: 2026-08-13

# Client Current State

`apps/ssh_mobile_full/` is the maintained complete application.
`apps/ssh_mobile_terminal/` validates the minimal Terminal-only dependency crop.

Maintained package owners cover:

- Core application, UI, and Connection contracts;
- Connection, Terminal, SFTP, Monitoring, System Administration, LAN Share,
  Playbook, RAG, MCP, AI, WebView, and Developer Features;
- App-scoped SSH infrastructure.

Legacy Full App paths remain only where a current consumer still requires a
compatibility export, adapter, or bridge. Their disposition is tracked by the
[compatibility inventory](../../docs/architecture/COMPATIBILITY_MIGRATION_INVENTORY.md);
new implementation goes to the owning package.

Feature/Core persistence is split by owner. There is no shared business
database, and a production database-open failure must not silently fall back to
an in-memory database.

Network runtime and public network-contract work is routed through the
[SDK domain](../sdk/current-state.md), even when `AppRuntime` creates the
App-scoped facade.
