最新更新时间：2026-08-08

# feature_lan_share

LAN Quick Share 的独立 Feature Package，负责设备发现、配对、HTTPS/WebSocket
传输、Web Share、传输历史和配对元数据。

## 边界

- 只通过 `app_core`、`app_ui`、`network_transport` 及本包定义的 Port 使用
  App 设置、日志、数据保护、网络和 Relay 能力。
- 不依赖 SSH、其他 Feature 的实现或 App 的 `/src/` 路径。
- `LanShareModule` 独占 `lan_share.db`、历史 Repository 和接收器资源；App
  Shell 只注入 App Scope 资源并负责配置是否激活接收器。
- 数据库只保存传输历史和不含密钥、Token 的配对元数据；密钥、PIN、Bearer
  Token 和 Relay 凭据继续由安全存储边界管理。

旧 `apps/ssh_mobile_full/lib/features/lan_share/**` 与
`apps/ssh_mobile_full/lib/services/lan_share/**` 在本迁移阶段保留为兼容面，
不会被批量删除。
