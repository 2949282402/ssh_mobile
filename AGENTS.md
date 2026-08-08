# Repository Guidelines

> 最新更新时间：2026-08-08

## Project Structure & Module Organization

The staged package migration currently includes `packages/features/feature_sftp/`,
`packages/features/feature_monitoring/`, `packages/features/feature_system_admin/`,
and `packages/features/feature_lan_share/`; their SFTP UI/Route state/path
Repository/`sftp.db`, Monitoring service/ports/models, and System Admin
UI/Route state/management service are the maintained implementations, while
the old App paths remain compatibility bridges. LAN Share additionally owns
`lan_share.db`, its transfer-history Repository, and its configurable Receiver
Module; the App Shell supplies settings, logging, data protection, identity,
and native-network adapters. `packages/features/feature_playbook/` now owns
the Playbook UI, approval-aware execution Service, Repository, and independent
`playbook.db`; the App Shell injects SSH, logging, and data-protection Ports.
`packages/features/feature_rag/` now owns the RAG UI, retrieval Service,
metadata Repository, bounded document cache, and independent `rag.db`; the App
Shell injects settings, API-key access, logging, and embedding Ports.
`packages/features/feature_mcp/` now owns the local MCP HTTP server, JSON-RPC
router, exposure/invocation policy, approval queue, activity Repository,
console UI, and independent `mcp.db`; App Shell adapters inject settings,
logging, and the AI tool runtime. MCP activities must not be added back to the
shared `AppDatabase` or `StorageService`.
`packages/features/feature_ai/` now owns AI chat, Agent, Skills, LLM provider/
runtime, tool orchestration, AI WebView contracts, and independent `ai.db`.
Its `AiModule` lazily owns the database and Repository; App Shell adapters in
`apps/ssh_mobile_full/lib/app/` inject only Core Capability contracts and App
Ports. The old `ai_chat`, `ai_skills`, and AI service paths remain non-owning
compatibility surfaces.
`packages/features/feature_ai/` now owns AI chat, Agent, Skills, LLM provider/
runtime, tool orchestration, AI WebView contracts, and independent `ai.db`.
Its `AiModule` lazily owns the database and Repository; App Shell adapters in
`apps/ssh_mobile_full/lib/app/` inject only Core Capability contracts and App
Ports. The old `ai_chat`, `ai_skills`, and AI service paths remain non-owning
compatibility surfaces.

This is a Dart workspace containing the full Flutter app for SSH, SFTP, server monitoring (including general metrics, port usage, process application performance, and service status), logs, LAN Quick Share, and OpenAI-compatible AI tools. The current full app lives in `apps/ssh_mobile_full/`: its `lib/` uses feature-first MVVM, its platform projects, assets, tests, and app-specific tools live beside it, and its `pubspec.yaml` is a workspace member. Cross-feature SSH/SFTP/storage/LLM infrastructure remains under `apps/ssh_mobile_full/lib/services/`; the MCP implementation is now owned by `packages/features/feature_mcp/`, while its App Shell adapters live under `apps/ssh_mobile_full/lib/app/`; shared security/protocol helpers remain under `apps/ssh_mobile_full/lib/core/services/`; Drift database and repositories remain under `apps/ssh_mobile_full/lib/data/`; shared UI now belongs to `packages/core/app_ui/`, while `apps/ssh_mobile_full/lib/theme/`, the migrated files under `apps/ssh_mobile_full/lib/widgets/`, and `apps/ssh_mobile_full/lib/utils/responsive.dart` remain only as compatibility exports; other helpers remain under `apps/ssh_mobile_full/lib/utils/`. `lib/models/` and `lib/screens/` inside the full app are legacy compatibility surfaces, not destinations for new work. Root-level `packages/core/`, `packages/infrastructure/`, and `packages/features/` are reserved for the staged modular migration; `packages/core/app_core/` owns pure Dart lifecycle/logging contracts, `packages/core/app_ui/` owns the shared theme, responsive metrics, and UI widgets, `packages/core/connection_core/` owns Connection domain models, repositories, the non-sensitive Connection Drift database, Secure Storage credentials, and Host Key contracts, `packages/features/feature_connection/` owns the migrated connection editor and ViewModel, `packages/features/feature_terminal/` owns the migrated terminal UI, route-scoped ViewModels, terminal output history, and `terminal.db`, and `packages/features/feature_mcp/` owns MCP server state, approval policy, console state, and `mcp.db`. The old terminal paths under `apps/ssh_mobile_full/lib/features/terminal/` and their tests remain compatibility exports/bridges during migration, not duplicate implementation destinations. `packages/infrastructure/network_transport/` owns the App Scope network facade and native handle adapter, `packages/infrastructure/ssh_core/` owns SSH session/runtime/pool/client contracts, and `packages/infrastructure/ssh_mobile_network_native/` owns the lower-level Dart/FFI binding. Root `pubspec.yaml` and `melos.yaml` define workspace tooling, with Melos pinned as a root development dependency, while `docs/`, `scripts/`, `installer/`, `.github/`, and `third_party/` remain repository-level directories. The vendored terminal package under `third_party/xterm/` is excluded from the full app analyzer.

## High-Level Architecture

Feature-first MVVM with Provider/Selector for state. UI composition, protocol adapters, persistent storage, monitoring, and AI orchestration are independent, separately testable layers:

```mermaid
flowchart LR
  Views[Feature Views] --> ViewModels[Feature ViewModels]
  ViewModels --> Services[SSH / SFTP / Monitor / AI Services]
  Services --> Protocols[SSH / SFTP / HTTP / WebView Adapters]
  Services --> Storage[StorageService Facade]
  Storage --> Drift[Encrypted Drift Repositories]
  Storage --> Secure[Platform Secure Storage]
  AI[AI Orchestration] --> Services
  AI --> Safety[Approval and Secret Policies]
```

- `apps/ssh_mobile_full/lib/main.dart` only delegates to `lib/app/app_bootstrap.dart`; `AppRuntimeFactory` creates App Scope services and `AppRuntime` owns their lifecycle. `AppRuntime.logger` exposes the Core `AppLogger` contract, currently backed by the App-layer `AppLogService` adapter; its `scope(name)` views do not own or dispose the root Logger. `SshMobileApp` exposes existing Runtime instances with `ChangeNotifierProvider.value`, while route/screen-scoped state stays local — e.g. the AI chat runtime is created by `AiChatRuntimeFactory` and provided by the chat view; terminal screens create focused session/history/window ViewModels. `AppBootstrapCoordinator` still starts preference and storage setup without blocking `runApp()`. Views hold layout and transient presentation state; validation, async orchestration, and repository coordination belong in ViewModels and services.
- `packages/core/connection_core/` is the Connection data boundary. `AppRuntime` creates exactly one `ConnectionDatabase`, `ConnectionRepository`, `CredentialRepository`, and Host Key capability; the database stores no password/private-key columns, and the module uses a new `connection.sqlite` baseline. `packages/features/feature_connection/` consumes only the Core repositories and injected runtime/verification contracts. Until SSH/SFTP finish their later Steps, `apps/ssh_mobile_full/lib/app/connection_feature_adapters.dart` performs the minimum old-Storage synchronization; that bridge is outside the Feature and is not a second Feature data API.
- `packages/infrastructure/network_transport/` is the App Scope network boundary. `AppRuntimeFactory` creates one lazy `NetworkRuntime`, `AppRuntime` disposes it after SSH/SFTP stop, and Features request only public Capability contracts. The package currently wraps the existing native v1 handle; it does not add a second TCP/UDP/QUIC/WebRTC implementation.
- `packages/infrastructure/ssh_core/` is the App Scope SSH boundary. Its public
  `SshSessionManager`, `SshSessionLease`, Session Pool, Runtime Adapter, Client,
  Host Key, command, and target-binding contracts do not depend on
  `StorageService` or Features. `AppRuntime` owns one Manager instance; the
  current `SshService` is the same-instance compatibility implementation until
  the Terminal Pilot completes the method-level migration. Feature code must
  release leases and must not close shared Sessions directly.
- `packages/core/app_ui/` is the shared UI boundary. Its public entry point is
  `package:app_ui/app_ui.dart`; it has no Feature, SSH, network, database, or
  App Service dependency. The old app theme/responsive/widget paths are
  compatibility exports only, and Feature-specific widgets remain in their
  owning Feature.
- `packages/features/feature_terminal/` is the first complete Feature Pilot. It
  owns terminal presentation/application code, the route-scoped
  `TerminalModule`, terminal metadata `terminal.db`, and the terminal history
  repository. It receives `ssh_core.SshSessionManager` and App/connection/logging
  Ports; it must not create or dispose the App Scope SSH Manager. The App Shell
  keeps only adapters and compatibility exports until later Storage/SSH Steps.
- `packages/features/feature_sftp/` owns the SFTP Route UI, Port contracts,
  path-history/favorites Repository, and `sftp.db`. It receives the App Scope
  `ssh_core.SshSessionManager` and a compatibility backend through the App Shell;
  it never creates a global SSH manager or closes the App-owned legacy SFTP
  backend. The old SFTP paths remain compatibility surfaces until later service
  convergence Steps.
- `packages/features/feature_monitoring/` owns real-time monitoring models,
  parser/probe code, low-priority SSH Ports, the monitoring Module, and its
  route-scoped ViewModel. It deliberately has no monitoring database: the
  current product keeps only the existing in-memory sampling history. The
  AppRuntime owns the Module/service, while old Performance Monitor service and
  tool paths remain non-owning compatibility bridges.
- `packages/features/feature_system_admin/` owns System Administration UI,
  route ViewModel, management command service, lifecycle Module, and the local
  monitoring Capability contract. It never imports `feature_monitoring`
  implementation; App Shell adapters provide SSH, connection catalog, SFTP
  home-directory snapshots, settings, logger, Host Key confirmation, and
  monitoring data. The old System Admin paths remain compatibility surfaces.
- `packages/features/feature_lan_share/` owns LAN discovery, pairing,
  HTTPS/WebSocket transfer, Web Share, transfer history, non-secret pairing
  metadata, and the `LanShareModule`. It depends on `network_transport`,
  `app_core`, and `app_ui`, never on SSH or another Feature. The App Shell
  adapter lives in `apps/ssh_mobile_full/lib/app/lan_share_feature_adapters.dart`;
  old LAN paths remain compatibility surfaces.
- `packages/features/feature_playbook/` owns Playbook UI, approval-aware
  sequential execution, encrypted run history, and `playbook.db`. It consumes
  only public Core/SSH contracts and injected App Ports; AI uses its public
  `PlaybookAutomationPort` boundary.
- `packages/features/feature_rag/` owns RAG document parsing, BM25/vector/Hybrid
  retrieval, metadata Repository, bounded file cache, `rag.db`, and route-scoped
  knowledge-base state. AI consumes only `RagCapability`; the Package never
  reads or migrates old RAG database files and never stores document正文 or
  large vectors in Drift.
- `packages/features/feature_ai/` owns AI chat, Agent, Skills, LLM providers and
  runtime, tool registry/orchestration, AI WebView contracts, and `ai.db`.
  `AiModule` owns lazy database/Repository initialization and disposal. AI
  consumes only `app_core` Capability contracts and injected App Ports; it
  never imports another Feature implementation or an App `/src/` path.
- Current legacy feature roots under `apps/ssh_mobile_full/lib/features/`:
  `connection`, `terminal`, `sftp`, `ai_chat`, `ai_skills`, `client_webview`,
  `performance`, `system_admin`, `lan_share`, `playbook`, `rag`, `settings`,
  `startup`, `home`, `developer_log`, `developer_panel`.
  `ai_chat`/`ai_skills` are compatibility surfaces owned by
  `packages/features/feature_ai/`. Migrated LAN UI belongs in
  `packages/features/feature_lan_share/`; migrated
  Playbook UI belongs in `packages/features/feature_playbook/`; new UI
  otherwise belongs in the owning feature, including `packages/features/feature_mcp/`
  for MCP UI. It never belongs in `apps/ssh_mobile_full/lib/screens/`
  (legacy) or `apps/ssh_mobile_full/lib/models/` (legacy shared surface).
- Monitoring presentation remains under the existing `performance` and System
  Administration UI during this migration; new monitoring application code
  belongs in `packages/features/feature_monitoring/`, not in a second App
  service implementation.
- Cross-feature compatibility infrastructure in `apps/ssh_mobile_full/lib/services/` includes SSH/SFTP, monitoring, storage, legacy LAN-share, and App adapters. AI implementation belongs in `packages/features/feature_ai/`; MCP implementation belongs in `packages/features/feature_mcp/`; the App Shell only provides their adapters. `apps/ssh_mobile_full/lib/core/services/` holds lower-level shared security/protocol factories (host-key policy, data protection). `apps/ssh_mobile_full/lib/data/` holds the remaining App Drift database, DAOs, and repositories. New shared infrastructure belongs in the appropriate package under `packages/` only when its current Step permits migration.
- Storage layering: Feature-owned Drift databases hold growing structured data: AI chats/agent metrics/traces in `ai.db`, terminal-history metadata in `terminal.db`, playbooks in `playbook.db`, SFTP path records in `sftp.db`, and RAG/MCP metadata in their respective databases. Sensitive fields are encrypted at rest; small preferences stay in SharedPreferences; passwords, private keys, API keys, and MCP tokens only in platform secure storage (`flutter_secure_storage`). A production DB failure must not silently fall back to an in-memory database.

AI agent runtime (client-side, not on the managed server): model context is built on-device, the provider is called, and the tool loop reaches remote systems via SSH/SFTP. Tool safety boundaries are enforced in code, not just prompts:

- Remote writes, uploads, renames, deletions, sensitive reads, and downloads require explicit approval.
- Destructive shell deletion commands are blocked; env-var dumps, cloud metadata endpoints, and sensitive paths are restricted.
- `.ssh`, `.env`, private keys, tokens, and cloud credentials are excluded from preview caches; tool arguments/results/traces are filtered by `ToolSecretPolicy`.
- Approvals bind to immutable server/provider/playbook/skill/monitor snapshots; an action is rejected if its snapshot is no longer current.
- Dangerous MCP tools return `approval_required` and cannot bypass the in-app approval UI.

## Build, Test, and Development Commands

Dependency and code generation (run after `pubspec.yaml` or Drift model changes):

- `dart pub get`: resolve the root Dart workspace from `pubspec.yaml`.
- `dart run melos exec --scope=app_core -- dart analyze .`: analyze the Core contract package.
- `dart run melos exec --scope=app_core -- flutter test --no-pub`: run Core contract tests.
- From `apps/ssh_mobile_full/`, `dart run build_runner build`: regenerate Drift DAOs (`lib/data/database/app_database.g.dart`) and other codegen. Generated files are committed; verify with `git diff --exit-code -- apps/ssh_mobile_full/lib/data/database/app_database.g.dart`.
- From `apps/ssh_mobile_full/`, `dart run tool/generate_app_icons.dart`: regenerate app icons. Verify with `git diff --exit-code -- apps/ssh_mobile_full/assets apps/ssh_mobile_full/android apps/ssh_mobile_full/ios apps/ssh_mobile_full/macos apps/ssh_mobile_full/web apps/ssh_mobile_full/windows/runner/resources/app_icon.ico`.

Static checks and formatting:

- `dart format apps/ssh_mobile_full/lib apps/ssh_mobile_full/test apps/ssh_mobile_full/tool`: format full-app Dart code.
- `dart format packages/core/app_core/lib packages/core/app_core/test`: format Core contract code.
- `dart format packages/core/app_ui/lib packages/core/app_ui/test`: format shared UI code.
- `dart format packages/features/feature_connection/lib packages/features/feature_connection/test`: format the Connection Feature package.
- `dart format packages/infrastructure/network_transport/lib packages/infrastructure/network_transport/test`: format the Network Transport package.
- `dart format packages/infrastructure/ssh_core/lib packages/infrastructure/ssh_core/test`: format the SSH Core package.
- `dart format packages/features/feature_terminal/lib packages/features/feature_terminal/test`: format the Terminal Feature package.
- `dart format packages/features/feature_sftp/lib packages/features/feature_sftp/test`: format the SFTP Feature package.
- `dart format packages/features/feature_monitoring/lib packages/features/feature_monitoring/test`: format the Monitoring Feature package.
- `dart format packages/features/feature_system_admin/lib packages/features/feature_system_admin/test`: format the System Admin Feature package.
- `dart format packages/features/feature_lan_share/lib packages/features/feature_lan_share/test`: format the LAN Share Feature package.
- `dart format packages/features/feature_playbook/lib packages/features/feature_playbook/test`: format the Playbook Feature package.
- `dart format packages/features/feature_rag/lib packages/features/feature_rag/test`: format the RAG Feature package.
- `dart format packages/features/feature_ai/lib packages/features/feature_ai/test`: format the AI Feature package.
- `dart format --output=none --set-exit-if-changed apps/ssh_mobile_full/lib apps/ssh_mobile_full/test apps/ssh_mobile_full/tool`: format check that fails on diffs (used in CI).
- From `apps/ssh_mobile_full/`, `flutter analyze`: run static analysis using the app's `analysis_options.yaml`. `third_party/**` is excluded from the analyzer.
- From `apps/ssh_mobile_full/`, `flutter test`: run all Flutter tests under the app's `test/`.
- From `apps/ssh_mobile_full/`, `flutter test test/path/to/file_test.dart`: run a single test file.
- From `packages/features/feature_connection/`, `flutter analyze` and `flutter test`: validate the Connection Feature package.
- From `packages/infrastructure/network_transport/`, `flutter analyze` and `flutter test`: validate the Network Transport package. Native hook tests require the repository Rust toolchain on PATH.
- From `packages/infrastructure/ssh_core/`, `flutter analyze` and `flutter test`: validate the SSH Core Session Pool, Runtime, Client, Host Key, and target contracts.
- From `packages/features/feature_terminal/`, `flutter analyze` and `flutter test`: validate the Terminal Feature package. Run full App checks from `apps/ssh_mobile_full/` so Flutter hooks select the App package and Windows native assets.
- From `packages/features/feature_sftp/`, `flutter analyze` and `flutter test`: validate the SFTP Feature package and its `sftp.db` lifecycle tests. Run full App checks from `apps/ssh_mobile_full/` so Flutter hooks select the App package and Windows native assets.
- From `packages/features/feature_monitoring/`, `flutter analyze` and `flutter test`: validate the Monitoring Feature package, explicit sampling lifecycle, and low-priority SSH Port contract. Monitoring activation restores module availability but does not start polling until the existing user/tool start action.
- From `packages/features/feature_system_admin/`, `flutter analyze` and `flutter test`: validate the System Admin Module lifecycle, management command parsing, and injected Port boundaries. Activation must not connect to a server automatically; disposal must close the Module-owned management session.
- From `packages/features/feature_lan_share/`, `flutter analyze` and `flutter test`: validate the LAN Share Module lifecycle, independent `lan_share.db`, transfer safety limits, and injected App/Network Ports. Receiver activation is controlled by Module configuration; Feature code must not construct native network or SSH implementations.
- From `packages/features/feature_playbook/`, `flutter analyze` and `flutter test`: validate the Playbook Module lifecycle, independent `playbook.db`, encrypted run history, approval target binding, and public AI capability boundary.
- From `packages/features/feature_rag/`, `flutter analyze` and `flutter test`: validate the RAG Module lifecycle, independent `rag.db`, metadata-only persistence, bounded cache policy, and BM25/vector/Hybrid retrieval through injected Ports.
- From `packages/features/feature_ai/`, `flutter analyze` and `flutter test`: validate the lazy AI Module/`ai.db` lifecycle, encrypted chat/metrics/trace Repository, AI Capability contracts, LLM providers, tool safety, and route-scoped runtime.
- From `packages/core/app_ui/`, `flutter analyze` and `flutter test`: validate the shared theme, responsive helpers, and UI widgets.
- From `apps/ssh_mobile_full/`, `flutter test --coverage --reporter expanded`: run tests with coverage.
- From `apps/ssh_mobile_full/`, `dart run tool/check_coverage.dart --minimum=35`: enforce the 35% non-generated line-coverage floor (CI gate).

Full local quality gate (fast loop):

```bash
dart pub get
dart format --output=none --set-exit-if-changed apps/ssh_mobile_full/lib apps/ssh_mobile_full/test apps/ssh_mobile_full/tool
cd apps/ssh_mobile_full
flutter analyze
flutter test
```

Run and platform builds:

- From `apps/ssh_mobile_full/`, `flutter devices`: list available targets.
- From `apps/ssh_mobile_full/`, `flutter run -d <device-id>`: run locally on a device, emulator, or desktop target (`android`, `windows`, `macos`, `chrome`, or a device ID).
- From `apps/ssh_mobile_full/`, `flutter build apk --debug`: build an Android debug APK. Release: `flutter build apk --release` / `flutter build appbundle --release`.
- From `apps/ssh_mobile_full/`, `flutter build macos`: build the macOS desktop app (enable first with `flutter config --enable-macos-desktop`).
- From `apps/ssh_mobile_full/`, `flutter build ios --release --no-codesign`: build iOS on macOS (requires iOS 14.0+).
- From `apps/ssh_mobile_full/`, `flutter build windows`: build the Windows desktop app (enable first with `flutter config --enable-windows-desktop`).
- `powershell -ExecutionPolicy Bypass -File .\scripts\build_windows_msi.ps1`: build the Windows MSI installer.

Agent skill sync (run after editing shared skills):

- `powershell -ExecutionPolicy Bypass -File .\scripts\sync_agent_skills.ps1 -Mode Check`
- `powershell -ExecutionPolicy Bypass -File .\scripts\sync_agent_skills.ps1 -Mode Link -Force`

## Coding Style & Naming Conventions

Use standard Dart formatting and `flutter_lints`. Prefer two-space indentation, `lower_snake_case.dart` filenames, `UpperCamelCase` classes/widgets, and `lowerCamelCase` members. Keep UI text centralized in `AppStrings`/`TerminalStrings` or the owning package's localized string contract, such as `feature_connection`'s `ConnectionStrings`. Route new module diagnostics through an injected `AppLogger` scope; the current App adapter remains `AppLogService` until later Feature migration. Do not use ad hoc `print` calls for app diagnostics. Keep shared UI styling in `package:app_ui/app_ui.dart`; the old app theme path is compatibility-only.

Every maintained Markdown document must place a `最新更新时间：YYYY-MM-DD` (or
`Last updated: YYYY-MM-DD` for English-first documentation) marker at its
beginning, immediately after YAML front matter when present. Update that marker
whenever the document content changes.

## Testing Guidelines

Add focused tests under `test/` with names ending in `_test.dart`. Use `flutter_test` for widget and unit coverage. Run `flutter test` and `flutter analyze` before submitting changes. Broaden tests when touching shared services such as storage, SSH/SFTP behavior, LLM tool dispatch, or platform branching. Automated tests use fakes and controlled fixtures and require no real SSH credentials or API keys — never commit real secrets into test fixtures, screenshots, or logs.

Deeper architecture, security, performance, and release detail lives in `docs/` (e.g. `MOBILE_UI_QA.md`, `RELEASE_CHECKLIST.md`, `VALIDATION_REPORT.md`, `ADR_ENGINEERING_BASELINE.md`, `PERFORMANCE_ACCEPTANCE.md`, `security_manual_regression.md`, `ANDROID_NATIVE_REWRITE_GUIDE.md`). The README is the user-facing source of truth for setup, configuration, and the integration checklist.

## Commit & Pull Request Guidelines

Recent commit subjects are short and direct, often English or Chinese, for example `add log`, `update`, or `font config`. Keep commits scoped and imperative when possible. Pull requests should include a clear summary, validation commands run, linked issues if applicable, and screenshots or screen recordings for UI changes.

## Security & Agent-Specific Notes

Never commit passwords, private keys, API keys, tokens, or server credentials. Store secrets through `flutter_secure_storage`, not `SharedPreferences`, and keep exports credential-free. Read `AGENT_MEMORY.md` before non-trivial maintenance work. Keep `.agents/skills/ssh-mobile-maintenance/SKILL.md` and `.claude/skills/ssh-mobile-maintenance/SKILL.md` synchronized with `.\scripts\sync_agent_skills.ps1 -Mode Check` after skill edits.
