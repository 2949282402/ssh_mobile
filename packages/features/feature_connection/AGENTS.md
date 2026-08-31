最新更新时间：2026-08-30

# feature_connection 维护约束

- 独立连接 Feature；禁止导入 Full App 或其他 Feature `/src/`。数据只经
  `connection_core` Public API；本包不创建 Drift、Secure Storage、SSH、SFTP 或
  Monitoring Service。跨模块行为定义本包 Capability Contract，由 App 注入。
- `ConnectionViewModel` 由 Route/Provider Scope 拥有，不关闭 App Scope 服务。旧
  App Connection 入口已关闭；调用方只能用 `feature_connection.dart` 或
  `connection_core.dart`（App adapter 除外）。新增/重构代码补中文职责/生命周期/
  安全注释。
- Contract：允许编辑 UI、ViewModel、文案、Route metadata、Ports、测试；公共 API
  变更同步 App Route Scope/adapters。无数据库；Connection 数据由
  `connection_core` 管理；Route 释放监听，AppRuntime 释放服务。

## 验证（代码变更）

`dart format --output=none --set-exit-if-changed lib test`、`flutter analyze`、
`flutter test`；local aggregate CI 仅按用户明确要求运行。
