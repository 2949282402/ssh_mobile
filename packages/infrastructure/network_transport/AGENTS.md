最新更新时间：2026-08-09

# network_transport Package Guidelines

## 职责

本 Package 只提供 App Scope 网络运行时、Capability Lazy Init、传输端点/连接
合约和原生网络 adapter。它不实现具体 TCP、UDP、QUIC、WebRTC 协议，也不放置
Feature UI、SSH 会话或 LAN 业务规则。

## 依赖与边界

- 生产代码只依赖 `app_core` 和 `ssh_mobile_network_native`；
- Feature 不得直接引用本 Package 的 `/src/`，只使用 `network_transport.dart`；
- `NetworkRuntimeImpl` 只能由 AppRuntime/Composition Root 创建，Feature 不得自行
  `new` 全局网络实现；
- `NativeNetworkAdapter` 不拥有跨 App 的静态单例，handle 的释放由创建它的
  `NetworkRuntimeImpl` 负责。
- `NetworkRuntime.diagnostics` 是只读生命周期观察契约；它只能报告
  `NetworkRuntimeImpl` 直接拥有的 native handle 和已登记的连接/Capability，
  不得为了填充诊断数字而接管 Feature 协议连接。

## 生命周期

- Capability 首次使用时才创建 native handle；相同 Capability 的并发初始化共享同一
  Future；失败会清除 in-flight 状态并允许重试；
- Runtime dispose 会等待未完成的 handle 创建，然后显式 close；dispose 后所有新的
  Capability 请求必须失败；
- handle 的底层顺序必须保持 `create -> start -> stop -> destroy`，Finalizer 不替代
  显式 close。

## 必须验证

```bash
flutter analyze --no-pub
flutter test --no-pub
```

修改公共 API 或 AppRuntime Owner 时，必须同步根 `README`、`AGENTS`、架构执行记录、
Agent memory 和维护 Skill。
