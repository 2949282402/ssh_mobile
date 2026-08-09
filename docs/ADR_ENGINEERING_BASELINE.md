# Engineering Baseline ADR

> 最新更新时间：2026-08-09

Status: Accepted

Updated: 2026-08-09

## Decisions

- Keep Provider + `ChangeNotifier` as the app state-management baseline.
  Compose services and feature ViewModels in `lib/main.dart`, and optimize hot
  paths with `Selector`, `context.select`, and repaint boundaries instead of
  migrating frameworks.
- Keep a pure feature-first MVVM layout as the directory baseline. Put
  feature-owned models, services, ViewModels, views, and widgets under
  `lib/features/<feature>/<layer>/`. Keep truly shared UI in
  `packages/core/app_ui/` through `package:app_ui/app_ui.dart`; old app theme
  and migrated widget paths are compatibility exports. Keep infrastructure in
  `lib/services/`, `lib/core/services/`, and `lib/data/` until its numbered
  package migration Step.
- Split code by feature and responsibility before a non-generated Dart file
  reaches 1000 lines. Prefer independently importable collaborators; use Dart
  `part` files only for cohesive code that needs library-private access. Never
  hand-edit or split generated files such as `*.g.dart`.
- Keep screen classes thin. Routing, layout composition, and short-lived UI
  affordances may stay in screens; validation, async orchestration, repository
  coordination, and reusable feature state belong in ViewModels or services.
- Expose protocol and repository seams through small Dart interfaces
  (`SshClientAdapter`, `SftpClientAdapter`, `LlmClientAdapter`,
  `AiToolExecutor`, and repository contracts) so ViewModels and tests can
  inject fakes instead of real SSH/SFTP/LLM clients. App Shell adapters may
  compose repositories, but Feature/Core modules remain their data Owners.
- Keep AI server tools safe by default: read-only diagnostics may run directly,
  write-like commands require user approval, and delete/remove commands remain
  blocked.
- Store secrets in secure storage only. Export/import and durable memory must
  never include passwords, private keys, API keys, bearer tokens, or host
  credentials.
- Store growth-oriented structured data in the owning Feature/Core Drift
  repositories, small settings in SharedPreferences, and credentials in secure
  storage. `AppAiStorageAdapter` is only an injected AI Port adapter and does
  not own the shared App database. Sensitive AI content, traces, todo steps,
  and Playbook content must be encrypted before SQLite writes.
- Android release builds do not allow cleartext traffic by default. Debug and
  profile builds may allow cleartext for local provider/SearXNG testing.

## Follow-Up Work

- Preserve current feature and storage boundaries; do not reintroduce
  monolithic screens, ViewModels, services, or SharedPreferences JSON stores.
- Expand unit tests around ViewModels and protocol/storage seams before deeper
  refactors so regressions are caught without real SSH/SFTP/LLM network
  access.
- Keep new feature work MVVM-first and avoid reintroducing broad `context.watch`
  subscriptions in page hot paths.
