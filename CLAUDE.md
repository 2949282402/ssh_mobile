# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Skill And Memory

Claude Code can discover the project skill at `.claude/skills/ssh-mobile-maintenance/SKILL.md`.
That file is kept synchronized with the Codex skill at `.agents/skills/ssh-mobile-maintenance/SKILL.md`; run `.\scripts\sync_agent_skills.ps1 -Mode Check` after skill edits, or `.\scripts\sync_agent_skills.ps1 -Mode Link -Force` to restore the local hard link.

Read `AGENT_MEMORY.md` before non-trivial code, documentation, or skill changes. It is the shared durable memory surface for Codex and Claude Code; do not put secrets or private credentials there.

## Common Commands

```bash
flutter pub get              # Install dependencies
dart format lib test         # Format Dart code
flutter analyze              # Static analysis
flutter test                 # Run tests
flutter clean                # Clean build artifacts
flutter devices              # List connected devices
flutter run -d <device-id>   # Run on specific device
flutter build apk --debug    # Android debug APK
flutter build apk --release  # Android release APK
flutter build windows        # Windows desktop
flutter build macos          # macOS (requires Xcode on macOS)
flutter build ios --release  # iOS (requires Xcode on macOS)
```

Windows MSI installer:
```bash
powershell -ExecutionPolicy Bypass -File .\scripts\build_windows_msi.ps1
```

The `third_party/` directory is excluded from analysis (`analysis_options.yaml`).

## Architecture

**State management:** Provider (`MultiProvider` in `lib/main.dart`). All services extend `ChangeNotifier` and are injected at the app root.

**Core services** (all in `lib/services/`, all registered at app level in `main.dart`):
- `storage_service.dart` — Central persistence layer. Uses `SharedPreferences` (encrypted via `DataProtectionService`) for config/list data and `flutter_secure_storage` for secrets (passwords, private keys, API keys). In-memory caches with debounced writes for high-frequency data (AI chats, skills, tmux sessions, terminal history). Some lists capped (AI chats: 80, terminal history: 200).
- `ssh_service.dart` — Multi-session SSH management via `dartssh2`. Manages `SshSession` objects with per-session output streams, tmux integration, keep-alive, and reconnect.
- `sftp_service.dart` — SFTP connections, caching, file operations.
- `llm_chat_service.dart` — OpenAI-compatible chat API client. Handles streaming, tool calls, web search, thinking/reasoning for DeepSeek models. Uses `dart:io` `HttpClient` directly (not a package HTTP client).
- `ai_tool_service.dart` — Function tool definitions and dispatching. Tools are defined as `AiTool` objects with name, description, JSON Schema properties, `required` fields, and a `handler` function. Server tools execute via one-shot SSH exec (never tmux). Client tools prefixed `client_`.
- `background_service.dart` — Android/iOS foreground service, notifications, WakeLock, power optimization checks. Platform-specific via `MethodChannel`.
- `app_settings.dart` — Theme mode, language (zh/en), font family, SFTP size limits. Uses `SharedPreferences` directly.
- `app_log_service.dart` — Application-wide structured logging with source file/line info.
- `performance_monitor_service.dart` — Server CPU/memory/disk/network/service status polling via SSH exec.
- `shortcut_command_service.dart` — Terminal shortcut bar commands with user-defined order.
- `server_status_probe.dart` — Read-only SSH exec probes for AI tools (performance, ports, applications, services).
- `client_system_tool_service.dart` — Client-side tool implementations (time, device info, network, battery, clipboard, alarms).

**Main screens** (`lib/screens/`):
- `home_screen.dart` — Bottom navigation hub (AI, Servers, SFTP, Monitor - with Performance, Ports, Apps, and Services tabs). Servers page includes embedded terminal window management.
- `llm_chat_screen.dart` — AI chat with multi-session, streaming Markdown, tool approval, context management, branching.
- `terminal_screen.dart` — Full-screen xterm terminal with shortcut bar, font scaling, tmux session binding.
- `sftp_screen.dart` — Remote file browser with upload/download/delete/edit/preview.

**Models** (`lib/models/`): Only `connection.dart` — `ConnectionConfig` (server connection parameters, auth, platform, launch mode) plus enums (`ServerPlatform`, `TerminalLaunchMode`, `AuthMethod`). Other record types (`AiChatRecord`, `AiSkillRecord`, `RestorableTmuxSession`, `TerminalHistoryRecord`) are defined within `storage_service.dart`.

**Routing:** Named routes via `onGenerateRoute` in `main.dart`: `/` (startup), `/terminal`, `/history`, `/sftp`, `/performance`, `/ai-skills`, `/add`, `/edit`.

## Key patterns

- **Sensitive data:** Passwords, private keys, and API keys go to `flutter_secure_storage`, never `SharedPreferences`. Export/backup explicitly zeros out these fields.
- **Language:** Chinese default. All UI strings are in `AppStrings` and `TerminalStrings` classes in `app_settings.dart`. When adding text, add both zh and en entries.
- **Performance:** High-frequency writes (AI chats, tmux sessions, terminal history) are debounced (`_protectedPrefWriteDebounce` = 700ms) and flushed on app backgrounding. Caches are returned as `List.unmodifiable` to prevent accidental mutation.
- **SSH sessions are NOT reused for AI tools** — AI tool commands use one-shot SSH exec connections. tmux sessions are only for interactive terminal windows.
- **Platform branching:** `ServerPlatform` enum drives OS-specific diagnostics (Linux uses `/proc`/`df`, Windows uses PowerShell). Windows + tmux combination is auto-corrected to plain SSH.
- **Background lifecycle:** `SshMobileApp` listens to `WidgetsBindingObserver` and flushes pending writes on pause/inactive/detach. `BackgroundServiceManager` initializes foreground service on Android and iOS.
- **Font handling:** App does NOT bundle font files. Font choices reference platform-installed fonts or open-source font family names.
