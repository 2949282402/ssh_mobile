> 最新更新时间：2026-08-30

# SSH Mobile 控制、Relay 与 Admin 后端服务

<p align="center">
  <a href="./README.md">English</a> | <strong>简体中文</strong>
</p>

本模块包含 SSH Mobile 的两个独立 Go 服务：

1. **Relay 后端** (`cmd/relay`、`internal/relay`):
   - 处理设备 Bootstrap（纯 V2 协议：`POST /v2/devices/enroll`、`POST /v2/devices/refresh`）。
   - 管理长连接 Protobuf V2 控制面（`GET /v2/control`）与 reservation 作用域的不透明数据面（`GET /v2/relay/{reservation_id}`）。
   - 独占设备生命周期、凭据签发与校验、在线状态 Presence 以及 MySQL/Redis 持久化。
   - 暴露受 `RELAY_INTERNAL_TOKEN` 保护的内部管理接口（`/internal/v2/*`）。

2. **Admin 后端** (`cmd/admin`、`internal/admin`):
   - 处理管理员登录认证、内存 Session 会话存储以及登录防爆破限流。
   - 对外提供 `front/` 控制台消费的公开 Admin REST API（`/api/admin/v1/*`）。
   - 通过 `RelayManagementClient` 在私有网络中调用 Relay 的内部管理接口（`/internal/v2/*`）。
   - 不持有 Relay 设备数据库、在线状态 Redis 或设备签名凭据密钥。
      启用 Telemetry 时，Admin 进程通过 `internal/telemetry` 使用隔离的
      Analytics MySQL 与可选 Redis 热缓存；这些不是 Relay 业务状态。

React + Vite + TypeScript 前端控制台位于 `../front/`，在 Caddy 背后由 `front` 容器提供静态资源。

## 接口列表

### Relay 公开端点
- `GET /healthz` — 服务存活探测（返回 204 No Content）。
- `POST /v2/devices/enroll` — 设备注册（要求 `protocol_version=2`）。
- `POST /v2/devices/refresh` — 设备凭据刷新（要求 Ed25519 签名绑定 V2 transcript）。
- `GET /v2/control` — 长连接 WebSocket 控制面（`RelayFrame` protobuf）。
- `GET /v2/relay/{reservation_id}` — Reservation 作用域 WebSocket 数据面（`RelayDataFrame` protobuf）。

### Relay 内部管理端点 (`Authorization: Bearer <RELAY_INTERNAL_TOKEN>`)
- `GET /internal/v2/status` — 运行时快照（goroutines、内存、活跃传输、设备数）。
- `GET /internal/v2/devices` — 已注册设备列表与在线状态。
- `POST /internal/v2/devices/{deviceId}/revoke` — 权威吊销设备（断开 socket、写入墓碑、广播事件）。
- `GET /internal/v2/access/enrollment-token` — 查询当前有效注册 Token。
- `POST /internal/v2/access/enrollment-token/rotate` — 轮换注册 Token（内存模式）。
- `POST /internal/v2/telemetry/attest` — 为 Admin Telemetry 校验既有 Relay 设备证明；不返回密钥、不写入 Analytics。

### Admin 公开端点 (`/api/admin/v1/*`)
- `POST /api/admin/v1/auth/login` — 管理员登录（设置 HttpOnly Session Cookie）。
- `POST /api/admin/v1/auth/logout` — 管理员退出（销毁 Session）。
- `GET /api/admin/v1/auth/session` — 检查会话状态。
- `GET /api/admin/v1/overview` — 系统概览状态。
- `GET /api/admin/v1/devices` — 设备列表及在线状态。
- `POST /api/admin/v1/devices/{deviceId}/revoke` — 吊销设备。
- `GET /api/admin/v1/access/enrollment-token` — 查看注册 Token。
- `POST /api/admin/v1/access/enrollment-token/rotate` — 轮换注册 Token。
- `GET /api/admin/v1/telemetry/overview` — 埋点监控大盘指标与错误分类分布。
- `GET /api/admin/v1/telemetry/events` — 多维过滤埋点事件浏览器。
- `GET /api/admin/v1/telemetry/diagnostics` — 基于 Redis 热缓存、失败时回退 MySQL 的近实时诊断数据流。
- `GET /api/admin/v1/telemetry/settings` — 获取当前动态策略与保留策略。
- `PUT /api/admin/v1/telemetry/settings` — 更新动态上报策略与数据保留配置。

### 埋点采集公开端点 (`/api/v1/telemetry/*`)
- `POST /api/v1/telemetry/enroll` — 设备使用既有 Relay 身份证明并一次性获取 Telemetry 密钥；服务端只存储哈希。
- `POST /api/v1/telemetry/enroll/rotate` — 使用新的 Relay 证明显式轮换 Telemetry 密钥。
- `POST /api/v1/telemetry/auth` — 客户端设备认证与临时 Token 签发。
- `GET /api/v1/telemetry/policy` — 动态获取最新上报策略。
- `POST /api/v1/telemetry/ingest` — 批量上报事件/诊断日志（HMAC 验签与持久幂等收据）。

Telemetry 上报针对 2C4G 部署做了有界保护：请求体上限为 1 MiB，单批最多
100 条记录，默认最多并发 4 个数据库写入（配置值会限制在 4–8）。已通过
Bearer Token 验证的设备使用带 TTL 清理的有界令牌桶，限流键取认证 Token
绑定的设备身份，不取请求体中的设备字段。写入槽位耗尽或设备突发额度耗尽时
返回 `429 Too Many Requests`、有界整数 `Retry-After` 以及结构化的
`INGEST_OVERLOADED` 或 `INGEST_RATE_LIMITED` 错误；请求体/批次超限在持久化
前返回 `413 Request Entity Too Large`。可通过 `TELEMETRY_MAX_*`、
`TELEMETRY_RATE_LIMIT_*` 与 `TELEMETRY_RETRY_AFTER_SECONDS` 在硬上限内调整，
详见 `.env.example`。

## 容器部署

使用项目根目录的 Docker Compose 部署：

```sh
# 命令从仓库根目录执行。
# 复制环境变量配置
cp .env.example .env
# 启动前替换所有 replace-with-* 占位符，尤其要让
# TELEMETRY_MYSQL_DSN/TELEMETRY_REDIS_URL 与 Analytics 容器密码一致。

# 构建并启动服务及持久化 Analytics 存储
docker compose --env-file .env --profile storage up -d --build
```

生产配置要求 `TELEMETRY_MYSQL_DSN`、`TELEMETRY_REDIS_URL`、
`TELEMETRY_AUTH_SECRET`、`ANALYTICS_MYSQL_PASSWORD`、
`ANALYTICS_MYSQL_ROOT_PASSWORD` 和 `ANALYTICS_REDIS_PASSWORD` 六项值；
Compose 缺少任一项会快速失败，示例文件只提供占位符，不包含可预测密码。
