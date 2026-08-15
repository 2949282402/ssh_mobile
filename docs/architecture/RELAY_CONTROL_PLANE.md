> 最新更新时间：2026-08-15

# Relay 控制面对齐《明确版》架构说明

## 1. 定位与范围

本文档描述 Go Relay 控制面（`relay/`）在「完全对齐《明确版》」改动后的现状
与目标边界。它以《网络传输SDK架构设计（最终版）》为设计基准，对照
[`docs/NETWORK_PLATFORM_IMPLEMENTATION_PLAN.md`](../NETWORK_PLATFORM_IMPLEMENTATION_PLAN.md)
与已接受的 ADR，记录本轮四个真实分叉及其权威决策边界。

控制面与数据面的职责分离保持如下：Go Relay 负责鉴权、presence、discovery
存储、peer 信令转发与 Relay 可达性；候选可达性、NAT 穿透、QUIC 与路径选择
属于 native SDK。Relay 永远是 fallback 而非大流量数据路径。

## 2. 已实现基线（《明确版》27 节中约 20 节）

以下能力已进入生产调用链，作为本轮改动的基础：

- **presence 租约**：每个在线设备持有按连接粒度的 presence 租约
  （take / renew / release），新连接通过租约抢占旧连接，杜绝旧连接残留在线。
- **心跳 20s / presence TTL 60s**：设备每 20s 心跳续租，TTL 60s 自然过期
  即离线。
- **单连接新替旧**：同一 `device_id` 的新连接替换旧连接（含跨实例定向断开
  被取代连接）。
- **opaque 信令转发**：`candidate_offer` / `candidate_answer`、
  `channel_message` / `channel_ack` / `crypto_handshake`、`webrtc_*` 等控制帧
  只校验信封边界与在线路由后原样转发，Relay 不解析 endpoint、Noise、SDP 或
  业务明文。
- **候选优先级顺序**：LAN Direct > IPv6 Direct > server-reflexive/port-mapped
  Direct > Relay（见 ADR-004），由 native 端候选排序与评分驱动。
- **4s 建连窗口**：Direct First 顺序建连，`DEFAULT_CONNECT_WINDOW_MS=4000`
  （见 ADR-008 修订）。
- **2s 探针**：Relay 建连后的后台 direct-upgrade 探针，用同一组有界 QUIC
  尝试探测更优 Direct 并原子升级（见 ADR-018）。
- **鉴权无状态 HMAC + Ed25519 proof + 防重放 nonce**：设备凭据自包含，
  Relay 验签验过期，nonce 防重放。
- **存储面**：MySQL 为 enrollment / 吊销 / 审计的 source of truth；Redis
  承载短期可重建状态（presence、discovery、nonce、admin 会话、跨实例事件）
  （见 [`docs/architecture/REDIS_MYSQL_SESSION_STORAGE_PLAN.md`](REDIS_MYSQL_SESSION_STORAGE_PLAN.md)）。
- **多实例事件总线**：Redis Pub/Sub 广播 `device.revoked` / `device.kicked` /
  `connection.replaced`，跨实例断连与吊销对账兜底。

## 3. 本轮四个改动

本轮把控制面未对齐《明确版》的四处分叉一次收口，全部为 Relay 控制面边界内
改动，native / 客户端侧随之消费。

### 3.1 lookup：presence + discovery 均有效 + owner 一致才 online，并返回候选

旧 lookup 只按本地 hub 是否在线回答 `online` 布尔。新语义（在线判定收紧版）：

- 对端 **presence 租约有效 且 discovery 快照存在 且 discovery.Generation > 0
  且 presence 与 discovery 的所有者 ConnectionID 一致** 时，才判定为 online
  并视为可连接；
- `lookup_response` 随 online 返回候选（来自 discovery 快照的 opaque
  candidates）；
- 只有 presence 或只有 discovery、gen-0 残留、或 owner 不一致（重连窗口内旧
  连接残留的 discovery）的一方不视为可连接，避免「在线但无候选」、「有候选
  但已离线」、以及「旧连接残留被误当在线」三种半态被错误用于建连。

### 3.2 服务端 discovery 存储（ADR-017 修订边界）

Relay 为每个在线设备维护一份 discovery 快照
（`discovery:{device_id}`，内容为 `{device_id, generation, opaque_candidates,
capabilities}`）。`opaque_candidates` 与 `capabilities` 由设备经
candidate_offer / 连接期上报，Relay 只整体保存、不解析其语义。快照随连接
生命周期管理：连接被替换或离线时清理，TTL / sweeper 兜底。权威边界见
[ADR-017](../adr/ADR-017-candidate-exchange.md) 的 2026-08-15 修订段：
**存储发现，但不解析信令**。

三个加固点（2026-08-15 二次修订）：

- **占位 discovery 已移除**：连接建立不再写占位 discovery，设备真正上传
  `discovery_update` 之前不可被发现（§8 由此自然成立，且占位「只继承
  generation、不继承候选」会误覆盖真实候选的缺陷一并消除）。
- **discovery 写入是 CAS**：只有当前 presence 租约 owner 才能写入 discovery
  （Redis Lua 原子 + 内存实现同构），封死跨实例重连竞态——被取代的旧连接
  无法把新连接的 discovery 覆盖回自身。
- **generation 单调约束限定在同一 owner 内**：同一连接上报更小的 generation
  才拒绝；跨 owner（重连 / 升级后的新连接）视为新的可发现 epoch，允许任意正
  generation——否则旧版本随机大 generation 残留会拒绝升级客户端更小的
  Unix-ms generation，导致设备一直不可发现。客户端用 Unix-ms 时间种子初始化
  generation（进程内单调；严格跨进程单调需持久化，见 §4.6）。

### 3.3 推送事件：presence_snapshot / peer_online / peer_updated / peer_offline

Relay 向每个已认证设备连接推送四类 presence 事件，让设备侧无需轮询即可感知
可信对端列表变化：

- `presence_snapshot`：上线/重连时的一次性全量对端在线视图；
- `peer_online` / `peer_updated` / `peer_offline`：单对端上线、generation
  更新、离线。

**事件轻 / lookup 重**：事件负载只携带 `device_id` + `generation`，不携带
候选。设备收到事件后按需发起 `lookup` 拉取候选，避免把大候选集高频推给所有
在线设备。

### 3.4 移除 500ms 并行竞速，改顺序 Direct First + lookup 前移（ADR-008 修订）

原决策为「Direct 立即尝试 + 500ms 后启动 Relay lookup + 首个 ready 胜出」。
第一轮改为顺序 Direct First：先只跑 Direct，等待 connect_window（默认 4s），
4s 内 `DIRECT_READY` 用 Direct，超时 `DIRECT_FAILED` 后再启动 Relay。第二轮
把 **Relay peer discovery lookup 前移到 Direct 之前**（`resolve_peer_discovery`，
2s 上限）：先解析对端在线状态并安装候选，再候选信令，再 Direct First，失败
才启动 Relay 数据面（不再重复 lookup）。修复「本地无对端候选时先走 Relay、
明明有公网候选却不尝试 Direct」的缺陷。Relay 数据面的 ready 语义与 8s 单
路线预算保持不变。权威决策见
[ADR-008](../adr/ADR-008-direct-relay-race.md) 的 2026-08-15 修订。

## 4. 关键边界

### 4.1 存储发现、不解析信令

discovery 快照的**存储**与 candidate_offer / candidate_answer 的**转发**
在语义上解耦：存储层读写 `discovery:{device_id}` 供 lookup 与 presence
事件消费；转发层仍只校验信封边界与在线路由，不读取候选 payload 的
endpoint、priority 或 generation 语义。两条路径共用「设备在线路由」判定，但
Relay 对候选内容保持零知识（ADR-017 修订边界）。

### 4.2 事件轻 / lookup 重

presence 推送事件只带 `device_id` + `generation`；候选一律由设备按需
`lookup` 拉取。这样：

- 在线设备越多，事件体积不随候选规模增长；
- 候选变更（generation 更新）由 `peer_updated` 提示，设备自取最新；
- Relay 不把高价值候选数据广播给无关对端。

### 4.3 多实例边界（明确版 §…现状）

presence / discovery / 事件总线均落在共享状态层（Redis，全 TTL），MySQL 仍
是 enrollment / 吊销 / 审计的唯一 source of truth。跨实例生命周期事件
（`device.revoked` / `device.kicked` / `connection.replaced` 与
`peer_online` / `peer_updated` / `peer_offline`）经 Redis Pub/Sub 广播。

当前多实例能力边界（单实例部署不受影响）：

- **Presence / Discovery：跨实例 ✅**。租约在 Redis，带 ConnectionID 所有权
  CAS（`TakeDiscovery` 原子校验 presence owner），跨实例重连竞态封死。
- **P2P Signaling：本实例路由 ❌**。`candidate_offer` / `candidate_answer` /
  `channel_message` / `channel_ack` / `crypto_handshake` / `webrtc_*` 仍按
  `h.peers[frame.TargetID]` 本实例转发：A 在 Relay-1、B 在 Relay-2 时，A 能
  lookup 到 B 的 discovery，但信令帧无法跨实例送达 B。
- **Relay Data：单实例 + 实例亲和 ❌**。数据面帧依赖双方连接在同一实例。

因此多实例下「A 知 B 在线 → lookup → 拿候选」成立，但「候选信令 → Direct →
Relay fallback」的完整链路需要双方落在同一 Relay 实例（实例亲和），或先做
跨实例信令转发。**短期约束：多 Relay 实例部署时，单台设备的控制连接与数据
连接必须绑定同一实例**；跨实例信令转发与 Relay Data 迁移是后续里程碑。

### 4.4 sweeper 离线判定

presence 租约 TTL 60s、心跳 20s 续租。sweeper 周期扫描租约，TTL 过期即判定
设备离线：清理其 discovery 快照、关闭残留连接、触发 `peer_offline` 推送与
admin 在线视图更新。sweeper 是事件丢失与心跳中断的兜底，保证不残留死设备
的候选与在线态。sweeper 判活以 presence 为准（presence 才是在线权威），
discovery 键可能被 Redis 逐出而与在线 presence 不同步，不以双有效判僵尸。

### 4.5 修正一轮（2026-08-15 二次修订，code-review 收口）

一次集中修正 review 发现的连接正确性问题，不扩功能：

- **lookup 前移 + generation-aware 权威对账**（见 3.4/ADR-017）：Discovery 解析
  先于 Direct；`lookup_response` 是连接前权威状态——新 generation 删旧代候选
  重建、同 generation 合并、明确 offline 删 discovery-derived path_manager，
  增量事件（peer_online/updated/offline）丢失也不影响最终连接正确性。
- **占位 discovery 移除 + 在线判定收紧**（见 3.1/3.2）：presence+discovery+
  gen>0+owner 一致四元判定。
- **Discovery CAS 原子化**（见 3.2）：Redis Lua 原子校验 presence owner。
- **peer_online 无条件清缓存**：新可发现 epoch，无论 generation 高低都清旧
  path_manager / candidate_attempts。
- **客户端不再用固定 TTL 推断远端下线**：native `peer_presence` 缓存只由
  `peer_offline`（权威增量）与 `presence_snapshot`（全量对账）增删，不再按
  300s 裁剪在线设备（心跳不广播，长在线设备的 last_online 不会刷新，固定
  TTL 会误删）。
- **generation 单调限定同一 owner**（见 3.2）：同一连接回退才拒绝；跨 owner
  允许任意正 generation，保证旧版本随机大 generation 不阻断升级客户端上传。

### 4.6 后续 follow-up（非本修正 PR）

- **Native 自动 Discovery 生命周期**：网络接口变化 / NAT Mapping 变化 / STUN
  结果变化时自动 `generation++`、重新 gather 候选、自动 `discovery_update`
  （当前只在 Relay 连接/重连时自动上传一次，候选变化后的再上传仍由上层显式
  触发，旧候选可能被心跳持续续 TTL）。
- **generation 严格跨进程单调**：当前用 Unix-ms 时间种子（进程内单调、系统
  时钟回拨时可能回退，但服务端 owner 限定 + 重连新 epoch 已兜底）；如需绝对
  单调应持久化 `generation = max(persisted + 1, unix_ms)`。
- **上传失败的可靠重试 / ACK**：当前 `discovery_update` 失败只记 debug，依赖
  下次 Relay 连接重传；可加 server ACK + 有限重试。
- **跨实例 P2P Signaling / Relay Data**（见 4.3）：多实例部署的前置工作。

## 5. 引用

- [ADR-004：NAT Traversal and Path Selection](../adr/ADR-004-nat-traversal.md)
- [ADR-017：Peer Candidate Exchange（2026-08-15 修订：存储发现不解析信令）](../adr/ADR-017-candidate-exchange.md)
- [ADR-008：Direct First 顺序建连（2026-08-15 修订）](../adr/ADR-008-direct-relay-race.md)
- [ADR-018：Relay-to-Direct Session Upgrade](../adr/ADR-018-relay-direct-upgrade.md)
- [Redis + MySQL 会话存储接入计划](REDIS_MYSQL_SESSION_STORAGE_PLAN.md)
- [SSH Mobile 跨平台 P2P 网络平台实施计划](../NETWORK_PLATFORM_IMPLEMENTATION_PLAN.md)
- [Relay README](../../relay/README.md)（端点、env、部署与硬化 backlog 归属）
