最新更新时间：2026-08-09

# System Admin Feature Guidelines

- 只通过 `package:feature_system_admin/feature_system_admin.dart` 使用本模块。
- 连接目录、SSH 会话、监控能力、SFTP 浏览、文案和 Host Key UI 必须从 Port 注入。
- 禁止导入其他 Feature 的实现或任何 Package 的 `lib/src/`。
- `SystemAdminModule` 是管理 Service/会话资源 Owner；Route ViewModel 只持有监听和页面状态。
- 管理命令必须保留 root、白名单 action、确认 Token 和命令取消边界。
- 本模块当前没有数据库；不要为实时管理快照新增 `system_admin.db`。

## Step29 标准字段

- 允许修改范围：管理页面、Route ViewModel、Module、命令 Service、Ports 和测试。
- 禁止依赖：Monitoring Feature 实现、其他 Feature `/src/`、App `/src/` 或全局 SSH/Storage。
- Public API 修改要求：只通过 `feature_system_admin.dart`，同步 App 注入适配器和安全测试。
- 数据库约束：不拥有数据库，不把实时管理快照持久化为 `system_admin.db`。
- 资源释放规则：Module 先取消命令再关闭管理会话；Route ViewModel 只释放自己的监听。
- 必须运行的测试：`dart format --output=none --set-exit-if-changed lib test`、`flutter analyze`、`flutter test`。
