最新更新时间：2026-08-30

# feature_mcp 维护约束

- Scope: MCP Server/JSON-RPC, exposure/invocation policy, approval queue,
  activity Repository, Module, pages, and tests; App adapters inject the tool
  executor and must not restore shared business storage.
- Listener 只绑定 `localhost`/`127.0.0.1`; Token, Origin, and JSON-RPC checks
  stay at the execution boundary, not in pages.
- `McpModule` alone owns `mcp.db`, activity Repository, approval queue, and HTTP
  Server. `McpToolExecutor` is App-adapter injected; never import AI Feature,
  `apps/.../lib/src/`, or old `AiToolService`.
- New tools update exposure policy, invocation approval, redacted activity, and
  tests. Public API only through `feature_mcp.dart`; API changes sync adapters,
  route metadata, and security tests. DB activity never returns to `AppDatabase`;
  secrets remain in secure boundaries. Module stops server/rejects pending
  approvals/closes DB; Route Scope releases ViewModels.

## Validation (code changes)

`dart format --output=none --set-exit-if-changed lib test`、`flutter analyze`、
`flutter test --exclude-tags native-loopback` on WSL; native runners/CI run
`mcp_http_server_native_test.dart` with the real loopback HTTP integration.
Local aggregate CI is user-opt-in.
