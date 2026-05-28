# Engineering Baseline ADR

Date: 2026-05-28

## Decisions

- Keep Provider as the app state-management baseline. Optimize with narrower
  `context.select` snapshots, feature-local controllers, and repaint boundaries
  instead of migrating frameworks.
- Keep SSH, SFTP, LLM, AI tools, and monitor protocol work inside services.
  Screen files should gradually shed pure helpers, dialogs, and leaf widgets
  into feature folders.
- Expose protocol and repository seams through small Dart interfaces
  (`SshClientAdapter`, `SftpClientAdapter`, `LlmClientAdapter`,
  `AiToolExecutor`, and storage repository contracts) so controllers and tests
  can inject fakes instead of real SSH/SFTP/LLM clients.
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
- Continue splitting large files by feature-owned components and controllers.
- Expand unit tests before protocol or storage refactors so regressions are
  caught without real SSH/SFTP/LLM network access.
