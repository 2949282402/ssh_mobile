最新更新时间：2026-08-30

# feature_sftp 维护约束

- 只依赖 `app_core`、`app_ui`、`ssh_core` 和本包 Ports；禁止 Full App services、
  其他 Feature `/src/` 或旧 App UI。App Shell 将旧 SFTP/Connection/Settings/
  logging/Host-Key 对话框适配为 Ports，适配逻辑不回流 Feature。
- `SftpModule` alone owns `sftp.db` and path Repository; Route VM releases only its
  listeners. App SSH Manager/compatibility backend are injected and never disposed
  here. DB fields/DAO changes run Drift generator and Repository/Module tests;
  passwords, private keys, Tokens, and raw credentials never enter DB.
- Target fingerprint, browse/preview/edit/upload/download/delete, Repository,
  lifecycle, or fail-closed changes start with a failing behavior test asserting
  result, target binding, and release. Contract: allowed SFTP UI/VM/Module/
  Repository/Service/Ports/tests; public API only `feature_sftp.dart`, syncing
  adapters/Route Scope/generated code; Module owns DB/listeners, AppRuntime owns
  SSH/compat backend.

## 验证（代码变更）

Package: `dart run build_runner build`, `flutter analyze --no-pub`,
`flutter test --no-pub`. Full App checks run from `apps/ssh_mobile_full/` so
native assets resolve correctly. Local aggregate CI is user-opt-in.
