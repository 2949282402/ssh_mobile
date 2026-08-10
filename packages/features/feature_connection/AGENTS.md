最新更新时间：2026-08-10

# feature_connection Agent Notes

- 这是连接 Feature 的独立 Package，禁止导入 `apps/ssh_mobile_full/lib/` 或其他 Feature 的 `/src/`。
- 数据访问必须使用 `connection_core` Public API；不要在这里创建 Drift 数据库、Secure Storage、SSH、SFTP 或监控 Service。
- 页面需要的跨模块行为必须定义为本包的 Capability Contract，再由 App 组合根注入实现。
- `ConnectionViewModel` 的资源 Owner 是 Route/Provider；它不负责关闭 App Scope 服务。
- 新增或重构代码使用中文注释说明职责、生命周期和安全约束。
- Connection 旧 App Feature 入口已关闭；调用方只能依赖
  `package:feature_connection/feature_connection.dart` 或
  `package:connection_core/connection_core.dart`，App Shell 适配器除外。
- 修改后至少运行 `dart format --output=none --set-exit-if-changed lib test`、`flutter analyze` 和 `flutter test`。

## Step29 标准字段

- 允许修改范围：连接编辑 UI、ViewModel、文案、Route metadata、Port 和本 Package 测试。
- 禁止依赖：App `/src/`、其他 Feature `/src/`、Drift 数据库、Secure Storage、SSH/SFTP 实现。
- Public API 修改要求：只通过 `feature_connection.dart`，同步 App Route Scope 和 adapters。
- 数据库约束：不拥有数据库，Connection 数据由 `connection_core` 管理。
- 资源释放规则：Route/Provider Scope 释放 ViewModel 监听；App Scope 服务由 AppRuntime 释放。
- 必须运行的测试：`dart format --output=none --set-exit-if-changed lib test`、`flutter analyze`、`flutter test`。
