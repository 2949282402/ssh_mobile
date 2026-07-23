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

**State management:** Provider and `ChangeNotifier`. `lib/main.dart` composes
application-lifetime infrastructure and shared feature ViewModels with
`MultiProvider`; use `Selector` and `context.select` in hot UI paths. Do not
add new application UI to `lib/screens/`: it is a legacy compatibility surface.

**Feature-first MVVM:** Feature-owned models, services, ViewModels, views, and
feature-local widgets live in `lib/features/<feature>/`. Current roots are
`connection`, `terminal`, `sftp`, `ai_chat`, `ai_skills`, `client_webview`,
`performance`, `system_admin`, `lan_share`, `playbook`, `rag`, `settings`,
`startup`, `home`, and `developer_log`. Shared UI belongs in `lib/widgets/` and
`lib/theme/`; protocol, storage, security, and cross-feature orchestration
belong in `lib/services/`, `lib/core/services/`, and `lib/data/`.

**Key ownership boundaries:**
- `ConnectionViewModel` owns saved-server validation and CRUD.
- `TerminalSessionViewModel`, `TerminalHistoryViewModel`, and
  `TerminalWindowsViewModel` own focused terminal state; `SshService` owns
  multi-session SSH/tmux transport.
- `SftpViewModel` owns feature state; `SftpService` owns SFTP transport and
  cache behavior.
- `AiChatViewModel` is screen-scoped. `AiChatRuntimeFactory` composes its
  `LlmChatService`, `AiToolService`, context, and generation collaborators.
- `PerformanceMonitorViewModel` owns multi-server monitoring selection;
  `SystemAdminViewModel` owns the single-server system-administration state.
- `StorageService` is the compatibility facade. Drift repositories and DAOs
  live under `lib/data/`; small preferences use SharedPreferences; passwords,
  private keys, API keys, and MCP tokens use secure storage.

**Core infrastructure:** `AppSettings`, `AppLogService`, `SshService`,
`SftpService`, `PerformanceMonitorService`, `SystemAdminService`,
`PlaybookService`, `RagService`, and `McpServerController` are composed in
`main.dart`. `SshHostKeyPolicy` and `DataProtectionService` live in
`lib/core/services/`. AI tool schemas/dispatch remain in `AiToolService` and
its `lib/services/ai_tool/` modules; remote commands use one-shot SSH exec,
and client tools are prefixed `client_`.

**Routes:** `onGenerateRoute` covers startup, terminal, terminal history and
windows, SFTP, system administration, AI Skills, Playbooks, connection
add/edit, and RAG knowledge. Additional feature state is created at the route
or owning view instead of becoming a global provider by default.

## Key patterns

- **Sensitive data:** Passwords, private keys, and API keys go to `flutter_secure_storage`, never `SharedPreferences`. Export/backup explicitly zeros out these fields.
- **Language:** Chinese is the default. Keep UI text centralized in
  `AppStrings`/`TerminalStrings` with Chinese and English entries.
- **Performance:** Drift-backed writes are flushed on lifecycle transitions.
  Keep large directory construction/sorting and remote-output parsing off the
  UI isolate, and prefer narrow Provider subscriptions over whole-service
  watches.
- **SSH sessions are NOT reused for AI tools** — AI tool commands use one-shot SSH exec connections. tmux sessions are only for interactive terminal windows.
- **Platform branching:** `ServerPlatform` enum drives OS-specific diagnostics (Linux uses `/proc`/`df`, Windows uses PowerShell). Windows + tmux combination is auto-corrected to plain SSH.
- **Background lifecycle:** `SshMobileApp` listens to `WidgetsBindingObserver` and flushes pending writes on pause/inactive/detach. `BackgroundServiceManager` initializes foreground service on Android and iOS.
- **Typography:** Use the native system font on every supported platform; the
  app no longer exposes an app-level font-family setting.
