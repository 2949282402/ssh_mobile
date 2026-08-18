最新更新时间：2026-08-19

# ADR-015: Generic TCP, UDP, and WebSocket Transports

状态：Accepted

## 背景

当前 native workspace 的 QUIC 是主要 Direct data plane，Relay client 内部使用
WebSocket，但 TCP、Generic UDP 和 Generic WebSocket 尚未形成可复用的 transport
边界。客户端不应按协议类型直接调用 transport；Session、Delivery、Crypto 和
RouteSelector 才是上层 owner。

## 决策

- 新增 native-only `network-transport` crate，提供统一 `Transport` 外观和稳定的
  `TransportKind`，内部实现 TCP、UDP、WebSocket 三种能力。
- TCP 使用四字节大端长度前缀和 4 MiB 有界 frame；UDP 使用 connected datagram，
  64 KiB 有界且保留 datagram 边界；WebSocket 只接受 512 KiB 有界 binary message，
  明文 Text 不作为业务帧。
- Transport 层不实现设备身份、Relay enrollment、应用 E2EE、ACK/重试或业务路由；
  这些能力继续由现有 native Session/Delivery/Crypto/Relay 层组合。
- 本 Step 只添加 Rust workspace 能力和单测，不新增 FFI 命令，不修改 Flutter/Dart
  客户端协议，也不替换当前 QUIC/Relay 默认路线。

### Direct race 集成边界

TCP 与 WebSocket 的 framing、认证和生命周期仍由各自 transport owner 负责；network-core 在 Direct candidate window 内统一调度它们。对支持 WebSocket 的 generic route，TCP 与 WebSocket 对同一 candidate 并发竞争，不能把 WebSocket 作为 TCP 失败后的串行 fallback。candidate 去重键包含 `candidate_id`、endpoint 和 generation，因此 endpoint/generation 更新会产生新的 attempt，权威 snapshot 删除的 pending candidate 不会继续启动。

## 影响

TCP/WebSocket 的 stream/message 边界与 UDP datagram 语义被显式区分，后续 fallback
可在 native RouteSelector 中组合，而不会把 Relay 专用协议复制到 Generic WebSocket。
Transport 队列和 frame 上限在边界内受控，避免无界网络输入直接进入业务层。

## 验证

- TCP 有界 frame、本地 UDP datagram、WebSocket binary message 均有 loopback round-trip
  测试。
- common `Transport` 外观报告稳定 transport kind。
- workspace 测试和 Clippy 使用 `--locked` 通过。
