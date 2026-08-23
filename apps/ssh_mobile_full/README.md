最新更新时间：2026-08-23

# ssh_mobile_full

## 职责

Full App 是 SSH Mobile 的完整 App Shell 和组合根，负责启动协调、`AppRuntime`
生命周期、路由聚合、App Port 适配器以及兼容清单中明确保留的 App Scope 后端。

## 不负责什么

新的 Feature 业务实现、跨 Feature 的 `/src/` 调用和第二套全局 SSH/Network Owner
不应继续放入本 App；新能力应进入对应的 Core、Infrastructure 或 Feature Package。

## Public API

App Shell 的稳定组合入口是 `lib/main.dart`、`lib/app/app_bootstrap.dart`、
`lib/app/app_runtime.dart` 和 `lib/app/navigation/`。外部调用方不得把旧
`lib/screens/`、`lib/models/` 或兼容 Service 当作新模块 API。

## 依赖

依赖由本 App 的 `pubspec.yaml` 声明，包含 Flutter、Core/Infrastructure/Feature
Package 和 App Shell 直接使用的插件；Feature 实现不得通过 App `/src/` 反向获取依赖。

## 数据库

App Shell 只拥有独立的 `app_logs` 日志数据库。Connection、AI、Terminal、SFTP、
Playbook、RAG、MCP 和 LAN Share 数据库分别由对应 Core/Feature Module 拥有；不再创建
统一 `AppDatabase`。

## 生命周期与资源 Owner

`AppRuntimeFactory` 创建 App Scope 资源，`AppRuntime` 按依赖逆序释放 Module → Realtime
→ SFTP → SSH → Network → Database → Logger（适配器与 Route Scope 资源先于 Module
解除）；Route Scope 负责 ViewModel、Controller、Timer 与 Subscription。控制面由
`network_sdk` 的 typed client 使用 App Shell 注入的 `SdkRequestExecutor`，LAN 数据面
仍由 Runtime-owned native gateway 负责。

## 测试命令

```bash
flutter analyze
flutter test
```
