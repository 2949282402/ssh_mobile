最新更新时间：2026-08-25

# network_sdk

`network_sdk` 是 Flutter 层的网络业务客户端契约与纯适配包。业务通过
`NetworkFacade` 消费高层操作（连接/断开对端、批量文件传输、可靠消息、实时会话、
Presence 提示事件流），并通过 `CommunicationClass` 表达通信语义，不按 QUIC、
TCP 或 WebSocket 暴露传输客户端。底层 `BootstrapClient`、`AuthenticatedApiClient`、
`SessionClient` 和 `EventStreamClient` 是 Facade 或 App Shell 的内部边界。

## 边界

- 定义可注入的客户端、结果、错误、Session、Route、Transfer、事件和请求执行器契约；
- `NetworkFacade` 是业务唯一门面，隐藏 Candidate/Resolve/PathManager/RelayClient
  状态机；`CommunicationClass` 固定五种业务类别（ReliableStream/ReliableMessage/
  BulkTransfer/UnreliableDatagram/RealtimeMedia），映射到现有 native tag；
- `NetworkFacade.registerPeer` 只更新 native 对端身份、E2E 密钥和可选 endpoint，
  不发起连接；`connectPeer` 只表达实际连接意图，也可为兼容调用方先注册再连接；
- 提供不持有 HTTP 资源的 `JsonBootstrapClient` 与
  `JsonAuthenticatedApiClient`，统一 JSON 编解码、Bearer 注入、刷新重试和错误映射；
- `SessionClient` 只提交业务意图，作为 `NetworkFacade` 的低层内部实现，
  数据面连接由 Rust/native runtime 持有；
- `RealtimeClient` 只提供 Feature-facing `RealtimeSession`，包括
  `start()`、`stop()`、`state`、`remoteVideo` 和 `audioState`；PeerConnection、
  ICE、SDP、signaling、socket 和 native media resource 全部由 App/native Owner 持有；
- 不创建 Socket、FFI handle、HTTP client 或 secure-storage 实现；
- `SdkRequestExecutor`、TLS、连接复用和平台网络策略由 App Shell 提供；
- 不拥有数据库或 App/Feature 生命周期资源。

## Public API

```dart
import 'package:network_sdk/network_sdk.dart';
```

`NetworkSdk` 聚合四类客户端；`Json*Client` 只消费 App Shell 注入的
`SdkRequestExecutor`，不会自行创建 HTTP client。Feature 只使用所需的最小客户端
或 App Shell 注入的 Feature Port。

`RealtimeSession` 是唯一的 Realtime Feature 边界。`RealtimeClientImpl` 只协调
App Shell 注入的 backend 事件和生命周期；当前 native DataChannel 暴露的是 typed
session state，未解码的视频帧和音频设备能力保持 unavailable，不把 SDP/ICE 事件
泄漏给 Feature。`start()`/`stop()` 的 Future 等待 App Shell 关联到
`NativeCommandResultEvent` 的命令完成；队列入列成功不会被当作操作完成，且 stop
只有在 native `closed` 状态事件到达后才把 session 状态置为 `stopped`。

Network V2 的命令边界按功能域提供 Connection、Identity、Transfer、Realtime 和
Relay lifecycle ports；`NetworkV2FacadeImpl` 只编排这些 port，不拥有注入的
`NetworkV2CommandPort`。Facade `dispose()` 只释放自身状态，App/native owner
仍负责 command port 的 stop/dispose。

开发阶段的旧网络类型别名也集中在本包中；Feature 必须直接导入
`package:network_sdk/network_sdk.dart`，不得再创建或导出本地
`network_models.dart` 桥接文件。

## 验证

```bash
flutter analyze --no-pub
flutter test --no-pub
```
