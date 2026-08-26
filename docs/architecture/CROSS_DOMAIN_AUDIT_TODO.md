> 最新更新时间：2026-08-25

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
bash scripts/bash/coverage/front_coverage.sh
bash scripts/bash/ci/full_test.sh --only front-quality --no-bootstrap
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
bash scripts/bash/coverage/backend_coverage.sh
bash scripts/bash/contracts/admin_api_contract.sh
bash scripts/bash/contracts/relay_v2_contract.sh
bash -n scripts/bash/coverage/backend_coverage.sh scripts/bash/contracts/admin_api_contract.sh scripts/bash/contracts/relay_v2_contract.sh
# 仅为 Compose 解析在子 shell 生成临时值；不要把这些值复用到部署环境。
(
export RELAY_PUBLIC_URL=http://127.0.0.1:18080
export RELAY_ENROLLMENT_TOKEN="$(openssl rand -hex 32)"
export RELAY_CREDENTIAL_KEY="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"
export ADMIN_USER=config-check
export ADMIN_PASSWORD="$(openssl rand -base64 24)"
docker compose --env-file relay/.env.example -f relay/compose.yaml config --quiet
export RELAY_STORAGE_MODE=mysql
export MYSQL_PASSWORD="$(openssl rand -hex 16)"
export RELAY_REDIS_PASSWORD="$(openssl rand -hex 16)"
export RELAY_DATABASE_URL="relay:${MYSQL_PASSWORD}@tcp(mysql:3306)/relay?parseTime=true&loc=UTC"
docker compose --env-file relay/.env.example -f relay/compose.yaml --profile storage config --quiet
)
git diff --check
```

## Client（已完成）

- [x] **C-01 AI 命令安全边界**：`run_command` 必须拒绝重定向、命令
  替换、换行和混合敏感路径；安全诊断改为精确命令/参数策略，不得
  在 Plan Mode 或无审批路径执行远程写入与子命令。
- [x] **C-02 MCP 安全与生命周期**：串行化 `start/stop/dispose`，阻止停用或
  退出后迟到监听；JSON-RPC 错误、活动和日志只返回稳定错误码与经统一
  策略脱敏的诊断。
- [x] **C-03 WebView SSRF 边界**：规范化 IPv4 的非标准表示，拒绝所有非
  全局可路由 IPv4/IPv6；在真正请求和每次重定向处校验 DNS 解析结果，
  防止 DNS rebinding 读取本机或内网资源。
- [x] **C-04 Playbook 并发与数据保护**：将“审批后动作未变”改为数据库
  revision CAS，并发编辑不得被执行侧覆盖；移除或迁移与加密 content 重复的
  明文 name/description。
- [x] **C-05 AI/RAG 数据与 Route 生命周期**：聊天标题不得明文复制用户
  prompt；PDF 在解压、文本、page/stream/chunk 和 embedding 前均有硬上限；AI
  生成必须在 Route/Module 释放前取消并收敛，迟到回调不得写已关闭的
  notifier、stream 或数据库。
- [x] **C-06 System Admin 不可变目标与破坏性操作**：并发 A/B 连接、Route
  销毁与迟到建连使用 generation/Lease fail-closed；所有 root 命令绑定
  connection/target/session；重启/关机 token 绑定同一快照并原子一次性消费。
- [x] **C-07 System Admin 命令与输出上限**：用户名和 shell 执行严格校验，
  密码绝不进入 shell 命令文本而通过受控 stdin/argv 输入；stdout/stderr 设
  统一硬上限，超限关闭会话并返回稳定错误。
- [x] **C-08 Connection/Host-key/凭据原子性**：Host Key 只在持久化成功后
  更新调用方对象；Connection 配置、Host Key 和安全存储凭据使用可回滚的
  staging/compensation；拒绝非 canonical ID 并使用无碰撞安全存储 key。
- [x] **C-09 SSH owner 和 Native stream 关闭屏障**：前台/后台 SSH 创建失败、
  同 session 并发建连与 shell-done 重连都必须有唯一 owner 且可等待释放；
  native stream 的迟到 open 和 send failure 必须释放局部句柄并从 registry 移除。
- [x] **C-10 SFTP 目标绑定和日志脱敏**：条目、编辑和确认任务携带创建时
  target fingerprint，同 ID 换主机后旧 UI 不得读/写/删新目标；敏感路径
  日志只保留操作类型、稳定错误码和不可逆 hash。
- [x] **C-11 Monitoring 与 Feature Module 代次**：Monitoring 每轮 start 固定
  epoch+target，stop/restart 后丢弃迟到 success/error/retry；SFTP/Terminal 初始化
  与销毁串行化，迟到初始化必须关闭局部数据库/服务，不得“复活”。
- [x] **C-12 Terminal 有界数据与 App owner**：历史加载期实时输出使用有界
  ring buffer；旧明文历史流式加密并原子替换；Terminal App 由有生命周期的
  Widget owner 等待幂等释放，cleanup 单项失败不得跳过后续 owner。
- [x] **C-13 AppRuntime/后台服务回滚**：构造失败时取消并有界等待已启动的
  initializer，迟到任务不得访问已释放 DB/logger；后台服务启动返回
  `false` 时立即释放已获取 power locks。
- [x] **C-14 LAN Share 会话、存储与配对边界**：native/WebShare 上传元数据
  必须原子消费且 pending+active 共享并发上限；桌面端导出不得把最大
  20 GiB 文件整体读入内存；远程配对复查不得在 unpair 后迟到恢复，
  HTTP client/响应有界释放；Transfer/Discovery 最终关闭必须可等待且先
  收敛 socket/server 再关闭 stream。
- [x] **C-15 架构审计报告语义**：兼容性门禁将“受批准的 App Shell adapter
  测试引用”与真正受基线约束的旧引用分开计数，避免 closed 模块显示
  `3 refs / 0 baseline` 却通过的误导输出。
- [x] **C-16 Client Domain 门禁**：通过所有受影响 package/app 的聚焦测试、
  format/analyze，架构/依赖/资源 owner/兼容性门禁，Client coverage 不低于
  80%，新手写生产文件不低于 90%；最终 Network V2 聚合覆盖率为 92.6%
  （766/827）。覆盖率门禁按测试文件隔离 Flutter 进程，再按源码行去重聚合，
  避免跨文件 runner 生命周期泄漏改变验收结果。

## SDK

- [x] **S-01 Relay 设备证明时效与转录一致性**：Dart refresh 与 Rust
  Control/Data WebSocket 必须签名时间戳、随机 nonce 和实际请求路径；本地严格拒绝
  非规范长度/编码、越界时间戳和签名路径分歧，不保留旧证明回退。
- [x] **S-02 RelayData 凭据边界**：reservation token 只允许通过
  `X-Relay-Token` 传递；URL query 中的凭据保持 fail-closed，日志、错误和连接 URL
  不携带 token。
- [x] **S-03 Dart/Rust/Go 跨进程契约**：覆盖有效、无效和过期证明，Redis 密码配置
  以及废弃 Relay 环境变量清理，确保客户端、原生 SDK 与 Relay 执行同一 ADR-031
  契约。
- [x] **S-04 SDK Domain 验收**：通过 Dart/Rust focused tests、format、analyze、
  clippy、Network v2 acceptance 与 SDK coverage；Domain 覆盖率不低于 80%，新手写
  生产文件不低于 90%。

SDK 验收证据：`network_sdk` 81 项测试和 `feature_lan_share` 全量测试通过；
`network-relay` 46 项测试、all-target clippy 与 workspace rustfmt 通过；严格跨进程
Client/Relay 验收返回 `CLIENT_BACKEND_STRICT_PASS`；Network v2 strict acceptance 通过。
SDK coverage 为 Dart aggregate 90.88%（各 package 91.87% / 90.24% / 90.41%），
Rust public SDK crates 95.68%，均高于 80% 门禁。文件规模复扫仍将
`network_http_clients.dart` 视为两个独立请求客户端及共享纯函数的无状态组合，不以物理
分文件替代逻辑解耦；冻结矩阵的事件 lane、path projection 与 same-role replacement
证据已路由到当前真实 Owner。

## 最终跨域验收

- [x] 复核所有 TODO、架构边界、文件规模报告和未提交用户改动；所有 Domain
  TODO 均已关闭，逻辑解耦报告覆盖全部大文件，用户原有未跟踪
  `packages/features/feature_webview/coverage/` 保持未修改、未纳入提交。
- [x] 运行 `scripts/bash/ci/full_test.sh --serial --no-bootstrap`：13 个 WSL 可运行门禁全部
  通过，总计 730 秒；平台专属 Windows/macOS/iOS 作业按脚本声明跳过。Front / Backend /
  Client / SDK 覆盖率分别为 96.01% / 90.4% / 92.6% / Dart 90.88% + Rust
  95.68%，全部通过 80% Domain 门禁。
- [x] 最终 `git diff --check` 与脚本语法检查通过；提交范围仅包含 Relay proof
  nonce 测试隔离、Flutter 测试 Owner/I/O 生命周期、Client coverage runner 隔离和本
  TODO 证据。无生成物进入提交，文档日期为 2026-08-24，用户的未跟踪 coverage
  目录继续保留在工作树中。
