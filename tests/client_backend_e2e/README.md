最新更新时间：2026-08-31

# 客户端—Relay 后端 E2E

该目录是客户端真实访问 Go Relay 的测试资产入口。测试由
`scripts/bash/e2e/client_backend_e2e.sh` 编排：默认在 WSL/Linux 中创建临时 Compose
项目、临时环境文件和临时凭据，运行结束后通过 `trap` 删除容器、卷和临时目录。

临时 Compose 环境会为 Relay MySQL/Redis、Analytics MySQL/Redis 和 telemetry auth
生成独立随机凭据，并把 DSN/URL 与容器密码保持一致；因此新增的生产配置
fail-fast 检查不会让 memory 或 mysql 矩阵通过缺省密码运行。凭据仍只存在于
临时目录，脚本退出时删除。

测试不会写入 `relay/.env`，不会把设备私钥、enrollment token 或 credential
保存到仓库。需要复用外部测试部署时，同时设置
`CLIENT_BACKEND_E2E_BASE_URL` 与 `RELAY_ENROLLMENT_TOKEN`，脚本会跳过 Compose
启动但仍运行 Caddy 路由、Dart bootstrap 和 Rust 控制/数据面验证。

级别：

- `smoke`：每日快速验证 enrollment/refresh、双客户端 v2 控制面、reservation
  数据面、ACK/关闭和 `/v2` Caddy 路由。
- `strict`：短 TTL 凭据过期→刷新→重连，并在测试后重启 Caddy/Relay 验证路由与
  健康检查恢复；默认隔离 Compose 还会启动 Relay MySQL/Redis，并通过管理 API
  撤销设备，断言两条连接都关闭。设置 `CLIENT_BACKEND_E2E_STORAGE=mysql`
  会选择 MySQL/Redis 持久化路径；Analytics MySQL/Redis 仍由 `storage` profile
  启动。HTTPS/WSS 仍由发布环境的受信任 CA
  矩阵显式启用，不能在未配置依赖时静默伪装成通过。

存储 profile 示例：

```sh
CLIENT_BACKEND_E2E_STORAGE=mysql bash scripts/bash/e2e/client_backend_e2e.sh strict
```

复用外部部署时，strict 吊销场景还需要同时设置
`CLIENT_BACKEND_E2E_ADMIN_USER` 与 `CLIENT_BACKEND_E2E_ADMIN_PASSWORD`；仅有设备
Token 时脚本会跳过管理吊销并明确输出原因。

HTTPS/WSS 外部验证可同时设置 `CLIENT_BACKEND_E2E_CA_FILE`。Rust bootstrap
HTTP 会通过该 CA 文件调用 curl；Dart 与控制面/数据面 SDK 仍要求该 CA 已安装到
WSL/Linux 的系统信任库。否则脚本会失败，而不会跳过 TLS 验证。本地 Compose 默认
仍使用 HTTP loopback，避免把自签名证书误当成受信任发布证据。

组件契约测试和本地 Rust 内存集成测试仍由各自门禁负责；本目录只承载跨进程真实
客户端—Go Relay 测试。`AuthenticatedApiClient` 的遗留 `/v1/peers`/`connect`
接口没有对应 Relay v2 端点，保留契约测试并作为后续兼容性清理项。

Rust E2E target 在普通 `cargo test --workspace` 中保持 ignored，避免没有临时
Compose 环境时误运行；统一入口会显式使用 `--ignored` 启动它。

部署后的线上联合测试不使用本目录的本地 Compose 生命周期；请使用独立的
[`online-e2e`](../online_e2e/README.md) 模块。该模块要求显式目标、管理员凭据和
确认标记，运行后只吊销带本次 run 前缀的测试设备。
