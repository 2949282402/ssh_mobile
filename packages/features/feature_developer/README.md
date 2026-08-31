最新更新时间：2026-08-30

# feature_developer

Developer Log、Developer Panel 和 diagnostics 展示页面的 Feature Package。

## 边界

- Package 只依赖 `DeveloperLogPort`、`DeveloperSettingsPort` 和
  `DeveloperDiagnosticsPort`，不引用 App Shell、旧 `lib/services` 或其他
  Feature 的 `src/` 实现。
- 日志数据库、SSH、RAG、MCP、性能监控和平台内存读取仍由 AppRuntime 及其
  适配器拥有；Developer Feature 只能读取脱敏快照，不能控制这些资源。
- `DeveloperDiagnosticsSnapshot` 展示 Module 初始化/激活状态、SSH 会话与
  Lease、NetworkRuntime native handle、已知数据库打开状态，以及已接入诊断
  的 Timer/订阅数量。它明确是 Owner 可观测资源的快照，不枚举所有 isolate
  中未接入的 Timer 或 Stream。
- `DeveloperPanelViewModel` 独占路由级帧计时回调和内存轮询 Timer，页面退出
  时通过 `dispose()` 移除监听、取消 Timer，避免调试页面泄漏资源。
- Telemetry 诊断操作区分原样重放 pending/synced 记录与显式重试 rejected 记录；
  后者通过独立 Port 方法执行，不改变 pending/synced 的语义。
- 调用方只允许从 `package:feature_developer/feature_developer.dart` 使用公共 API。

## 生命周期与注入

App Shell 创建并注册三个 Port 适配器。日志页面的 ViewModel 由路由创建；
悬浮面板按设置创建自己的 ViewModel，并在禁用或 Host 销毁时释放。

## 验证

```text
dart format --output=none --set-exit-if-changed lib test
dart analyze
flutter test
```

## Package contract

- 职责：提供 Developer Log、Developer Panel、生命周期诊断模型和展示页面。
- 不负责：创建或控制日志、SSH、RAG、MCP、监控、数据库和平台内存资源。
- Public API：`package:feature_developer/feature_developer.dart`，包括三个 Port、
  snapshot 模型、ViewModel 和面板组件。
- 依赖：`app_core`、`app_ui`、Provider 和 Flutter SDK。
- 数据库：不拥有数据库；只展示 AppRuntime 注入的脱敏数据库状态。
- 生命周期与资源 Owner：AppRuntime 拥有底层适配器；Route/Panel ViewModel 拥有
  帧回调、监听、Memory polling Timer 和 Controller，并在 `dispose()` 释放。
- 测试命令：`dart format --output=none --set-exit-if-changed lib test`、
  `flutter analyze --no-pub`、`flutter test --no-pub`。
