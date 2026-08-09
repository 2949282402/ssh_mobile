最新更新时间：2026-08-09

# feature_sftp 开发约束

- 业务包只依赖 `app_core`、`app_ui`、`ssh_core` 和自身 Port；禁止引用
  `apps/ssh_mobile_full/lib/services/`、其他 Feature 的 `/src/` 或旧 App UI 实现。
- App Shell 适配器负责把旧 SFTP、Connection、Settings、日志和 Host Key 对话框
  转成公开 Port；不要把适配逻辑反向放回 Feature。
- `SftpModule` 是 `sftp.db` 和路径 Repository 的唯一 Owner，Route ViewModel 只
  解除自身监听。App Scope SSH Manager 和兼容 SFTP 后端不得由 Feature dispose。
- 新增数据库字段或 DAO 后必须运行 Drift build_runner，并补充 Repository/Module
  测试；不得在数据库中保存密码、私钥、Token 或未脱敏的凭据。
- 生产行为验证使用本目录的 `flutter analyze` 和 `flutter test --no-pub`；完整
App 验证必须从 `apps/ssh_mobile_full/` 目录执行，以便 native assets 选择正确。

## Step29 标准字段

- 允许修改范围：SFTP 页面、ViewModel、Module、Repository、Feature Service、Ports 和测试。
- 禁止依赖：其他 Feature 实现、App `/src/`、全局 SSH/SFTP Owner 或未注入的凭据服务。
- Public API 修改要求：只通过 `feature_sftp.dart`，同步 App adapters、Route Scope 和生成代码。
- 数据库约束：`SftpModule` 独占 `sftp.db`；不得保存密码、私钥、Token 或未脱敏凭据。
- 资源释放规则：Module 关闭数据库和自身监听；AppRuntime 负责 SSH Manager/兼容 Backend。
- 必须运行的测试：`dart run build_runner build`、`flutter analyze --no-pub`、`flutter test --no-pub`。
