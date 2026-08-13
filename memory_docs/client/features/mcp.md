> Last updated: 2026-08-13

# MCP Feature Memory

## Ownership and state

`packages/features/feature_mcp/` owns the loopback Streamable HTTP JSON-RPC
server, tool exposure and invocation policies, in-memory approval queue,
console state, redacted activity repository, and `mcp.db`. `McpModule` owns
the server, database, repository, and queue. AppRuntime injects settings,
logging, and the AI Tool Runtime.

Application disposal stops the server, rejects pending approvals, and closes
the Module database. Route disposal releases only route-scoped ViewModels.

## Execution boundaries

- Tool exposure and invocation authorization are separate policies. Hidden
  tools never reach execution.
- Review mode fails closed for state-changing or write-like operations. A
  configured review call that cannot build a valid approval request returns
  `approval_required` instead of executing.
- Trusted mode may directly execute exposed calls, but target binding, input
  validation, secret policy, sensitive-path rules, and destructive-command
  blocking still apply.
- Approval handles and callbacks are process-local. The queue is never persisted
  and is cleared when exposure, review configuration, mode, token, or server
  lifecycle changes invalidate pending work.
- Activity is bounded and redacted. It excludes tokens, request arguments,
  tool output, peer/origin detail, remote-resource detail, and raw exceptions.

General AI tool visibility, approval, execution, and redaction remain owned by
the [AI Feature](ai.md). The MCP package only reaches that runtime through its
injected Port.

Canonical package contracts:

- [MCP README](../../../packages/features/feature_mcp/README.md)
- [MCP AGENTS](../../../packages/features/feature_mcp/AGENTS.md)
- [Security regression guide](../../../docs/security_manual_regression.md)
