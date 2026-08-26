最新更新时间：2026-08-26

# ssh_core Agent Notes

## Scope

本包只维护 SSH Session、Runtime、Pool、Client、Host Key 和命令执行契约。

## Rules

- 外部只能导入 `package:ssh_core/ssh_core.dart`，禁止跨包引用 `lib/src/`。
- 不得依赖 Feature 或 App Shell 存储实现；凭据和 Host Key 通过 Core Repository 注入。
- Session 的 Socket、Shell、Timer、Stream 和 Subscription 必须由 Runtime/Pool
  拥有并释放；调用方只能 release Lease。
- 修改 Pool、Lease、引用计数、idle timeout、shutdown/reacquire 或并发生命周期时，
  必须先添加能失败的生命周期测试，并验证 exactly-once release/close 合同。
- 移动端 Background SDK 只能出现在 App 层注入的 Runtime 实现中。
- 变更后执行 `dart format`、`flutter analyze` 和 `flutter test`。

## Step29 标准字段

- 允许修改范围：SSH Manager、Pool、Lease、Runtime/Client/Host Key/目标契约和测试。
- 禁止依赖：Feature、App Shell 存储实现、Background SDK 或跨包 `/src/`。
- Public API 修改要求：只通过 `package:ssh_core/ssh_core.dart`，同步 AppRuntime、Feature adapters 和安全测试。
- 数据库约束：不拥有数据库；凭据、Host Key 和秘密由 Core Repository/Port 注入。
- 资源释放规则：AppRuntime 关闭 Manager；Pool 释放 Socket、Shell、Timer、Stream；Feature 只能 release Lease。
- 必须运行的测试：`dart format --output=none --set-exit-if-changed lib test`、`flutter analyze`、`flutter test`。
