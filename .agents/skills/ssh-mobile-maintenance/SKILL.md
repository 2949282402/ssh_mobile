---
name: ssh-mobile-maintenance
description: Use when modifying or debugging this SSH Mobile Flutter project, especially SSH/tmux sessions, SFTP file operations, AI chat, OpenAI-compatible LLM streaming, AI tool definitions, settings persistence, logs, navigation behavior, Android device launch/install failures, README updates, or project documentation.
---

# SSH Mobile Maintenance

## Quick Start

Before changing code, inspect the existing pattern in `lib/screens/` and
`lib/services/`. Keep changes narrow and run validation afterward:

```powershell
$env:PUB_HOSTED_URL='https://pub.flutter-io.cn'
& 'E:\coding\flutter_windows_3.41.9-stable\flutter\bin\flutter.bat' analyze
& 'E:\coding\flutter_windows_3.41.9-stable\flutter\bin\flutter.bat' build apk --debug
```

If the local Flutter SDK path is different, discover it instead of hardcoding a
new path in source or docs.

## Maintenance Rules

- Preserve user work in the git tree. Do not revert unrelated dirty files.
- Prefer project services over duplicating protocol code.
- Write logs for SSH, SFTP, LLM requests, AI tools, and caught failures through
  `AppLogService` so the log page remains useful.
- Keep mobile and Windows behavior consistent for shared SSH/SFTP features.
- Keep model configuration in the LLM settings dialog. Do not add another model
  selector on the chat page.
- Keep AI server tools safe by default: read-only diagnostics run directly, any
  command that may write or change server state must pause for explicit human
  approval in the chat page, and credential exposure remains blocked.
- When code changes add, remove, rename, or materially change files, features,
  navigation entries, settings, AI tools, dependencies, or platform behavior,
  update this skill and `README.md` in the same task so documentation stays in
  sync with the project.
- When writing or changing code, add concise maintenance comments for non-obvious
  behavior, lifecycle constraints, protocol quirks, safety gates, or context
  management decisions. Avoid noisy comments that only restate the code.

## Common Workflows

### LLM Chat and Tools

Use `lib/services/llm_chat_service.dart` for provider protocol behavior and
`lib/services/ai_tool_service.dart` for model-callable tools.

- Stream chat with SSE (`stream: true`) and surface chunks immediately to the UI.
- Tool calls may arrive split across multiple SSE deltas. Accumulate id, name,
  and argument fragments before executing tools.
- The chat input `+` toolbar should display the current tool catalog from
  `AiToolService.tools`, not a duplicated UI-only list, so tool maintenance stays
  centralized.
- The same toolbar includes a Skills entry that opens the custom AI Skills
  manager. Keep skill storage in `StorageService`, and keep the manager page
  theme-aware, bilingual, and flexible enough for SKILL.md-style content,
  references, templates, and maintenance notes. Custom skills have an enabled
  flag; disabled skills remain editable but should not appear in chat selection
  or be injected into request context.
- The toolbar can also select a default target server, insert prompt templates,
  and temporarily apply a custom Skill. Add those as user-message `contextText`
  rather than changing the main system prompt, so provider prompt caches stay
  useful.
- DeepSeek thinking mode can return `reasoning_content`. If the response has
  tool calls, pass `reasoning_content` back unchanged in the assistant tool-call
  message. Surface reasoning, tool requests, tool results, and approval outcomes
  as collapsed chat trace details; keep them out of future model context.
- Track context window usage with the selected 259K, 512K, or 1M limit. When
  estimated usage reaches 90%, call the current model to summarize older
  history before continuing the user request.
- Keep the primary system prompt stable for cache hits. If old history is
  compressed, pass the summary as a normal assistant memory message instead of
  injecting dynamic system text.
- Preserve full chat display text, but avoid sending every stored byte back to
  the model. Long generated documents, HTML, or multi-code-block outputs should
  use compact message context such as `AiChatMessageRecord.contextText`.
- When editing a past user message or regenerating an assistant reply, truncate
  messages after that point and regenerate fresh assistant text, traces, token
  stats, and `contextText`. Chat branches should copy messages through the
  selected assistant reply and continue with the same context slimming rules.
- Store per-assistant-message token and elapsed-time metadata and render it as
  small, low-emphasis text below the message bubble.
- If users report `too many tool rounds`, inspect both tool loop limits and
  whether the command whitelist blocks reasonable read-only discovery commands.
- If adding write-capable tools, preserve the approval gate: show the exact
  server and command in the chat page, execute only after approval, and let
  rejection abort the current operation so the user can give new instructions.
- Keep AI command execution on the plain one-shot SSH exec path. Do not attach
  tmux or reuse interactive terminal sessions for LLM tools.

### SFTP

Use `lib/services/sftp_service.dart` for connection/session behavior and
`lib/screens/sftp_*.dart` for UI.

- Keep multi-server switching warm when possible.
- Remember the last remote path per connection and restore it after reconnect.
- Require confirmation before delete.
- Prefer separate editor/viewer pages for larger editing and previews.
- Keep upload, download, edit, delete, preview behavior aligned across mobile
  and Windows.

### Navigation and Chat UX

Current main page order is Servers, Windows, SFTP, AI, then Logs. The mobile
bottom navigation and desktop rail show only Servers, Windows, SFTP, and AI;
Logs sits to the right of AI in the `PageView`.

Use keyed animations for chat switching. Avoid an `AnimatedSwitcher` around a
`ListView` that shares a `ScrollController`, because it can briefly mount two
lists with the same controller.

Use `AutomaticKeepAliveClientMixin` for the AI chat page so streaming responses
continue while the user switches to another navigation page.

The Servers page opens the settings drawer on a left swipe. Keep data
export/import there. Backup JSON should include saved servers, restorable
windows, terminal history, AI settings, AI chats, and custom skills, but must
not export passwords, private keys, API keys, tokens, or other secrets. Imports
should leave those credential fields empty so users reconfigure them.

### Android Device Launch

`INSTALL_FAILED_USER_RESTRICTED` usually means the phone blocked USB install or
the user canceled the install prompt. It is not a Gradle or Flutter compile
failure when the APK was already built successfully.

## References

Read [references/lessons.md](references/lessons.md) when the task touches LLM
streaming, DeepSeek errors, SFTP reconnects, navigation animation, README
encoding, or Android install/debug issues.

Before finishing any code-change task, check whether `README.md` or this skill
needs to change. Prefer small documentation updates over letting docs drift.
