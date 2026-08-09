最新更新时间：2026-08-09

# feature_developer 维护约束

## 允许修改范围

允许修改 Developer Log、Panel、诊断模型/页面、ViewModel、公共 Port 和本 Package
测试；AppRuntime 的底层资源与适配器不属于本 Feature 的 Owner 范围。

## 禁止依赖

只依赖 `app_core`、`app_ui` 和注入的 Developer Ports；禁止导入 App Shell、其他
Feature 实现或其他 Package 的 `/src/`，也不得直接创建日志、SSH、RAG、MCP、监控
或平台内存服务。

## Public API 修改要求

调用方只能使用 `package:feature_developer/feature_developer.dart`。修改
`DeveloperDiagnosticsSnapshot` 或 Port 时，必须同步 App 适配器、面板测试、架构
文档和生命周期断言；诊断字段只能表达 Owner 可观测资源。

## 数据库约束

本 Feature 不拥有数据库；日志数据库和其他 App Scope 数据由 AppRuntime 及其适配器
负责，诊断页面不得新增统一存储入口或保存敏感内容。

## 资源释放规则

Route/Panel ViewModel 负责帧回调、监听、Memory polling Timer 和 Controller 的
释放；AppRuntime 负责适配器订阅及底层资源。不能枚举的 legacy 资源不得伪装成精确
全局计数。

## 必须运行的测试

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test --no-pub
```
