> 最新更新时间：2026-08-27

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
   - 不持有数据库、Redis 或设备签名凭据密钥。

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

### Admin 公开端点 (`/api/admin/v1/*`)
- `POST /api/admin/v1/auth/login` — 管理员登录（设置 HttpOnly Session Cookie）。
- `POST /api/admin/v1/auth/logout` — 管理员退出（销毁 Session）。
- `GET /api/admin/v1/auth/session` — 检查会话状态。
- `GET /api/admin/v1/overview` — 系统概览状态。
- `GET /api/admin/v1/devices` — 设备列表及在线状态。
- `POST /api/admin/v1/devices/{deviceId}/revoke` — 吊销设备。
- `GET /api/admin/v1/access/enrollment-token` — 查看注册 Token。
- `POST /api/admin/v1/access/enrollment-token/rotate` — 轮换注册 Token。

## 容器部署

使用项目根目录的 Docker Compose 部署：

```sh
# 复制环境变量配置
cp .env.example .env

# 构建并启动服务
docker compose up -d --build
```
