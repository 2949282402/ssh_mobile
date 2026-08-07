最新更新时间：2026-08-07

# app_core

`app_core` 提供应用级的最小公共合约：

- 生命周期：`Disposable`、`Activatable`、`DisposableBag`；
- Module：`AppModule`、`ModuleDescriptor`、`ModuleRegistry`；
- 日志：`AppLogger`、`ScopedLogger`、`AppLoggerImpl`、`LogRecord`、`LogLevel`、
  有界 `LogBuffer` 和可释放的 `LogSink`；
- Capability：按类型注册和读取的 `CapabilityRegistry`。

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
