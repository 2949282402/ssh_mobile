最新更新时间：2026-08-30

# app_core 维护约束

- 只维护跨模块公共合约和轻量机制：lifecycle、Module Descriptor/Registry/
  Context、Logger/Capability contracts and light implementations, plus their
  pure tests/docs. 不放 Flutter Widget、SSH、网络、Drift、数据库或 Feature 规则。
- 生产依赖不得反向引用 Feature/Infrastructure/SSH/Drift/Flutter UI；Context
  不用静态单例找服务。Registry 只持有静态 Descriptor；CapabilityRegistry 不
  释放注册资源，创建方负责 `dispose/close/cancel/release`。
- `AppLoggerImpl` owns its `LogBuffer`/Sinks and App Scope creator disposes it；
  `ScopedLogger` 只转发、不重复释放根 Logger。新增资源须标明 Owner/释放方式。
- Public API 变更同步 `package:app_core/app_core.dart`、调用方、README、测试及
  根架构记录。数据库不属于本包，也不定义业务表。

## 验证（代码变更）

`dart analyze .`、`flutter test`；local aggregate CI 仅按用户明确要求运行。
