最新更新时间：2026-08-24

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

后台 SSH 的平台前台服务与 isolate runtime 分属不同 Owner：
`BackgroundServiceManager` 只负责通知/权限/power lock/服务启停，后台入口点创建的
`_BackgroundSshRuntime` 独占 session registry、SSH/tmux、keepalive 和事件订阅；两者
不得共享 SSH client、shell 或 Timer。

前台 `SshService` 中，`_SshBackgroundEventBridge` 独占后台插件事件订阅，
`_SshSessionProjection` 独占不可变 session 列表与 connection overview 聚合；连接、
会话、命令和 history queue 仍由 `SshService` 拥有。前后台建连在登记到 session
registry 前由 attempt owner 持有，并以 per-session generation 阻止迟到回调覆盖新资源；
`SshService.close()` 会等待 connect/reconnect、后台 isolate 确认、订阅、runtime、history
queue、Session Pool 和 native stream connector 完成释放。Network V2 codec 是窄 facade，命令
编码与 Peer/Transfer/SSH Stream typed decoder 彼此独立；Realtime 使用自己的 native
protocol，不属于当前 V2 event schema。

## 测试命令

```bash
flutter analyze
flutter test
```
