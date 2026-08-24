> 最新更新时间：2026-08-24

# SSH Mobile 控制与中继服务器

<p align="center">
  <a href="./README.md">English</a> | <strong>简体中文</strong>
</p>

该 Go 服务提供 SSH Mobile 的设备控制平面和 WebSocket 中继。默认是纯内存模式：
不依赖外部存储，进程重启会断开全部连接，客户端必须重新注册。当配置
`RELAY_STORAGE_MODE=mysql`（需同时配置 `RELAY_REDIS_URL`）时，设备注册与吊销可跨
重启持久化，并启用共享的在线状态/防重放/管理端会话/事件层以支撑多实例设计。
独立的 React + Vite + TypeScript 管理端位于 `../front/`，由 Compose 的 `front`
服务提供静态文件；Relay 不再嵌入或提供管理端页面。它不持久化传输数据帧或文件名，
也绝不读取设备私钥或凭据明文。

## `.env` 配置

Compose 部署的所有参数都来自 `relay/.env`。缺少必填密钥或密钥强度不足时，
服务会拒绝启动；Compose 也要求端口、限制、时长和镜像配置全部显式写入该文件：

| 环境变量 | 要求 |
|---|---|
| `RELAY_PUBLIC_DOMAIN` | 公网 DNS 名称；本地冒烟测试可填写显式 `http://` 地址 |
| `RELAY_PUBLIC_URL` | 写入 `RelayReserveResponse.relay_data_endpoint` 的公开 Relay origin；HTTPS 发布为 WSS，显式 WSS 保持不变，HTTP/WS 仅允许回环集成测试 |
| `RELAY_HTTP_PORT` | Caddy 对外 HTTP 端口 |
| `RELAY_HTTPS_PORT` | Caddy 对外 HTTPS 端口 |
| `RELAY_CADDY_IMAGE` | Caddy 镜像及版本，通常为 `caddy:2.8-alpine` |
| `CADDY_HTTP_PORT` | Caddy 容器内部 HTTP 监听端口 |
| `CADDY_HTTPS_PORT` | Caddy 容器内部 HTTPS 监听端口 |
| `RELAY_INTERNAL_PORT` | Go Relay 容器内部监听端口 |
| `FRONT_INTERNAL_PORT` | Nginx 前端容器内部监听端口 |
| `RELAY_STORAGE_MODE` | 设备面存储后端：`memory`（默认，进程本地）或 `mysql`（注册/吊销持久化，需 Redis） |
| `RELAY_DATABASE_URL` | MySQL DSN（必须启用 `parseTime=true` 并使用 UTC location；规范形式含 `loc=UTC`），`RELAY_STORAGE_MODE=mysql` 时必填 |
| `RELAY_REDIS_URL` | Redis URL，提供共享状态层（在线状态/防重放/管理端会话/跨实例事件），`RELAY_STORAGE_MODE=mysql` 时必填 |
| `RELAY_REDIS_PASSWORD` | 独立 Redis 密码，至少 16 个字符，`RELAY_STORAGE_MODE=mysql` 时必填 |
| `MYSQL_ROOT_PASSWORD` | 可选 Compose `storage` profile 使用的 MySQL root 密码 |
| `MYSQL_DATABASE` / `MYSQL_USER` / `MYSQL_PASSWORD` | 可选 Compose `storage` profile 使用的数据库和应用账号 |
| `RELAY_INSTANCE_ID` | 实例稳定标识，写入在线状态；默认每次进程随机生成 |
| `RELAY_PRESENCE_TTL` | 在线状态键有效期（设备心跳续期）；默认 `60s` |
| `RELAY_CREDENTIAL_TTL` | 设备凭据有效期，使用 Go duration 格式 |
| `RELAY_ADMIN_SESSION_TTL` | 管理员会话有效期，使用 Go duration 格式 |
| `RELAY_MAX_CONNECTIONS` | Relay 最大连接数，必须为正整数 |
| `RELAY_MAX_ENROLLED_DEVICES` | 内存中允许保留的最大设备注册数 |
| `RELAY_MAX_REVOKED_DEVICES` | 内存中允许保留的最大撤销墓碑数；容量满时新的撤销请求会 fail-closed |
| `RELAY_MAX_TRANSFER_SESSIONS` | 内存中允许保留的最大活动传输会话数 |
| `RELAY_MAX_PENDING_FRAMES_PER_DEVICE` | 每个设备允许排队的最大出站帧数 |
| `RELAY_MAX_PENDING_BYTES_PER_DEVICE` | 每个设备允许排队的最大出站字节数 |
| `RELAY_MAX_FRAMES_PER_SECOND_PER_DEVICE` | 每个设备每秒允许的最大入站帧数 |
| `RELAY_MAX_BYTES_PER_SECOND_PER_DEVICE` | 每个设备每秒允许的最大入站字节数 |
| `RELAY_MAX_ADMIN_SESSIONS` | 内存中允许保留的最大管理员会话数 |
| `RELAY_ADMIN_LOGIN_MAX_ATTEMPTS` | 每个 IP+用户名窗口允许的登录次数 |
| `RELAY_ADMIN_LOGIN_WINDOW` | 管理员登录限流窗口，使用 Go duration 格式 |
| `RELAY_ADMIN_LOGIN_BLOCK` | 管理员登录封禁时长，使用 Go duration 格式 |
| `RELAY_MAX_ADMIN_LOGIN_ENTRIES` | 内存中允许保留的最大 IP/用户名限流条目数 |
| `RELAY_HTTP_READ_TIMEOUT` | HTTP 请求读取超时，使用 Go duration 格式 |
| `RELAY_HTTP_WRITE_TIMEOUT` | HTTP 响应写入超时，使用 Go duration 格式 |
| `RELAY_HTTP_IDLE_TIMEOUT` | HTTP keep-alive 空闲超时，使用 Go duration 格式 |
| `RELAY_HTTP_MAX_HEADER_BYTES` | HTTP 请求头最大字节数 |
| `RELAY_TRUSTED_PROXY_CIDRS` | 逗号分隔的可信直接代理 CIDR；默认空值表示忽略客户端 IP 转发头与 `X-Forwarded-Proto` |
| `RELAY_NETWORK_SUBNET` | 可选的 Compose 隔离测试子网覆盖，默认 `172.30.0.0/24` |
| `RELAY_CADDY_IP` | 子网内 Caddy 静态地址，默认 `172.30.0.10`，必须与可信代理 CIDR 一致 |
| `RELAY_ENROLLMENT_TOKEN` | 随机注册口令，至少 16 个字符 |
| `RELAY_CREDENTIAL_KEY` | Base64URL 编码的随机密钥，解码后至少 32 字节 |
| `RELAY_ADMIN_USER` | Web 管理面板管理员账号 |
| `RELAY_ADMIN_PASSWORD` | 随机管理密码，至少 12 个字符 |

Compose 会根据 `RELAY_INTERNAL_PORT` 生成 Go 服务的 `RELAY_ADDR`；直接运行 Go
程序时可以单独设置 `RELAY_ADDR`。请使用密码学安全随机数生成器分别创建密钥，
绝对不要提交真实 `.env`。未设置的正数限制使用文档中的有限默认值；若显式设置为空、
格式错误、零或负数，配置会直接失败，不再静默改变部署边界。

`RELAY_PUBLIC_URL` 是 HTTP 边缘 origin，而不是原样使用的数据 socket scheme：
`https://relay.example` 会规范化为 `wss://relay.example`，回环测试地址
`http://127.0.0.1:<port>` 会变为 `ws://127.0.0.1:<port>`。配置允许会被规范化掉的
根路径 `/`，但会拒绝其它 path、query、fragment、内嵌凭据、非回环 HTTP/WS 和
回环 HTTPS/WSS，避免把 reservation token 发布到攻击者选择或语义含混的端点。

Redis 客户端安全边界由进程硬编码拥有，`RELAY_REDIS_URL` 查询参数不能放宽：启用
context 取消、禁用自动命令重试，dial/read/write/pool-wait 均为 2 秒，pool size 与
最大活动连接数均为 64；具体操作的调用方 deadline 仍可施加更严格的上限。

## Docker Compose 生产部署

Docker Compose 是唯一支持的部署方式。仓库提供的 Compose 配置把 Caddy/Front
放在边缘网络，把 MySQL/Redis 放在仅 Relay 可加入的内部状态网络。Redis 强制认证并
使用 `noeviction`；内存压力会拒绝状态写入并让 Relay fail-closed，而不是静默驱逐
nonce 或管理员会话安全状态。Caddy 负责 HTTPS/WSS 证书、同源路由和反向代理。

1. 将公网 DNS `A` 或 `AAAA` 记录指向主机，并开放 80/443 端口。
2. 复制 `.env.example` 为 `.env`，替换其中所有值，包括端口、运行限制、时长和
   管理员凭据：

   ```sh
   cp .env.example .env
   ```

   PowerShell：

   ```powershell
   Copy-Item .env.example .env
   ```

3. 构建、启动并持续查看部署日志：

   ```sh
   docker compose --env-file .env up --build
   ```

   `compose.yaml` 包含 `caddy`、`front` 和 `relay` 三项服务，因此这一条命令会
   持续显示三者的合并日志。

Caddy 只持久化证书状态。不要为中继容器添加数据卷，也不要把内部 Go 端口直接
暴露到公网。

Caddy 在内网终止 HTTPS/WSS 并反向代理到 Relay。仓库自带的 Compose 文件为 Caddy
容器分配了固定内网地址（`172.30.0.10`），`RELAY_TRUSTED_PROXY_CIDRS` 默认即指向
该地址，使 Relay 信任 Caddy 的转发头以按真实客户端 IP 做登录限流。若修改内网子网，
请同步更新 `RELAY_TRUSTED_PROXY_CIDRS`。如果不使用可信代理直接运行 Relay，
请将 `RELAY_TRUSTED_PROXY_CIDRS` 置空；此时转发头会被完全忽略。
同一个直接对端信任边界也约束 `X-Forwarded-Proto`：只有直接 TLS，或可信代理报告的
`https`，才能给管理员 Cookie 设置 `Secure`，并让管理端 Origin 校验使用 HTTPS
scheme；不可信对端不能伪造 scheme 来改变 Cookie 或同源判断。

## 安全模型

- 注册只接受协议版本 1，并将凭据绑定到设备 ID 与 Ed25519 公钥。
- v2 WebSocket 鉴权请求携带规范正整数 Unix 秒 `X-Relay-Timestamp` 和新的
  32 字节 nonce。Ed25519 证明精确签名
  `GET\n<path>\n<timestamp>\n<nonce>`，末尾没有换行；重复 nonce 或超出
  包含式 ±300 秒窗口的证明会被拒绝。
- 凭据必须匹配当前持久 enrollment 及其 generation；撤销设备会立即关闭活动 Control、
  RelayData 及 active data counterpart，并拒绝后续控制面与数据面准入。
- 浏览器 WebSocket 使用标准同源校验；不携带 `Origin` 的原生客户端仍受支持。
- 管理 API 必须具有 HttpOnly Cookie 会话。所有改变状态的管理员请求都会拒绝跨站
  Origin 或 Fetch Metadata；携带请求体时必须使用 `application/json`。登录按客户端
  IP+用户名限流，并返回不泄露认证状态的通用响应和有界 `Retry-After` 提示。
- 登录限流默认以直连对端 `RemoteAddr` 为准，忽略 `X-Forwarded-For`/`X-Real-IP`；
  客户端 IP 转发头和 `X-Forwarded-Proto` 仅在对端位于显式配置的
  `RELAY_TRUSTED_PROXY_CIDRS` 边界内时才受信，防止直连部署通过伪造头绕过限流，
  或伪造 HTTPS 改变管理员 Cookie/Origin 策略。
- 前端动态设备数据通过 React 文本节点渲染，不加载外部脚本或字体。
- Caddy 设置内容安全、禁止嵌入、内容类型与引用来源等限制响应头。

在默认 `memory` 模式下，设备状态完全驻留内存，因此服务重启本身就是安全边界：全部
客户端需要重新注册。在 `mysql` 模式下，设备注册与吊销会持久化，重启不再清空它们；
请把数据库凭据与持久化的注册数据视为敏感状态。

## 接口

- `GET /`：由 Caddy 转发到前端 SPA；Go Relay 不再嵌入管理端
- `POST /api/admin/v1/auth/login`：管理员登录
- `POST /api/admin/v1/auth/logout`：管理员注销
- `GET /api/admin/v1/auth/session`：当前管理员会话状态
- `GET /api/admin/v1/overview`：需要登录的运行概览
- `GET /api/admin/v1/devices`：需要登录的设备注册快照
- `POST /api/admin/v1/devices/{deviceId}/revoke`：需要登录的设备撤销
- `GET /api/admin/v1/access/enrollment-token`：需要登录的注册 Token 读取
- `POST /api/admin/v1/access/enrollment-token/rotate`：`memory` 模式下需要登录的
  进程内 Token 轮换；持久化 `mysql` 部署返回 `409`，必须统一更新所有实例的
  `RELAY_ENROLLMENT_TOKEN` 后重启
- 旧的 `/api/*` 管理路由已移除，不提供兼容别名。
- `POST /v1/devices/enroll`：协议版本 1 的设备注册
- `POST /v1/devices/refresh`：为已注册设备重新签发短期凭据，不需要注册 Token
- `GET /v2/control`：已认证的长连接控制 WebSocket
- `GET /v2/relay/{reservation_id}`：按 Reservation 隔离、只承载不透明加密数据的 WebSocket
- 不提供 `/v1/connect`；传输流量仅使用物理分离的 v2 控制面与数据面。
- `GET /healthz`：健康检查（`204`）

`POST /v1/devices/refresh` 接受
`{device_id, public_key, timestamp, nonce, signature}`，返回与注册相同的
`{credential, expires_at, server_time, protocol_version}`。`timestamp` 必填，
为有符号 64 位 Unix 秒整数。Ed25519 签名覆盖精确 transcript
`POST\n/v1/devices/refresh\n<timestamp>\n<nonce>`，末尾没有换行。
Relay 包含式接受 `server_time - 300 <= timestamp <= server_time + 300`；
缺失或非正数返回 `400`/`invalidArgument`，过时或超前返回
`401`/`authenticationFailed`。32 字节 nonce 只消费一次，并在签名时间戳加
301 秒时失效；每设备最多 128 个活跃 nonce。防重放 Cache 写入失败时
返回 `503` 与 `retry_with_backoff`，绝不签发凭据。同密钥重复 enrollment
不会清除已消费的设备证明 nonce，因此不会在时效窗口内重开 refresh 或
WebSocket 签名请求。
不提供旧 transcript
fallback；新鲜请求中的未注册 `device_id` 返回 `404`，客户端必须重新注册。

`GET /v2/control` 与 `GET /v2/relay/{reservation_id}` 都必须携带
`X-Relay-Timestamp`、`X-Relay-Nonce`、`X-Relay-Signature`。时间戳是规范的
正整数 Unix 秒十进制文本，签名精确覆盖
`GET\n<path>\n<timestamp>\n<nonce>`，末尾没有换行。Relay 包含式接受
±300 秒边界，并将 nonce 消费到签名时间戳加 301 秒。时间戳缺失、格式非法、
过时或超前，以及 nonce 重放或防重放 Cache 不可用，均返回
`401`/`authenticationFailed` 且不升级 socket。Control 与 RelayData 独立生成
证明；旧的无时间戳 transcript 没有兼容回退
（[ADR-031](../docs/adr/ADR-031-relay-refresh-proof-freshness.md)）。

设备 HTTP 失败统一使用稳定的 v1 网络错误结构，不暴露底层异常文本：

```json
{
  "code": 8,
  "message": "safe diagnostic",
  "operation": "connect_relay",
  "peer_id": "optional-device-id"
}
```

管理端 HTTP 错误使用独立的版本化结构：

```json
{
  "error": {
    "code": "unauthorized",
    "message": "Administrator authentication failed."
  }
}
```

当前管理员 API 使用保存在缓存层的 HttpOnly 会话：memory composition 使用进程内
缓存，MySQL composition 使用 Redis。管理员会话、设备注册、撤销墓碑、传输会话、
每个设备的待发送数据以及登录限流条目都受上述 `RELAY_MAX_*` 配置限制。memory 模式
的 proof nonce bucket 使用最早到期 min-heap 与固定预算惰性清理：未过期窗口跨
re-enrollment/revocation 保留，历史空设备 bucket 无需全表扫描即可收敛。撤销墓碑还具备
凭据过期感知：墓碑只在被撤销
设备的当前凭据仍可能被出示的时段内保留；当有界内存存储被仍然有效的墓碑占满时，新的
撤销请求会 fail-closed 拒绝，而不是淘汰旧的墓碑。`memory` 模式下所有状态在进程重启时
清空；`mysql` 模式下设备注册与撤销墓碑持久化。配置中的注册口令始终是进程配置值。

Go HTTP 服务启用了请求读取超时、响应写入超时、空闲超时和请求头大小上限。收到
终止信号后先执行 HTTP graceful shutdown（最长 15s），随后使用一个 10s 的 Relay
运行时总预算先并发收敛 RelayData、Control/Hub 和事件对账，再让 Cache/Storage 在同一
预算的剩余时间内并发关闭。Hub 子预算为 5s，RelayData graceful-plus-forced 子预算为
5s；RelayDataClose 先获得 2s 冲刷窗口，随后强制关闭剩余 socket。即使依赖忽略
context 取消，`Server.Close` 也不会无限阻塞。
Compose 的 `stop_grace_period: 30s` 大于完整 25s 预算，避免 Docker 在关停中途
SIGKILL；MySQL 与 Redis 启动也共用一个 15s 总 deadline。

服务会拒绝不支持的协议版本，不提供 v1 兼容降级、`/v1/control` 路由或
Dart 侧 Relay 数据面。

## Transport WebSocket

传输流量仅使用 v2。`/v2/control` 承载已认证的 protobuf `RelayFrame`，负责控制、
发现、信令和 reservation；`/v2/relay/{reservation_id}` 只承载 reservation 作用域的
`RelayDataFrame` 与不透明加密 payload。两条路由有独立 writer、准入规则和生命周期；
数据帧进入控制面或控制帧进入数据面都属于协议违规。

两条物理 WebSocket 分别执行前述带时间戳的四段证明。Rust 共用请求构造器不代表
Control 与 RelayData 共用 nonce、证明、socket、队列或 rate budget。

证明通过后，两条路由均使用一个 5s 的设备安全准入总 deadline，覆盖 per-device
stripe 等待、持久 enrollment 检查、WebSocket upgrade、不可路由 staging、第二次持久
enrollment/lease 检查与 activation。staged worker barrier 保证失败的登记后复查之前，
Ready、PairReady 和客户端流量都无法穿透；端点可路由后立即释放 stripe，长连接不会
长期阻塞 revoke 或 re-enrollment。

Relay Data 实现边界明确：`reservation.go` 拥有模型和 memory/Redis TTL 存储；
`relay_data_admission.go` 拥有 upgrade 前的 device/role/token 绑定；
`relay_data_registry.go` 拥有 one-shot role slot、配对、吊销和关停索引；
`relay_data_connection.go` 拥有 socket pump 与 Ping/Pong；
`relay_data_flow_budget.go` 独立拥有出站积压计数和入站速率窗口。pump 只借用窄化的
reservation lease 与 pair owner 接口。

## Network Protocol v2 Relay 合同

v2 控制面/数据面 wire 合同冻结在基线提交
`6ec194bb3a66a748215d3abc11d6da84bd329619`；schema 与 golden fixture 由
[`protocol/RELAY_V2_CONTRACT.md`](../protocol/RELAY_V2_CONTRACT.md) 统一维护。
v2 transport 与 Bootstrap HTTP v1 路由明确分离：

- `ConnectivityOffer` 不含 `target_device_id`。只有同一条长期 control
  connection 先成功完成 `ResolvePeerRequest`/READY 后才可接受 Offer（Resolve →
  Offer gate）；该 gate 不跨越后续 answer 或 direct probe 持锁。Offer 成功入目标
  writer queue 后还会建立独立的 30 秒有界 fallback gate，绑定 initiator connection、
  `attempt_id`、target device/connection；`RelayReserveRequest` 必须逐项匹配并一次性消费。
  attempt 与 gate 使用精确可删除的 expiry min-heap，普通 Offer 不会在 Hub 锁内扫描
  上限 65,536 条的注册表。权威 Offer 也在进入该锁前编码；锁内只重新验证两端精确
  connection owner、登记索引并非阻塞入队。
- `RealtimeSignal` 保留 `target_device_id`，但不含 `sender_device_id`。接收端只能从
  已建立的 realtime 会话绑定取得远端身份；未知绑定必须 fail closed。
- `RelayDataFrame` 只包含 `RelayDataConnect`、`RelayDataPayload`、
  `RelayDataAck`、`RelayDataClose`；没有 `RelayDataReady` protobuf 消息，也没有
  `ready` oneof 字段。
- 两个角色的 Connect 都通过后，PairReady 只发送一次 WebSocket Ping，payload 为
  `ssh-mobile-relay-paired-v1:<reservation_id>`，不是 protobuf frame。两端 writer
  queue 都接收 marker 后 registry 才提交 pair；每个端点只有在自己的 marker 实际写入
  后才能转发数据，接收端 FIFO 则保证 PairReady 排在 payload 之前。服务端 30 秒 Ping /
  15 秒 Pong 与二进制帧共用 single writer，但使用独立 marker
  `ssh-mobile-relay-keepalive-v1`，不会被误判为第二次 PairReady。
- pending 状态的同角色重试会替换旧端点；active pair 上的同角色重试会使两个旧角色
  一并失效并关闭，重试端点成为新 pending pair 的第一端，counterpart 必须重新连接后
  才会收到新的 one-shot PairReady。普通断线则终结已消费的 reservation；后续端点必须
  重新申请 reservation，不能复用旧 token。
- reservation TTL 只约束 pending admission。active data pair 在 reservation 过期和
  凭据自然过期后仍保持；显式设备吊销会在 registry forwarding lock 下原子终止
  pending、active 端点及其 counterpart，丢弃已排队业务帧，并等待已开始的 socket
  write 收敛后返回。不透明帧的 protobuf 编码和内存分配在进入该锁前完成；临界区只做
  状态复核、flow budget 预留与非阻塞入队。
- 两条物理 WebSocket 分别使用上述带时间戳的四段证明；Rust 共享请求构造器不代表
  Control 与 RelayData 共享 nonce、证明、socket、队列或 rate budget。
- DiscoveryPublish 的设备级 fan-out 预算会跨 reconnect 与同密钥 re-enrollment 保留；
  只有本地持久 revoke/delete 成功，或事件/对账读取确认持久 enrollment 已不存在时，
  才释放其有界 map slot。迟到的旧 generation 事件不能重置当前 enrollment 的预算。

运行 `bash scripts/relay_v2_contract.sh` 会在不修改工作树的情况下校验 22 个 frozen
fixture。若环境缺少 `protoc`，脚本会为 descriptor equality 明确输出 `NOT RUN`；这不代表本地
完整 descriptor gate 已通过。

## 验证

```sh
go fmt ./...
go test ./...
go test -race ./...
go vet ./...
go run golang.org/x/vuln/cmd/govulncheck@v1.6.0 ./...
```

在仓库根目录运行 `bash scripts/admin_api_contract.sh`，可将真实 Go 管理接口生成的
响应交给 Front 生产请求客户端和 Zod schema 校验。运行时 fixture 只写入私有临时目录，
凭据会被脱敏且不会提交到仓库。

### Network v2 Phase 0 合同矩阵

在仓库根目录运行提交的 Relay v2 fixture 与跨 owner 证据清单的非修改性基线检查：

```sh
bash scripts/network_v2_acceptance.sh baseline
```

strict 入口还会调用所属 Rust/Go 测试选择器，并在矩阵仍有 `characterized` 或
`gap` 时失败：

```sh
bash scripts/network_v2_acceptance.sh strict
```

基线通过不表示最终验收已完成；未关闭项保留在
`protocol/contract_tests/acceptance_matrix.json` 中。

### 真实客户端—Relay E2E

组件/合同测试、本地 Rust/内存集成测试，以及真实客户端—Go Relay 部署属于不同的证据层。
最后一层会启动独立的 Flutter/Dart 与 Rust 客户端进程，经 Caddy 访问 Go Relay，实际覆盖
`/v1` 注册/刷新、`/v2/control` 和 `/v2/relay/{reservation_id}`；真实 Android/iOS
设备网络仍需单独执行，不能由容器测试替代。

在仓库根目录使用 WSL/Linux 入口：

```sh
bash scripts/client_backend_e2e.sh smoke
bash scripts/client_backend_e2e.sh strict
bash scripts/full_test.sh --with-client-backend-smoke --no-bootstrap
```

`smoke` 覆盖注册与刷新、两个认证控制客户端、discovery/resolve/offer/answer、实时信令、
reservation 建立、opaque 数据、ACK/关闭以及 Caddy `/v2` 路由守卫，成功标记为
`CLIENT_BACKEND_SMOKE_PASS`。`strict` 额外使用短凭据 TTL 验证过期 → refresh → 重连，并
重启 Caddy 与 Relay，成功标记为 `CLIENT_BACKEND_STRICT_PASS`。

每次运行都会创建私有临时 Compose 项目、注册 Token、凭据密钥、网络子网和数据目录；退出时
通过 trap 删除容器、卷、网络和临时文件，不写入 `relay/.env`，也不会把凭据保留在仓库中。
若要复用已经运行的部署，必须同时设置 `CLIENT_BACKEND_E2E_BASE_URL` 与
`RELAY_ENROLLMENT_TOKEN`。strict 的隔离 Compose 流程还会登录管理 API 撤销在线设备，
并断言其控制面和数据面 socket 同时关闭。设置 `CLIENT_BACKEND_E2E_STORAGE=mysql` 可额外
启动 MySQL/Redis profile，验证持久化存储 wiring；带受信任测试 CA 的 HTTPS/WSS 仍属于发布
配置矩阵，外部部署可通过 `CLIENT_BACKEND_E2E_CA_FILE` 显式提供 CA。内存模式 HTTP smoke
的 Rust bootstrap 会使用该文件；Dart 与 WSS SDK 仍要求同一 CA 已安装到 WSL/Linux
系统信任库。内存模式 HTTP smoke 不宣称覆盖这些路径。

路由守卫是强约束：未认证的 `/v2/control` 与 `/v2/relay/*` 必须返回 Relay 的 JSON `401`，
绝不能返回 Front SPA 的 `text/html`；合法 WebSocket 升级则由注册后的真实 Rust SDK 客户端
实际执行。

### 存储集成测试

MySQL/Redis 集成测试（`TestMySQLStore*`、`TestRedisStore*`、
`TestMultiInstance*`）在未设置 `RELAY_TEST_MYSQL_DSN` 与 `RELAY_TEST_REDIS_URL`
时会跳过。可用一次性容器起存储并运行：

```sh
docker run -d --rm --name relay-test-mysql -p 3306:3306 \
  -e MYSQL_ROOT_PASSWORD=root -e MYSQL_DATABASE=relay \
  -e MYSQL_USER=relay -e MYSQL_PASSWORD=relay mysql:8.4
docker run -d --rm --name relay-test-redis -p 6379:6379 redis:7-alpine

RELAY_TEST_MYSQL_DSN='relay:relay@tcp(127.0.0.1:3306)/relay?parseTime=true&loc=UTC' \
RELAY_TEST_REDIS_URL='redis://127.0.0.1:6379/0' \
go test ./...
```

go-sql-driver 会自动处理 MySQL 8 默认的 `caching_sha2_password` 认证（RSA
交换），因此 DSN 无需额外认证参数。注意 `compose.yaml` 的 storage profile
只声明 `expose:` 而不发布端口，测试进程（连 `127.0.0.1`）够不到这些服务——
请用上面的 `docker run -p` 一次性起存储，或加一个带 `ports:` 的 dev compose
override。
