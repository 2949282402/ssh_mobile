# SSH Mobile Lessons

## Build and Environment

- Resolve the Flutter SDK dynamically instead of recording machine-local paths:
  prefer `flutter` on `PATH`, then `FLUTTER_ROOT\bin\flutter.bat` on Windows or
  `FLUTTER_ROOT/bin/flutter` on macOS/Linux.
- Use `PUB_HOSTED_URL=https://pub.flutter-io.cn` when package access is flaky.
- Avoid writing fixed SDK, toolchain, or resource absolute paths into app code,
  README, skills, or `AGENT_MEMORY.md`. Use environment variables, platform
  discovery commands, or repo-relative paths.

## Encoding and Documentation

- The previous README contained mojibake. Prefer rewriting corrupted docs as
  clean UTF-8 instead of patching garbled text.
- Keep README focused on current behavior: SSH/tmux, SFTP, AI assistant, tools,
  logs, Android troubleshooting, and known limits.
- Treat docs as part of the code change. When adding, removing, renaming, or
  materially changing files, features, navigation entries, settings, AI tools,
  dependencies, or platform behavior, update both README and this skill if they
  describe the affected area.

## OpenAI-Compatible LLMs

- Do not use `request.write(jsonString)` for JSON containing non-Latin text.
  Encode with `utf8.encode`, set `contentLength`, and send bytes with
  `request.add(bodyBytes)`.
- DeepSeek thinking mode may require `reasoning_content` to be passed back on
  tool-call rounds. Capture it from streaming deltas and attach it to the next
  assistant tool-call message.
- Show hidden reasoning only as collapsed chat trace details, alongside tool
    requests, tool results, and approval outcomes. These traces are persisted for
    user inspection but must not be included in future model context.
- Keep default DeepSeek models available:
  - `deepseek-v4-flash`
  - `deepseek-v4-pro`
- Model configuration belongs in the LLM settings dialog. The chat page should
    not duplicate model selection.
- Show the user-facing AI tool catalog through the chat input toolbar by reading
    `AiToolService.tools`. Do not duplicate tool names, descriptions, or
    parameter schemas in the UI.
- Custom AI Skills are user-managed records with name, description, and freeform
    SKILL.md-style content. The manager should support mobile and desktop layouts,
    theme colors, Chinese/English strings, and reference/template text without
    forcing a rigid schema. Disabled skills stay saved for editing but must be
    filtered out of chat toolbar selection and request context.
- Toolbar-selected target servers, prompt templates, and temporary skills should
    be represented as user-message context, not dynamic system prompt changes.
- Write LLM request failures and tool failures into `AppLogService`.
- Context window size is a model setting. Keep choices to 259K, 512K, and 1M.
- DeepSeek official streaming usage requires `stream_options: {"include_usage": true}`.
  It sends an extra chunk before `[DONE]`; that chunk has empty `choices` and
  request-level `usage`. Non-streaming responses include `usage` on the final
  object.
- Use provider-reported token usage when available, including DeepSeek
  `prompt_cache_hit_tokens`, `prompt_cache_miss_tokens`, and
  `completion_tokens_details.reasoning_tokens`. Keep a local estimate fallback
  so streaming providers without `usage` can still show useful stats, and mark
  fallback values as estimated in the UI.
- Trigger context compression at 90% of the selected window by calling the
    current model to summarize older messages, then continue with the summary plus
    the latest user turn.
- Keep the main chat system prompt byte-stable where possible so provider prompt
    caches can hit. Put compression summaries into assistant memory messages, not
    dynamic system prompts.
- Persist separate context memory for chat messages when display content is too
    large to resend. For example, keep generated documents visible in history but
    store a compact `contextText` placeholder for future requests.
- For user-message edits and assistant regeneration, discard later messages
    before calling the model again. Reusing old assistant traces or token stats
    after the edit point would make the visible branch and model context diverge.
    Branching from an assistant reply should copy history only through that reply.
  - Add comments when code depends on subtle protocol behavior, lifecycle timing,
    user-safety requirements, or memory/context tradeoffs. Keep comments focused
    on why the code exists or what must not be broken during maintenance.
  - Per-message token usage and elapsed time should be subtle UI chrome below AI
    replies, not part of the Markdown message body.

## AI Tool Safety

- Centralize tools in `lib/services/ai_tool_service.dart`.
- Tool definitions are how the model knows available tools: they are sent in the
  `tools` array of the OpenAI-compatible chat request.
- Redact secrets in logs: keys, tokens, passwords, private keys.
- Keep `run_command` read-only by default. Allow useful discovery commands such as
  `which`, `whereis`, `command -v`, `readlink`, `realpath`, `printenv`, `env`,
  `ls`, `pwd`, `ps`, `df`, `du`, `tail`, `head`, `cat`, and status commands.
- Commands outside the read-only discovery set are write-capable and must go
  through the chat-page approval panel before execution.
- Rejection should abort the current operation and let the user type follow-up
  guidance. Approval should be logged before execution.
- Continue blocking commands that request elevated shells, passwords, private
  keys, or secret handling.
- AI tools must execute commands through the one-shot SSH exec path
  (`SshService.runOneShotCommand`). Do not attach tmux, create terminal shells,
  or reuse interactive terminal sessions for LLM command execution.

## Navigation and Backup

- The main page order is AI, Servers, Windows, SFTP, Logs. The rail/bottom bar
  intentionally omits Logs; the app still launches on Servers by default.
- The Servers page no longer owns a swipe-open settings drawer. Open settings
  from the settings icon only so left swipes can switch to the next page.
- The AI page opens chat history from the left on a deliberate left-edge-to-right
  swipe; make the panel track the finger and settle open/closed instead of
  waiting until swipe end to show a modal.
- The chat input `+` menu should expand below the input row as a fixed-height
  function panel, similar to WeChat, so the input remains anchored above tools.
  Keep this panel minimal: Server selection and Skills management only.
- On compact mobile widths, the AI Skills manager should use separate Skills
  and Editor tabs. A fixed-height list above a long editor makes both areas feel
  cramped and fights the keyboard.
- Backup JSON should be versioned and include all user-restorable state:
  connection configs, restorable windows, terminal history, AI settings,
  AI chats, and custom AI skills. Do not export passwords, private keys, API
  keys, tokens, or other secrets; imports should require users to reconfigure
  those fields.

## SFTP

- Cache SFTP sessions per server so switching servers does not always disconnect
  the previous one.
- Store and restore the last remote path per connection after reconnect.
- Deleting a saved server should remove related SSH windows and SFTP sessions.
- Delete operations need a second confirmation.
- Editing should use a full page for more space, scrolling, font scaling, and
  mobile landscape support when orientation is not locked.
- Non-text previews can use dedicated viewer paths for PDF/HTML/Markdown instead
  of forcing everything through the text editor.

## Flutter UI Details

- Use `AutomaticKeepAliveClientMixin` for pages that must continue background UI
  work, such as streaming AI responses while another page is selected.
- Do not estimate chat context tokens directly in `build`; cache by active chat
  and message fingerprint so navigation and theme rebuilds stay cheap.
- Throttle streaming answer UI updates instead of calling `setState` for every
  SSE text chunk. Markdown parsing is expensive enough to make page switching
  stutter during long answers.
- Render the currently streaming assistant message as plain selectable text and
  only parse Markdown after the response completes.
- Prefer lazy page construction for the home `PageView`; eagerly constructing
  adjacent pages can load AI chat history even when the user starts on Servers.
- For the smoothest page swipes, let heavyweight pages know whether they are the
  settled active page. AI chat should not load stored history while it is merely
  an adjacent prebuilt page during a drag.
- Wrap main pages in `RepaintBoundary`, use `TickerMode` for non-active pages,
  and replace broad `context.watch` calls in the home shell with `select`ed
  fields so unrelated service notifications do not invalidate the swipe target.
- Cache log entry snapshots and level counts in `AppLogService`; repeated
  `toList().reversed` and per-chip scans in the log page add up quickly during
  AI/tool-heavy sessions.
- For SFTP lists, take one local entries snapshot per build and wrap rows in
  `RepaintBoundary`; avoid repeatedly calling service getters from every row.
- Provider `select` only helps if selected getters return stable values. Cache
  unmodifiable connection/session views in services instead of allocating a new
  list for every getter call.
- For chat switching, keyed `TweenAnimationBuilder` is safer than wrapping the
  message `ListView` in `AnimatedSwitcher` when a shared `ScrollController` is
  involved.
- Saving AI provider settings should not call broad `StorageService`
  notifications; persist them on demand, wait until the dialog route has
  finished a frame, then let the AI page update its own visible model state.
- If Android still reports Flutter `_dependents.isEmpty` when saving model/API
  key settings, move the settings UI out of `AlertDialog` and into a dedicated
  route. Dropdowns, secure-storage writes, keyboard focus, and log updates are
  much easier to sequence safely on a normal page.
- AI chat and settings errors must be logged through `AppLogService`, but log UI
  notifications should be deferred until after the current frame so logging does
  not rebuild provider dependents during route/dialog teardown.
- Repeated `RenderFlex overflowed ... on the bottom` errors usually mean a
  compact `Column` is inside a dialog, bottom input panel, toolbar, or
  keyboard-shrunk viewport without a scroll/height boundary. Wrap that local
  stack in `SingleChildScrollView`/`ListView`, or give the flexible middle area
  `Expanded`, before tuning pixel padding.
- If a RenderFlex overflow log does not identify project code, log the full
  `FlutterErrorDetails.toString()` output, not only `toStringShort()`. The full
  diagnostic tree can include the relevant widget and ownership chain needed to
  find fixed-height nav bars, tool panels, chips, and tiles.
- Do not animate a compact nav/tool panel's height while immediately swapping in
  taller `Row`/`Column` content. During the first expansion frames the full
  content is laid out in the old collapsed height and can report transient
  RenderFlex overflows. Switch the height immediately, then animate opacity or
  child transitions instead.
- When users say text cannot fit, prefer making the text area scrollable before
  hiding content or shrinking fonts. Distinguish prose from machine text: prose
  can wrap; paths, commands, logs, stack traces, model names, and other unbroken
  strings should be horizontally scrollable and selectable so nothing is hidden.
- Long model names need `isExpanded: true`, `selectedItemBuilder`, `maxLines: 1`,
  `overflow: TextOverflow.ellipsis`, and `softWrap: false` inside dropdowns.
- When the log page is reachable but removed from the navigation bar, map its
  selected navigation index to `null` so the navigation selected state
  disappears.

## Android Troubleshooting

- If Flutter builds and installs then fails with
  `INSTALL_FAILED_USER_RESTRICTED: Install canceled by user`, the phone blocked
  or canceled installation. Check USB install permission, debug authorization,
  OEM security prompts, and install restrictions.
- This error is different from Gradle build failure; the APK already exists.
