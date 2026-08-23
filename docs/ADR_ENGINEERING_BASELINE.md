> 最新更新时间：2026-08-23

# Engineering Baseline ADR

Status: Accepted

## Decisions

- Keep Provider + `ChangeNotifier` as the app state-management baseline.
  Compose App Scope resources in `apps/ssh_mobile_full/lib/app/`; Feature route
  scopes create their own ViewModels. Optimize hot paths with `Selector`,
  `context.select`, and repaint boundaries instead of migrating frameworks.
- Keep package-first feature MVVM as the directory baseline. Feature-owned
  models, services, ViewModels, views, and widgets live in the owning
  `packages/features/feature_*` member; shared contracts and UI live in
  `packages/core/`; App-scoped SSH/SFTP/network/platform implementations stay
  behind App Shell adapters or the owning Infrastructure package. Packages use
  public entry points and never import another package's `/src/`.
- Review every non-generated production file once it exceeds 500 lines and also
  review smaller files whose responsibilities span multiple owners. Split only
  at a real logic, lifecycle, storage, protocol, or test seam; do not create
  cosmetic `part` files to satisfy a line count. Never hand-edit or split
  generated files such as `*.g.dart`.
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
  not own a shared business database. Sensitive AI content, traces, todo steps,
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
