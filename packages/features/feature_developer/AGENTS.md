最新更新时间：2026-08-30

# feature_developer 维护约束

- Scope：Developer Log/Panel、诊断模型/页面、ViewModel、公共 Ports 和测试；
  AppRuntime 底层资源/adapter 不属于本 Feature。
- 仅依赖 `app_core`、`app_ui` 和注入的 Developer Ports；禁止 App Shell、其他
  Feature `/src/`，或直接创建日志/SSH/RAG/MCP/Monitoring/platform memory 服务。
- 公共 API 只能从 `feature_developer.dart` 使用。修改
  `DeveloperDiagnosticsSnapshot`/Port 时同步 App adapter、面板测试、架构文档和
  生命周期断言；字段只能表达 Owner 可观测资源。
- 不拥有 DB；日志数据库和其他 App Scope 数据由 AppRuntime/adapters 管理，诊断
  页面不建统一存储或保存敏感内容。Route/Panel VM 释放帧回调、监听、memory
  polling Timer、Controller；AppRuntime 释放底层订阅。不可枚举的 legacy 资源不得
  伪装成精确全局计数。

## 验证（代码变更）

`dart format --output=none --set-exit-if-changed lib test`、`flutter analyze --no-pub`、
`flutter test --no-pub`；local aggregate CI 仅按用户明确要求运行。
