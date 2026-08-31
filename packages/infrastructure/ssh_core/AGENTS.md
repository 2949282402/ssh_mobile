最新更新时间：2026-08-30

# ssh_core 维护约束

- Scope: SSH Session/Runtime/Pool/Client, Host Key, command execution, and
  target contracts. Public API only `package:ssh_core/ssh_core.dart`; no Feature,
  App Shell storage, or cross-package `/src/`. Credentials/Host Keys arrive via
  Core Repositories.
- Runtime/Pool owns Session Socket/Shell/Timer/Stream/Subscription and closes
  them; callers only release `SshSessionLease`. `AppRuntime` closes the manager;
  Feature never closes shared Sessions. Mobile Background SDK is App-injected
  Runtime only.
- Pool/Lease/refcount/idle timeout/shutdown/reacquire/concurrency changes first
  add lifecycle failure tests asserting exactly-once release/close. Contract:
  allowed Manager/Pool/Lease/Runtime/Client/Host-Key/target code/tests; no DB or
  persistence owner. Public API changes sync AppRuntime, Feature adapters, and
  security tests.

## 验证（代码变更）

`dart format --output=none --set-exit-if-changed lib test`、`flutter analyze`、
`flutter test`；local aggregate CI 仅按用户明确要求运行。
