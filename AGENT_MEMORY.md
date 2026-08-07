> 最新更新时间：2026-08-07

# Agent Memory

This is the small durable memory shared by Codex and Claude Code. It records
current, non-obvious decisions that are expensive to rediscover from a single
file. It is not a changelog, architecture guide, test report, or feature list.

## Maintenance

- Read this file before non-trivial repository work.
- Replace or merge stale decisions instead of appending chronological notes.
- Keep implementation detail in code/tests and stable policy in `AGENTS.md`,
  the maintenance skill, ADRs, or focused docs.
- Never store secrets, user-private data, machine-local paths, temporary test
  results, completed migration phases, or claims such as "100% tests pass".

## Durable Decisions

### Runtime ownership

- Startup is intentionally lazy. Bootstrap loads preferences and storage;
  feature scopes own heavy ViewModels. `SshService.ensureInitialized()` gates
  SSH runtime work, `AiChatRuntimeFactory` owns the view-scoped chat runtime,
  and `LanReceiverCoordinator` exposes exactly one receiver-owned
  `LanShareViewModel` to the LAN page and pairing/chat routes.
- `StorageService.appDatabase` may be requested before async initialization.
  It must own one cached database instance, concurrent `init()` calls must share
  one future, Drift setup must reuse that instance, and log database binding
  must finish before storage reports readiness.
- During active development Drift remains one current schema at version 1.
  Schema changes regenerate `app_database.g.dart` and may require deleting the
  local development database; do not add compatibility migrations without an
  explicit release requirement.

### AI and security

- Tool visibility is an execution boundary, not only a model hint. Hidden tools
  must never reach approval, execution, cache, loop-guard, or budget paths.
  Connection requirements and execution-plan step gates are enforced again at
  execution time.
- Approved plan actions must flow through `AiToolService.execute` (or the
  equivalent provider path) so approval state cannot be bypassed. Default
  planning persists chat-bound `todoSteps`; create a reusable Playbook only
  when the user explicitly requests one.
- The local MCP server is loopback-only and reuses `AiToolService`. External
  MCP calls default to `reviewConfiguredTools`, where only exposed tools
  selected for review enter the in-memory queue when a dynamic approval request
  exists; `trustedAgent` may execute exposed tools directly. Exposure is one
  shared persisted set across both modes. Missing exposure preferences preserve
  current hard-allowed tools; after an explicit change, new Tool names stay
  unexposed until selected. Both modes retain immutable target binding,
  `ToolSecretPolicy`, hidden-tool rules, input validation, and destructive-command
  blocking. The queue is cleared on exposure/mode/review/token/lifecycle changes
  and is never persisted. Built-in Agent approvals are unaffected.
- 2026-08-05: MCP fail-closed boundary. In `reviewConfiguredTools` mode,
  `McpInvocationPolicy` returns `denied` for state-changing / write-like tools
  not in the secondary-review set (they never execute silently); read-only
  tools still execute directly. `McpToolHandler._executeDirectlyAuthorized`
  grants `approvedWrite: true` only in `trustedAgent` mode. A tool in the
  review set whose approval request cannot be built fails with
  `approval_required` instead of executing. The approval queue expires
  un-reviewed items after 10 minutes (`approval_timeout`). `ssh_ensure_session_connected`
  belongs in `defaultSecondaryReviewTools`. Do not re-open a fail-open
  execution path for external MCP write operations.

### Network transfer

- LAN file sends use the injected v1 `NetworkService`; do not restore legacy
  transport adapters or protocol fallbacks. Native commands/events are typed,
  peer identity and keys are pinned before connect, and command acceptance is
  distinct from terminal transfer completion/failure events.
- Public relay frames remain memory-only and end-to-end encrypted. The only
  supported production deployment is `relay/compose.yaml` with Caddy; clients
  enroll explicitly, connect through HTTPS/WSS, and require receiver approval.

### UI and performance

- 2026-07-17: LAN Quick Share pairing receivers initialize outside the
  deferred LAN page. QR scans and device-list taps emit the same short-lived
  invitation; QR URLs carry the stable device ID and native transfer port.
  Foreground navigation merges reciprocal invitations for the active device,
  and the pairing screen changes role when needed so simultaneous initiators
  cannot deadlock in pending_remote. Invitations never establish trust; PIN
  verification does, and PIN values must not be logged.

- 2026-07-17: Windows terminal input keeps one multiline draft shared by the
  inline command composer and advanced keyboard. Shell-symbol keys edit the
  draft, `Enter` submits through xterm bracketed paste, `Shift+Enter` adds a
  line, sent commands can be recalled locally, and an empty draft forwards
  terminal control/navigation/function keys instead of swallowing them.
- 2026-07-17: The Windows advanced keyboard is data-driven with QWERTY,
  Shell-symbol, navigation, and F1-F12 layers plus compose/direct modes.
  Shift/Ctrl/Alt have one-shot and locked states and route through xterm; the
  built-in quick-bar selection persists in preferences and app backups.
- 2026-07-17: Advanced keyboard rows always scale into the available width;
  do not restore per-row horizontal scrolling. Keep staggered QWERTY alignment,
  physical-style modifier/space proportions, modern rounded keycap surfaces,
  and narrow-screen overflow tests.
- 2026-07-17: Keep non-generated Dart source and test files below 1000 lines.
  Split by feature responsibility using library `part` files or focused
  collaborators while preserving public/interface methods on their declaring
  classes. Never hand-split generated files such as Drift `*.g.dart`; change
  the generator inputs instead.
- 2026-07-15: Loading flows keep network I/O asynchronous and move potentially
  large remote-output decoding, SFTP directory construction/sorting, monitor
  parsing, and system-admin parsing to background isolates. UI-isolate work is
  limited to applying results and notifying widgets; cache directory scans use
  asynchronous filesystem iteration.
- 2026-07-15: Home settings groups use `AppSectionCard` through
  `_SettingsSection`; retain settings rows and their existing state/storage
  callbacks, and use the shared card instead of reintroducing local Material
  card styling.
- 2026-08-03: Global settings retain only application appearance,
  security/privacy, backup, and developer controls. Terminal appearance,
  server list layout, SFTP limits, LAN identity/relay/permissions, and MCP
  lifecycle settings belong to their feature pages; AI Skills and MCP are
  linked from the AI LLM settings page.
- 2026-08-03: `SftpViewModel` is provided from the application root so the
  SFTP page, editor/viewer routes, and feature-owned settings routes share one
  stable instance. Do not reintroduce a page-local SFTP provider around the
  navigation shell.
- 2026-07-15: Developer Log uses the shared page surface and switches its
  header actions below the title on narrow or high-text layouts; keep all
  selection/copy/delete behavior in `DeveloperLogViewModel`. The AI chat shell
  also sits on `AppPageSurface`, while streaming, history, tool approval, and
  composer ownership remain unchanged.
- 2026-07-15: Ports, Applications, and Services share `_ServerSnapshotTab`.
  Keep its snapshot-only fetching and selected-server cache behavior intact;
  its shared presentation now owns the server context card, 48 dp refresh
  action, and loading/error/empty recovery states so feature tabs do not add
  divergent raw placeholders. At 200% text it switches to a compact header and
  inline loading/error treatment; the Ports and Services mode switch remains
  horizontally scrollable rather than constraining labels.
- 2026-07-15: Monitor health and disk panels use `AppSectionCard`; the disk
  header is an accessible 48 dp expand/collapse action. Keep monitor data
  sourcing and in-memory health/alert behavior unchanged when altering their
  presentation.
- 2026-07-15: The System Administration workspace now uses the shared page
  surface/header and shows a localized connection, snapshot, Root, loading, or
  failure state without changing selection or SSH connection semantics. The
  mobile server strip reserves height through 200% text; its collapse switch
  only lays out the current child so an outgoing expanded strip cannot overflow
  during the height animation. Keep its 48 dp collapse/expand and reorder
  controls, visible desktop status chips, and per-server semantic state.
- 2026-07-15: The SFTP server selector keeps per-server `Selector` snapshots,
  exposes visible and semantic connected/connecting/disconnected states, and
  preserves 48 dp reorder/collapse actions. Desktop collapse uses
  `AnimatedSize` around fixed-width children so the full pane is never laid
  out at an intermediate narrow width; compact cards stack status details at
  150% text or above and reserve extra strip height for the 200% text target.
- 2026-07-15: The SFTP file toolbar adapts from its actual pane width rather
  than target platform, keeps all primary actions at least 48 dp, and stacks
  at 150% text. Directory empty states are vertically scrollable because the
  server strip and toolbar can leave a short content viewport at 200% text;
  the path-history sheet subtracts keyboard and safe-area insets before
  choosing its height. File rows retain the revision snapshot and per-row
  `RepaintBoundary` performance boundary.
- 2026-07-11: Settings drawers use `settingsDrawerWidthFor` and cannot exceed
  the viewport. Their scroll padding includes the system bottom inset; language
  rows expose the localized label plus current value, and the Servers
  list/grid selector is full-width so Chinese, English, and larger text do not
  wrap into vertical fragments.
- 2026-07-10: `MobileUiMetrics` in `lib/utils/responsive.dart` is the single
  source for mobile control, chrome, and visual-density correction. It
  interpolates physical short edges from 1280 to 1440 px: the 1.5K baseline
  uses 0.84 controls, 0.952 chrome, and -0.4 density; the 2K baseline uses 0.92
  controls and standard chrome/density. Never apply this correction to the
  user's system text scale. `AppBreakpoints` also owns the 720 dp Servers-grid,
  840 dp expanded-width, and 480 dp compact-height thresholds; short landscape
  windows use an icon-only rail so 1.5K and 2K phones cannot overflow.
- 2026-07-10: Primary UI workspaces share the modern design system in
  `lib/theme/app_theme.dart` and `lib/widgets/app_surface.dart`. Reuse
  `AppPageSurface`, `AppPageHeader`, `AppIconBadge`, `AppSectionCard`, and
  `AppEmptyState` instead of introducing page-local palette, shadows, icon
  tiles, section cards, or empty states. Interactive section headers expose a
  localized button label, expanded state, tap action, and at least a 48 dp
  target. Main navigation is Servers, SFTP, AI, System Admin, Logs; desktop app
  settings open from the rail on every main page, while AI settings remain
  separate.
- 2026-07-10: Portfolio hardening pins the Dart/Flutter dependency baseline,
  adds CI formatting/coverage/Android/iOS gates, ignores generated coverage,
  and replaces default platform icons through `tool/generate_app_icons.dart`.
  Custom mobile home navigation items expose one labeled semantic button with
  selected state; keep icon/text descendants excluded to avoid duplicate
  screen-reader announcements.
- 2026-07-04: Fixed Windows compilation error in GitHub Actions (due to deprecation of C++ experimental coroutines in newer MSVC toolsets) by adding `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS` to the global CMake definitions in [windows/CMakeLists.txt](file:///home/ubuntu/Documents/coding/ssh_mobile/windows/CMakeLists.txt).
- 2026-08-03: Local MCP Server is implemented in Flutter/Dart under
  `lib/services/mcp/`, not native runners. It binds only to local hosts,
  serves Streamable HTTP JSON-RPC at `POST /mcp`, stores its Bearer token in
  secure storage, and exposes existing `AiToolService` tools through separate
  `McpToolExposurePolicy` and `McpInvocationPolicy` layers. External MCP
  calls default to `reviewConfiguredTools`; `trustedAgent` can directly run
  exposed calls, but bound calls still use `executeApproved` and both modes
  retain hard security checks. The in-memory queue is cleared on policy/token/
  lifecycle changes and is never persisted.
- 2026-08-03: The Windows/macOS `mcp_console` feature is a separate desktop
  diagnostics page opened from MCP settings. It exposes loopback server state,
  port checks, a token-authenticated `initialize` then `tools/list` self-test,
  copied client templates, `McpToolExposurePolicy` snapshots, redacted local
  activity, and a dedicated approval queue navigation page. The queue page
  must render only `AiToolApprovalRequest` previews; never expose raw MCP
  arguments or persist approval callbacks.
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
- 2026-07-01: Android app Gradle config no longer applies
  `org.jetbrains.kotlin.android` in `android/app/build.gradle.kts`. Keep KGP
  only as the settings classpath entry and configure Kotlin with top-level
  `kotlin { compilerOptions { ... } }` to avoid Flutter built-in Kotlin
  migration warnings.
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
- 2026-07-23: The current architecture is pure feature-first MVVM. New UI and
  feature state belong under `lib/features/<feature>/` (models, services,
  viewmodels, views, and feature-local widgets); shared UI belongs in
  `lib/widgets/` and `lib/theme/`; cross-feature infrastructure belongs in
  `lib/services/`, `lib/core/services/`, and `lib/data/`. `lib/screens/` is
  legacy compatibility only. `main.dart` composes application-lifetime
  services/shared ViewModels, while the AI-chat runtime and terminal
  session/history/window ViewModels are view-scoped. Keep README (both
  languages), CLAUDE.md, the shared maintenance skill, and architecture docs
  on these paths and ownership boundaries.
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
- 2026-06-20: Execution Mode step-by-step reliability. Mutating remote tools are gated by the current step status during execution mode: pending tasks must be marked running first, failed tasks block subsequent execution, and skipped tasks require reasons. Added dedicated `client_task_retry` and `client_task_skip` tools and UI buttons in message bubble.
- 2026-06-21: Execution Mode step-scoped remote tools gate. Gating now covers all server/ssh/sftp/monitor tools, including read-only diagnostics such as detect_os and sftp_read_text, to enforce proper step update workflows. Skipping running steps directly is disallowed; skipping a step from AI triggers a plan_task_change approval request.
- 2026-06-21: Execution Mode step gate trace and approval-aware handler boundary. Plan execution gate traces include step-scoped metadata for easier debugging. Approval-aware tools such as client_task_skip must execute through AiToolService.execute/provider.execute so approvedWrite is propagated; direct handlers must not bypass approval.
- 2026-06-21: Drift is the persistence backend for growth-oriented structured
  data: AI chats/messages, AgentRunMetrics, terminal-history metadata,
  Playbooks, and SFTP recent/favorite paths. Keep `StorageService` as the
  facade, small settings in SharedPreferences, and credentials/API keys in
  secure storage.
- 2026-06-21: Production database open failures must surface through
  `StorageService`; never hide them with `NativeDatabase.memory()` or a legacy
  preference fallback. AI chat message text/context/attachments/traces/
  todoSteps and Playbook `content_json` are field-encrypted before Drift writes.
- 2026-07-18: `StorageService.appDatabase` can be read by root providers before
  asynchronous storage initialization starts. Keep database creation cached and
  single-owner, make concurrent `init()` calls share one future, reuse the same
  instance from Drift initialization, and await `AppLogService.setDatabase`
  before signaling Drift readiness; otherwise Windows may reject a second open
  of the same database or retain a closed logger database in tests.
- 2026-07-18: LAN pairing completion is reciprocal and role-independent, so
  either peer may enter its PIN first and reciprocal invitations must preserve
  typed input on the active route. After pairing, require peer-specific bearer
  authentication and certificate fingerprint pinning. Ignore remote local
  paths, confine receives and recall deletion to the LAN sandbox, bound pending
  state and request/preview sizes, and persist interrupted incoming uploads as
  failed after deleting partial data. Web Share uses a short-lived capability;
  Android discovery owns a multicast lock, Apple targets declare local-network
  service access, and Windows firewall access remains app/local-subnet scoped.
- 2026-06-22: Agent Trace history is now a Drift-only growth store under
  `agent_trace_events`, with `StorageService` as the facade. Trace content is
  redacted, size-capped, encrypted in `content_json`, tied to assistant
  messages via `agentRunId`, and intentionally excluded from backup export.
- 2026-06-22: Widget testing pages like LlmChatScreen with locally-scoped providers and target platform overrides must manage debug variable changes inside the testWidgets body using a try-finally block, as the binding's invariant tester runs before the global tearDown hook. Subtree provider instances can be retrieved via context lookups on public descendant widgets (e.g. Scaffold).
- 2026-06-23: App typography is now configured to completely rely on the native system fonts on all supported platforms (Android, Windows, iOS, macOS), and the custom app-level font selection feature has been completely removed to simplify settings and ensure standard system font behavior.
- 2026-07-01: Approved AI plan execution now performs a client runtime health preflight through `ClientHealthAdvisor` / `client_check_runtime_health`. Blocking client-side issues stop execution; warning issues require explicit confirmation. Tool loop plan gating refreshes the in-memory `PlanExecutionSnapshot` from successful `client_task_update/retry/skip` calls instead of reloading chats before every tool call.
- 2026-07-14: SFTP viewer inputs are untrusted and must stay bounded before
  allocation. Text/Markdown/image/HTML reads use caller limits plus a one-byte
  sentinel, over-budget cache entries are invalidated before bounded fallback,
  retries bypass cache, Markdown/HTML external content stays inert, and image
  decoding has dimension/frame/total-pixel budgets. Remote PDFs are identified
  without reading or native parsing and direct users to a trusted external
  reader until page limits can be enforced before renderer allocation.
- 2026-07-15: The app root subscribes only to `AppVisualSettingsSnapshot` and
  reuses cached Material/Shad theme objects. Terminal font and other
  feature-scoped settings must not rebuild the whole navigation shell; theme
  changes must avoid stacked interpolation animations.
- 2026-07-16: The app offers cached Monochrome, Indigo, Ocean, Emerald, Rose,
  and Amber Material/Shad palettes. Monochrome is the fresh-install and invalid
  preference fallback; palette choice persists through settings backup/import.
- 2026-07-15: SFTP and System Administration share expanded desktop/mobile
  server selector chrome through `lib/widgets/server_selector.dart`. Keep
  feature-specific bindings responsible for SFTP single-select and Monitor
  multi-select behavior instead of duplicating selector layout.
- 2026-07-15: Ports, Applications, and Services snapshot lists omit redundant
  single-server summary headers. Ports/Services keep their mode selector
  centered without a duplicate content-toolbar refresh action.
- 2026-07-15: Users and Sessions tabs subscribe directly to their ViewModel
  list/loading state, and manual root retry continues loading the active tab.
  SystemAdmin fetch debounce is awaited and epoch-cancelable; forced
  `refreshAllData()` must run all four management fetches instead of sharing a
  timer that drops Accounts, Sessions, or Services.
- 2026-07-15: System Administration has no global tab-bar Refresh All or hidden
  generic workspace header/status layer. Its refresh action stays fixed at the
  top right beside the independently scrollable server selector and dispatches
  only to the active Ports, Applications, Services, Users, or Sessions tab;
  Monitor and Power do not expose it. This avoids duplicate controls and
  unrelated SSH work.
- 2026-07-16: The SFTP upload action follows `ColorScheme.secondary` in both
  desktop and compact toolbars; do not restore a fixed deep-purple button.
- 2026-07-16: The SFTP directory error retry reconnects the active server when
  its SFTP client is closed, but refreshes the current path when the session is
  still open. Keep UI retries on this state-aware path so connection failures
  do not silently call the no-op directory refresh path.
- Primary workspaces reuse `AppPageSurface`, `AppPageHeader`, `AppSectionCard`,
  `AppEmptyState`, and the shared server selector. `MobileUiMetrics` and
  `AppBreakpoints` remain the sources for adaptive density and thresholds;
  never scale the user's system text setting.
- Terminal input keeps one multiline draft shared by the inline composer and
  advanced keyboard. Preserve IME composition, bracketed-paste submission,
  local command recall, direct terminal-key forwarding for an empty draft, and
  non-scrolling keyboard rows that fit available width.
