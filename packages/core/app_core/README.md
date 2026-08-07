最新更新时间：2026-08-07

# app_core

`app_core` 提供应用级的最小公共合约：

- 生命周期：`Disposable`、`Activatable`、`DisposableBag`；
- Module：`AppModule`、`ModuleDescriptor`、`ModuleRegistry`；
- 日志：`AppLogger`、`LogRecord`、`LogLevel`；
- Capability：按类型注册和读取的 `CapabilityRegistry`。

本 Package 不依赖 Flutter UI、SSH、Drift 或任何 Feature。它只定义边界和
生命周期机制，具体实现由 AppRuntime、Infrastructure 或 Feature 通过依赖注入
提供。`ModuleRegistry` 只保存静态 Descriptor，不缓存重型 Module Runtime。

## 验证

```bash
dart analyze .
flutter test
```
