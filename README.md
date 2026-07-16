<p align="center">
  <img src="assets/app_icon_1024.png" alt="SSH Mobile icon" width="112" />
</p>

<h1 align="center">SSH Mobile</h1>

<p align="center">
  A cross-platform SSH, SFTP, server monitoring, and AI-assisted operations client for long-running remote sessions
</p>

<p align="center">
  <strong>English</strong> | <a href="./README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="https://github.com/hejulian2004/ssh_mobile/actions/workflows/flutter.yml"><img src="https://github.com/hejulian2004/ssh_mobile/actions/workflows/flutter.yml/badge.svg" alt="Flutter CI" /></a>
</p>

SSH Mobile is a Flutter-based cross-platform SSH and SFTP client for Android, iOS, macOS, Windows, and Web. It combines multi-window terminals, remote file management, server monitoring, secure storage, and OpenAI-compatible AI tools in a single mobile and desktop operations workspace.

The project began with a two-core server that had only 1 GB of memory. Running a complete AI agent directly on that machine was unreliable, so SSH Mobile moves model inference and agent orchestration to the client device. The client can then inspect and manage low-resource servers through SSH and SFTP without consuming their limited memory.

> Mobile operating systems may suspend background processes, switch networks, or reclaim the application process. For durable remote workspaces, use SSH Mobile together with `SSH + tmux`.

## How Codex and GPT-5.6 Were Used

Codex and GPT-5.6 were central to the AI-assisted development workflow for SSH Mobile. They accelerated implementation and analysis, while the developer retained responsibility for architecture, security decisions, validation, and the final code.

- **Codex** was used for repository-wide code exploration, feature implementation, refactoring, debugging, test generation, code review, and synchronization of documentation and maintenance scripts.
- **GPT-5.6** was primarily used to implement the following areas:
  - **1.5K and 2K phone UI adaptation:** introduced a centralized `MobileUiMetrics` policy based on the physical short edge, tightening control and navigation density for 1280–1440 px 1.5K screens while preserving standard proportions on 2K screens without scaling system text. It also refined responsive breakpoints and compact layouts across Servers, SFTP, Logs, Settings, and System Administration.
  - **UI and component refactoring:** compacted server cards, SFTP toolbars and file rows, log entries, and monitoring controls; extracted shared server-selector components for SFTP and System Administration; and supported the feature-first MVVM refactoring of startup, terminal, monitoring, and administration screens.
  - **Startup and runtime performance:** cached Material and Shad theme objects, limited root subscriptions to immutable visual settings, prevented terminal-font and other feature-scoped settings from rebuilding the complete application shell, preserved lazy page and tab activation, reduced rebuilds with `Selector`, cached chart and list calculations, and moved remote-output decoding, SFTP entry construction and sorting, and monitoring/system-administration parsing to background isolates.
  - Representative commits: [`33d5f63`](https://github.com/hejulian2004/ssh_mobile/commit/33d5f63e77381fe1c94b6feaf9967abb5926b4fb), [`97b52b5`](https://github.com/hejulian2004/ssh_mobile/commit/97b52b59ac31ce44e732a672ae61d65109304ad5), [`1e587bf`](https://github.com/hejulian2004/ssh_mobile/commit/1e587bf3d521fd9007cd2636d86ad69cc26b2320), [`833256a`](https://github.com/hejulian2004/ssh_mobile/commit/833256ab73134d474daea8aa9790678976f9c70b), [`3d2ceda`](https://github.com/hejulian2004/ssh_mobile/commit/3d2ceda56aba01be8f4452c492913b9f9fa11079), and [`9ffd48e`](https://github.com/hejulian2004/ssh_mobile/commit/9ffd48e2bc26fd3a3c6fc2cb83973076a7e01902).
- **Gemini** was also used to cross-check selected implementation and documentation decisions.
- Every AI-generated or AI-modified change was reviewed and passed through formatting, static analysis, automated tests, coverage checks, and manual verification before being retained.

AI is therefore both a product capability and a development collaborator in this repository. The project includes maintenance skills, non-sensitive project memory, deterministic validation commands, and quality gates designed to make agent-assisted engineering more controlled and reproducible.

## Highlights

- **SSH connection management** with passwords, private keys, encrypted private keys, jump hosts, server platform selection, and SSH host-key trust-on-first-use verification.
- **Multi-window terminals** that allow several fixed-name sessions per server and stable tmux session binding.
- **SFTP file management** with browsing, recent and favorite paths, uploads, downloads, editing, previews, and explicit deletion confirmation.
- **Server monitoring** for performance, ports, applications, services, users, and active sessions.
- **AI chat** with streaming output, Markdown, persistent history, message editing, regeneration, branching, and context compression.
- **AI tools** for server diagnostics, command execution, SFTP operations, client health checks, web access, logs, and backups.
- **Local MCP server** support on desktop platforms, including generated configuration for Codex, Claude Code, and Gemini CLI.
- **Secure storage** using platform secure storage, encrypted Drift fields, and encrypted preview caches.
- **Approval and redaction policies** for remote writes, sensitive reads, destructive operations, tool arguments, results, and logs.
- **Adaptive layouts** for phones, tablets, and desktop environments.
- **Backup and restore** for servers, terminal history, AI settings, chats, playbooks, metrics, and path records without exporting passwords, private keys, or API keys.

## Architecture

SSH Mobile uses a feature-first MVVM architecture with Provider and Selector for state management. UI composition, protocol adapters, persistent storage, monitoring, and AI orchestration are separated into independently testable layers.

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

### Project Structure

- `lib/main.dart`: application startup and dependency composition.
- `lib/features/`: feature-owned models, ViewModels, services, and views.
- `lib/services/`: SSH, SFTP, LLM, AI tools, monitoring, storage, and MCP infrastructure.
- `lib/data/`: Drift database, DAOs, and repository implementations.
- `lib/core/services/`: lower-level cross-feature services and factories.
- `lib/theme/`, `lib/widgets/`, `lib/utils/`: design system, reusable widgets, and utilities.
- `test/`: unit and widget tests.
- `docs/`: architecture, security, performance, validation, and release documentation.
- `scripts/`, `tool/`: build, generation, synchronization, and quality-check scripts.
- `third_party/xterm/`: vendored terminal package.

## AI Agent Runtime

The AI agent runs on the client rather than on the managed server. SSH Mobile builds the model context, calls an OpenAI-compatible provider, controls the tool loop, and accesses remote systems through SSH and SFTP.

The runtime currently includes:

- separate main, helper, and audit model roles with fallback policies;
- SSE streaming, persistent chat history, message branching, and context compression;
- request-specific tool exposure based on plan mode, approved plans, selected servers, and WebView availability;
- tool-call budgets, independent agent-loop limits, and safety audits before additional budget expansion;
- approvable `todoSteps` for one-off work and reusable playbooks for explicitly saved workflows;
- operational memory assembled from RAG chunks, AI skills, useful traces, and previous successful plans;
- client runtime health preflight checks for network, battery optimization, notification permissions, and thermal state;
- composite diagnostic tools for service health inspection, incident context collection, and server-state comparison.

### Tool Safety Boundaries

- Remote writes, uploads, renames, deletions, sensitive reads, and downloads require explicit approval.
- Destructive shell deletion commands are blocked.
- Environment-variable dumps, cloud metadata endpoints, and sensitive filesystem paths are restricted.
- `.ssh`, `.env`, private keys, tokens, cloud credentials, and other sensitive content are excluded from preview caches.
- Tool arguments, results, and traces are filtered or blocked by `ToolSecretPolicy`.
- Dangerous MCP tools return `approval_required` and cannot bypass the application approval interface.
- SSH session changes, tmux restoration, terminal-history deletion, log clearing, and monitoring state changes remain inside the same approval boundary.

## SSH and Terminal Sessions

The Servers page stores connection profiles, validates authentication details, and manages terminal windows. When a host key is first observed, the user must confirm its fingerprint. A later fingerprint change blocks the connection rather than silently trusting the new key.

Linux servers are designed to work well with `SSH + tmux`. Windows servers use plain SSH unless the target is WSL or another Linux-like shell. Fixed terminal window names make reconnection and tmux session restoration deterministic.

## SFTP Security and Performance

SFTP supports directory browsing, path history, favorites, uploads, downloads, text editing, and previews for text, Markdown, images, and sandboxed HTML.

External resources and navigation are blocked in Markdown and HTML previews. Remote PDFs are not parsed inside the application; users are instructed to download them and open them with a trusted reader. Deleting a file or directory requires entering its complete target name.

Configurable limits are available for downloads, text previews, rich previews, and editing. In-memory reads enforce hard limits and chunk validation before allocation. Large directory construction and sorting are moved to background isolates to prevent UI stalls.

## Server Monitoring

The monitoring workspace contains four primary sections:

- `Performance`: manual multi-server sampling with approximately ten minutes of in-memory history.
- `Ports`: single-server port snapshots and management operations.
- `Applications`: process snapshots.
- `Services`: service snapshots and management operations.

Linux monitoring reads sources such as `/proc` and `df -P`. Windows monitoring uses PowerShell JSON probes. Decoding, parsing, and sorting are performed in background isolates so the UI isolate receives processed results only.

## Local MCP Server

Desktop platforms can expose a local Streamable HTTP and JSON-RPC MCP endpoint:

```text
http://127.0.0.1:<port>/mcp
```

The current implementation binds only to `127.0.0.1`, uses a Bearer token, and rejects unauthenticated requests and non-local origins. The settings interface can check port availability, restart the service, regenerate the token, and copy configuration snippets for Codex, Claude Code, and Gemini CLI.

## Data and Storage

Growing structured data such as AI chats, agent metrics, terminal-history metadata, playbooks, and SFTP path records is stored with Drift. Small preferences remain in SharedPreferences. Passwords, private keys, API keys, and MCP tokens remain in platform secure storage.

Sensitive Drift fields—including AI message bodies, context, attachments, tool traces, todo steps, and playbook content—are encrypted before being written to SQLite. Startup migrations re-encrypt historical sensitive fields in retryable batches and log row counts without logging field values.

A production database failure does not silently fall back to an in-memory database, preventing apparently successful writes from disappearing after restart.

## Engineering Quality

### Verified Baseline

Local validation was completed on July 10, 2026, with Flutter 3.44.2 and Dart 3.12.2:

- `flutter analyze`: no issues.
- `flutter test --coverage`: 568 tests passed.
- Non-generated line coverage: 39.3% (`12690/32302`), with a 35% CI floor.
- Android debug and unsigned release APKs built successfully.
- Windows release build completed successfully.
- Icon generation, Drift generation, shared agent-skill synchronization, formatting, and diff checks are deterministic.

See [docs/VALIDATION_REPORT.md](docs/VALIDATION_REPORT.md) for the commands, verification scope, and device-dependent checks that remain.

### Test Coverage

Automated tests cover ViewModels, storage migrations, protocol parsing, LLM streaming, tool loops, approval policies, secret filtering, and selected UI components. GitHub Actions applies formatting, static analysis, test, coverage, and build quality gates.

## Development

### Requirements

- Flutter `>=3.44.0` with CI pinned to `3.44.2`
- Dart SDK `>=3.12.0 <4.0.0`
- Android Studio and Android SDK, or the corresponding platform toolchain
- Visual Studio with `Desktop development with C++` for Windows builds
- macOS and Xcode for iOS and macOS builds

### Common Commands

```bash
flutter pub get
dart format lib test tool
flutter analyze
flutter test
flutter test --coverage
dart run tool/check_coverage.dart --minimum=35
flutter devices
flutter run -d <device-id>
```

### Android

```bash
flutter build apk --debug
flutter build apk --release
flutter build appbundle --release
```

Outputs:

- `build/app/outputs/flutter-apk/`
- `build/app/outputs/bundle/release/app-release.aab`

### Windows

```powershell
flutter config --enable-windows-desktop
flutter build windows
powershell -ExecutionPolicy Bypass -File .\scripts\build_windows_msi.ps1
```

Outputs:

- `build/windows/x64/runner/Release/`
- `build/windows_msi/out/SSH_Mobile_Windows_v1.0.0_setup.msi`

### macOS

```bash
flutter config --enable-macos-desktop
flutter build macos
```

### iOS

```bash
flutter build ios --debug
flutter build ios --release
open ios/Runner.xcworkspace
```

## Agent Collaboration Files

- Codex maintenance skill: `.agents/skills/ssh-mobile-maintenance/SKILL.md`
- Claude Code maintenance skill: `.claude/skills/ssh-mobile-maintenance/SKILL.md`
- Non-sensitive cross-session project memory: `AGENT_MEMORY.md`

After modifying a shared skill, run:

```powershell
.\scripts\sync_agent_skills.ps1 -Mode Check
.\scripts\sync_agent_skills.ps1 -Mode Link -Force
```

Never store passwords, private keys, API keys, tokens, or server credentials in agent skills, project memory, logs, or documentation.

## Related Documentation

- [Release Checklist](docs/RELEASE_CHECKLIST.md)
- [Validation Report](docs/VALIDATION_REPORT.md)
- [Engineering Baseline ADR](docs/ADR_ENGINEERING_BASELINE.md)
- [Performance Acceptance](docs/PERFORMANCE_ACCEPTANCE.md)
- [Security Manual Regression](docs/security_manual_regression.md)
- [Android Native Rewrite Guide](docs/ANDROID_NATIVE_REWRITE_GUIDE.md)

## Operational Notes

- Background policies, network switching, and process reclamation can interrupt long-running connections.
- Android release builds disable cleartext traffic by default; debug and profile builds allow it only for local OpenAI-compatible provider testing.
- macOS credentials use standard Keychain configuration to avoid entitlement-related failures.
- Installing tmux on Linux servers is recommended so remote sessions survive client disconnection.

## License

This repository does not currently declare an open-source license. Add an explicit `LICENSE` file before public distribution or accepting external contributions.