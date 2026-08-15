> 最新更新时间：2026-08-15

# ADR-017：Peer Candidate Exchange and Connectivity Checks

## Status

Accepted for the native network v1 runtime.

2026-08-15 修订：新增 Relay 控制面对 discovery 的**存储**决策——存储发现
（discovery 快照）但不解析信令 payload；`lookup` 与 `presence_snapshot` 由此
获得候选数据，信令转发仍保持不解析。其余原决策不变。

## Context

One configured peer endpoint is insufficient for LAN interfaces, server
reflexive addresses, public IPv6, and route changes. Candidate reachability
must not be treated as trust: a path is usable only after the existing
identity-bound QUIC handshake succeeds.

## Decision

- `network-nat` owns the bounded Candidate model and ICE-like Offer/Answer
  state. Every candidate carries an ID, endpoint, kind, priority, interface,
  and non-zero generation.
- Candidate signaling uses authenticated Relay control frames
  (`candidate_offer` and `candidate_answer`) and opaque URL-safe payloads. The
  Relay validates only envelope limits and online peer routing; it does not
  interpret candidate endpoints.
- Each Offer starts a bounded connectivity attempt identified by an opaque
  `attempt_id`; the Answer echoes that ID and carries the negotiated connect
  window. Answers for an older attempt are ignored. The answering peer also
  starts parallel authenticated QUIC Initial attempts in the same window, so
  the QUIC attempt itself performs NAT punching on the shared socket.
- A new generation atomically replaces the previous remote candidate set.
  Older generations are ignored, and a same-generation update is treated as a
  complete set so removed addresses cannot remain usable indefinitely.
- Direct connectivity checks run as parallel authenticated QUIC attempts over
  the ranked candidates. The first identity-verified connection wins; failed,
  unreachable, or incorrectly authenticated candidates do not block other
  candidates. Relay remains the fallback route.
- STUN candidate gathering accepts a bounded comma-separated list of servers
  from `SSH_MOBILE_STUN_SERVERS`; responses must match the source address,
  magic cookie, transaction ID, and IPv4/IPv6 XOR-MAPPED-ADDRESS.
- Candidate lists are bounded to 32 entries and 32 KiB per signaling payload.
  Quality metrics are sampled after authentication and affect ranking only;
  they are not trusted when received from a peer.

### 2026-08-15 修订：Relay 存储 discovery，但转发信令仍不解析 payload

对齐《明确版》的 Relay 控制面语义，本轮在「Relay 只做 opaque 转发」的既有
边界内增加**存储发现**能力，并保持**存储与转发分离**：

- Relay 为每个在线设备维护一份 discovery 快照（`discovery:{device_id}`），
  内容为 `{device_id, generation, opaque_candidates, capabilities}`。
  `opaque_candidates` 与 `capabilities` 由设备经 candidate_offer / 连接期
  上报，Relay 只整体保存，不解析 endpoint、priority 或 generation 的语义。
- discovery 快照供两类消费：`lookup` 返回候选，以及构建 `presence_snapshot`
  推送事件。
- `lookup` 只有在 **presence 租约有效且 discovery 快照存在**时才判定对端
  online，并随 `lookup_response` 返回候选；否则视为 offline。
- 信令转发（`candidate_offer` / `candidate_answer`）**仍然不解析 payload**：
  存储层的读写与转发路径语义解耦，Relay 只校验信封边界与在线路由。
- discovery 快照随连接生命周期管理：连接被新连接替换或离线时清理，TTL /
  sweeper 兜底，避免残留死设备候选。

（原 ADR-017 的候选模型、attempt/generation 语义、connect window、STUN、
有界列表等决策不变。）

## Consequences

The runtime can exchange multiple LAN, public IPv6, and server-reflexive
candidates without changing the Flutter/client business protocol. Candidate
updates can be applied without accepting stale NAT state. Full Relay-to-Direct
background upgrade uses the same bounded QUIC attempt and additional native
transports remain later integration steps; this ADR defines the candidate
exchange and authenticated nomination boundary they will consume.

## Verification

The native tests cover multiple candidates, deterministic LAN/IPv6/NAT fallback
ranking, stale generation/attempt rejection, duplicate/mismatched candidate
rejection, STUN transaction and IPv4/IPv6 parsing, and Relay codec preservation.
The retained Docker Relay harness covers end-to-end Candidate Offer/Answer
routing. Full-cone, port-restricted, symmetric-NAT, and UDP-blocked behavior is
represented by deterministic candidate fixtures in unit tests; privileged
network-namespace testing remains an environment-dependent integration gate.
