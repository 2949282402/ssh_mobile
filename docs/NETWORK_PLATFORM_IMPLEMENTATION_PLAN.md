> 最新更新时间：2026-08-12

# SSH Mobile 跨平台 P2P 网络平台实施计划

**Status:** In progress; WireGuard scope removed from the current project
**Target Repository:** `hejulian2004/ssh_mobile`
**Plan Type:** Architecture + Implementation + Protocol + Engineering Specification

---

# 当前实施状态（2026-08-12）

本文件同时保留完整目标架构与后续阶段；以下状态只描述已经接入生产调用链的部分：

- 已完成 Rust Tokio runtime、版本化 Protobuf command/event FFI 和 Dart
  helper-isolate 生命周期。
- 已完成 Quinn 直连、固定 Ed25519 peer 身份握手、显式接收审批、512 KiB
  有界流式传输、SHA-256 校验、临时文件提交、接收端持久化完成确认、取消和进度事件。
- `LanShareViewModel` 通过 `NetworkService` 提交 native 文件任务；命令接受与
  `TransferCompleted`/`TransferFailed` 终态事件严格分离，历史只保存稳定错误码。
- peer 公布的 candidate 会进入每 peer `PathManager` 并由选择结果驱动 QUIC；
  Candidate Offer/Answer、持续 RTT/loss 探测、并行 direct 竞速和 Relay 到
  Direct 的稳定窗口升级已经进入 native Session 调用链。
- Rust Relay 已实现当前 v1 协议的 WSS 认证、opaque offer、AES-GCM chunk、
  complete/complete_ack、取消、接收入站审批及安全落盘；Flutter 只负责 v1
  enrollment、凭据安全存储和 native 配置，不再建立 Dart Relay 数据面。
- `network-core::RealtimeManager` 已作为 Session-owned Realtime Route 接入
  WebRTC；Offer/Answer/ICE/Restart/Close 只走认证 Relay control plane，
  `ssh_mobile_network_native` 通过 helper isolate 提供有界 typed Realtime
  command/event API，不向 Dart 暴露 Quinn、Socket 或 WebRTC 原生句柄。
- native `network-core::connection` now models routes as `RouteTopology × RouteTransport`. Native route selection records blocked QUIC/UDP candidates explicitly, falls back to TCP or WebSocket/WSS only when the requested capability permits it, and leaves SessionId/Delivery/Recovery ownership unchanged.
- Plan 3 Step 1 now separates native Delivery active receive state from
  processed dedup history. TTL/LRU pruning cannot remove `InFlight` or
  `OrderedBuffered`; application ACK timeout fails a strict ordered channel
  without skipping Sequence, and explicit Session close clears receive-side
  active state.
- Plan 3 Step 2 now separates Realtime queue acceptance from command completion.
  `NetworkRealtimeGateway` returns a `NativeCommandTicket`; the App Shell keeps a
  bounded `commandId → Completer<SdkResult<void>>` map with timeout and dispose
  cleanup. `RealtimeSession` lifecycle states remain native-state-event driven, and
  a successful stop command waits for native `closed` before reporting `stopped`.
- Plan 3 Step 3 now makes `Session` own a composed `ActiveRoute` with a bounded
  generic carrier. Authenticated TCP and direct WebSocket routes can carry
  Delivery data/ACK frames, reconnect under the same logical SessionId, and
  recover pending Delivery state. Route admission reuses pinned Ed25519 identity
  proof plus a Session binding; UDP has no reliable-message capability. QUIC
  migration atomically swaps the active carrier before Delivery recovery, and
  public peer/route events expose `RouteTopology × RouteTransport` metadata.
- `network_sdk.RealtimeClient` now provides a Feature-safe `RealtimeSession` boundary;
  the App Shell maps native lifecycle events while Features cannot encode SDP/ICE or
  touch PeerConnection, sockets, or native handles. Native DataChannel media remains
  typed-unavailable until a native decoder/media event is implemented.
- Step 9 has a fixed A–L real-network fault matrix in
  `docs/NETWORK_FAULT_MATRIX.md`; native direct/route migration/recovery,
  coturn fallback, Docker functional smoke, Caddy recovery, Relay restart, and
  checkpoint/resume tests are recorded, while physical network switching,
  background/foreground, and 1 GiB+ device transfer still require device evidence.
- 当前项目不再支持或实现 WireGuard；本文后续相关章节仅保留为历史方案记录，
  不属于当前实现和发布验收范围。
- Go Relay 只支持当前 `/v1/devices/enroll`、`/v1/connect` 与内存 session；
  开发阶段不保留旧注册接口、协议降级或旧客户端兼容。
- Flutter 公共网络层统一返回 `NetworkResult`，公开事件使用类型化事件；
  Realtime command result 只在 App Shell adapter 内部关联，不向 Feature 暴露。
  LAN HTTP 错误使用稳定的
  `code`、`message`、`operation`、`peer_id` 结构，WebShare 固定 HTTPS，
  浏览器不满足安全上下文时禁止传输而不自动降级。
- WireGuard、完整公网 candidate 协调、路径迁移和 Phase 11 RTC 尚未完成，不能因
  上述文件传输闭环而标记为已交付。

开发阶段 Drift 只维护 `schemaVersion = 1` 的当前 schema；字段变化后删除本地
开发数据库并重新生成代码，不编写迁移或旧数据导入逻辑。

---

# 1. Plan 目标

本计划的目标是在不推翻现有 SSH Mobile 架构的前提下，将当前：

- SSH / SFTP
- LAN Quick Share
- 公网 WebSocket Relay
- Flutter 跨平台客户端

逐步升级为一套统一的跨平台网络通信平台。

最终支持：

1. Windows / Android / iOS / macOS 多端。
2. 设备身份与可信设备管理。
3. IPv6 优先直连。
4. IPv4 NAT 穿透。
5. P2P 优先、Relay 自动回退。
6. QUIC 高速文件传输。
7. WireGuard 虚拟局域网。
8. Windows RDP / SSH / SMB 等远程访问。
9. 服务器只参与控制和必要的数据转发，不保存文件内容。
10. 后续扩展语音、视频、屏幕共享。
11. Flutter 只承担 UI 与业务状态。
12. Rust 统一实现跨平台网络核心。
13. Go 负责服务端控制平面与 Relay。

最终技术栈：

| 层 | 技术 |
|---|---|
| UI | Flutter / Dart |
| 客户端网络核心 | Rust |
| 异步运行时 | Tokio |
| 文件传输 | QUIC |
| QUIC 首选实现 | Quinn |
| QUIC 实现 | Quinn |
| NAT | IPv6 + multi-server STUN + Candidate Exchange + simultaneous QUIC connectivity checks |
| VPN | WireGuard |
| 服务端 | Go |
| 控制连接 | HTTPS + WSS |
| 控制消息 | Protobuf |
| Relay | Go memory-only relay |
| 文件 E2E | X25519 + AEAD |
| 实时音视频 | WebRTC（后续） |

---

# 2. 当前仓库状态分析

当前 SSH Mobile 已经不是一个简单 SSH 客户端。

仓库采用 feature-first MVVM：

```text
lib/features/<feature>/
    models/
    services/
    viewmodels/
    views/
    widgets/

lib/services/
lib/core/services/
lib/data/
lib/widgets/
lib/theme/
```

并明确规定：

- 新 UI 不进入 `lib/screens/`
- 跨 feature 基础设施放 `lib/services/`
- 安全和协议基础设施放 `lib/core/services/`
- ViewModel 不承担底层协议实现
- Dart 非生成文件原则上不得超过 1000 行

因此，本计划不会重新设计 Flutter 层架构，而是在现有 MVVM 下面增加：

```text
Flutter Feature/ViewModel
        ↓
Dart Network Service
        ↓
Rust SDK FFI
        ↓
Network Core
```

---

# 3. 当前已有能力必须复用

## 3.1 LAN Quick Share

当前已经存在：

```text
lib/features/lan_share/
lib/services/lan_share/
```

并且已经实现：

- mDNS / LAN discovery
- HTTPS receiver
- WebSocket
- 设备配对
- PIN 验证
- 文件上传
- 文件元数据
- 文件历史
- Transfer progress
- Recall
- 设备持久身份

当前 LAN HTTP endpoints 继续使用 HTTPS，并保留 512 KiB streaming buffer；文件数据发送统一由 `NetworkService` 提交给 native v1 runtime。

因此：

> QUIC 功能不能另写一套独立 UI 和文件历史系统。

本次重构只替换文件数据面的 transport 能力，不改变 `LanShareViewModel` 以上的业务结构。

---

# 4. 当前安全模型必须保留

现有 LAN Share 已经使用：

```text
X25519
    ↓
共享密钥
    ↓
AES-256-GCM
```

并且配对后会持久化对端 X25519 公钥。

公网 Relay 如果没有已经 pinned 的 X25519 key，会拒绝发送文件。

现有 Relay 又单独维护 Ed25519 signing key，用于证明：

```text
credential 属于当前 device
```

而不是仅依赖 bearer token。

未来必须明确区分三套密钥：

```text
Device Identity Key
Ed25519
用于身份签名

Peer E2E Key
X25519
用于应用层 E2E

WireGuard Key
Curve25519/WireGuard
只用于 WireGuard
```

**禁止为了“简单”而复用这些密钥。**

---

# 5. 当前 Go Relay 也不应推翻

当前已经存在：

```text
relay/
```

Go Relay 已实现：

```text
POST /v1/devices/enroll
GET  /v1/connect
GET  /healthz
```

并且：

- 使用 Ed25519 设备证明
- credential 有有效期
- WSS 长连接
- session 内存保存
- frame rate limit
- session TTL
- server 不保存文件
- 不保存 filename
- 不保存 transfer metadata
- 不保存 frame

因此未来应该：

```text
relay/
   ↓
演进
   ↓
server/
```

而不是重新写一个服务端。

---

# 6. 当前 Native FFI 状态

当前仓库已经加入：

```text
packages/infrastructure/ssh_mobile_network_native/
```

当前 native package 已经管理真实 `NetworkRuntime`，通过 command/event FFI
执行 QUIC、文件传输、Relay 数据路径和 WebRTC Realtime 控制路径；
`NativeNetworkRuntime` 只暴露稳定 ID、枚举、revision、bounded bytes 和
typed event stream。`ssh_net_abi_version()` 仅用于 ABI smoke test，不能代表
业务命令成功。

---

# 7. 最终总体架构

```text
                           ┌───────────────────────────┐
                           │       Go Control Server   │
                           │                           │
                           │ Auth / Device Registry    │
                           │ Signaling / Presence      │
                           │ NAT Coordination          │
                           │ Relay                     │
                           │ STUN                      │
                           └─────────────┬─────────────┘
                                         │
                                  HTTPS / WSS
                                         │
                     ┌───────────────────┴───────────────────┐
                     │                                       │
                Device A                                Device B
                     │                                       │
               Flutter App                              Flutter App
                     │                                       │
               Dart Service                             Dart Service
                     │                                       │
                  FFI ABI                                  FFI ABI
                     │                                       │
                Rust SDK ─────────────────────────────── Rust SDK
                     │              P2P                      │
       ┌─────────────┼──────────────┬─────────────┐          │
       │             │              │             │          │
      NAT           QUIC        WireGuard       Crypto       │
       │             │              │             │          │
    STUN          Files         RDP/SSH/SMB      E2E         │
       │             │              │                        │
       └──────── Path Selection / Connection Manager ────────┘
```

---

# 8. Control Plane / Data Plane 分离

这是整个架构最重要的约束。

## Control Plane

Go Server 负责：

```text
Authentication
Device Presence
Device Discovery
Peer Signaling
Candidate Exchange
Relay Discovery
WireGuard Configuration Distribution
ACL
Session Coordination
```

Control Plane 不传正常文件内容。

## Data Plane

Rust SDK 负责：

```text
UDP
STUN
NAT Traversal
QUIC
File Transfer
E2E Encryption
Connection Migration
Route Measurement
WireGuard orchestration
```

---

# 9. 连接策略

不要简单实现：

```text
先尝试 A
失败以后再尝试 B
```

应建立统一的：

```text
PathManager
```

---

# 10. PathManager

每个 peer 可以拥有多个 Candidate：

```text
LAN IPv4
LAN IPv6
Public IPv6
STUN Server Reflexive IPv4
Mapped Port
Relay
WireGuard endpoint
```

内部模型：

```rust
pub enum CandidateKind {
    Lan,
    PublicIpv6,
    ServerReflexive,
    PortMapped,
    Relay,
}
```

每个 candidate 保存：

```text
IP
Port
Interface
Address Family
RTT
Loss
Last Success
Priority
```

---

# 11. 路径选择顺序

逻辑上：

```text
LAN Direct
   ↓
IPv6 Direct
   ↓
IPv4 UDP P2P
   ↓
Peer Relay
   ↓
Public Relay
```

不能仅仅按照固定顺序。

应该综合：

```text
RTT
Loss
Availability
Relay Cost
Path Type
```

进行评分。

SDK 必须支持：

```text
RELAY
  ↓
后台发现 DIRECT
  ↓
自动升级
```

以及：

```text
DIRECT
  ↓
网络变化
  ↓
失效
  ↓
RELAY
```

---

# 12. NAT 穿透规范

STUN 的任务不是传数据，而是发现：

```text
private endpoint
        ↓ NAT
public IP : public port
```

连接模型参考 ICE：

```text
Gather Candidates
        ↓
Exchange Candidates
        ↓
Connectivity Check
        ↓
Nominate Path
```

第一阶段建议定义为：

> ICE-style candidate selection

直到完整通过 ICE compliance test 后再改名。

---

# 13. UDP Socket 设计要求

必须：

```text
同一个 UDP socket
      ↓
本地候选 + 多服务器 STUN
      ↓
交给 Quinn
      ↓
有界 simultaneous QUIC connectivity check
      ↓
实际 P2P transport
```

不能：

```text
STUN Socket A
得到公网 1.2.3.4:50000

关闭

重新创建 Socket B

QUIC 从 60000 发包
```

否则 STUN 得到的 NAT mapping 已经没有意义。

因此 Rust SDK 应将 socket 生命周期交给：

```text
EndpointManager
```

而不是 QUIC、STUN 各自创建 UDP socket。

---

# 14. QUIC 选择

QUIC 提供：

- UDP transport
- reliable stream
- multiplexing
- flow control
- loss recovery
- path migration

本项目第一实现推荐：

```text
Quinn
```

原因：

```text
Rust SDK
   ↓
Quinn

语言模型统一
async 模型统一
Cargo 统一
错误处理统一
```

当前只维护 Quinn native backend，不保留第二套 QUIC 实现。

定义：

```rust
pub trait QuicBackend {
    // backend abstraction
}
```

第一实现：

```text
QuinnBackend
```

未来可以增加：

当前只维护 Quinn native backend；旧 C wrapper、头文件和平台二进制已经移除。

---

# 15. QUIC 数据模型

连接建立后：

```text
QUIC Connection

Stream 0
Control

Stream 1
File A

Stream 2
File B

Stream 3
Message

Datagram
Future real-time control
```

V1：

```text
一个文件 = 一个可靠 QUIC stream
```

多个文件：

```text
多个 stream
```

这样更容易控制：

- backpressure
- resume
- memory
- fairness

---

# 16. 文件协议

定义：

```protobuf
message FileManifest {
    string transfer_id = 1;
    string file_name = 2;
    uint64 file_size = 3;
    int64 modified_at = 4;
    string content_hash = 5;
    uint32 protocol_version = 6;
}
```

传输：

```text
Offer
 ↓
Accept
 ↓
Manifest
 ↓
Data
 ↓
Hash Verify
 ↓
Commit
```

---

# 17. Chunk

现有代码使用：

```text
512 KiB
```

应该先继续使用这个默认值。

定义：

```text
DEFAULT_TRANSFER_BUFFER = 512 KiB
```

后续 benchmark 再调整。

---

# 18. Resume

文件传输必须从第一版协议就考虑 resume。

Receiver 保存：

```text
transfer_id
file_size
completed_offset
temporary_path
partial_hash_state / chunk hashes
```

重连后：

```protobuf
message ResumeRequest {
    string transfer_id = 1;
    uint64 offset = 2;
}
```

Sender：

```text
seek(offset)
 ↓
继续 stream
```

---

# 19. 文件 E2E 加密

QUIC 已经加密。

但考虑 Relay 以及现有安全模型，建议继续保留应用层 E2E：

```text
File
 ↓
Application E2E
 ↓
QUIC
 ↓
UDP
```

Relay 永远只看到 ciphertext。

现有项目已经具备 X25519 + AES-256-GCM 和 pinned peer key，因此 V1 不要同步更换密码算法。

---

# 20. WireGuard 定位

WireGuard 不承担文件传输。

它承担：

```text
Virtual Network
```

例如：

```text
10.66.0.2
10.66.0.3
```

之后：

```text
RDP
SSH
SMB
自定义 TCP 服务
数据库
局域网应用
```

都可以直接运行。

WireGuard key distribution 和 configuration distribution 交给 Go Control Plane。

---

# 21. WireGuard 不自己实现协议

禁止：

```text
ssh_mobile 自己实现 WireGuard crypto
```

使用官方平台组件。

Windows：

```text
embeddable-dll-service
```

更底层需求才使用：

```text
WireGuardNT
```

Android：

```text
com.wireguard.android:tunnel
```

Apple：

```text
WireGuardKit
```

---

# 22. WireGuard 平台抽象

Rust 中定义：

```rust
pub trait WireGuardBackend {
    fn start(
        &self,
        config: TunnelConfig,
    ) -> Result<TunnelHandle, NetworkError>;

    fn update_peer(
        &self,
        peer: PeerConfig,
    ) -> Result<(), NetworkError>;

    fn stop(
        &self,
        tunnel: TunnelHandle,
    ) -> Result<(), NetworkError>;
}
```

真正 platform API 分别由 Windows / Android / iOS 实现。

---

# 23. WireGuard P2P 限制

不能假设：

```text
STUN成功
=
WireGuard一定能使用相同映射
```

因为 STUN UDP socket 与 WireGuard 内部 UDP socket 可能不是同一个 socket。

Phase A：

```text
Fixed Listen Port
       +
Endpoint Exchange
       +
Persistent Keepalive
```

做到 easy NAT P2P。

失败：

```text
WireGuard Hub / Server path
```

Phase B：

如果未来需要接近 Tailscale 的成功率，再单独评估 Userspace WireGuard Backend。

---

# 24. Rust SDK 目录结构

推荐：

```text
native/
└── network_core/
    ├── Cargo.toml
    ├── rust-toolchain.toml
    │
    └── crates/
        ├── network-core/
        ├── network-protocol/
        ├── network-identity/
        ├── network-nat/
        ├── network-quic/
        ├── network-transfer/
        ├── network-wireguard/
        ├── network-relay/
        └── network-ffi/
```

---

# 25. 每个 crate 职责

## network-core

负责：

```text
NetworkRuntime
PeerManager
ConnectionManager
PathManager
Lifecycle
```

不得包含 UI。

## network-protocol

包含：

```text
Protobuf
message version
error code
wire format
```

## network-identity

负责：

```text
device identity
peer public identity
sign/verify
```

private key persistence 必须通过 host secure-storage adapter。

## network-nat

负责：

```text
Interface enumeration
IPv4
IPv6
multi-server STUN
Candidate
QUIC connectivity check
Path Probe
Keepalive
```

## network-quic

负责：

```text
QuinnEndpoint
Connection
Stream
Datagram
TLS
```

## network-transfer

负责：

```text
File Manifest
Chunk
Resume
Checksum
Transfer State Machine
```

## network-wireguard

负责：

```text
WireGuard desired state
Peer config
Tunnel lifecycle abstraction
Route assignment
```

不是 WireGuard crypto implementation。

## network-relay

负责：

```text
Relay connection
Relay path
Fallback
```

## network-ffi

唯一职责：

```text
Rust
↕
C ABI
```

业务代码禁止直接放这里。

---

# 26. Flutter Native Package 重构

当前 native package：

```text
packages/ssh_mobile_network_native/
```

该 package 通过 Build Hook 管理 Rust FFI；不再保留旧 QUIC C wrapper 或代码生成配置。

---

# 27. Flutter FFI 架构

继续使用现有 Build Hook / Code Assets 路线。

结构：

```text
hook/build.dart
   ↓
cargo build
   ↓
cdylib
   ↓
CodeAsset bundling
```

---

# 28. FFI ABI 原则

绝对不要：

```text
Flutter直接绑定Rust struct
```

ABI 固定为：

```text
C ABI
```

Rust：

```rust
#[no_mangle]
pub extern "C" fn ...
```

输出：

```text
Windows → .dll
Android → .so
Linux → .so
macOS → dylib/framework
```

---

# 29. FFI API 设计

推荐使用：

```text
Runtime
+
Command
+
Event
```

模型，而不是为每个业务持续增加新的 C function。

建议：

```c
typedef uint64_t ssh_net_runtime_t;

typedef struct {
    uint8_t* ptr;
    size_t len;
} ssh_net_buffer_t;

SSH_NET_EXPORT
uint32_t ssh_net_abi_version(void);

SSH_NET_EXPORT
int32_t ssh_net_runtime_create(
    const uint8_t* config,
    size_t config_len,
    ssh_net_runtime_t* out_handle
);

SSH_NET_EXPORT
int32_t ssh_net_runtime_start(
    ssh_net_runtime_t handle
);

SSH_NET_EXPORT
int32_t ssh_net_runtime_command(
    ssh_net_runtime_t handle,
    const uint8_t* command,
    size_t command_len
);

SSH_NET_EXPORT
int32_t ssh_net_runtime_poll_event(
    ssh_net_runtime_t handle,
    uint32_t timeout_ms,
    ssh_net_buffer_t* out_event
);

SSH_NET_EXPORT
void ssh_net_buffer_free(
    ssh_net_buffer_t buffer
);

SSH_NET_EXPORT
void ssh_net_runtime_destroy(
    ssh_net_runtime_t handle
);
```

---

# 30. Command/Event 模型

Dart：

```text
Command protobuf
     ↓
FFI
     ↓
Rust runtime
```

Rust：

```text
NetworkEvent protobuf
     ↓
FFI poll
     ↓
Dart helper isolate
     ↓
typed Stream
```

Realtime v1 使用现有 ABI 的 command/event oneof：Start/Stop/Signal 命令对应
RealtimeState/RealtimeSignal 事件；Dart facade 只镜像这些字段和大小边界，
Rust `network-protocol` 仍是唯一 wire-contract owner。

未来增加 voice / video / remote-control / port-forwarding 时无需不断修改 ABI。

---

# 31. Dart Public API

Flutter 业务代码不得直接使用 FFI symbols。

定义：

```dart
abstract interface class NetworkService {
  Stream<NetworkEvent> get events;

  Future<NetworkResult<void>> start(NetworkRuntimeConfig config);
  Future<NetworkResult<void>> stop();
  Future<NetworkResult<void>> upsertPeer(PeerConfig peer);
  Future<NetworkResult<void>> connect(String peerId);
  Future<NetworkResult<void>> disconnect(String peerId);
  Future<NetworkResult<void>> configureRelay(RelayConfig config);
  Future<NetworkResult<void>> disconnectRelay();
  Future<NetworkResult<TransferSession>> send({
    required String transferId,
    required String peerId,
    required String filePath,
  });
  Future<NetworkResult<void>> cancel(String transferId);
  Future<NetworkResult<void>> respondToIncoming({
    required String transferId,
    required bool accept,
  });
  Future<NetworkResult<RouteSnapshot>> state(String peerId);
}
```

底层 `ssh_mobile_network_native` facade 另外提供
`startRealtimeSession`、`stopRealtimeSession`、`sendRealtimeSignal` 和
`Stream<NativeNetworkEvent>`。它不替换 App Shell 的 `network_sdk` 模型源，
也不让 Flutter 业务代码直接调用 FFI symbol；客户端集成由后续授权的 App
Shell 变更完成。

---

# 32. Flutter Infrastructure Layer

新增：

```text
packages/infrastructure/network_sdk/lib/
├── network_sdk.dart
└── src/
    ├── network_models.dart
    ├── network_clients.dart
    ├── network_http_clients.dart
    └── network_requests.dart

apps/ssh_mobile_full/lib/services/network/
├── network_service.dart
└── network_protocol_codec.dart
```

`network_sdk` 是 Flutter 网络结果、Session、Route 和 typed event 的唯一模型源；
App Shell 的 `network_service.dart` 只负责把已有 v1 FFI gateway 适配为 SDK
`SessionClient`，Feature 不直接依赖 native package，也不维护本地模型桥接。

---

# 33. LAN Share 接入

原：

```text
LanShareViewModel
      ↓
NetworkService
      ↓
Rust QUIC / native Relay
direct or selected relay route
```

目标与当前实现一致：`NetworkService` 统一提交 native v1 命令，
typed events 统一报告进度、完成和失败。

定义：

```dart
Stream<NetworkEvent> get events;
Future<NetworkResult<TransferSession>> send(...);
```

命令返回只表示 accepted；最终结果必须由 typed transfer event 报告。
路径时必须返回失败，不得转入旧 HTTPS 文件发送流程。

---

# 34. Go Server 最终结构

将：

```text
relay/
```

逐渐演进为：

```text
server/
├── cmd/
│   └── ssh-mobile-server/
│       └── main.go
│
├── internal/
│   ├── auth/
│   ├── control/
│   ├── device/
│   ├── signaling/
│   ├── relay/
│   ├── stun/
│   ├── session/
│   ├── metrics/
│   └── config/
│
└── tests/
```

---

# 35. Server API

Enrollment：

```http
POST /v1/devices/enroll
```

Request：

```text
device_id
identity_public_key
enrollment_token
client_version
platform
```

Response：

```text
credential
expires_at
server_time
protocol_version
```

Control Connection：

```http
GET /v1/connect
Upgrade: websocket
```

设备 Relay 数据面使用 binary frame；不提供旧的 control 路由。

---

# 36. ControlEnvelope

```protobuf
message ControlEnvelope {
    uint32 protocol_version = 1;
    string request_id = 2;
    string source_device_id = 3;
    string target_device_id = 4;

    oneof payload {
        Presence presence = 10;
        PeerConnectRequest connect_request = 11;
        CandidateUpdate candidate_update = 12;
        CandidateProbe candidate_probe = 13;
        RelayRequest relay_request = 14;
        PeerDisconnect disconnect = 15;
    }
}
```

---

# 37. Candidate

```protobuf
message Candidate {
    enum Type {
        LAN = 0;
        IPV6_DIRECT = 1;
        SERVER_REFLEXIVE = 2;
        PORT_MAPPED = 3;
        RELAY = 4;
    }

    Type type = 1;
    string address = 2;
    uint32 port = 3;
    uint32 priority = 4;
    string network_id = 5;
}
```

---

# 38. ConnectionIntent

```protobuf
enum ConnectionIntent {
    FILE_TRANSFER = 0;
    REMOTE_NETWORK = 1;
    CONTROL = 2;
    VOICE = 3;
    VIDEO = 4;
}
```

文件和实时控制的 fallback 策略不同。

---

# 39. File 策略

文件：

```text
优先等待短时间 Direct Probe
```

例如：

```text
1500~3000ms
```

避免立刻把大文件送入低带宽 Relay。

---

# 40. Remote Control 策略

远控：

```text
Connectivity > Throughput
```

可以先建立 Relay，再后台尝试升级为 Direct。

---

# 41. Server Relay

现有 v1 WSS Relay 作为 native runtime 的可达性路径：

```text
Native control/data path
Opaque file path
```

保持：

```text
memory-only
opaque payload
session expiration
backpressure
rate limit
```

设备只使用 `/v1/connect`；不提供独立 control 路由，也不保留 Dart Relay
数据面或 HTTPS 文件回退。

---

# 42. WireGuard Relay 安全属性

Hub-and-spoke：

```text
A
 ↓ WireGuard
Server
 ↓ WireGuard
B
```

服务器是实际 WireGuard peer，因此服务器能够看到 inner IP packet。

如果未来要求：

> Relay 服务器绝对不能看到 remote-network plaintext

再增加：

```text
E2E QUIC RemotePortTunnel
```

或 userspace WireGuard opaque relay。

---

# 43. Remote Desktop

Windows RDP：

```text
mstsc
 ↓
Virtual IP
 ↓
WireGuard
 ↓
Target Windows
```

Rust SDK 不实现 RDP。

SDK 只负责：

```text
Network connectivity
```

---

# 44. Future RemotePortTunnel

后续可增加：

```text
localhost:13389
      ↓
Rust TCP Proxy
      ↓
QUIC stream
      ↓
peer
      ↓
127.0.0.1:3389
```

作为 WireGuard 不可用时的增强 fallback。

---

# 45. 音视频扩展

音视频进入独立 media layer。

Voice：

```text
Microphone
 ↓
Opus
 ↓
WebRTC
```

Video：

```text
Camera / Screen
 ↓
H.264 / AV1
 ↓
WebRTC
```

Native v1 已实现 WebRTC Realtime subsystem、Runtime/FFI signaling 闭环和真实
native data plane：`RealtimeIoDriver` 将每个 `WebRtcPeer` 与 UDP socket、ICE/
DTLS/SRTP/SCTP/DataChannel packet pump、timeout driver 绑定，并由
`RuntimeTaskSupervisor` 按 `realtime:<id>` 管理。localhost 双端 DataChannel 和
coturn relay-only DataChannel E2E 已通过；Relay 仍只转发有界控制信令，Dart
仍只消费 typed state/signaling events。音视频设备采集、媒体渲染和 Flutter UI
接入不属于本轮 native SDK Step，不能据此宣称 App 端媒体功能已验收。

---

# 46. 开发 Phase 0：建立工程基线

## Step 0.1

新增：

```text
docs/NETWORK_PLATFORM_IMPLEMENTATION_PLAN.md
```

## Step 0.2

新增：

```text
docs/adr/
ADR-001-network-core-language.md
ADR-002-quic-backend.md
ADR-003-wireguard-platform.md
ADR-004-nat-traversal.md
ADR-005-network-identity.md
```

## Step 0.3

记录 baseline：

```text
flutter analyze
flutter test
go test ./...
```

以及：

```text
LAN file transfer throughput
Relay file transfer throughput
CPU
Memory
RTT
```

## Step 0.4

准备测试环境：

```text
Windows A
Windows B
Android
LAN WiFi
手机热点
不同运营商网络
公网服务器
IPv6网络
```

---

# 47. Phase 1：Rust SDK Bootstrap

目标：

> Flutter → FFI → Rust 完整闭环。

## Step 1.1

创建：

```text
native/network_core/
```

Cargo workspace。

## Step 1.2

实现：

```rust
pub struct NetworkRuntime;
```

负责 Tokio runtime 生命周期。

## Step 1.3

先实现：

```text
network-core
network-ffi
```

不写 QUIC。

## Step 1.4

实现：

```text
ssh_net_abi_version()
ssh_net_runtime_create()
ssh_net_runtime_start()
ssh_net_runtime_destroy()
```

## Step 1.5

把现有 `ssh_quic_ping()` 替换为：

```text
ssh_net_abi_version()
```

作为 ABI smoke test。

## Step 1.6

native package 已统一为 `ssh_mobile_network_native`，不再保留旧 package 名称。

## Step 1.7

修改 Build Hook：

```text
hook/build.dart
   ↓
cargo build
   ↓
cdylib
   ↓
CodeAsset
```

## Step 1.8

必须同时通过：

```text
Windows x64
Android arm64-v8a
```

两个平台不通过，不进入 Phase 2。

---

# 48. Phase 2：Command/Event FFI

## Step 2.1

建立：

```text
protocol/proto/network/v1/
```

## Step 2.2

实现：

```protobuf
NetworkCommand
NetworkEvent
NetworkError
```

## Step 2.3

Rust 实现：

```text
command queue
event queue
runtime worker
```

## Step 2.4

实现：

```text
ssh_net_runtime_command()
ssh_net_runtime_poll_event()
```

## Step 2.5

Dart 创建：

```text
NetworkNativeIsolate
```

持续 poll event。

## Step 2.6

Dart 暴露：

```dart
Stream<NetworkEvent>
```

---

# 49. Phase 3：Go Control Plane

## Step 3.1

当前开发协议只保留：

```text
/v1/devices/enroll
/v1/connect
```

不提供 `/v1/devices/register` 或旧 proof transcript。

## Step 3.3

严格校验 protocol v1；不支持的版本直接拒绝。

## Step 3.4

实现：

```text
Device Online
Device Offline
Peer Lookup
Peer Connect Request
```

## Step 3.5

客户端定时 heartbeat。

## Step 3.6

Server 不保存：

```text
File name
File contents
File chunks
Remote path
```

日志同样不得记录这些数据。

---

# 50. Phase 4：NAT Traversal

## Step 4.1 Interface Discovery

Rust 获取：

```text
IPv4 interfaces
IPv6 interfaces
```

过滤 loopback、link-local 和无效 interface。

## Step 4.2 IPv6

检测 global IPv6，优先发送 direct probe。

## Step 4.3 STUN Client

实现 STUN Binding Request，获取：

```text
server-reflexive endpoint
```

## Step 4.4 Candidate Exchange

发送到 Go：

```text
host candidate
ipv6 candidate
srflx candidate
```

## Step 4.5 QUIC Connectivity Punch

双方收到 Candidate Offer/Answer 后，在 generation 绑定的 attempt ID 和有界
connect window 内同时发起 Quinn Initial。QUIC 的身份握手本身就是 connectivity
check；不能再让独立的 raw `UdpSocket::recv_from()` probe 与 Quinn 竞争共享
socket。

## Step 4.6 Connectivity Authentication

候选可达不等于可信。只有通过现有设备身份绑定的 QUIC 应用握手后，Connection
才能被 nominated；超时、身份失败或 UDP 被阻断时保留 Relay fallback。

## Step 4.7 Path Benchmark

每条 path 测：

```text
RTT
loss
last_seen
```

## Step 4.8 Selection

PathManager 选择最佳路径。

## Step 4.9 Keepalive

维护 NAT mapping。

## Step 4.10 Reprobe

网络变化后重新 gather / probe。

---

# 51. Phase 5：QUIC P2P

## Step 5.1

增加：

```text
network-quic
```

## Step 5.2

引入 Quinn。

## Step 5.3

创建：

```rust
QuicEndpointManager
```

## Step 5.4

QUIC 复用 PathManager 管理的 UDP endpoint。

## Step 5.5

增加 ALPN：

```text
ssh-mobile/1
```

## Step 5.6

Application handshake：

```text
Device ID
Protocol version
Random challenge
Identity proof
Capabilities
```

## Step 5.7

peer 未经过可信身份验证以前，禁止文件、remote control 和 control RPC。

---

# 52. Phase 6：QUIC 文件传输

## Step 6.1

实现：

```text
TransferOffer
TransferAccept
TransferReject
```

## Step 6.2

实现 `FileManifest`。

## Step 6.3

实现 streaming read。

禁止：

```text
readAsBytes(entire file)
```

## Step 6.4

使用 bounded buffer，默认 512 KiB。

## Step 6.5

实现 progress event。

## Step 6.6

实现 receiver temp file。

## Step 6.7

完成后 hash verification。

## Step 6.8

成功后 atomic rename。

## Step 6.9

增加 resume。

## Step 6.10

增加 cancel。

---

# 53. Phase 7：接入现有 LAN Share

不要新增第二个文件 UI。

## Step 7.1

新增：

```text
NetworkService
```

## Step 7.2

旧 HTTPS 文件发送路径从当前开发版本移除。

## Step 7.3

新增：

```text
NativeNetworkService
```

## Step 7.4

`LanShareViewModel` 不处理 QUIC/Relay wire 细节，只消费 `NetworkResult` 与 typed events。

当前实现中 ViewModel 不再直接调用 `LanTransferService.sendFileStream()`；实际
session 的 direct/relay 路由、总字节数和失败原因写入 LAN history。

## Step 7.5

Drift history 增加：

```text
transport
route_type
avg_rtt
bytes_total
failure_reason
```

不得保存 session key、private key、credential。

---

# 54. Phase 8：Native Relay Path

直连不可用时：

```text
PathManager
 ↓
RelayCandidate（由 native runtime 选择）
```

## Step 8.1

复用现有 Go v1 WSS Relay；Dart 不建立 Relay 数据面。

## Step 8.2

保持 opaque payload。

## Step 8.3

Relay 不解密 file data。

## Step 8.4

结束后立即删除 session routing state。

## Step 8.5

后台继续 direct probe。

V1 不强制正在进行中的文件中途迁移路径，V2 再支持 migration。

---

# 55. Phase 9：WireGuard

## Step 9.1

定义：

```rust
WireGuardBackend
```

## Step 9.2 Windows

优先集成 WireGuard embeddable-dll-service，必要时才使用 WireGuardNT。

## Step 9.3 Android

增加 Flutter platform plugin：

```text
Kotlin
 ↓
com.wireguard.android:tunnel
```

## Step 9.4

Control Server 分配：

```text
virtual IPv4
virtual IPv6
peer public key
endpoint candidates
```

## Step 9.5

Rust 生成 desired tunnel state；Platform backend apply actual tunnel state。

## Step 9.6

Windows：

```text
mstsc 10.x.x.x
```

验证 RDP。

## Step 9.7

测试：

```text
SSH
SMB
ICMP
RDP TCP
RDP UDP
```

---

# 56. Phase 10：路径优化

增加：

```text
RouteSnapshot
```

UI 可以展示：

```text
Connection: Direct
Protocol: QUIC
Endpoint: IPv6
RTT: 26 ms
Loss: 0.1%
```

或：

```text
Connection: Relay
Relay: Shenzhen
RTT: 112 ms
```

---

# 57. Phase 11：语音 / 视频

前面的网络平台稳定后才进入。

增加：

```text
media/
```

而不是修改 transfer。

---

# 58. Rust Coding Standard

必须执行：

```text
cargo fmt
cargo clippy
cargo test
```

命名：

```text
lower_snake_case.rs
UpperCamelCase
lower_snake_case
UPPER_SNAKE_CASE
```

公开 API：

```rust
/// 使用当前可用的最佳网络路径连接对端。
///
/// # Errors
///
/// 没有可用直连或 Relay 路径时返回 `NetworkError::NoRoute`。
pub async fn connect_peer(...) -> Result<...>
```

模块：

```rust
//! NAT traversal and candidate selection.
```

注释解释 WHY，而不是复述代码 WHAT。

---

# 59. unsafe 规范

每一个 `unsafe` 必须紧跟：

```rust
// SAFETY:
```

例如：

```rust
// SAFETY: `ptr` comes from Dart FFI and has been validated
// against `len` before constructing the slice.
unsafe {
    // ...
}
```

FFI crate 以外禁止随意出现 `unsafe`。

---

# 60. Rust Panic 规范

绝对禁止 panic 穿过 FFI boundary。

FFI 层：

```text
catch_unwind
 ↓
NetworkError
```

正常网络路径禁止随意使用：

```rust
unwrap()
expect()
```

---

# 61. Rust Error 规范

统一：

```rust
pub enum NetworkError {
    InvalidArgument,
    AuthenticationFailed,
    NoRoute,
    Timeout,
    PeerOffline,
    Quic,
    Nat,
    Relay,
    WireGuard,
    Io,
    Cancelled,
}
```

Flutter 接收稳定 error code + safe message。

---

# 62. Go Coding Standard

必须：

```text
gofmt
go test ./...
go vet ./...
```

Exported API：

```go
// RegisterDevice 注册一个新的已认证设备。
func RegisterDevice(...)
```

Request-scoped operation：

```go
func Foo(ctx context.Context, ...)
```

`context.Context` 放第一个参数。

Error：

```go
fmt.Errorf("register peer: %w", err)
```

禁止吞 error。

---

# 63. Dart Coding Standard

继续遵循当前仓库：

```text
dart format
flutter analyze
flutter test
```

文件：

```text
lower_snake_case.dart
```

类：

```text
UpperCamelCase
```

成员：

```text
lowerCamelCase
```

继续使用：

```text
Provider
ChangeNotifier
Selector
context.select
```

不因为网络 SDK 引入第二套 state management。

---

# 64. Logging 规范

Flutter：

```text
AppLogService
```

禁止新增 `print()` / `debugPrint()` 作为生产日志。

Rust：

```text
tracing
```

Go：structured log。

禁止日志内容：

```text
password
private key
session key
file content
API key
bearer token
full credential
PIN
X25519 private key
WireGuard private key
```

---

# 65. Protocol Versioning

所有 network message 固定使用当前开发线 v1：

```text
protocol_version
```

规则：

```text
不支持的版本
→ 返回明确的版本错误

不支持的能力
→ 只拒绝该操作，不降级到旧协议或旧传输
```

不能用客户端版本字符串猜协议兼容性。

---

# 66. Capability Negotiation

Peer handshake：

```text
supports_quic_file
supports_ipv6
supports_nat_v1
supports_relay_v1
supports_wireguard
supports_resume
supports_webrtc
```

当前开发阶段不接收旧客户端协议；capability 只决定当前协议内是否允许某项操作，
不触发旧 HTTPS/Relay 降级。

---

# 67. Security Boundary

必须区分：

```text
Authenticated
≠
Authorized
```

知道设备身份，不代表允许：

```text
发送文件
访问RDP
访问SMB
建立VPN
```

仍需要 ACL / peer trust。

第一次配对继续复用 QR / PIN / reciprocal pairing。

配对完成后 pinned：

```text
Device ID
Ed25519 identity key
X25519 E2E key
```

---

# 68. Key Rotation

协议预留：

```text
key_id
previous_key_id
rotation_signature
```

即使 V1 暂时没有 UI。

---

# 69. FFI Memory Ownership

每一个 pointer API 必须写清：

```text
Who allocates?
Who frees?
Can caller retain?
Thread safe?
Nullable?
```

例如：

```c
/*
 * Ownership:
 * - Returned buffer is owned by Rust.
 * - Caller MUST invoke ssh_net_buffer_free exactly once.
 * - Buffer MUST NOT be retained after free.
 */
```

---

# 70. FFI Threading

文档必须明确：

```text
runtime_create → any worker isolate
command → thread-safe
poll_event → only one consumer
destroy → after polling stopped
```

---

# 71. Testing Strategy

分五层。

## Layer 1：Unit

Rust：

```text
Candidate scoring
Protocol parser
Transfer state
Resume
Encryption
Error mapping
```

Go：

```text
credential
device proof
session
relay routing
rate limit
```

Dart：

```text
event mapping
ViewModel
NetworkService / NetworkResult / typed event mapping
```

## Layer 2：FFI Tests

```text
create
start
command
event
destroy
invalid buffer
double destroy
runtime shutdown
```

## Layer 3：Local Integration

同机运行 Rust Peer A / Peer B，测试 QUIC。

## Layer 4：LAN Integration

```text
Windows ↔ Windows 1 GB
Windows ↔ Android 1 GB
```

## Layer 5：Real Network Matrix

| A | B | 预期 |
|---|---|---|
| 同 LAN | 同 LAN | Direct LAN |
| 公网 IPv6 | 公网 IPv6 | IPv6 Direct |
| Easy NAT | Easy NAT | UDP Direct |
| Easy NAT | Hard NAT | Direct or Relay |
| Hard NAT | Hard NAT | Relay |
| WiFi | 5G | Direct or Relay |
| UDP blocked | 任意 | Relay |

---

# 72. 网络切换测试

Android：

```text
WiFi
 ↓
5G
 ↓
WiFi
```

验证：

```text
connection state
reprobe
transfer recovery
UI state
```

---

# 73. File Performance Acceptance

记录：

```text
iperf baseline
QUIC throughput
CPU
RSS
disk throughput
RTT
loss
```

建议 acceptance：

```text
P2P QUIC throughput
≥ 80% 可用路径 baseline
```

高速 LAN 同时检测 CPU 是否成为 bottleneck。

---

# 74. Relay Performance

Relay benchmark：

```text
A upload
Server ingress
Server egress
B receive
```

Relay 只定义为：

```text
availability fallback
```

不能定义为正常大型文件路径。

---

# 75. Flutter Performance

Network event 不能每收到一个 packet 就：

```text
notifyListeners()
```

Transfer progress 应 throttle：

```text
100~250ms
```

一次 UI update。

---

# 76. CI

新增：

```text
.github/workflows/network-rust.yml
.github/workflows/server-go.yml
```

Rust：

```text
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test --workspace
```

Go：

```text
gofmt check
go vet ./...
go test ./...
```

Flutter：

```text
dart format
flutter analyze
flutter test
```

---

# 77. Build Matrix

至少：

```text
Windows x64
Android arm64
```

随后：

```text
Linux x64
macOS arm64
iOS arm64
Windows arm64
```

---

# 78. Git 开发策略

建议分支：

```text
feat/network-sdk-bootstrap
feat/network-ffi-events
feat/control-protocol-v1
feat/nat-candidates
feat/quic-p2p
feat/quic-file-transfer
feat/file-resume
feat/relay-fallback
feat/wireguard-windows
feat/wireguard-android
```

一个 PR 只做一个可独立验证的 architectural change。

---

# 79. 推荐 Milestones

## M0 — Architecture

```text
ADR
Protocol skeleton
Directory layout
Baseline benchmark
```

## M1 — Rust SDK

```text
Windows Rust FFI
Android Rust FFI
Runtime
Command/Event
```

## M2 — Control Plane

```text
Device auth
Presence
Signaling
Protobuf
```

## M3 — Direct Network

```text
IPv6
STUN
Candidates
simultaneous QUIC connectivity check
PathManager
```

## M4 — QUIC

```text
P2P QUIC
identity verification
```

## M5 — File Transfer

```text
QUIC files
progress
cancel
resume
checksum
Relay fallback
```

## M6 — WireGuard

```text
Windows
Android
RDP
SSH
SMB
```

## M7 — Production Hardening

```text
CI
failure recovery
network migration
metrics
security audit
benchmark
```

## M8 — RTC

```text
Voice
Video
Screen Share
```

---

# 80. 建议 GitHub Issue 拆分

```text
#1  Network architecture ADR
#2  Rust Cargo workspace
#3  Rust FFI ABI v1
#4  Flutter native package migration
#5  Network event isolate
#6  Protobuf protocol v1
#7  Go control-plane refactor
#8  Device presence
#9  IPv6 candidate discovery
#10 STUN client
#11 Candidate exchange
#12 QUIC connectivity punch
#13 PathManager
#14 Quinn backend
#15 QUIC peer authentication
#16 QUIC file offer protocol
#17 File streaming
#18 File resume
#19 File checksum
#20 LAN Share NetworkService event contract
#21 Public relay integration
#22 Route diagnostics UI
#23 Windows WireGuard
#24 Android WireGuard
#25 RDP acceptance test
#26 Network security audit
#27 Performance benchmark
#28 CI cross-platform
```

---

# 81. Definition of Done：Rust SDK

```text
Windows build
Android build
FFI lifecycle stable
no panic across FFI
no leak
event isolate working
unit tests
clippy clean
documented ABI
```

---

# 82. Definition of Done：P2P

```text
LAN direct
IPv6 direct
IPv4 NAT direct
Relay fallback
direct → relay
relay → direct
network switch
```

---

# 83. Definition of Done：File Transfer

```text
empty file
1 KB
512 KB
10 MB
1 GB
cancel
resume
receiver rejects
sender disappears
receiver disappears
hash mismatch
disk full
network switch
relay fallback
```

---

# 84. Definition of Done：WireGuard

```text
Windows ↔ Windows
Windows ↔ Android

ping
SSH
RDP TCP
RDP UDP

route cleanup
tunnel shutdown
app crash recovery
```

---

# 85. 不应该做的事情

不重写现有 Flutter MVVM。

不自己实现 QUIC。

不自己实现 WireGuard crypto。

不把所有数据都放进 WireGuard。

不让 Flutter 自己处理 UDP。

不在服务器存文件。

不为了跨平台把所有平台 API 强行塞入 Rust。

Rust 是：

```text
network core
```

不是：

```text
platform API replacement
```

---

# 86. 最终代码结构

```text
ssh_mobile/
│
├── lib/
│   ├── features/
│   │   ├── lan_share/
│   │   ├── connection/
│   │   ├── remote_access/
│   │   └── ...
│   │
│   ├── services/
│   │   ├── network/
│   │   ├── lan_share/
│   │   ├── relay/
│   │   └── ...
│   │
│   ├── core/
│   └── data/
│
├── packages/
│   ├── ssh_mobile_network_native/
│   └── ssh_mobile_wireguard_platform/
│
├── native/
│   └── network_core/
│       ├── Cargo.toml
│       └── crates/
│           ├── network-core/
│           ├── network-protocol/
│           ├── network-identity/
│           ├── network-nat/
│           ├── network-quic/
│           ├── network-transfer/
│           ├── network-relay/
│           ├── network-wireguard/
│           └── network-ffi/
│
├── server/
│   ├── cmd/
│   └── internal/
│       ├── auth/
│       ├── device/
│       ├── control/
│       ├── signaling/
│       ├── relay/
│       └── stun/
│
├── protocol/
│   └── proto/
│       └── v1/
│
├── docs/
│   ├── NETWORK_PLATFORM_IMPLEMENTATION_PLAN.md
│   └── adr/
│
└── test/
```

---

# 87. 最终数据路径

## 文件直连

```text
Flutter
 ↓
Rust SDK
 ↓
QUIC
 ↓
P2P
 ↓
Rust SDK
 ↓
Flutter
```

服务器：

```text
0 file traffic
```

## 文件无法 P2P

```text
Rust
 ↓
E2E Encrypt
 ↓
Go Relay
 ↓
E2E Ciphertext
 ↓
Rust
```

Server：

```text
不存
不解密
只转发
```

---

# 88. Windows Remote Control

最优：

```text
RDP
 ↓
WireGuard P2P
 ↓
Target Windows
```

无法 P2P：

```text
RDP
 ↓
WireGuard fallback / future QUIC tunnel
 ↓
Server
 ↓
Target
```

---

# 89. Voice / Video

未来：

```text
Go Signaling
     │
     │ SDP / ICE
     ↓
WebRTC P2P

失败
 ↓
TURN
```

---

# 90. 最终职责划分

## Flutter

```text
UI
ViewModel
user intent
permissions UI
progress UI
route diagnostics
```

## Rust

```text
network runtime
peer connection
NAT
QUIC
file transfer
crypto
route selection
connection migration
WireGuard orchestration
```

## Go

```text
authentication
device registry
presence
signaling
candidate exchange
relay
server policy
```

## Platform Native

```text
Windows WireGuard
Android VpnService
iOS NetworkExtension
platform secure integration
```

---

# 91. 最终架构决策

```text
Flutter
   │
   │ MVVM
   ↓
Dart Network Service
   │
   │ FFI
   ↓
Rust Network SDK
   │
   ├── PathManager
   ├── NAT
   ├── QUIC
   ├── File Transfer
   ├── E2E
   └── WireGuard Controller
              │
              │
       ┌──────┴──────┐
       │             │
      P2P         Go Server
       │             │
       │        Control / Relay
       │             │
       └──────┬──────┘
              │
          Remote Peer
```

核心原则：

> **控制面走 Go；数据面走 Rust；Flutter 不处理底层协议；P2P 永远优先；Relay 只保证可达性；文件走 QUIC；虚拟局域网与传统远程协议走 WireGuard；音视频未来独立走 WebRTC。**

该方案最大程度复用 SSH Mobile 已有的：

```text
MVVM
LAN Share
Pairing
X25519
Secure Storage
Drift History
Go Relay
Flutter UI
```

同时把当前刚建立的 native FFI 层升级为真正可长期扩展的跨平台 Network SDK。

这是当前 `ssh_mobile` 最适合的演进路径，而不是重新创建一套与现有项目平行的网络系统。
