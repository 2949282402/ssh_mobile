> Last updated: 2026-08-30

# AI Feature Memory

`packages/features/feature_ai/` owns AI chat, Agent/Skills, LLM providers,
tool orchestration, and `ai.db`. `AiModule` lazily owns the database,
repositories, provider/runtime, and tool registry; Route Scope owns ViewModels,
streams, timers, and controllers. App Shell injects settings, logging,
protection, SSH/SFTP, monitoring, Playbook, RAG, MCP, and WebView capabilities;
it retains their ownership.

Chat titles are not derived from prompt text. Route close rejects approvals,
cancels the provider request, awaits generation, then releases notifiers. Module
close invalidates in-flight lazy initialization before closing `ai.db`. Chat,
metrics, traces, attachments, context, and other sensitive fields are encrypted
before Drift writes; database-open failure never falls back to memory.

Execution boundaries:

- OpenAI-compatible JSON is UTF-8; streaming handles fragmented tool-call
  deltas and usage-only chunks before the terminal marker. Provider-required
  reasoning survives tool rounds but hidden reasoning stays out of later context
  and persisted traces.
- Tool visibility is an execution gate: hidden/unexposed tools never reach
  approval, execution, cache, loop guard, or budget. Preflight owns visibility and
  plan gates; budget coordinator owns extensions/blocking; one result recorder
  folds serial/parallel outcomes into provider messages, system hints, ledger,
  and traces.
- Remote writes and sensitive reads require approval bound to immutable target /
  action snapshots; stale snapshots fail closed. `ToolSecretPolicy` redacts
  arguments/results/approvals/traces; environment dumps, metadata endpoints, and
  secret paths remain restricted. Shell commands are one-shot SSH and destructive
  deletion remains blocked.
- Default planning uses chat-bound `todoSteps`; a persisted Playbook is created
  or executed only on explicit reusable-Playbook request. Helper agents receive
  no tool definitions and never execute client/SSH/SFTP tools; the primary
  runtime owns tool, approval, cancellation, and redaction.

Cross-feature ports: `RagCapability`, `PlaybookAutomationPort`, and
`AiWebViewPort`; MCP consumes an injected AI Tool Runtime Port and AI never
imports MCP implementation. Add [MCP](mcp.md), [SFTP](sftp.md), or
[LAN Share](lan-share.md) Memory only when that boundary changes.

Contracts/design: [AI README](../../../packages/features/feature_ai/README.md),
[AI AGENTS](../../../packages/features/feature_ai/AGENTS.md),
[Agent Trace](../../../docs/AGENT_RUN_TRACE.md), and
[security regression](../../../docs/security_manual_regression.md).
