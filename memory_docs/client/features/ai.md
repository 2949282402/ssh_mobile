> Last updated: 2026-08-24

# AI Feature Memory

## Ownership and state

`packages/features/feature_ai/` owns AI chat, Agent, Skills, LLM
provider/runtime code, tool orchestration, and `ai.db`. `AiModule` lazily owns
the database, repositories, provider/runtime creation, and tool registry.
Route Scope owns AI ViewModels, streams, timers, and controllers. App Shell
adapters inject settings, logging, text protection, SSH/SFTP, monitoring,
Playbook, RAG, MCP, and WebView capabilities without transferring ownership.

Chat, metrics, trace, attachments, context, and other sensitive fields are
encrypted before Drift writes. Database-open failures surface; they do not
fall back to an in-memory production store.

## Execution boundaries

- Encode OpenAI-compatible JSON request bodies as UTF-8 bytes. Streaming
  parsers must tolerate fragmented tool-call deltas and a usage-only chunk
  before the terminal marker.
- Preserve provider-required reasoning payloads across the provider's tool
  rounds, while keeping hidden reasoning out of future model context and
  redacted persisted traces.
- Tool visibility is an execution boundary, not only a model hint. A hidden or
  unexposed tool never reaches approval, execution, cache, loop guard, or budget paths.
- Tool-loop preflight owns visibility and plan-step gates, the budget-audit
  coordinator owns extensions and remaining-call blocking, and one result
  recorder folds both serial and parallel outcomes into provider messages,
  system hints, ledger entries, and traces.
- Remote writes and sensitive reads require approval bound to immutable target
  and action snapshots. Stale snapshots are rejected before execution.
- Tool arguments, results, approvals, and persisted traces pass through
  `ToolSecretPolicy`; environment dumps, metadata endpoints, and secret-bearing
  paths remain restricted.
- Shell commands use one-shot SSH execution, respect the target platform, and
  keep destructive deletion blocked.
- Default request planning uses chat-bound `todoSteps`. A persisted Playbook is
  created or executed only when the user explicitly requests a reusable Playbook.
- Helper agents do not receive tool definitions or execute client/SSH/SFTP
  tools; the primary runtime retains tool, approval, cancellation, and redaction ownership.

## Cross-feature routing

- AI reaches RAG through `RagCapability`, Playbook through
  `PlaybookAutomationPort`, and client WebView through `AiWebViewPort`.
- MCP consumes an injected AI Tool Runtime Port; AI does not import the MCP implementation.
- Add [MCP Memory](mcp.md), [SFTP Memory](sftp.md), or
  [LAN Share Memory](lan-share.md) only when that boundary changes.

Package-local contracts and focused design:

- [AI README](../../../packages/features/feature_ai/README.md)
- [AI AGENTS](../../../packages/features/feature_ai/AGENTS.md)
- [Agent Trace design](../../../docs/AGENT_RUN_TRACE.md)
- [Security regression guide](../../../docs/security_manual_regression.md)
