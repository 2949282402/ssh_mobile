最新更新时间：2026-08-09

# app_core Package Guidelines

## 职责

本 Package 只维护跨模块公共合约和轻量机制，不放置 Flutter Widget、SSH、网络、
数据库、Feature 业务规则或具体日志输出实现。

## 允许修改范围

- 生命周期接口和资源释放工具；
- Module Descriptor、Registry、Context 和稳定状态；
- 日志与 Capability 的公共 Contract 和轻量实现（`AppLogger`、作用域 Logger、
  有界 `LogBuffer`、可释放 `LogSink`）；
- 对应的纯合约单元测试和文档。

## 依赖与生命周期约束

- 生产依赖不得反向引用 Feature、Infrastructure、SSH、Drift 或 Flutter UI；
- Registry 只能长期持有静态 Descriptor，不得缓存所有 Module Runtime；
- Context 不得通过静态单例查找服务；
- CapabilityRegistry 不拥有 Capability 的释放责任，资源由注册方 Owner 释放；
- `AppLoggerImpl` 持有自己的 `LogBuffer` 和 Sink 列表，必须由创建它的 App
  Scope Owner 调用 `dispose()`；`ScopedLogger` 只转发记录，不重复释放根 Logger；
- 新增资源必须说明 Owner 和 `dispose/close/cancel/release` 方式。

## 必须验证

```bash
dart analyze .
flutter test
```

公共 API 变更必须同步更新 `README.md`、测试和根架构执行记录。

## Step29 标准字段

- 允许修改范围：生命周期、Module、Logger、Capability 公共合约、轻量实现和纯测试。
- 禁止依赖：Flutter UI、SSH、网络、Drift、Infrastructure、Feature 或静态 Service locator。
- Public API 修改要求：同步 `package:app_core/app_core.dart`、所有调用方、测试和根架构文档。
- 数据库约束：不拥有数据库，也不定义业务数据表。
- 资源释放规则：CapabilityRegistry 不释放注册资源；创建方负责 `dispose/close/cancel/release`。
- 必须运行的测试：`dart analyze .`、`flutter test`。
