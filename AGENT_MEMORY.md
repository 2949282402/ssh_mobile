# Agent Memory

This file is shared durable project memory for Codex and Claude Code. It is a
repository file, not live model memory: both agents must read and update it when
project-level decisions, recurring pitfalls, or maintenance notes should survive
across sessions.

## Rules

- Read this file before non-trivial code, documentation, or skill changes.
- Add concise dated notes for durable decisions and recurring project lessons.
- Prefer updating or replacing stale notes over appending duplicates.
- Do not store secrets, private keys, passwords, API keys, tokens, host
  credentials, or user-private data here.
- Do not store machine-local absolute SDK, toolchain, or resource paths here;
  use environment variables, discovery commands, or repo-relative paths.
- Keep notes short enough that agents can load the whole file without wasting
  context.

## Notes

- 2026-06-16: On keyboard-heavy mobile flows, avoid `MediaQuery.of(context)`
  in large server/file list rows when only size/density is needed. Prefer
  narrow helpers such as `MediaQuery.sizeOf` +
  `MediaQuery.devicePixelRatioOf` (`mobileUiScaleOf`) so keyboard
  `viewInsets` changes do not rebuild whole card lists.
- 2026-06-16: SSH password auth must also wire a keyboard-interactive fallback
  for servers that do not offer plain `password`. Do not cache parsed
  private-key identities in memory; parse them per connection attempt so
  private key material is not retained beyond the active auth flow.
- 2026-05-18: Codex and Claude Code share SSH Mobile maintenance guidance
  through `.agents/skills/ssh-mobile-maintenance/SKILL.md` and
  `.claude/skills/ssh-mobile-maintenance/SKILL.md`. Use
  `scripts/sync_agent_skills.ps1` to check or restore synchronization.
- 2026-05-18: Android native rewrite planning lives in
  `docs/ANDROID_NATIVE_REWRITE_GUIDE.md`; it is now a beginner-oriented
  step-by-step Kotlin + Compose + MVVM tutorial aligned with SSH/SFTP,
  monitor, AI tools, logs, settings, and backup behavior.
- 2026-05-27: `OverflowScrollText` can live inside `ExpansionTile` content, but
  it must use its own `PageStorageBucket`; otherwise Flutter may read the
  tile's stored expanded-state `bool` as a scroll offset and then trip
  follow-on widget-tree assertions around `SelectableText`.
- 2026-05-27: On the Servers, SFTP, and Performance Monitor pages, avoid
  top-level Provider subscriptions to whole health/status maps or whole monitor
  service state. Prefer per-card/per-panel `Selector` snapshots so one
  connection's sampling or SFTP state change does not rebuild the entire page.
- 2026-05-27: For the Servers page, cache lightweight SSH connection summaries
  in `SshService` and let the page select that cached overview instead of
  recomputing summaries from `ssh.sessions` inside the widget tree. For SFTP
  directory panes, prefer a session-side `entriesRevision` over `listEquals`
  on every `Selector` pass so large directories do not pay repeated O(n)
  equality checks.
- 2026-05-27: In the Performance Monitor page, keep Ports/Applications/Services results
  cached per selected-server key inside the page state so switching tabs does
  not refetch snapshots unless the selection changes or the user explicitly
  refreshes.
- 2026-05-28: When wrapping `ReorderableListView.builder` items in `Selector`
  or another widget, keep the stable item key on the immediate widget returned
  by `itemBuilder`. A key on a descendant does not satisfy Flutter's reorderable
  list assertion.
- 2026-05-28: Keep app-wide settings dependencies narrow in page hot paths:
  prefer `context.select<AppSettings, AppLanguage>` or a page-specific value
  snapshot over `context.watch<AppSettings>()`, so unrelated setting changes do
  not rebuild full pages. AI chat streaming text is intentionally held in a
  local `ValueNotifier` and committed back to `AiChatRecord` only on
  completion/cancel/error; avoid per-token `_replaceChat`/whole-page `setState`
  regressions.
- 2026-05-28: The vendored xterm renderer treats new `TerminalStyle` and
  `TerminalTheme` object identities as cache-changing inputs. Keep those
  objects memoized for unchanged font/theme values; otherwise ordinary terminal
  screen rebuilds clear paragraph/color caches and can amplify font-scaling
  repaint artifacts.
- 2026-05-28: Android release builds intentionally set
  `usesCleartextTraffic=false`; debug/profile manifests override it for local
  provider testing only. Do not re-enable release cleartext unless a scoped
  network security config and README/ADR note are added.
- 2026-05-28: Core SSH/SFTP/LLM/AI tool and storage flows expose small Dart
  contracts for future fake injection. Backup imports intentionally clear any
  cached AI API key and ignore credential fields from JSON; users must
  reconfigure passwords, private keys, and API keys after importing.
- 2026-05-28: AI `web_search` is now local client WebView search only. It no
  longer stores provider/base URL settings, is enabled by default, and can be
  disabled by the user; keep search results client-side and tied to the current
  chat's WebView session. Prefer lightweight DuckDuckGo HTML results over Bing
  SERP DOM parsing for stability, and avoid viewport-geometry visibility checks
  in result extraction because AI browsing may run in a background WebView.
  Keep the configured per-call result count embedded in the `web_search` tool
  schema and aligned with the execution clamp.
- 2026-05-28: AI WebView browsing has a per-chat operation token. While active,
  the WebView UI is view-only; user interruption clears the token so the tool
  result reports interruption instead of continuing from a stale page.
- 2026-05-29: Added `client_save_experience_skill` AI tool in
  `AiToolService` so the model can write summarized experience records directly
  into local `AiSkillRecord` storage when users ask to persist a skill.
- 2026-05-28: In LLM settings, leaving the API key field blank must preserve
  the saved secure-storage key. Only an explicit clear action should delete the
  stored key; otherwise model/base URL edits can silently break later chats.
- 2026-05-28: Cache fetched LLM model lists in local settings per normalized
  Base URL. Reopen the settings page from cache first, and treat manual refresh
  as the action that replaces the cached list.
- 2026-05-28: LLM settings are provider-aware now. Keep Base URL history in
  plain preferences, keep multiple API keys in secure storage with masked
  previews, show DeepSeek thinking controls only for DeepSeek-like models, and
  show OpenAI reasoning effort only for supported OpenAI reasoning model ids.
- 2026-05-28: AI client tools now include permission status, redacted client
  log queries, and chat-bound WebView state/navigation helpers behind
  `ClientSystemToolService` and `ClientWebViewService` adapters. Keep client
  file saves in the client-system adapter so SFTP downloads return save
  metadata rather than raw file contents to the model.
- 2026-05-28: `sftp_write_text` is a detached path-based SFTP tool that always
  requires user approval. Reuse the app SFTP edit/download size settings in AI
  tools, and keep the approval card showing server, remote path, byte count,
  and a short content preview before any remote write executes.
- 2026-05-28: AI tools now use a shared `ToolSecretPolicy` to redact tool
  arguments/results/traces and to block likely secret-bearing paths and
  environment-dump commands before the model sees them. Do not expose saved SSH
  passwords, private keys, API keys, tokens, backup JSON, raw terminal
  history, or secret-path file contents through any future tool.
- 2026-05-28: Saved-server tool coverage now flows through
  `ServerCatalogAdapter`, monitor coverage through
  `PerformanceMonitorToolAdapter`, and detached SFTP path operations through
  expanded `SftpClientAdapter` helpers (`stat/upload/mkdir/rename/delete`).
  Keep new AI tool work on these adapters so tests can inject fakes and so
  secrets remain outside the model-visible layer.
- 2026-05-29: AI chat now has automatic multi-agent collaboration for complex
  requests. Helper agents run before the primary answer and never receive tool
  definitions or execute SSH/SFTP/client tools directly; keep real tool calls,
  approval gates, cancellation, and secret redaction under the primary
  `LlmChatService`/`AiToolService` flow.
- 2026-05-31: Removed unnecessary dynamic ValueKey from RepaintBoundary in
  `TerminalViewArea` to prevent element disposal and subtree recreation during
  zooming and transitions. Added queue limits in `TerminalScreen` to discard
  excess writes exceeding 200,000 characters, preventing memory leaks and UI
  freezes on massive runaway terminal streams.
- 2026-05-31: Config export and import (version 2) now includes AppSettings
  (theme, language, font, SFTP limits), ShortcutCommandService (usage, custom
  commands, order), secret cache configs, and max AI upload sizes. Registered
  callbacks in `StorageService` (`registerOnImportCallback`) allow high-level
  ChangeNotifiers to automatically reload and refresh UI states post-import.
- 2026-06-01: Modularized `LlmChatService` (split into `llm_chat_types.dart`, `llm_system_prompt.dart`, and `llm_context_compressor.dart`) and `LlmChatScreen` (split into `llm_settings_screen.dart`, `message_bubble.dart`, `history_panel.dart`, `chat_tools_bar.dart`, `tool_approval_panel.dart`, and `ai_strings.dart`) using Dart's native `part`/`part of` pattern. This dramatically reduced the massive single-file complexity (screen down from 5600 lines to 3000 lines; service down from 1350 lines to 800 lines) while maintaining full feature coverage, same private/package access, and passing 100% of unit tests.
- 2026-06-02: Modularized `HomeScreen` (split into `home_settings_strings.dart` and `settings_panel.dart` under `lib/screens/home/`) using Dart's native `part`/`part of` pattern. This reduced the single-file complexity of the home page by over 800 lines (from ~2450 lines to ~1615 lines) while maintaining library-private access and passing all 118 unit and widget tests.
- 2026-06-02: Modularized `ai_tool_service.dart` (schemas extracted to `lib/services/ai_tool/`), `sftp_screen.dart` (split into `sftp_server_pane.dart`, `sftp_file_pane.dart`, and `sftp_models.dart` under `lib/screens/sftp/`), and `terminal_screen.dart` (split into `terminal_dialogs.dart`, `terminal_windows_input.dart`, and `terminal_settings_models.dart` under `lib/screens/terminal/`) using Dart's native `part`/`part of` pattern. This decoupled complex schema aggregates, layout pane widgets, and session action dialogs, reducing single-file sizing and maintaining full test suite coverage (118/118 passing).
- 2026-06-06: README, `docs/ANDROID_NATIVE_REWRITE_GUIDE.md`, and the shared SSH Mobile maintenance skill should mirror the current feature-first MVVM layout. When documenting entry points, cite the feature ViewModel or feature-owned view under `lib/features/*` together with the coordinating `lib/screens/*` shell and `lib/services/*` infrastructure, instead of describing the app as screen-only.
- 2026-06-15: Keep `README.md` and the shared SSH Mobile maintenance skill concise and factual. Prefer current product shape over changelog-style "now added" notes, and keep monitor docs aligned with the four current tabs: Performance, Ports, Applications, and Services.
- 2026-06-15: AI chat tool use now has per-run budget guardrails. Default budget is 20 tool calls, the first limit auto-extends by half, and every later extension requires an internal safety audit that may disable further tools and force a final no-tools summary. Keep this audit independent from the normal multi-agent toggle, and keep state-changing SSH session and terminal-history tools behind the generic approval UI.
- 2026-06-16: 完成整个 SSH Mobile Flutter 客户端项目的 MVVM 架构重构，将 Connection、Settings、Performance 以及 SFTP 模块完全分离为 View-ViewModel-Repository 模式，全局通过 ChangeNotifier 和精度选择（Selector）降低 rebuild 消耗，保证了终端及采样热路径的高性能与 100% 单元测试通过率。
- 2026-06-16: 完成 AI Chat 模块的 MVVM 架构重构 (Phase 7)。新建了 `AiChatViewModel` 接管所有的聊天会话列表、当前选中会话、流式输出、取消 token、工具审批及 metrics 记录等核心逻辑。重构了 `LlmChatScreen` 及其部分扩展（附件、快捷命令、历史会话、生成流控制等），实现状态数据与 UI 彻底解耦。废弃并清空了原 `chat_token_compression` 和 `chat_controller_ops` 辅助逻辑分块，新增了针对 ViewModel 的完整业务单元测试并保持 100% 运行通过率。
- 2026-06-16: 完成 Phase 8A AI Chat ViewModel 瘦身与 Provider 生命周期修正。创建了 AiChatRuntimeFactory 隔离 LLM 聊天服务、AI 工具服务以及上下文编排器的构造逻辑；瘦身 AiChatViewModel 内部低层服务字段，改为通过工厂委托生成相应运行时；移除了 lib/main.dart 中的全局 AiChatViewModel ChangeNotifierProvider 注册，生命周期完全由 LlmChatScreen 局部 Provider 接管，确保在 Tab KeepAlive 状态下仅有单实例运行。

- 2026-06-16: 完成 Phase 8B AI Chat Context / Message Pipeline 抽离。新建了 AiChatContextBuilder, AiChatMessageMapper, AiChatTokenEstimator，将上下文构建、历史消息映射、Token 估算及缓存控制等非状态逻辑彻底从 AiChatViewModel 中解耦抽离，使 ViewModel 进一步收敛为纯粹的状态与 Action 调度层；修复了流式回答 finally 块中 cancellationToken 清理逻辑的 identity 判定缺陷，避免并发或快速重入时可能误清理后续 cancel token 的隐患；运行 flutter analyze 和 flutter test 达到 100% 通过率且无 Warning。
- 2026-06-16: 完成 Phase 9A & 9B AI Chat Generation Runner / Run Coordinator 抽离与审计清理。将生成迭代生命周期、流式节流渲染触发、中英文状态/Trace 本地化以及指标保存持久化逻辑从 ViewModel 解耦至 GenerationRunner、StatusTranslator、MetricsRecorder 三大独立服务。优化了 ViewModel 构造函数依赖引用避免重复分配，补齐了核心服务单元测试且通过率 100%，架构更加高内聚低耦合。
- 2026-06-17: AI chat 的默认规划目标是当前请求的聊天内 `todoSteps`。只有当用户明确要求保存、复用、管理或运行可复用剧本/脚本时，才暴露或调用 `Playbook` 相关工具；回复中的 ` ```playbook ` 代码块仍只是 todo 计划的持久化格式。
- 2026-06-18: System Administration 的 Monitor tab 保持独立多服务器监控选择；除 Monitor 外的 Ports / Applications / Services / Users / Sessions / Power 共享 `SystemAdminViewModel.selectedConnectionId`。root 管理连接只表示当前底层连接，不能反向改写选择，连接成功后也不能自动 `refreshAllData()`；当前 tab activation 负责按需加载。
- 2026-06-18: SSH Host Key TOFU 校验集中在 `SshHostKeyPolicy`。当前 `dartssh2` 只通过 `onVerifyHostKey` 暴露 MD5 fingerprint，因此持久化 fingerprint 需按 MD5 格式规范化；UI 首次使用可提示确认，AI 工具和后台 SSH 不得自动信任未知或变化的 host key。
- 2026-06-18: 安全边界常态化：SFTP preview/download cache 必须用
  `DataProtectionService` 加密且不得缓存 `.ssh`、`.env`、私钥、云凭据、
  token/secret/api_key、`/etc/shadow`、`/etc/sudoers`、`/proc/*/environ`
  等路径；AI 工具阻断环境变量 dump、cloud metadata 和敏感路径，普通远程
  文件 read/download 与日志读取走审批；WebView AI 读取阻断本地/内网/metadata
  URL 和敏感表单；日志统一经 `ToolSecretPolicy` 脱敏；backup import 先做
  大小、数量、字段长度和 schema 校验并继续丢弃凭据；后台通知默认隐藏服务器名。
- 2026-06-20: Tool visibility is a hard execution boundary. Tool calls must be blocked when the requested tool is absent from `visibleToolsByName`. Hidden/unexposed tools must not enter approval, execution, cache, loop guard, or budget-audit paths. This preserves ToolExposureRouter as an actual security boundary rather than only a model hint.
- 2026-06-20: Post-tool review and connection-required boundaries. Post-tool review is controlled by `postToolReviewEnabled`, separate from normal `multiAgentEnabled`. Tool execution must enforce connection requirements independently from ToolExposureRouter. Server/SSH/SFTP/monitor tools without `connectionId` should return `connection_required` and must not perform remote operations.
- 2026-06-20: Plan Mode output validation before execution handoff. A valid plan must have persisted chat-bound `todoSteps` or a valid ` ```playbook ` JSON block with non-empty steps. If validation fails, the service requests one format-only repair attempt without execution tools. 
- 2026-06-20: Plan Mode streaming is buffered before validation. Plan Mode plain-text output is buffered until structural validation/repair finishes. `LlmChatService` does not directly mutate chat storage for playbook persistence; `ChatOrchestrator` is the final todoSteps persistence boundary. This prevents showing invalid plans and avoids storage write conflicts with the ViewModel final save.

