最新更新时间：2026-08-08

# feature_connection Agent Notes

- 这是连接 Feature 的独立 Package，禁止导入 `apps/ssh_mobile_full/lib/` 或其他 Feature 的 `/src/`。
- 数据访问必须使用 `connection_core` Public API；不要在这里创建 Drift 数据库、Secure Storage、SSH、SFTP 或监控 Service。
- 页面需要的跨模块行为必须定义为本包的 Capability Contract，再由 App 组合根注入实现。
- `ConnectionViewModel` 的资源 Owner 是 Route/Provider；它不负责关闭 App Scope 服务。
- 新增或重构代码使用中文注释说明职责、生命周期和安全约束。
- 修改后至少运行 `dart format --output=none --set-exit-if-changed lib test`、`flutter analyze` 和 `flutter test`。
