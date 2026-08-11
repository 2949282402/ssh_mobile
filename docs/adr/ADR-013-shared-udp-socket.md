最新更新时间：2026-08-11

# ADR-013: Shared UDP Socket for Candidate Discovery and QUIC

状态：Accepted

## 背景

NAT 发现、STUN、UDP 探测和 QUIC 都依赖外部可见的 UDP source port。原运行时
虽然已有 `QuicEndpointManager::from_bound_socket`，但配置路径仍调用 `new()`，
使运行时没有明确执行“先绑定、再发现、最后交给 QUIC”的单 socket 闭环。

## 决策

- `configure_runtime` 只绑定一次 native UDP socket，并记录实际绑定地址；端口为
  `0` 时以系统分配后的真实端口进行本地 Candidate 发现。
- 本地 Candidate 和可选 STUN 查询在同一个底层 socket 上完成，之后通过
  `UdpSocket::into_std()` 将该 socket 原样交给 Quinn，不关闭后重绑第二个 socket。
- native-only 环境变量 `SSH_MOBILE_STUN_SERVER=host:port` 可启用有界 STUN 查询；
  未配置时只执行本地 Candidate 发现，不改变现有客户端协议或 Flutter/Dart API。
- `PathManager` 由 `RuntimeState` 持有，避免候选收集完成后因 Endpoint Manager
  临时值释放而丢失。

## 影响

同一 NAT 映射下的 STUN、UDP probe 和 QUIC 可以复用相同的 source port，降低
“STUN 看到的端口”和“QUIC 实际使用端口”不一致导致的穿透失败。STUN 仍只提供
候选地址，最终 Peer 身份认证继续由 QUIC 应用握手负责。

## 验证

- `from_bound_socket` 的回归测试确认 Quinn Endpoint 保留预绑定 UDP 端口。
- workspace 测试覆盖 runtime/QUIC 现有认证和传输链路。
