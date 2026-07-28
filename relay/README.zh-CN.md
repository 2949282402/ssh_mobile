> 最新更新时间：2026-07-28

# SSH Mobile 控制与中继服务器

<p align="center">
  <a href="./README.md">English</a> | <strong>简体中文</strong>
</p>

本服务是面向 SSH Mobile 网络传输 / P2P NAT 穿透备用线路的内存控制平面与 WebSocket 中继服务器。它绝不持久化存储传输数据帧、文件名或原始文件内容。设备在注册后获得带签名的凭据；重启中继服务仅会断开当前活动会话，绝不会泄露任何文件内容。

## 快速启动（零配置开箱即用）

服务器无需配置任何必填环境变量即可直接运行。缺失的 Token 与 HMAC 密钥会在启动时自动生成，并在 Web 管理面板中直观显示。

```sh
cd relay
go run ./cmd/relay
```

在任意浏览器中打开 `http://localhost:8080` 即可进入 **Web 管理控制面板**，查看与复制自动生成的 `Enrollment Token`、监控活动 WebSocket 连接以及管理已注册设备。

## 独立 Docker 运行

```sh
docker build -t ssh-mobile-relay relay
docker run --rm -p 8080:8080 ssh-mobile-relay
```

如需自定义凭据，亦可通过环境变量指定：

```sh
docker run --rm -p 8080:8080 \
  -e RELAY_ENROLLMENT_TOKEN='custom-admin-token' \
  ssh-mobile-relay
```

## Docker Compose 生产部署

项目附带的 Compose 部署方案使用 Caddy 进行 HTTPS/WSS 终结，并自动申请公网 TLS 证书。

1. 为中继主机创建公网 DNS `A` 或 `AAAA` 记录，并在防火墙开放 TCP 80 端口与配置的 HTTPS 端口。保持 80 端口映射以供 Caddy 进行 ACME HTTP 域名验证；客户端使用非默认 HTTPS/WSS 端口时，可在 `.env` 中设置 `RELAY_HTTPS_PORT`。
2. 复制 `.env.example` 为 `.env` 并按需配置：
   - Linux / macOS: `cp .env.example .env`
   - Windows PowerShell: `Copy-Item .env.example .env`
3. 启动服务：

   ```sh
   docker compose --env-file .env up --build -d
   docker compose logs -f caddy relay
   ```

宿主机仅暴露 80/443 端口给 Caddy，Go 中继服务留在内部 Docker 网络中。Caddy 仅持久化证书状态。**请勿添加数据卷**：会话与中继数据帧设计上均为纯内存存储。

## `.env` 配置文件详细参数指南

### 1. 如何复制 `.env` 文件

- **Linux / macOS Bash**:
  ```bash
  cd relay
  cp .env.example .env
  ```
- **Windows PowerShell**:
  ```powershell
  cd relay
  Copy-Item .env.example .env
  ```

### 2. 环境变量参数分类指南

| 参数名称 | 修改要求 | 默认/示例值 | 详细说明 |
|---|---|---|---|
| `RELAY_PUBLIC_DOMAIN` | **必须修改** | `relay.example.com` | 服务器绑定的公网 DNS 域名。**切勿包含 `http://` 或 `https://` 前缀**。Caddy 会利用此域名向 Let's Encrypt 自动申请并续期 SSL/TLS 证书。 |
| `RELAY_ENROLLMENT_TOKEN` | **可选修改** | (自动生成) | 客户端首次注册中继时需填写的凭据口令。若保持留空，启动时会自动生成安全随机 Token，并直接在 Web 控制面板中显示；生产环境建议显式设置为你自定义的口令。 |
| `RELAY_CREDENTIAL_KEY` | **可选修改** | (自动生成) | 用于签发 HMAC 客户端凭据的主密钥。必须为 32 字节以上的 Base64URL 随机字符串。若保持留空，启动时会自动安全生成。 |
| `RELAY_HTTPS_PORT` | **可选修改** | `443` | 对外暴露的 HTTPS / WSS 端口。若宿主机的 `443` 端口已被占用，可修改为其他端口（如 `8443`）。 |
| `RELAY_HTTP_PORT` | **可选修改** | `80` | 对外暴露的 HTTP 端口。供 Caddy 进行 ACME 证书验证，通常保持 `80` 即可。 |

### 3. 注意事项与安全禁区（绝对不能改/不能做）

1. ❌ **请勿将真正的 `.env` 文件提交至 Git 仓库**：包含了你的公网域名与凭据口令，属于敏感文件（已被 `.gitignore` 包含）。
2. ❌ **请勿在中继容器挂载任何存储卷（Data Volumes）**：中继服务设计为**纯内存无状态路由**，不保存传输数据帧、文件名或历史纪录。挂载硬盘卷会破坏无痕路由安全承诺。
3. ❌ **请勿将内部 Go 服务直接暴露到外网**：Go 服务默认仅在 Docker 内部网络监听 `:8080`，必须由前端的 Caddy 统一进行 TLS/SSL 证书终结与安全防护。

## Web 管理面板与 API 接口说明

- **`GET /`**：Web 管理控制面板（包含 HTML/CSS/JS 界面，用于监控活动会话、已注册设备与安全凭据）。
- **`GET /api/stats`**：返回 JSON 遥测数据（在线设备数、活动会话数、运行时间、Go 内存占用、已注册设备列表）。
- **`POST /api/token/rotate`**：一键重新生成管理员 `Enrollment Token`。
- **`POST /api/devices/revoke`**：撤销/解绑指定注册设备并强制切断其当前活动 WebSocket 连接。
- **`POST /v1/devices/enroll`**：设备注册与凭据颁发（需携带 `EnrollmentToken`）。
- **`GET /v1/control`**：WebSocket 控制通道（处理心跳与 Peer Presence 在线广播）。
- **`GET /healthz`**：健康检查接口（返回 `HTTP 204`）。
