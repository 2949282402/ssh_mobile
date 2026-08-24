> 最新更新时间：2026-08-22

# ADR-TRANSPORT-NETWORK-V2：传输网络 v2 架构（Breaking Refactor 总纲）

## Status

Accepted for the transport-network v2 breaking refactor (2026-08-15). This is
the Step 1 ADR of the Main 基线版 refactor; it defines the overall v2
architecture, the four highest principles, the naming scheme, the first-phase
single-instance scope, and which v1-contract ADRs it supersedes. Implementation
steps 2-11 follow the design doc execution order.

## Context

Network v1 (`RuntimeState`) couples presence, discovery cache, candidate,
`PathManager`, Session, reconnect, direct-upgrade, and business state into one
interlocked machine: a presence change cascades into discovery cache, candidate,
path, session, reconnect, and route-migration changes. The Main 基线版 design
(「SSH_Mobile 传输网络架构重构设计 Main 基线版」, 2026-08-15) classifies this as a
breaking refactor: we stop maintaining "一个永远正确的远端网络状态", and instead
**真正要通信时重新向服务器解析当前状态，然后建立一次新的连接**；已经
authenticated 且仍由路径 owner 判定健康、capability-compatible 的现有 path
可以在控制面之前复用，不发送无主的 target-less Offer。

This ADR is the top-level decision. It does not repeat the per-subject details;
the four companion ADRs (Discovery, Connection Lifecycle, Business Recovery,
Relay Data Plane) hold those decisions.

## Decision

### The four highest principles

```text
Presence Push is advisory.         Presence 推送只是 UI 提示。
Resolve/Lookup is authoritative.   新建/替换连接前必须查询服务器；健康现有 path
                                   的复用由物理路径 owner 判定。
Transport Connection is disposable.网络连接本身允许直接废弃重建。
Business state is resumable when necessary. 只有真正需要连续性的业务状态才恢复。
```

Every implementation step must obey these four rules. In particular:

- `Presence` events only ever update `PresenceHintCache` for the UI. They must
  not mutate `ConnectivityAttempt`, `CandidateSet`, `ConnectionSession`,
  `Transfer`, `Delivery`, or `PathMetrics`.
- Every creation of a new Transport Connection (or a re-creation after a lost
  connection) must first run `ResolvePeer` against the server. Existing healthy
  SSH/transfer streams do not re-Resolve per command/chunk.
- A Transport Connection and its `ConnectionSession` are destroyed together; no
  generic transparent reconnect restores an old socket, old `SessionId`, or old
  Noise root.
- Business continuity (file transfer, reliable message, Delivery) is owned
  above the transport and resumed across fresh connections by business identity
  (`transfer_id` / `MessageId`).

### Implementation ownership closeout

The current implementation makes the four principles executable rather than
descriptive:

- `PeerSupervisor` is the sole mutable Peer connectivity/lifecycle owner and
  receives transport-loss reports through its generation-guarded mailbox.
- `PeerPathManager` owns the Direct and Relay `PhysicalPath` carriers. A
  `PathHandle` is non-owning; business operations acquire and release a
  `PathLease`, and normal drain is distinct from hard close/security revoke.
- `ConnectionSessionStore` stores only connection identity, remote binding,
  admission winner state, and security decisions. It does not expose route,
  carrier, Relay-data, Peer lifecycle, or capability-union state.
- Delivery, Transfer, ReliableStream, SSH, and Realtime use the path owner for
  transport selection. Transport loss destroys the ConnectionSession; only
  Delivery/Transfer business identities may resume on a fresh connection.
- `E2eePolicy::Required` installs a fresh application root after authenticated
  Noise/path admission. `E2eePolicy::Disabled` is identity-only Direct and
  cannot open a Relay path or create application crypto context.
- Stage A is cache/configured Direct only; Stage B is authoritative
  Resolve→Offer with a fixed four-second Direct window; Stage C reserves Relay
  only after `READY`, Direct failure, capability compatibility, Required E2EE,
  and remaining budget.

### Naming scheme for generation / epoch / revision

The four previously overloaded concepts are fixed as follows:

| 概念 | 名称 | 语义 | 权威来源 |
|---|---|---|---|
| Discovery 版本 | `runtime_epoch`（128-bit 随机，每次 native runtime 启动生成）+ `revision`（同 epoch 内严格递增） | 描述设备当前可连接信息；同 epoch 内可比较，跨 epoch 不可比较 | 本 ADR + ADR-DISCOVERY-V2 |
| Delivery 恢复代 | `recovery_epoch` | 描述业务恢复周期；V2 中继续存在但锚定到业务身份而非 `SessionId` | ADR-010（V2 修订） |
| Crypto 轮换代 | `KeyEpoch` | 描述 Session 密钥轮换窗口 | ADR-023 / ADR-028 |
| Realtime 快照版本 | `revision` | 描述 WebRTC/Realtime 快照新旧（v1 wire 契约保留语义） | ADR-029 |

v2 **deletes** the v1 `generation` concept (Unix-ms 时间种子、跨进程单调、
old generation > new generation 特判) in favor of `runtime_epoch + revision`.

### ADR-028 的 "v2" 名称碰撞

`transport-network v2` 是**协议代际（protocol generation）**：指本次对整个传输网络
体系（presence / discovery / connection / relay data plane）的破坏性重构，是
Main 基线版的设计代号。它 **不是** ADR-028 中被拒绝的 crypto-handshake v2：

- ADR-028 的 "v2 is rejected" 指 **Noise 密钥协商版本**：v2 手写 Root 推导被拒绝，
  当前采用 v3 Root exchange（`Noise_XX_25519_AESGCM_SHA256` + 独立 RootSeed）。
- transport-network v2 与 crypto 版本正交：v2 重构**保留** ADR-028 的 v3
  `KeyEpoch` / 结构化 nonce / 前向保密，不降级、不复用被拒绝的 v2 协商。

在阅读任何 ADR 时，"v2" 必须按上下文区分：`ADR-*V2` 与 `transport-network v2`
= 协议代际；`ADR-028` 的 "v2" = 被拒绝的 crypto 版本。出现歧义时以本命名表为准。

### First-phase deployment scope（单实例）

第一阶段明确只支持：

```text
Relay Control = 单实例
Relay Data    = 单实例
Redis         = 外部共享 live state（presence/discovery 同步）
MySQL         = 外部持久状态（durable truth）
```

代码和文档**不得宣称 Multi-instance supported**，直到完整实现
`Global Control Routing` + `Relay Data Node Selection` 之后才开放多实例。
Redis 仍是共享 live state 层（其键结构天然支持跨实例 presence/discovery
同步），但第一阶段部署是单 Relay Control + 单 Relay Data 实例。

### Superseded v1 ADRs

以下 v1 契约 ADR 的内容被 v2 删除，标记 Superseded（沿用 ADR-003 模式）：

- ADR-006（v1-only 契约，禁止 v2/fallback —— v2 反转）
- ADR-029（v1 协议契约 wire shapes —— Relay Protocol V2 取代）
- ADR-009（自动重连 —— ConnectionSession 可丢弃取代）
- ADR-014（路径质量采样与迁移 —— PathManager 仅保留 metrics）
- ADR-018（Relay→Direct 后台升级 —— 从主链移除）

## Consequences

- 这是一次明确的破坏性重构：删除旧协议、旧 API、旧状态机；不保留 v1/v2
  双栈、deprecated compatibility adapter 或旧客户端兼容。
- 服务器重新成为连接前的权威；presence 推送丢失的最坏结果是 UI 几秒钟
  显示不准确，不影响连接正确性。
- 大流量（Relay Data）不能阻塞 heartbeat / signaling（Control）。
- 迁移完成后 v1 网络状态机必须从 main 删除；新架构是唯一实现。

## Verification

按 Main 基线版 §41 验收清单执行，至少覆盖：新建/替换连接前 Resolve、健康现有
path 复用时控制面零调用、Presence 只
用于 UI Hint、Presence Event 无权修改 ConnectivityAttempt、Discovery 使用
runtime_epoch + revision 且有 ACK、Resolve 四态、Candidate 完全 attempt
scoped、PathManager 不保存远端长期 Discovery Truth、Direct First 固定 4s、
Control/Relay Data 物理分离、ConnectionSession 与 Transport 同生命周期、
Delivery/Transfer 自行恢复、SSH/WebRTC 新建 Session、Relay→Direct 无触发透明
升级移除（环境变化触发的 bounded Direct recovery 除外），以及 Rust / Go / Dart /
Flutter 测试全部通过。当前提交的
`protocol/contract_tests/acceptance_matrix.json` 已将 60 个案例标记为
`covered`；本地 `scripts/network_v2_acceptance.sh strict`、Go/Dart owner
套件、buf 和 descriptor 门禁，以及选定的 architecture/protocol/SDK CI jobs
均已通过；完整 App/feature/设备与服务集成门禁仍由 CI 执行。
