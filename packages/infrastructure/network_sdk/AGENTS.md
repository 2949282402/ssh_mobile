最新更新时间：2026-08-12

# network_sdk Package Guidelines

## 允许范围

- 修改 Flutter 网络客户端契约、类型化结果/错误、事件、请求执行器和 fake；
- 修改不拥有网络资源的 JSON Bootstrap/鉴权客户端实现；
- 修改公共入口和契约测试；
- 修改必须同步 App Shell adapter、使用方 Feature、架构依赖文档和资源所有权记录。

## 禁止事项

- 不依赖任何 Feature 或 App `/src/`；
- 不直接依赖 `ssh_mobile_network_native`、FFI symbol、Socket、HTTP client 或
  secure storage；
- 不实现第二套 QUIC、Relay、WebSocket 或文件协议；
- 不拥有数据库、Timer、Isolate 或 App Scope runtime。

## API 规则

- `BootstrapClient` 不携带 Bearer；
- `JsonBootstrapClient` 只能通过注入的 `SdkRequestExecutor` 发起公开探测和
  enrollment；不得在 Package 内导入 `dart:io` 或创建 `HttpClient`；
- `AuthenticatedApiClient` 只表达控制面请求；
- `JsonAuthenticatedApiClient` 最多在 401 后刷新并重试一次，失败必须失效会话，
  不得把 Token 放入错误、事件或日志；
- `SessionClient` 只表达业务 Session/Transfer 操作；
- `RealtimeSession` 是 Feature 唯一的实时会话接口；只允许读取 `state`、
  `remoteVideo`、`audioState` 并调用 `start()`/`stop()`，不得增加 SDP、ICE、
  PeerConnection、socket 或 native handle 参数。
- `EventStreamClient` 只暴露统一 typed event stream；
- 开发阶段过渡别名只能保留在 `network_sdk`；不得让 Feature 维护或重新导出
  一份本地 `network_models.dart`；
- 新增传输实现必须先更新 ADR，不得新增 `*SocketClient` 类型。
- Realtime backend 事件必须由 App Shell adapter 映射；CommandResult、SDP/ICE
  signaling 和 native media resource 不得泄漏到 Feature。
- `RealtimeSession.start()`/`stop()` 的 Future 只能由 App Shell adapter 关联到
  `NativeCommandResultEvent` 后完成；队列 acceptance 不得推进 negotiating、connected
  或 stopped。`RealtimeStateChangedEvent` 是 negotiating、connected、restarting、
  stopped、failed 的主要 Source of Truth；stop command 成功仍须等待 native `closed`。

## 必须验证

```bash
flutter analyze --no-pub
flutter test --no-pub
```
