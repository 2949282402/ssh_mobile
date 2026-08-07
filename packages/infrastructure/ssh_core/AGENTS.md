最新更新时间：2026-08-08

# ssh_core Agent Notes

## Scope

本包只维护 SSH Session、Runtime、Pool、Client、Host Key 和命令执行契约。

## Rules

- 外部只能导入 `package:ssh_core/ssh_core.dart`，禁止跨包引用 `lib/src/`。
- 不得依赖 Feature 或 `StorageService`；凭据和 Host Key 通过 Core Repository 注入。
- Session 的 Socket、Shell、Timer、Stream 和 Subscription 必须由 Runtime/Pool
  拥有并释放；调用方只能 release Lease。
- 移动端 Background SDK 只能出现在 App 层注入的 Runtime 实现中。
- 变更后执行 `dart format`、`flutter analyze` 和 `flutter test`。
