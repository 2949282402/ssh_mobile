最新更新时间：2026-08-28

# app_core

`app_core` 提供应用级的最小公共合约：

- 生命周期：`Disposable`、`Activatable`、`DisposableBag`；
- Module：`AppModule`、`ModuleDescriptor`、`ModuleRegistry`；
- 日志：`AppLogger`、`ScopedLogger`、`AppLoggerImpl`、`LogRecord`、`LogLevel`、
  有界 `LogBuffer` 和可释放的 `LogSink`；
- Capability：按类型注册和读取的 `CapabilityRegistry`。
- Telemetry：由 `contracts/telemetry/*.yaml` 生成的 `TelemetryEvents`、
  `TelemetryErrorCodes` 和类型化 `TelemetryClient.record(event: ...)` 公共合约；
  `TelemetryTransport.authenticateDevice` 使用服务端返回的 `expiresIn`，缺少本地
  遥测密钥时通过 App 注入的既有 Relay 身份 Provider 完成一次性 enrollment。
  `TelemetryLogSink` 只转发显式 allowlist 中的结构化 error/critical 记录，
  `TelemetryRedactor` 在本地落库前执行 schema allowlist 与 fail-closed 脱敏。
  `TelemetryClient` 独立拥有周期 flush、retry 和策略刷新定时器，并支持注入
  `TelemetryTimerFactory`、clock 和 random 以进行无真实等待的确定性测试。

本 Package 不依赖 Flutter UI、SSH、Drift 或任何 Feature。它只定义边界和轻量
机制，具体平台日志实现由 AppRuntime 或 App 层通过依赖注入提供。
`LogBuffer` 默认只保留最新 2000 条记录；`AppLoggerImpl.dispose()` 负责关闭
其 Sink，但不拥有 ScopedLogger 的释放责任。`ModuleRegistry` 只保存静态
Descriptor，不缓存重型 Module Runtime。

## 验证

```bash
dart analyze .
flutter test
```

## Package contract

- 职责：提供生命周期、Module、日志和 Capability 公共合约及轻量实现。
- 不负责：Flutter UI、SSH、网络、数据库、平台适配和 Feature 业务规则。
- Public API：`package:app_core/app_core.dart`。
- 依赖：生产代码只依赖 Dart SDK；测试使用 `flutter_test` 和 lint 工具。
- 数据库：不拥有数据库，也不保存业务数据。
- 生命周期与资源 Owner：Registry/Capability 不拥有运行时资源；创建方负责
  `dispose/close/cancel/release`，AppRuntime 负责 App Scope Logger。
- 测试命令：`dart analyze .`、`flutter test`。
