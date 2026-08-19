最新更新时间：2026-08-19

# ssh_mobile_network_native 维护约束

## 允许修改范围

允许修改 Dart FFI facade、native asset hook、平台构建配置、Rust 协议绑定和对应
测试；协议字节、状态枚举和构建目标变化必须同步 Network Transport 合约。Realtime
command/event 的类型化 API 必须继续隐藏 Rust handle、Socket 和 WebRTC 内部对象。

## 禁止依赖

不得依赖 Feature、App Shell、Flutter UI 或 Dart 全局 Service；Dart 只通过受控
FFI handle 调用 Rust，不得在这里复制业务层 LAN/SSH/SFTP 实现。

## Public API 修改要求

公共入口为 `package:ssh_mobile_network_native/ssh_mobile_network_native.dart`。
修改 FFI 状态、命令、事件或 hook 行为时，必须同步 `network_transport`、平台
构建文档和 Dart/Rust 测试。

Delivery 的应用 ACK 绑定当前 ConnectionSession 的 Session ID、Channel 和
Message ID；跨连接的业务状态由 Delivery/Transfer manager 持有。Recovery Epoch
属于 Rust Delivery transport 状态，不得成为 Dart/Flutter 业务身份或由客户端
回传的字段。重复消息必须区分 InFlight 与 Processed，前者禁止 ACK。
`SessionBoundOrdered` 必须由 native Delivery owner 维护 expected sequence、
单个 in-flight 消息和有界 reorder buffer；不得在 Dart 侧用事件到达顺序补偿。

Application E2EE 必须由 native ConnectionSession owner 维护。每个 transport
Connection 创建新的 SessionId 与 Noise root；transport loss 销毁
ConnectionSession，不继承旧 crypto context。Network Protocol V2 的
`SendMessage` / `DataMessage` 不携带 per-message crypto mode，始终使用
ConnectionSession E2EE。Pending Delivery 状态只能保存逻辑明文，不能缓存任何 Route ciphertext；
Delivery/Transfer 的业务状态留在 manager，并在新 ConnectionSession 上恢复。
同一 ConnectionSession 内的 QUIC、Relay 以及 Relay 文件分块使用同一
CryptoContext；新连接按新的 root 重新加密，禁止跨 Transport 继承旧 context。
Relay 控制面可以转发 opaque bytes，但不得读取业务明文、内容密钥或 nonce。

Rust native background work must be registered with `RuntimeTaskSupervisor`.
Production code must not create an unowned `tokio::spawn`; bounded local
`JoinSet` attempts are allowed only when the surrounding ConnectionSession/runtime task
owns and joins the set. ConnectionSession-scoped carrier handshake, channel
receiver, and file receiver work must use the ConnectionSession task group;
Delivery retry and Transfer resume workers remain business-manager-owned across
transport loss. There is no ConnectionSession-owned reconnect or direct-upgrade task.
Runtime stop must cancel the root, close Relay/WebRTC/QUIC owners, await all
supervisor tasks, and only then release the native runtime.

NAT candidate exchange is also native-owned. The shared UDP socket is handed to
Quinn after local and multi-server STUN gathering; the production connectivity
check is the bounded, identity-authenticated QUIC attempt itself. Do not add a
second raw UDP probe protocol or let an independent `recv_from` loop compete
with Quinn. Candidate Offer/Answer changes must preserve generation, attempt
ID, connect-window bounds, stale-answer rejection, and Relay fallback.

WebRTC data-plane ownership is native-only. `network-webrtc::RealtimeIoDriver`
owns the UDP socket together with the sans-I/O `WebRtcPeer` and must be started
and cancelled through `network-core::RuntimeTaskSupervisor`; no Feature or Dart
code may open a second WebRTC socket or drive `poll_write`, `poll_read`, or
`handle_timeout` directly. Local host candidates are registered before SDP is
created, trickled STUN/TURN candidates are forwarded through the existing
authenticated signaling control plane, and `relay_only` is reserved for TURN
fallback/privacy validation. The local E2E and coturn-backed relay-only tests
are part of the native network quality gate.

## 数据库约束

本 Package 不拥有数据库；配对凭据、Token 和业务历史由上层安全存储或 Feature
Module 管理，native runtime 不得持久化秘密。

## 资源释放规则

`NativeNetworkRuntime` 的 Owner 必须负责 isolate 停止、Rust handle destroy 和
重复释放保护；生命周期顺序保持 `Running -> Stopping -> Stopped -> Destroyed`，
停止后拒绝新命令。

## 必须运行的测试

```bash
dart analyze
dart test
cargo fmt --all -- --check
cargo test --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
# With coturn listening on 127.0.0.1:3478:
cargo test -p network-webrtc --locked -- --ignored relay_only_drivers_exchange_data_channel_payloads
```
