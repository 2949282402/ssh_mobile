> 最新更新时间：2026-08-18

# ADR-RELAY-DATA-PLANE-V2：Control/Data 物理分离、Reservation 模型、Relay Protocol V2

## Status

Accepted for the transport-network v2 breaking refactor (2026-08-15). Companion
to ADR-TRANSPORT-NETWORK-V2; implements design doc §24-§25, §31-§33 and
Steps 2, 7.

## Context

v1 用单个 `GET /v1/connect` WebSocket 复用控制帧（JSON）与 0x10 binary 数据帧，
`RelayClient` 共享一个 socket 与一个 outbound mpsc；控制面还携带文件投递信封
（`channel_message` / `channel_ack` / session accept|complete|cancel）。v2 要求
Control 与 Relay Data **物理拆开**，数据面使用 Reservation 模型，协议升级为
Protobuf Binary over WebSocket。

## Decision

### Control Plane 与 Relay Data 必须物理拆开

```text
/v2/control
/v2/relay
```

- **Control Connection**（长期存在）只传：Auth、Heartbeat、Discovery、Resolve、
  Connectivity Signaling、Presence Hint、Realtime Signaling、Relay Reservation。
  绝不允许 File Chunk、Delivery Payload、Bulk Payload。
- **Relay Data Connection** 只负责：Connect/Ready 配对握手、Encrypted Payload
  Forwarding、Flow Control、Close。服务器不解密业务数据；只有 reservation 的
  initiator 与 responder 两个 token 角色都在线后，Relay 才向双方发送 Ready。
- Rust 端拆分 `RelayControlClient` / `RelayDataClient`，二者**严禁共享**
  outbound queue、rate limit budget、socket。大流量不能阻塞 heartbeat /
  signaling / Resolve。

### Relay Data 使用 Reservation 模型

Direct 失败后：

```text
A → ReserveRelay(B) → Relay Control
   → RelayReservation { reservation_id, relay_data_endpoint, expires_at, local_token }
B 同时收到 IncomingRelayReservation
双方分别连接 /v2/relay/{reservation_id}
Relay 确认两端角色后 → RelayDataReady → encrypted payload
```

数据通道只负责配对握手、encrypted forwarding / flow control / close。
`relay_data_endpoint` 与 `local_token` 由 reservation 授予；连接双方凭
`reservation_id` 进入同一数据通道。相同角色的重试替换旧端点，不会把两个
initiator 或两个 responder 互相配对；Rust `RelayDataClient` 只有收到 Ready
后才返回连接成功。

### Relay Protocol V2

新增 `protocol/relay_v2.proto`，Protobuf Binary over WebSocket，替代现有
Control JSON。核心消息至少包含：

```text
Ready
Heartbeat / HeartbeatAck
DiscoveryPublish / DiscoveryAck
ResolvePeerRequest / ResolvePeerResponse
ConnectivityOffer / ConnectivityAnswer
PresenceHintSnapshot / PeerAvailableHint / PeerUnavailableHint
RelayReserveRequest / RelayReserveResponse / IncomingRelayReservation
RealtimeSignal
ProtocolError
```

- 所有 Request 必须携带 `request_id`；所有异步 attempt 必须携带 `attempt_id`。
- **禁止继续依靠全局 Notify 判断应答归属**（删除 v1
  `candidate_signal_notify` 关联模式）。

### 错误模型固定

```text
Control：  ControlUnavailable / AuthenticationFailed / PeerOffline /
           PeerNotReady / ResolveTimeout / ProtocolError
Direct：   NoCandidate / DirectTimeout / TransportFailed /
           PeerIdentityMismatch / CryptoHandshakeFailed
Relay：    RelayUnavailable / RelayReservationFailed / RelayConnectFailed
Business： RecoverableTransportLoss / OperationExpired / ResumeRejected
```

禁止全部映射为通用 `RelayError` 或 `IoError`。

### 单实例部署范围

第一阶段：`Relay Control = 单实例`、`Relay Data = 单实例`、`Redis = 外部共享
live state`、`MySQL = 外部持久状态`。不得宣称 Multi-instance supported，直到
完整实现 `Global Control Routing` + `Relay Data Node Selection`。

## Consequences

- Control 与 Data 面在 socket / queue / rate budget 上彻底隔离，大流量不阻塞
  控制面。
- 数据面不承载业务解析，Relay 对 Discovery 语义与业务明文保持零知识。
- Relay Protocol V2 的 `request_id` / `attempt_id` 关联取代全局 Notify，消除
  stale/delayed answer 竞态。

## Verification

按 Main 基线版 §40 测试矩阵的 Relay 组执行：大文件 Relay Data 满载时 Control
heartbeat / Resolve / signaling 不受影响；Control 面禁止 File Chunk / Delivery
Payload / Bulk Payload（静态守卫）；Relay Protocol V2 的 request_id 关联、
attempt_id 关联、stale answer 忽略；reservation 生命周期（expires_at 过期、
local_token 校验、角色配对、Ready 栅栏、双方连接 /v2/relay/{reservation_id}）。
