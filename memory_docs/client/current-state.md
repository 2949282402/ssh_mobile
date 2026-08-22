> Last updated: 2026-08-22

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

## Validation gates

The daily App regression gate runs from the repository root and intentionally
does not collect Flutter coverage:

```bash
bash scripts/full_test.sh --no-bootstrap
```

For App-local checks, run the required commands from the Full App directory:

```bash
cd apps/ssh_mobile_full
flutter analyze
flutter test
```

The periodic client Network V2 boundary gate is separate:

```bash
bash scripts/client_coverage.sh --no-bootstrap
```

It covers the App-owned Network V2 service boundary, not every unrelated Full
App UI feature. If a WSL Flutter runner cannot expose its VM Service, configure
`CLIENT_FLUTTER_BIN` to a working source runner and use the documented
`SSH_MOBILE_DISABLE_DART_PROFILING=1` workaround in
[`docs/COVERAGE_POLICY.md`](../../docs/COVERAGE_POLICY.md); an ordinary
`flutter test` pass is not a coverage pass.
