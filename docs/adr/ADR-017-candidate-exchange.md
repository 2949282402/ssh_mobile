> 最新更新时间：2026-08-19

# ADR-017：Peer Candidate Exchange and Connectivity Checks

## Status

Accepted for the native network v1 runtime. The transport-network v2 runtime supersedes this ADR's generation ordering and Direct-race details; the current rules are maintained in [ADR-DISCOVERY-V2](ADR-DISCOVERY-V2.md) and [ADR-CONNECTION-LIFECYCLE-V2](ADR-CONNECTION-LIFECYCLE-V2.md).

2026-08-19 修订：新增 Relay 控制面对 discovery 的**存储**决策——存储发现
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
- `lookup` 只有在 **presence 租约有效 且 discovery 快照存在 且
  discovery.Generation > 0 且 presence 与 discovery 的所有者 ConnectionID
  一致**时才判定对端 online，并随 `lookup_response` 返回候选；否则视为
  offline。owner 不一致的条目（重连窗口内旧连接残留的 discovery）不算在线。
- **占位 discovery 已移除**：连接建立本身不再写 discovery，设备在真正上传
  `discovery_update` 之前不可被发现（对齐 §8「上传 discovery 后才广播
  online」）。
- **discovery 写入是 CAS**：只有当前 presence 租约 owner 才能写入 discovery
  （Redis Lua 原子 + 内存实现同构），被取代的旧连接无法把新连接的 discovery
  覆盖回自身（跨实例重连竞态封死）。
- **generation 单调约束限定在同一 Discovery owner 内**：同一连接上报更小的
  generation 才被拒绝；跨 owner（重连 / 升级后的新连接）视为新的可发现 epoch，
  允许任意正 generation——否则旧版本随机大 generation 残留会拒绝升级客户端
  更小的 Unix-ms generation，导致设备一直不可发现。客户端用 Unix-ms 时间种子
  初始化 generation（进程内单调；严格跨进程单调需持久化
  `generation = max(persisted + 1, unix_ms)`，是后续项）。
- **同 generation 的 Discovery 不可变**：同一 owner 内，generation 相同但候选/
  能力内容变化 → 拒绝（候选变化必须 `generation++`），保证「同一个 generation
  永远对应同一份 Discovery 快照」；内容相同 → 仅刷新、不广播。
- **lookup 是连接前的权威对账**：`lookup_response` 反映服务器权威状态，按返回
  generation 替换/刷新本地 path_manager（新 generation → 删旧代候选重建；同
  generation → 合并），并同步 `peer_presence.generation`；明确 offline 时删除
  discovery-derived path_manager / candidate_attempts、移除 `peer_presence` 条目
  （此前有缓存则 emit Offline），保留配置 endpoint 供 LAN Direct。增量事件
  （peer_online/updated/offline）是低延迟通知，可能因 Pub/Sub 瞬时丢失，最终
  正确性由连接前 lookup 兜底。
- **peer_online / presence_snapshot 无条件清缓存**：`peer_online` 视为新的可发现
  epoch，无论 generation 高低都清掉该对端的旧 path_manager / candidate_attempts；
  `presence_snapshot` 是一次 Control Plane 全量重新对账，对快照中所有 peer 无条件
  清旧 discovery-derived 缓存（owner-scoped generation 下重连可产生 new < old，
  仅比较 generation 无法识别 epoch），后续 connect 经 lookup 重新获取权威候选。
- 信令转发（`candidate_offer` / `candidate_answer`）**仍然不解析 payload**：
  存储层的读写与转发路径语义解耦，Relay 只校验信封边界与在线路由。
- discovery 快照随连接生命周期管理：连接被新连接替换或离线时清理，TTL /
  sweeper 兜底，避免残留死设备候选。

（原 ADR-017 的候选模型、attempt/generation 语义、connect window、STUN、
有界列表等决策不变。）

## Consequences

The runtime can exchange multiple LAN, public IPv6, and server-reflexive
candidates without changing the Flutter/client business protocol. Candidate
updates can be applied without accepting stale NAT state. The former
Relay-to-Direct background-upgrade wording is v1 history; v2 uses the
Direct-First bounded window and selects a route for the lifetime of the
ConnectionSession. This ADR defines the candidate exchange and authenticated
nomination boundary consumed by the v2 lifecycle ADRs.

## Verification

The native tests cover multiple candidates, deterministic LAN/IPv6/NAT fallback
ranking, stale generation/attempt rejection, duplicate/mismatched candidate
rejection, STUN transaction and IPv4/IPv6 parsing, and Relay codec preservation.
The retained Docker Relay harness covers end-to-end Candidate Offer/Answer
routing. Full-cone, port-restricted, symmetric-NAT, and UDP-blocked behavior is
represented by deterministic candidate fixtures in unit tests; privileged
network-namespace testing remains an environment-dependent integration gate.
