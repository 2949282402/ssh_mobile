> 最新更新时间：2026-08-19

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
| `RELAY_HTTP_PORT` | Caddy 对外 HTTP 端口 |
| `RELAY_HTTPS_PORT` | Caddy 对外 HTTPS 端口 |
| `RELAY_CADDY_IMAGE` | Caddy 镜像及版本，通常为 `caddy:2.8-alpine` |
| `CADDY_HTTP_PORT` | Caddy 容器内部 HTTP 监听端口 |
| `CADDY_HTTPS_PORT` | Caddy 容器内部 HTTPS 监听端口 |
| `RELAY_INTERNAL_PORT` | Go Relay 容器内部监听端口 |
| `FRONT_INTERNAL_PORT` | Nginx 前端容器内部监听端口 |
| `RELAY_STORAGE_MODE` | 设备面存储后端：`memory`（默认，进程本地）或 `mysql`（注册/吊销持久化，需 Redis） |
| `RELAY_DATABASE_URL` | MySQL DSN（需含 `parseTime=true&loc=UTC`），`RELAY_STORAGE_MODE=mysql` 时必填 |
| `RELAY_REDIS_URL` | Redis URL，提供共享状态层（在线状态/防重放/管理端会话/跨实例事件），`RELAY_STORAGE_MODE=mysql` 时必填 |
| `RELAY_INSTANCE_ID` | 实例稳定标识，写入在线状态；默认每次进程随机生成 |
| `RELAY_PRESENCE_TTL` | 在线状态键有效期（设备心跳续期）；默认 `60s` |
| `RELAY_CREDENTIAL_TTL` | 设备凭据有效期，使用 Go duration 格式 |
| `RELAY_SESSION_TTL` | Relay 会话有效期，使用 Go duration 格式 |
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
| `RELAY_TRUSTED_PROXY_CIDRS` | 逗号分隔的可信代理 CIDR 列表；默认空值表示登录限流从不信任 `X-Forwarded-For`/`X-Real-IP` |
| `RELAY_ENROLLMENT_TOKEN` | 随机注册口令，至少 16 个字符 |
| `RELAY_CREDENTIAL_KEY` | Base64URL 编码的随机密钥，解码后至少 32 字节 |
| `RELAY_ADMIN_USER` | Web 管理面板管理员账号 |
| `RELAY_ADMIN_PASSWORD` | 随机管理密码，至少 12 个字符 |

Compose 会根据 `RELAY_INTERNAL_PORT` 生成 Go 服务的 `RELAY_ADDR`；直接运行 Go
程序时可以单独设置 `RELAY_ADDR`。请使用密码学安全随机数生成器分别创建密钥，
绝对不要提交真实 `.env`。

## Docker Compose 生产部署

Docker Compose 是唯一支持的部署方式。仓库提供的 Compose 配置将 Go 服务
Go 服务和前端容器保留在内部网络，由 Caddy 负责 HTTPS/WSS 证书、同源路由和
反向代理。

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

## 安全模型

- 注册只接受协议版本 1，并将凭据绑定到设备 ID 与 Ed25519 公钥。
- WebSocket 鉴权证明覆盖 HTTP 方法、路径和新的 32 字节随机数，重复随机数会被
  拒绝。
- 凭据仅在当前进程中存在匹配设备注册时有效；撤销设备会立即关闭活动连接。
- 浏览器 WebSocket 使用标准同源校验；不携带 `Origin` 的原生客户端仍受支持。
- 管理 API 必须具有 HttpOnly Cookie 会话。所有改变状态的管理员请求都会拒绝跨站
  Origin 或 Fetch Metadata；携带请求体时必须使用 `application/json`。登录按客户端
  IP+用户名限流，并返回不泄露认证状态的通用响应和有界 `Retry-After` 提示。
- 登录限流默认以直连对端 `RemoteAddr` 为准，忽略 `X-Forwarded-For`/`X-Real-IP`；
  仅当对端位于显式配置的 `RELAY_TRUSTED_PROXY_CIDRS` 边界内时才信任转发头，
  防止直连部署通过伪造头字段绕过按客户端 IP 的限流。
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
- `POST /api/admin/v1/access/enrollment-token/rotate`：需要登录的 Token 轮换
- 旧的 `/api/*` 管理路由已移除，不提供兼容别名。
- `POST /v1/devices/enroll`：协议版本 1 的设备注册
- `GET /v1/connect`：已认证的中继 WebSocket
- 不提供独立 control WebSocket 路由；设备数据使用 v1 已认证中继连接。
- `GET /healthz`：健康检查（`204`）

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

当前管理员 API 使用保存在缓存层的 HttpOnly 会话（默认内存，配置 `RELAY_REDIS_URL`
时为 Redis）。管理员会话、设备注册、撤销墓碑、传输会话、每个设备的待发送数据以及登录
限流条目都受上述 `RELAY_MAX_*` 配置限制。撤销墓碑还具备凭据过期感知：墓碑只在被撤销
设备的当前凭据仍可能被出示的时段内保留；当有界内存存储被仍然有效的墓碑占满时，新的
撤销请求会 fail-closed 拒绝，而不是淘汰旧的墓碑。`memory` 模式下所有状态在进程重启时
清空；`mysql` 模式下设备注册与撤销墓碑持久化。配置中的注册口令始终是进程配置值。

Go HTTP 服务启用了请求读取超时、响应写入超时、空闲超时和请求头大小上限。收到
终止信号后先执行 HTTP graceful shutdown（最长 15s），再关闭内存 Hub 并等待 peer
与清理 goroutine 收敛，Hub 关闭受 5s 预算约束。Compose 的 relay 服务设置了
`stop_grace_period: 30s`，大于完整的 20s 关停预算，避免 Docker 在关停流程中途
SIGKILL 进程。

服务会拒绝不支持的协议版本，不提供 v1 兼容降级、`/v1/control` 路由或
Dart 侧 Relay 数据面。

## WebSocket 协议 v1

- 鉴权并加入 Hub 后，服务端发送
  `{"type":"ready","protocol_version":1,"device_id":"..."}`；客户端只有校验该帧
  后才能报告连接成功。
- `heartbeat` 对应 `heartbeat_ack`。文件控制类型固定为 `offer`、`accept`、
  `resume`、`complete`、`complete_ack` 和 `cancel`。
- `crypto_handshake` 是 Session Noise XX 应用层 E2EE 的有界 opaque 控制类型；
  Relay 只校验路由信封并转发，不解析 Noise payload，也不接触 Session key。
- 服务端丢弃客户端声明的身份字段，并在每个转发的文件控制帧中写入已经鉴权的
  `sender_id`。
- 32 位小写十六进制 `session_id` 标识一个内存传输会话。只有发送端可以
  offer、发送二进制块和 complete；只有接收端可以 accept、resume 和确认完成；
  任一端均可 cancel。
- 二进制帧使用 25 字节头：1 字节类型（`0x10`）、16 字节会话 ID、8 字节无符号
  大端序号，之后是服务端不可见的密文。
- 字节发送完毕不代表成功；只有接收端校验并返回 `complete_ack` 后，发送端才能
  报告成功。

## 验证

```sh
go fmt ./...
go test ./...
go test -race ./...
go vet ./...
go run golang.org/x/vuln/cmd/govulncheck@v1.6.0 ./...
```

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
