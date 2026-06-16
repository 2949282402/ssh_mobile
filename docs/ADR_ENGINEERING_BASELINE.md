# Engineering Baseline ADR

Date: 2026-06-16

## Decisions

- Keep Provider + `ChangeNotifier` as the app state-management baseline.
  Compose services and feature ViewModels in `lib/main.dart`, and optimize hot
  paths with `Selector`, `context.select`, and repaint boundaries instead of
  migrating frameworks.
- Keep a feature-first MVVM layout as the directory baseline. Put long-lived
  view state and user actions in `lib/features/<feature>/viewmodels`, put
  feature-owned models/forms in `lib/features/<feature>/models|views`, keep
  navigation shells and part-based page composition in `lib/screens/`, and
  keep infrastructure in `lib/services/` plus `lib/core/services/`.
- Keep screen classes thin. Routing, layout composition, and short-lived UI
  affordances may stay in screens; validation, async orchestration, repository
  coordination, and reusable feature state belong in ViewModels or services.
- Expose protocol and repository seams through small Dart interfaces
  (`SshClientAdapter`, `SftpClientAdapter`, `LlmClientAdapter`,
  `AiToolExecutor`, and storage repository contracts) so ViewModels and tests
  can inject fakes instead of real SSH/SFTP/LLM clients. `StorageService` may
  implement repository contracts when that keeps persistence centralized.
- Keep AI server tools safe by default: read-only diagnostics may run directly,
  write-like commands require user approval, and delete/remove commands remain
  blocked.
- Store secrets in secure storage only. Export/import and durable memory must
  never include passwords, private keys, API keys, bearer tokens, or host
  credentials.
- Android release builds do not allow cleartext traffic by default. Debug and
  profile builds may allow cleartext for local provider/SearXNG testing.

## Follow-Up Work

- Move growth-oriented structured data, such as AI chats and terminal history
  metadata, out of monolithic SharedPreferences JSON when practical.
- Continue moving remaining page-owned business state into feature ViewModels
  only when it reduces coupling; do not move stable infrastructure merely for
  symmetry.
- Expand unit tests around ViewModels and protocol/storage seams before deeper
  refactors so regressions are caught without real SSH/SFTP/LLM network
  access.
- Keep new feature work MVVM-first and avoid reintroducing broad `context.watch`
  subscriptions in page hot paths.
