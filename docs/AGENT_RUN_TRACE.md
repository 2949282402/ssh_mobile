# Agent Run Trace & Metrics Design Document

This document outlines the architecture, lifecycles, and measurement definitions for agent execution and tool looping in the `ssh_mobile` project.

---

## 1. Agent Run Lifecycle

An Agent Run represents a single session starting from a user message, progressing through multi-agent collaboration, LLM processing, tool execution loop rounds, and finishing with a final markdown reply.

```
[User Message]
      │
      ▼
[Multi-Agent Preflight Collaboration] (Optional)
      │
      ▼
[Loop Round 0] ────────► [LLM Completion Output Chunk Stream]
      ▲                                │
      │                                ▼
      │                     [Tool Calls Requested?]
      │                          /        \
      │                       Yes          No
      │                        /            \
      │                       ▼              ▼
      │             [Tool Loop Controller]  [Run Complete]
      │             - Safety Auditing
      │             - Cache Retrieval
      │             - Human Approvals
      │             - Sequential Exec
      │                        │
      └────────────────────────┘
```

### 1.1 Multi-Agent Collaboration
* **Preflight Trigger**: Evaluates user request complexity and risk. If high-risk keywords (e.g. `delete`, `restart`, `写入`, `删除`, `重启`) are detected, the `Reviewer` agent is dynamically loaded.
* **DAG execution sequence**: Runs helpers in parallel (`explore` and `planner`), feeds outputs to subsequent tasks (`operator` and `reviewer`), and gathers advisory notes in `summarizer`.
* **Runtime Post-Tool Review Trigger**: Activated dynamically if a critical tool fails (`toolError`), loop guard triggers (`loopGuardBlocked`), approval is rejected with abort (`approvalRejected`), or safety budgets are exhausted/safety audit is rejected (`budgetAuditRejected`). It maps these outcomes to the corresponding `MultiAgentTrigger` (e.g., `postBudgetAudit` for `budgetAuditRejected`), calling the `Reviewer` and `Summarizer` for diagnostic recovery steps. Post-tool reviews do not execute tools. Current active plan step is retrieved dynamically via an explicit `PlanExecutionSnapshot` passed from the chat stream runner, preventing errors from guessing the current session via storage loads. The post-tool review context includes the explicit `Plan execution phase` when a `PlanExecutionSnapshot` is available. If no snapshot is available, the context records `No active plan snapshot.`

### 1.2 Tool Loop Execution
* **Loop Guard Protection**: A deterministic guard monitors repeating identical signature patterns. Read-only tool execution is terminated if a single tool is repeated $\ge 3$ times or alternating loop sequences are detected.
* **Safety Audit Escalation**: Once tool calls reach the safety budget ceiling, the system performs an internal safety audit, asking the LLM to inspect the ledger log for loops or drift.
* **Sequential Transitions**: Step execution progresses in strict order (`pending -> running -> success/failed/skipped`). Sequential constraints are strictly checked before starting (`running`) or skipping (`skipped`) any task step. If any preceding step is not completed, transition is blocked with code `order_violation`. Completed step mutations are locked (`completed_task_locked`). If a preceding step failed, subsequent execution is blocked with code `failed_dependency` (though skipping subsequent steps is permitted).
* **Tool Visibility Boundary**: Tool exposure is an execution boundary, not only a prompt hint. If the model requests a tool that is not present in `visibleToolsByName`, `ToolLoopController` returns a `tool_not_visible` tool result and does not call approval or execution paths. Hidden tools must not consume tool budget, trigger approval, or reach `AiToolService.execute`.

---

## 2. Metrics Definition & `AgentRunSummary`

Every run computes statistics published via `onStats` and logged to `AppLogService`.

### 2.1 Metric Fields
* **`totalRounds`**: Number of completion rounds performed.
* **`toolCalls`**: Number of actual tools dispatched.
* **`cacheHits`**: Number of read-only cache matches retrieved.
* **`dedupBlockedCalls`**: Count of repeated calls blocked by loop guard.
* **`approvalCount`**: Number of actions requiring human verification.
* **`approvedCount`**: Number of human approvals accepted.
* **`helperFanout`**: Count of sub-agents run in the collaboration phase.
* **`auditEscalationLevel`**: Number of safety audits run during budget limits.

### 2.2 Execution Outcomes (`AgentFinalOutcome`)
* **`success`**: Complete answer returned successfully.
* **`cancelled`**: Session terminated by `LlmCancellationToken`.
* **`modelError`**: Network/API error on the primary completions model.
* **`toolError`**: Fatal execution exception during tool dispatch.
* **`approvalRejected`**: Human rejected an action and requested abort.
* **`planModeBlocked`**: Non-read-only action attempted during plan phase.
* **`budgetAuditRejected`**: Safety auditor flagged a loop/drift or user rejected extension.
* **`loopGuardBlocked`**: Deterministic loop guard terminated execution.

---

## 3. Privacy & Redaction Rules

Trace contents and ledger summaries undergo strict privacy stripping:
* **Secret Masking**: Passwords, private keys, and API tokens are redacted as `[REDACTED]` or masked (e.g., `api_key=sk-...12`) before recording in the trace or passing to sub-agents.
* **Argument Preview Truncation**: Arguments are capped at 400 characters, and tool stdout results are capped at 600 characters to prevent prompt bloat and data leakage.

---

## 4. Operational & Execution Boundaries

### Post-tool Review Toggle
`multiAgentEnabled` controls normal preflight collaboration.
`postToolReviewEnabled` controls recovery review after tool failures, approval rejection, unavailable approval, budget audit rejection, and loop guard blocking.
They are intentionally separate so users can disable normal helper agents while still keeping safety recovery enabled.

### Connection Required Boundary
Plan Mode may expose server-related tools for planning or diagnostics, but execution still requires an explicit `connectionId`.
If a server/SSH/SFTP/monitor tool is called without a selected connection, the tool layer returns `connection_required` and does not perform remote operations.

---

## 5. Plan Output Validation

Plan Mode final output is validated before execution handoff. A valid Plan Mode result must either:
1. Persist chat-bound `todoSteps` (e.g. from `client_task_create` calls), or
2. Include a valid ` ```playbook ` JSON block with non-empty steps.

If validation fails, the model gets one format-only repair attempt. If the repair still fails, the chat stays in Plan Mode and the user receives an explicit explanation.

### Plan Mode Streaming and Persistence Boundary

During Plan Mode, single-LLM text is fully buffered until output validation/repair completes. The user should see the validated final plan, not an invalid draft followed by a repair. 
`LlmChatService` owns validation, one-shot repair, and tracing. `ChatOrchestrator` owns the final conversion from a valid playbook JSON block to chat-bound `todoSteps`. The service layer must not directly write to the database (mutate `AiChatRecord`) during validation/repair, avoiding race conditions and ensuring a clean MVVM data flow.

---

## 6. Step-scoped remote tools

In Execution Mode, step gating applies to remote/server-scoped tools, including read-only diagnostics.
The assistant must mark the current todoStep as running before calling server/ssh/sftp/monitor tools, not only before mutating tools.
Pure client/app tools such as `client_time`, `app_get_operational_settings`, `web_search`, and `list_servers` may run outside the step gate.
Step-gate block traces include `stepScoped`, `executionMode`, `reason`, and the current step status.
Approval-aware tools such as `client_task_skip` must be executed through `AiToolService.execute` so that the `approvedWrite` flag is correctly propagated; the direct handler fallback intentionally enforces `approvedWrite=false` to prevent bypassing approval.


