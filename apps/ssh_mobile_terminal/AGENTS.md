最新更新时间：2026-08-30

# Terminal-only App Guidelines

- This App is the minimal Terminal dependency-crop validator; do not copy Full
  App business Services. `lib/app/terminal_app_runtime.dart` owns App resources.
- The root Stateful Widget is an awaitable/idempotent exit owner: remove Route/
  Feature borrowers, then release Module → SSH → Network → Database → UI owners
  → Logger. Continue after individual failures; resources must provide
  `dispose/close/cancel/release`.
- Terminal uses only `feature_terminal` public API/Ports and never another
  package's `/src/`. Do not add AI, RAG, MCP, WebView, LAN Share, SFTP, or Full
  App business implementations. Expansion belongs in Full App/Feature packages.
- Contract changes update `TerminalFeatureScope`, Runtime injectors, tests, and
  dependency-crop docs. `TerminalModule` alone owns `terminal.db`; Runtime owns
  App Scope, Module owns DB, Route Scope owns page resources.

## Validation for code changes

`flutter pub deps`, `flutter analyze`, and `flutter test` (package-local; local
aggregate CI remains user-opt-in). Dependency output must not contain
`feature_ai`, `feature_rag`, `feature_mcp`, `feature_webview`,
`feature_lan_share`, or `feature_sftp`.
