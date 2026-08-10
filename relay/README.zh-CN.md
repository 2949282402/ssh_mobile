> 最新更新时间：2026-08-11

# SSH Mobile 控制与中继服务器

<p align="center">
  <a href="./README.md">English</a> | <strong>简体中文</strong>
</p>

该 Go 服务提供 SSH Mobile 的内存设备控制平面和 WebSocket 中继。独立的
React + Vite + TypeScript 管理端位于 `../front/`，由 Compose 的 `front` 服务
提供静态文件；Relay 不再嵌入或提供管理端页面。它不持久化传输数据帧、文件名、
凭据或设备状态。进程重启会断开全部连接，客户端必须重新注册。

## 必填配置

缺少必填密钥或密钥强度不足时，服务会拒绝启动：

| 环境变量 | 要求 |
|---|---|
| `RELAY_ENROLLMENT_TOKEN` | 随机注册口令，至少 16 个字符 |
| `RELAY_CREDENTIAL_KEY` | Base64URL 编码的随机密钥，解码后至少 32 字节 |
| `RELAY_ADMIN_USER` | Web 管理面板管理员账号 |
| `RELAY_ADMIN_PASSWORD` | 随机管理密码，至少 12 个字符 |

可选项包括 `RELAY_ADDR`（默认 `:8080`）、`RELAY_CREDENTIAL_TTL`
（默认 `24h`）、`RELAY_SESSION_TTL`（默认 `15m`）和
`RELAY_MAX_CONNECTIONS`（默认 `2048`）。

请使用密码学安全随机数生成器分别创建这些密钥，绝对不要提交真实 `.env`。

## Docker Compose 生产部署

Docker Compose 是唯一支持的部署方式。仓库提供的 Compose 配置将 Go 服务
保留 Go 服务和前端容器在内部网络，由 Caddy 负责 HTTPS/WSS 证书、同源路由和
反向代理。

1. 将公网 DNS `A` 或 `AAAA` 记录指向主机，并开放 80/443 端口。
2. 复制 `.env.example` 为 `.env`，替换其中每个占位值：

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

## 安全模型

- 注册只接受协议版本 1，并将凭据绑定到设备 ID 与 Ed25519 公钥。
- WebSocket 鉴权证明覆盖 HTTP 方法、路径和新的 32 字节随机数，重复随机数会被
  拒绝。
- 凭据仅在当前进程中存在匹配设备注册时有效；撤销设备会立即关闭活动连接。
- 浏览器 WebSocket 使用标准同源校验；不携带 `Origin` 的原生客户端仍受支持。
- 管理 API 必须具有 HttpOnly Cookie 会话，前端动态设备数据通过 React 文本节点
  渲染，不加载外部脚本或字体。
- Caddy 设置内容安全、禁止嵌入、内容类型与引用来源等限制响应头。

设备状态完全驻留内存，因此服务重启本身就是安全边界：全部客户端需要重新注册。

## 接口

- `GET /`：由 Caddy 转发到前端 SPA；Go Relay 不再嵌入管理端
- `POST /api/login`、`POST /api/logout`、`GET /api/auth-status`：面板鉴权
- `GET /api/stats`：需要登录的内存遥测
- `GET /api/token`：需要登录的当前注册 Token 读取
- `POST /api/token/rotate`：需要登录的注册 Token 轮换
- `POST /api/devices/revoke`：需要登录的设备撤销
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

服务会拒绝不支持的协议版本，不提供 v1 兼容降级、`/v1/control` 路由或
Dart 侧 Relay 数据面。

## WebSocket 协议 v1

- 鉴权并加入 Hub 后，服务端发送
  `{"type":"ready","protocol_version":1,"device_id":"..."}`；客户端只有校验该帧
  后才能报告连接成功。
- `heartbeat` 对应 `heartbeat_ack`。文件控制类型固定为 `offer`、`accept`、
  `resume`、`complete`、`complete_ack` 和 `cancel`。
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
go vet ./...
go test ./...
```
