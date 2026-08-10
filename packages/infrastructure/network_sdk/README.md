最新更新时间：2026-08-10

# network_sdk

`network_sdk` 是 Flutter 层的网络业务客户端契约与纯适配包。它按鉴权策略和
生命周期区分 `BootstrapClient`、`AuthenticatedApiClient`、`SessionClient`
和 `EventStreamClient`，但不按 QUIC、TCP 或 WebSocket 暴露传输客户端。

## 边界

- 定义可注入的客户端、结果、错误、Session、Route、Transfer、事件和请求执行器契约；
- 提供不持有 HTTP 资源的 `JsonBootstrapClient` 与
  `JsonAuthenticatedApiClient`，统一 JSON 编解码、Bearer 注入、刷新重试和错误映射；
- `SessionClient` 只提交业务意图，数据面连接由 Rust/native runtime 持有；
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

## 验证

```bash
flutter analyze --no-pub
flutter test --no-pub
```
