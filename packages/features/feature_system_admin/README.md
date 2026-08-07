最新更新时间：2026-08-08

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
