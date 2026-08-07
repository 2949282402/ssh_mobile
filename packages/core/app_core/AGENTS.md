最新更新时间：2026-08-07

# app_core Package Guidelines

## 职责

本 Package 只维护跨模块公共合约和轻量机制，不放置 Flutter Widget、SSH、网络、
数据库、Feature 业务规则或具体日志输出实现。

## 允许修改范围

- 生命周期接口和资源释放工具；
- Module Descriptor、Registry、Context 和稳定状态；
- 日志与 Capability 的公共 Contract；
- 对应的纯合约单元测试和文档。

## 依赖与生命周期约束

- 生产依赖不得反向引用 Feature、Infrastructure、SSH、Drift 或 Flutter UI；
- Registry 只能长期持有静态 Descriptor，不得缓存所有 Module Runtime；
- Context 不得通过静态单例查找服务；
- CapabilityRegistry 不拥有 Capability 的释放责任，资源由注册方 Owner 释放；
- 新增资源必须说明 Owner 和 `dispose/close/cancel/release` 方式。

## 必须验证

```bash
dart analyze .
flutter test
```

公共 API 变更必须同步更新 `README.md`、测试和根架构执行记录。
