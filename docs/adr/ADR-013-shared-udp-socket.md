> 最新更新时间：2026-08-12

# ADR-013: Shared UDP Socket for Candidate Discovery and QUIC

状态：Accepted

## 背景

NAT 发现、STUN 和 QUIC 都依赖外部可见的 UDP source port。原运行时
虽然已有 `QuicEndpointManager::from_bound_socket`，但配置路径仍调用 `new()`，
使运行时没有明确执行“先绑定、再发现、最后交给 QUIC”的单 socket 闭环。

## 决策

- `configure_runtime` 只绑定一次 native UDP socket，并记录实际绑定地址；端口为
  `0` 时以系统分配后的真实端口进行本地 Candidate 发现。
- 本地 Candidate 和可选 STUN 查询在同一个底层 socket 上完成，之后通过
  `UdpSocket::into_std()` 将该 socket 原样交给 Quinn，不关闭后重绑第二个 socket。
- native-only 环境变量 `SSH_MOBILE_STUN_SERVERS=host:port,host:port` 可启用有界
  多服务器 STUN 查询；未配置时只执行本地 Candidate 发现，不改变现有客户端
  协议或 Flutter/Dart API。
- Candidate Exchange 通过 generation、attempt ID 和有界 connect window 协调双方
  的 QUIC Initial；QUIC connectivity attempt 本身承担 NAT punch，不再定义第二套
  raw UDP probe 协议。
- `PathManager` 由 `RuntimeState` 持有，避免候选收集完成后因 Endpoint Manager
  临时值释放而丢失。

## 影响

同一 NAT 映射下的 STUN 和 QUIC 可以复用相同的 source port，降低“STUN 看到的
端口”和“QUIC 实际使用端口”不一致导致的穿透失败。STUN 仍只提供候选地址，最终
Peer 身份认证继续由 QUIC 应用握手负责；连接窗口过期或 QUIC 身份认证失败时，
已有 Relay race 仍可作为 fallback。

## 验证

- `from_bound_socket` 的回归测试确认 Quinn Endpoint 保留预绑定 UDP 端口。
- workspace 测试覆盖 runtime/QUIC 现有认证和传输链路。
