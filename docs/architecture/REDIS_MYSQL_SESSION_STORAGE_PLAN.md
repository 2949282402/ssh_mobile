> 最新更新时间：2026-08-15
> 状态：已达成共享理解，待评审后实施
> 适用对象：Go Relay 控制面（`relay/`）后端

> **2026-08-15 修订（对齐 transport-network v2）**：本计划原文按「多实例」设计
> 状态/缓存面。transport-network v2（Main 基线版 §26，
> [ADR-TRANSPORT-NETWORK-V2](../adr/ADR-TRANSPORT-NETWORK-V2.md)）第一阶段明确
> **单 Relay Control + 单 Relay Data 实例**；Redis 为外部共享 live state
> （跨实例 presence/discovery 同步）。`Global Control Routing` /
> `Relay Data Node Selection` 未完整实现前不得宣称 Multi-instance supported。
> 下文所有「多实例」表述已收敛为单实例部署语义。

# Redis + MySQL 会话存储接入计划

## 0. 摘要

为 Go Relay 控制面引入 MySQL（持久化 source of truth）与 Redis（短生命周期共享状态），
把当前"进程重启即清空、设备需重新 enroll"的内存状态机，升级为**可持久化**的
会话/鉴权/状态架构；部署拓扑为**单 Relay Control + 单 Relay Data 实例**，Redis
为外部共享 live state。

**本轮范围边界**：只做**状态/缓存面**接入 MySQL / Redis 共享 live state。数据面
（两个设备之间的 WS 控制帧转发）保持单实例；多实例部署与跨实例数据面转发
（`Global Control Routing` / `Relay Data Node Selection`）列为后续里程碑（见 §9）。

**核心不变量**：
- MySQL 是**唯一 source of truth**（enrollment、吊销、审计）。
- Redis 只承载**短期、可重建、高频**状态（在线 presence、防重放 nonce、admin 会话、传输会话元数据），全部带 TTL。
- Redis 不可用时 **fail-open**：鉴权回退 MySQL 直查，仅在线/防重放/实时通知降级。
- 升级**无缝滚动**（已签发凭据与已建连接在升级期间不断）。

---

## 1. 已锁定决策（`/grill-me` 会话产出）

| # | 决策 | 结论 |
|---|------|------|
| Q1 | 会话范围 | 客户端↔Relay 鉴权 + 连接状态；SSH 隧道状态留在 native SDK 内存态；Admin 会话本轮一并覆盖 |
| Q2 | 部署拓扑 | 第一阶段**单实例**部署；Redis 承载共享 live state（其键结构支持跨实例 presence/discovery 同步） |
| Q3 | 持久化边界 | MySQL = 唯一准（设备/enrollment、吊销、审计）；Redis = 短期可重建态，全 TTL |
| Q4 | 一致性 | **cache-aside 失效式**：先写 MySQL → 删/失效 Redis key → TTL 兜底 |
| Q5 | 共享状态事件 | Redis Pub/Sub 广播 `session.invalidate` / `device.revoked` 等事件 |
| Q6 | Token 形态 | **适配现状**：不新造双 token 签发；enrollment（deviceID+公钥）落 MySQL，连接态/防重放/presence 落 Redis，保住无状态 HMAC 凭据 |
| Q7 | 降级 | **fail-open**（针对 Redis）；MySQL 是鉴权裁决唯一准，Redis 挂只降级加速层/状态层 |
| Q8 | 升级 | **无缝滚动**：统一鉴权校验入口，新旧逻辑同一路径，过渡完删旧路径 |
| Q9 | 数据面 | 本期数据面保持单实例（单 Relay Control + 单 Relay Data 实例）；跨实例转发后续里程碑 |

---

## 2. 现状基线（改动前的事实）

全部来自代码调研，均为"当前为真"：

- **Go Relay 纯内存，零持久化、零存储依赖**（`relay/go.mod` 仅 `gorilla/websocket`）。
- 状态容器（均进程内 `map` + 锁）：
  - 活跃 WS 对端 `hub.peers map[string]*peer`（key = deviceID）— `relay/internal/relay/hub.go:55-64`
  - 传输会话 `hub.transferSessions map[string]session`（TTL 15m，`config.go:30`）— `hub.go:35-41`
  - enrollment `Server.enrolledDevices`、吊销 `Server.revokedDevices`、防重放 `Server.proofNonces`、admin `Server.admin` — `server.go:18-28`
- **鉴权无状态**：设备凭据为自包含 HMAC 令牌 `base64url(claims).base64url(mac)`，payload `{device_id, public_key, expires_at}`；`verifyCredential` 只验签+过期，无查表 — `credential.go:28-73`。
- 连接鉴权 `authenticatedRequest`：Bearer HMAC + `X-Relay-Nonce`（32B）+ `X-Relay-Signature`（Ed25519 对 `METHOD\nPATH\nnonce`）+ nonce 防重放（内存，每设备 128 上限）+ 吊销检查 + 公钥匹配 — `device_enrollment.go:191-256`。
- 心跳 20s → `heartbeat_ack`（`hub_control.go:34-43`）；`peer.lastSeen` 记录但**无空闲超时踢人**。
- 吊销为内存 tombstone，受 `MaxRevokedDevices` 容量上限约束（fail-closed）— `revocation.go:26-47`。
- admin 会话：内存 `map` + HttpOnly cookie `relay_session`，TTL 24h，`MaxAdminSessions` 上限 — `admin_auth.go:26-94`。
- 在线统计直接读内存 `hub.peers` — `admin_api.go:58-75`。
- 客户端本地 SQLite（drift）/secure storage 只存**设备侧**连接配置与身份，服务端不涉及 — `packages/core/connection_core`。
- **无可迁移的历史服务端数据**：引入存储是"从零建存储"，无需迁移历史数据；但存在**存量已 enroll 设备与已签发凭据**，升级需无缝（见 §7）。

---

## 3. 目标架构

### 3.1 职责边界

```
┌─────────────── MySQL（source of truth，持久）────────────────┐
│  devices（enrollment）、revocations、audit_events               │
│  → 重启不丢；单实例 + Redis 共享 live state                    │
└───────────────────────────────────────────────────────────────┘
                    ▲ 读（可选 Redis 读缓存 + TTL 兜底）
                    │ 写（先 MySQL → 失效缓存 → 发事件）
┌─────────────── Redis（ephemeral，全 TTL）────────────────────┐
│  presence / nonce / admin:session / transfer / relay:events   │
│  → 在线态、防重放、实时通知；可重建、可丢                     │
└───────────────────────────────────────────────────────────────┘
                    ▲
┌─────────────── Relay 实例（进程内只留本实例数据面）────────────┐
│  hub.peers（本实例活跃 WS）+ 内存读缓存（可选）               │
└───────────────────────────────────────────────────────────────┘
```

### 3.2 MySQL Schema（草案）

```sql
CREATE TABLE devices (
  device_id   VARCHAR(64) PRIMARY KEY,
  public_key  VARBINARY(64) NOT NULL,             -- Ed25519 公钥（对齐 EnrolledDevice 字段格式）
  status      VARCHAR(16) NOT NULL DEFAULT 'active', -- active | revoked
  enrolled_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE revocations (
  device_id   VARCHAR(64) PRIMARY KEY,
  revoked_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  valid_until TIMESTAMP NOT NULL,                 -- 吊销生效上界（凭据过期时间）
  reason      VARCHAR(255) NULL
);

CREATE TABLE audit_events (                       -- 可选，为审计留口子
  id          BIGINT AUTO_INCREMENT PRIMARY KEY,
  device_id   VARCHAR(64) NULL,
  event       VARCHAR(64) NOT NULL,               -- enroll|refresh|connect|revoke|disconnect
  detail      VARCHAR(512) NULL,
  created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_device (device_id),
  INDEX idx_created (created_at)
);
```

Schema 迁移：新增 `relay/internal/relay/storage/migrations/`，启动时用嵌入 SQL 或轻量迁移器执行；不做外部迁移工具依赖。

### 3.3 Redis Key 规范（草案）

| Key | 值 | TTL | 替代 |
|-----|-----|-----|------|
| `presence:{device_id}` | `{instance, last_seen}` | 60s（心跳 20s 续期） | Redis 在线态（替代"读内存 hub.peers"） |
| `nonce:{device_id}:{nonce}` | `1`（原子 SETNX） | 5m | 内存 `proofNonces`（Redis 防重放） |
| `admin:session:{token}` | admin 身份 | 24h | 内存 `adminAuthState.sessions` |
| `transfer:{session_id}` | 传输会话元数据 JSON | 15m（活动续期） | 内存 `hub.transferSessions` |
| `dev:{device_id}` | enrollment 读缓存 | 60s（cache-aside） | — |
| `rev:{device_id}` | 吊销读缓存 | 60s（cache-aside） | — |

Pub/Sub 频道 `relay:events`，事件负载为 JSON `{type, device_id, ts}`：
- `device.revoked` — 断开该设备连接
- `device.kicked` — 重复登录/管理端踢人，踢掉旧连接
- `session.invalidate` — admin 会话失效等通用失效通知

### 3.5 核心流程

**鉴权连接（Redis 共享 live state）**
1. 设备连到 Relay 实例 → `upgradeDevice` → `authenticatedRequest`。
2. 实例验 HMAC（共享 `CredentialKey`）+ 过期检查（无状态，独立可验）。
3. 原子消费 nonce：`SETNX nonce:{id}:{nonce}`（失败即重放拒绝）→ 替代 `consumeProofNonceLocked`。
4. 查 enrollment：Redis 读缓存 `dev:{id}` → miss 回源 MySQL `devices`（cache-aside）→ 公钥匹配 + `status=active`。
5. 查吊销：`rev:{id}` / MySQL `revocations` → 命中即拒绝。
6. 写 presence：`SETEX presence:{id}` = 本实例 ID + last_seen。
7. `hub.add(peer)`（仅本实例数据面）+ 审计事件。

**enroll / refresh**
- `enroll`：写 MySQL `devices`（UPSERT）→ 失效 `dev:{id}` → 发事件 → 签发凭据。
- `refresh`：查 MySQL enrollment 存在才重发凭据（当前重启后 404 的问题因持久化而消失）。

**吊销 / 踢人**
- 管理端 revoke → 写 MySQL `revocations` + `devices.status` → 失效缓存 → 发 `device.revoked` → 关闭该设备 peer。
- 重复 deviceID 连接：新连接写 presence 覆盖 → 检测 presence 归属变化（或 `device.kicked`）→ 关闭旧 peer。

**心跳 / presence**
- 每 20s 心跳续期 `presence:{id}`；TTL 60s 自然过期即离线（顺带得到"空闲超时"语义，弥补当前无 idle 踢人的缺口，可选启用）。

---

## 4. Go Relay 改动点（按文件）

| 文件 | 改动 |
|------|------|
| `relay/internal/relay/config.go` | 新增 `DATABASE_URL`、`REDIS_ADDR`/`REDIS_URL`、`REDIS_PASSWORD`、`RELAY_STORAGE_MODE=memory\|mysql` 等字段与 `ConfigFromEnvironment` 解析；确保 `CredentialKey` 由 env 注入 |
| `relay/internal/relay/storage/`（新增） | MySQL 访问 + `Storage` 接口 + schema 迁移；`Storage` 提供内存实现（无存储模式，保持现状为默认） |
| `relay/internal/relay/cache/`（新增） | Redis client + key 封装 + `Cache` 接口 + 内存/空实现 |
| `relay/internal/relay/server.go` | `NewServer` 注入 `Storage`/`Cache`；`enrolledDevices`/`revokedDevices` 读写改走存储层（保留内存读缓存） |
| `relay/internal/relay/device_enrollment.go` | enroll/refresh 走存储；`authenticatedRequest` 查存储 + Redis 防重放 nonce |
| `relay/internal/relay/revocation.go` | 吊销写 MySQL + 发 Pub/Sub 事件；重定义容量语义（DB 为界，内存只做热缓存） |
| `relay/internal/relay/admin_auth.go` | admin 会话迁 Redis（TTL 24h） |
| `relay/internal/relay/hub.go` | transferSessions 迁 Redis（可选，见 §9）；presence 写入；踢人 |
| `relay/internal/relay/admin_api.go` | 在线统计改从 Redis presence 聚合 |
| `relay/internal/relay/hub_control.go` | 心跳续期 presence |

**接口草案**（保持小而稳，便于内存实现做单测与无存储默认）：

```go
type Storage interface {
    GetEnrollment(ctx context.Context, deviceID string) (*EnrolledDevice, error)
    UpsertEnrollment(ctx context.Context, d *EnrolledDevice) error
    SetRevoked(ctx context.Context, deviceID string, validUntil time.Time, reason string) error
    IsRevoked(ctx context.Context, deviceID string, at time.Time) (bool, error)
    AppendAudit(ctx context.Context, e AuditEvent) error
}

type Cache interface {
    SetPresence(ctx context.Context, deviceID, instanceID string, ttl time.Duration) error
    GetPresence(ctx context.Context, deviceID string) (Presence, error)
    ConsumeNonce(ctx context.Context, deviceID, nonce string, ttl time.Duration) (bool, error)
    SetAdminSession(ctx context.Context, token, identity string, ttl time.Duration) error
    GetAdminSession(ctx context.Context, token string) (string, bool, error)
    // ...transfer、读缓存等
}
```

---

## 5. 一致性 / 降级 / 安全

- **一致性**：写路径统一"先 MySQL → 失效 Redis 读缓存 → 发事件"。不引入分布式事务/锁；enrollment 与吊销以 MySQL 行为准，Redis 读缓存 TTL 兜底防脏。防重放靠 Redis SETNX 原子性，无竞态窗口。
- **降级（fail-open，针对 Redis）**：Redis 不可用时，鉴权直查 MySQL（跳过读缓存），nonce 防重放降级为进程内尽力而为（接受故障期间重放窗口，日志告警），presence/admin 会话/传输元数据/实时通知降级。核心鉴权不中断。
- **MySQL 故障**：鉴权是裁决路径 → **fail-closed**（无法裁决即拒绝），加告警与熔断；不把 MySQL 当缓存层弱化其权威地位。
- **凭据安全**：`CredentialKey` 与 DB/Redis 口令经 env/密钥管理注入，**不得入库、日志、文档**（遵循仓库 CLAUDE.md 规则）。审计表不存凭据明文。

---

## 6. 配置与部署

- 新增 env：`DATABASE_URL`（MySQL DSN）、`REDIS_URL`/`REDIS_ADDR` + `REDIS_PASSWORD`、`RELAY_STORAGE_MODE`（`memory` 默认 | `mysql`）、可选 `RELAY_STORAGE_READ_CACHE_TTL` 等。更新 `relay/.env.example` 与 `relay/README.md`（env/部署段归属 README）。
- `relay/compose.yaml`：新增 `mysql`、`redis` 服务 + 数据卷；Caddy 拓扑保持。
- **第一阶段部署为单 Relay Control + 单 Relay Data 实例**：单实例共享同一 `CredentialKey`（env）；presence 路由与 Pub/Sub 事件在同一实例内闭环。多实例部署（`Global Control Routing` 与 `Relay Data Node Selection`）未完整实现前不支持，也不在 compose 中提供 LB 实例亲和路由。
- 密钥/口令走环境注入或密钥管理，不进 compose 明文（生产用 secret 文件/外部注入）。

---

## 7. 升级顺序（无缝滚动，决策 Q8）

1. **Phase 0 — 抽象与无存储默认**：引入 `Storage`/`Cache` 接口 + 内存实现，`RELAY_STORAGE_MODE=memory` 为默认，行为与现状完全一致；现有测试全绿。
2. **Phase 1 — MySQL 持久化**：enrollment/吊销落 MySQL，读走缓存+回源。**一次性播种**：启用前把运行中实例内存里的 enrollment 导出写入 MySQL（离线 dump 或一次性迁移命令），保证存量已 enroll 设备在滚动部署中不断线。
3. **Phase 2 — Redis 状态层**：presence/nonce/admin/transfer 迁 Redis，feature flag 控制；双写对比期后删内存路径。
4. **Phase 3 — 统一入口收口**：鉴权收敛到单一校验函数（新旧逻辑同路径），过渡完成后删旧分支；更新 `memory_docs/backend/current-state.md`（"重启即清空"一句失效）与 `relay/README.md`。
5. **Phase 4 — 单实例交付收口**：MySQL/Redis 状态面在**单 Relay Control + 单
   Relay Data 实例**拓扑下压测验证；Pub/Sub 踢人/吊销在同一实例内闭环。多实例
   部署（`Global Control Routing` / `Relay Data Node Selection`）列为后续里程碑
   （见 §9），不在第一阶段范围。

每 Phase 完成必须回到"可分析、可测试"状态再进入下一 Phase（对齐仓库维护 Skill 的验证门禁）。

---

## 8. 验证方案

- **单元**：`Storage`/`Cache` 接口用内存实现做 fake；现有 `relay/` Go 测试全部通过；新增存储层单测（upsert/吊销/缓存失效）。
- **集成**（compose 起 mysql+redis）：重启存活（enroll → 重启 relay → 凭据仍有效，不再需要重新 enroll，**头号行为变化**）；吊销（设备被断开）；Redis 停机回退（停 redis → 鉴权仍可用）；重复登录踢旧连接。多实例跨实例行为不在第一阶段验证范围。
- **工具**：`go test ./...`、`go vet ./...`；CI 视需要新增 Go 存储 job（对齐现有 `.github/workflows/`）。
- **手动回归**：对照 `relay/README.md` 部署文档走一遍 enroll → 连接 → 传输 → 吊销全流程。

---

## 9. 里程碑与范围边界

- **本期（M1）**：Phase 0–4 全部落地，交付可持久化的会话/鉴权/状态面；部署拓扑为单 Relay Control + 单 Relay Data 实例，Redis 为共享 live state；数据面保持单实例。
- **后续（M2，显式 deferred）**：多实例部署与跨实例数据面转发（两个设备落在不同实例时控制帧的桥接/路由）——需先完整实现 `Global Control Routing` + `Relay Data Node Selection` 再开放（见 [ADR-TRANSPORT-NETWORK-V2](../adr/ADR-TRANSPORT-NETWORK-V2.md)）；独立工程，等真实多实例流量需要时再启动。
- 传输会话迁 Redis（`transfer:{session_id}`）为**可选**：若短期内传输会话无需跨连接/跨实例接管，可保留进程内实现，presence 与鉴权先行。
