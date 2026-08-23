> 最新更新时间：2026-08-24

# 跨域项目审查 TODO

本文记录项目审查第 3 阶段的可执行事项与验收证据。审查严格按
Front → Backend → Client → SDK 的顺序推进；进入一个 Domain 后才展开其完整
TODO，修复并通过该 Domain 门禁后再进入下一个 Domain。

状态说明：`[x]` 已修复并验证，`[ ]` 尚未进入或尚未完成。代码与测试是当前
行为的权威证据，本文件不复制 Domain Memory 或架构文档。

## Front

- [x] **F-01 管理员会话状态 fail-closed**：修复登出后仍停留在控制台、连接恢复
  后残留旧错误、登出后旧会话探测迟到复活登录态，以及受保护请求返回 401、会话
  复查又失败时继续保留旧登录态。
- [x] **F-02 通用 API 响应边界**：204 响应仍经过 endpoint schema 校验；调用方
  已取消时，即使底层 `fetch` 无视 AbortSignal 并迟到成功，也拒绝该响应。
- [x] **F-03 Enrollment Token 生命周期**：30 秒到期会重置 active observer；轮换
  会取消旧读取；卸载后的迟到响应不能回填；明文轮换结果不进入 MutationCache；
  复制、展示和 QueryCache 仍保持短时、内存内、明确操作后访问。
- [x] **F-04 过期快照与撤销一致性**：Overview/Devices 刷新失败时明确标为旧数据；
  撤销成功会先从本地快照移除设备，再尝试权威刷新。
- [x] **F-05 部署语义文案**：移除硬编码的 memory-only、重启必然清空设备及含混的
  Protocol v1 文案；改为存储配置中立表述，并明确浏览器使用 Admin API v1。
- [x] **F-06 键盘与 CSP 边界**：移动导航支持焦点进入、焦点约束、Escape、焦点恢复
  和关闭态不可聚焦；设备撤销操作包含设备 ID；剪贴板 fallback 不再产生被生产
  CSP 禁止的 inline style，并保证临时明文节点最终清理。
- [x] **F-07 Front 回归与覆盖率**：61 项测试通过；aggregate statements/lines
  96.01%、branches 85.58%、functions 90%，通过 80% Domain 门禁。

Front 验收命令：

```bash
cd front
npm run typecheck
npm run lint
npm run test:run
npm run build
cd ..
bash scripts/front_coverage.sh
bash scripts/full_test.sh --only front-quality --no-bootstrap
```

## Backend（已完成）

- [x] **B-01 完整 Backend 审查**：已按 Backend Memory、Relay README、Go 实现、
  测试、配置、Compose 与跨域 wire 边界完成审查，并将发现项落实为以下可独立验收的
  修复；未把用户的 Rust 工作树改动纳入 Backend 编辑范围。
- [x] **B-02 Network V2 管理指标**：管理概览改为读取真实、并发安全的 RelayData
  活动配对数；pending 单端不计数，配对释放后立即归零，并有生命周期回归测试。
- [x] **B-03 Front↔Relay 契约门禁**：真实 Go handler 在私有临时目录生成已脱敏
  响应，Front 生产请求客户端与 Zod schema 验证路径、方法、状态码、204、401 和
  JSON 字段；门禁已接入 `full_test.sh` 与独立 GitHub Actions job。
- [x] **B-04 设备身份与准入原子性**：enrollment generation 进入凭据与 Control/
  RelayData 身份；Server 设备 stripe 与 Hub presence-admission stripe 都可由 context
  取消且共享 caller deadline。一个 5 秒总预算覆盖持久检查、WebSocket upgrade、
  不可路由 staging、登记后复查与 activation；revoke、re-enroll、跨实例事件和对账按
  generation fail-closed，已关闭的当前 Control peer 不能继续路由缓冲帧。Relay
  reservation 还必须消费同一 Control connection 上绑定 attempt/target 的一次性
  Resolve → Offer fallback gate。
- [x] **B-05 RelayData one-shot 生命周期**：pending 同角色重试替换旧端点，active
  同角色重试关闭两个旧端点并要求 counterpart 重新连接；PairReady 两端 enqueue/
  commit 原子化，数据必须等待本端 PairReady 实际写入；keepalive 使用独立 marker；
  reservation TTL 删除后只允许已跟踪 active/replacement pair 重试，初始 pending
  不得绕过共享存储；普通断线终结已消费的 reservation，必须重新申请。吊销与业务帧
  forwarding 在 registry mutex 下线性化；最大 512 KiB 帧的 protobuf 编码/分配先在锁外
  完成，锁内只复核状态、预留 flow budget 并非阻塞入队。terminal writer 丢弃排队帧，
  revoke 会等待已开始的真实 WebSocket 写入收敛。
- [x] **B-06 状态与关停边界**：Redis 启用 context timeout、禁用自动重试，并硬限制
  2 秒 socket/pool wait 与 64 连接 pool；URL 查询不能覆盖。MySQL+Redis 启动共用
  15 秒 deadline；`NewServer` memory 模式和 MySQL composition 都会清除误传/启动期的
  DatabaseURL、RedisURL 与 RedisPassword，Hub 只保留所属标量能力。RelayData、Hub
  和事件对账先并发收敛，Cache/Storage 再在同一个 10 秒总预算的剩余时间内并发关闭；
  忽略 context 的依赖不能无限阻塞。memory proof nonce 使用每设备 earliest-expiry heap
  与固定预算 cleanup，历史设备 bucket 有界收敛且未过期证明跨 re-enroll/revoke 保留。
  MySQL 并发回归只使用 `_test.go` 内的事务/外键 gate，生产 adapter 不保留测试 hook
  或 observer。
- [x] **B-07 部署、代理与有界状态**：`RELAY_PUBLIC_URL` 正确执行 HTTPS→WSS、
  回环 HTTP→WS；只信任可信直接代理的客户端 IP 头与 `X-Forwarded-Proto`，Cookie
  `Secure`/管理端 Origin 使用同一信任边界；DiscoveryPublish limiter 仅在持久
  enrollment 确认删除后释放 slot，reconnect、同密钥 re-enroll 和迟到事件不能重置。
  Control attempt 与 reservation gate 使用精确可删除的 expiry min-heap；Offer 普通热路径
  不再在 Hub 全局锁内扫描最多 65,536 条状态，满容量只定向回收一个堆顶，单连接仅检查
  固定上限 64 的反向索引桶。权威 initiator snapshot 的最大 512 KiB Offer 也先在锁外
  编码/分配；锁内重新绑定两端精确 connection，仅登记索引并非阻塞入队，失败完整回滚。
- [x] **B-08 Backend Domain 门禁**：最终补丁后的 `gofmt`、完整 Go suite、race、vet、
  Backend coverage、Front↔Relay 管理契约、22 个 Relay V2 fixture/descriptor、memory /
  storage Compose config、相关脚本语法与 `git diff --check` 均通过；Backend coverage
  为 90.4%（门槛 80%），临时 MySQL/Redis 集成测试实际执行且未 skip，无 Backend
  环境 gap。

Backend 验收命令：

```bash
cd relay
files="$(gofmt -l ./cmd ./internal)"; test -z "$files"
go test ./...
go test -race ./...
go vet ./...
cd ..
bash scripts/backend_coverage.sh
bash scripts/admin_api_contract.sh
bash scripts/relay_v2_contract.sh
bash -n scripts/backend_coverage.sh scripts/admin_api_contract.sh scripts/relay_v2_contract.sh
# 仅为 Compose 解析在子 shell 生成临时值；不要把这些值复用到部署环境。
(
export RELAY_PUBLIC_URL=http://127.0.0.1:18080
export RELAY_ENROLLMENT_TOKEN="$(openssl rand -hex 32)"
export RELAY_CREDENTIAL_KEY="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"
export RELAY_ADMIN_USER=config-check
export RELAY_ADMIN_PASSWORD="$(openssl rand -base64 24)"
docker compose --env-file relay/.env.example -f relay/compose.yaml config --quiet
export RELAY_STORAGE_MODE=mysql
export MYSQL_PASSWORD="$(openssl rand -hex 16)"
export RELAY_REDIS_PASSWORD="$(openssl rand -hex 16)"
export RELAY_DATABASE_URL="relay:${MYSQL_PASSWORD}@tcp(mysql:3306)/relay?parseTime=true&loc=UTC"
docker compose --env-file relay/.env.example -f relay/compose.yaml --profile storage config --quiet
)
git diff --check
```

## Client（待 Backend 完成后展开）

- [ ] **C-AUDIT 完整 Client 审查、TODO、修复与 Domain 验收**。

## SDK（待 Client 完成后展开）

- [ ] **S-AUDIT 完整 SDK 审查、TODO、修复与 Domain 验收**。

## 最终跨域验收

- [ ] 复核所有 TODO、架构边界、文件规模报告和未提交用户改动。
- [ ] 运行 `scripts/full_test.sh` 与 Front/Backend/Client/SDK 四个覆盖率门禁。
- [ ] 检查最终 `git diff --check`、状态、提交边界、生成物和文档日期标记。
