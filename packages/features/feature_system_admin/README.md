最新更新时间：2026-08-09

# feature_system_admin

System Administration 的 UI、Route ViewModel、管理命令协调和安全确认流程。

Package 只依赖 `app_core`、`app_ui`、`connection_core`、`ssh_core` 及显式 Port。
连接目录、SSH 管理会话、监控数据、SFTP 家目录浏览、文案和 Host Key 确认均由
App Shell 注入；不会创建全局 SSH/Storage，也不会直接引用
`feature_monitoring` 的实现。

当前模块不创建独立数据库。`SystemAdminModule` 持有管理服务并在 dispose 时关闭
当前管理会话和活动命令；`SystemAdminViewModel` 由 Route Scope 持有。

旧 `apps/ssh_mobile_full/lib/features/system_admin/` 路径在迁移期间保留为兼容
实现和测试入口；新 App Shell 使用本 Package 的公共入口。

## Package contract

- 职责：提供系统管理页面、Route ViewModel、管理命令协调和安全确认。
- 不负责：监控 Feature 实现、SSH/连接/SFTP 基础设施、数据库或 App 全局资源。
- Public API：`package:feature_system_admin/feature_system_admin.dart`。
- 依赖：`app_core`、`app_ui`、`connection_core`、`ssh_core` 和注入的管理 Port。
- 数据库：不拥有数据库；实时管理快照不得新增 `system_admin.db`。
- 生命周期与资源 Owner：AppRuntime 拥有 `SystemAdminModule`；Module 负责管理
  Service、活动命令和会话；Route Scope 负责 ViewModel。
- 测试命令：`dart format --output=none --set-exit-if-changed lib test`、
  `flutter analyze --no-pub`、`flutter test --no-pub`。
