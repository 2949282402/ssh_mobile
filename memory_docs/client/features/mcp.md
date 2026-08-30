> Last updated: 2026-08-30

# MCP Feature Memory

`packages/features/feature_mcp/` owns the localhost Streamable HTTP JSON-RPC
server, tool exposure/invocation policy, in-memory approval queue, console state,
redacted activity repository, and `mcp.db`. `McpModule` owns server, DB,
repository, and queue; AppRuntime injects settings, logging, and the AI Tool
Runtime. Route disposal releases only route ViewModels.

Application disposal stops the server, rejects pending approvals, and closes the
Module DB. Lifecycle actions are serialized and generation-bound; awaited
`close()` invalidates late starts and closes local handles before DB close.
`McpSelfTestRunner` owns protocol self-test orchestration, not the HTTP server.

- Exposure and invocation authorization are separate; hidden tools never execute.
- Review mode fails closed for writes/state changes and returns
  `approval_required` when it cannot build a valid request. Trusted mode may
  execute exposed calls only after target binding, input validation, secret/path
  policy, and destructive-command blocking.
- Approval handles/callbacks are process-local; the queue is never persisted and
  clears when exposure, review, mode, token, or server lifecycle changes.
- Activity is bounded/redacted and excludes tokens, request args, tool output,
  peer/origin or remote-resource details, and raw exceptions.

General visibility/approval/execution/redaction belong to [AI Memory](ai.md);
MCP reaches it through its injected Port. Contracts: [MCP README](../../../packages/features/feature_mcp/README.md),
[MCP AGENTS](../../../packages/features/feature_mcp/AGENTS.md), and
[security regression](../../../docs/security_manual_regression.md).
