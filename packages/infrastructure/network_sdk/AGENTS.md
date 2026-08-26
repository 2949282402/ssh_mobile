最新更新时间：2026-08-26

# network_sdk Package Guidelines

当前开发阶段的 LAN/Network V2 变更是 breaking-only。不得保留旧 API wrapper、
deprecated alias、旧 LAN pairing/storage migration、V1/V2 dual path 或旧文件
协议 fallback。LAN Control Protocol V2 与 Native Network Protocol V2 是独立版本域；
修改 LAN Control 不得把 Native wire schema 升为 V3。

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
- `NetworkFacade` 是 Feature 唯一的业务网络门面；暴露高层连接/传输/实时操作，
  隐藏 Candidate/Resolve/PathManager/RelayClient，不新增 native tag；
- `NetworkFacade.registerPeer`、`connectPeer`、`disconnectPeer` 和 `removePeer` 是
  独立状态变化。`connectPeer` 要求调用方先注册 peer，不得隐式 register；
  `removePeer` 只用于显式 trust revoke/unpair，不能由 Discovery timeout、Relay
  disconnect、route change、App background 或 Feature deactivate 调用。
- `SdkPeerConfig.allowDirect/allowRelay` 只表达已经由上层 Trust/authorization
  决定的 route eligibility；未授权 route 必须在 native route eligibility 层被拒绝。
- `CommunicationClass` 固定五种业务类别，映射到现有 native command/event；
- `SessionClient` 只表达业务 Session/Transfer 操作，作为 `NetworkFacade` 的低层内部实现；
- `RealtimeSession` 是 Feature 唯一的实时会话接口；只允许读取 `state`、
  `remoteVideo`、`audioState` 并调用 `start()`/`stop()`，不得增加 SDP、ICE、
  PeerConnection、socket 或 native handle 参数。
- `EventStreamClient` 只暴露统一 typed event stream；
- `NetworkFacade.sendMessage` 在本 breaking refactor 中保持稳定的
  unavailable/invalid-argument 边界；Feature 的 text/clipboard 继续由 authenticated
  LAN HTTPS + application E2E 承载。不得在 SDK 内增加临时 message implementation
  或明文 fallback。
- 不新增 LAN/Network V2 过渡别名；现有类型别名若仍被非本次边界使用，必须集中
  在 `network_sdk`，不得让 Feature 维护或重新导出一份本地 `network_models.dart`；
- 新增传输实现必须先更新 ADR，不得新增 `*SocketClient` 类型。
- Realtime backend 事件必须由 App Shell adapter 映射；CommandResult、SDP/ICE
  signaling 和 native media resource 不得泄漏到 Feature。
- `RealtimeSession.start()`/`stop()` 的 Future 只能由 App Shell adapter 关联到
  `NativeCommandResultEvent` 后完成；队列 acceptance 不得推进 negotiating、connected
  或 stopped。`RealtimeStateChangedEvent` 是 negotiating、connected、restarting、
  stopped、failed 的主要 Source of Truth；stop command 成功仍须等待 native `closed`。

## 必须验证

JSON/request/error mapping、401 refresh、Facade/Realtime 状态转换和 dispose 语义
变更必须先有失败的行为测试；涉及 native command/event 或 wire contract 时还要先
固定 Dart 侧 contract，并在 Green 后运行对应 Dart ↔ Rust/Protocol 门禁。

```bash
flutter analyze --no-pub
flutter test --no-pub
```
