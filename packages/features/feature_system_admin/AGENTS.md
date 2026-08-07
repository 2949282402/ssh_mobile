最新更新时间：2026-08-08

# System Admin Feature Guidelines

- 只通过 `package:feature_system_admin/feature_system_admin.dart` 使用本模块。
- 连接目录、SSH 会话、监控能力、SFTP 浏览、文案和 Host Key UI 必须从 Port 注入。
- 禁止导入其他 Feature 的实现或任何 Package 的 `lib/src/`。
- `SystemAdminModule` 是管理 Service/会话资源 Owner；Route ViewModel 只持有监听和页面状态。
- 管理命令必须保留 root、白名单 action、确认 Token 和命令取消边界。
- 本模块当前没有数据库；不要为实时管理快照新增 `system_admin.db`。
