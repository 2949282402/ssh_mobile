最新更新时间：2026-08-31

# online-e2e

`online-e2e` 是部署后的线上联合测试模块，目标是已经运行的
`Caddy → Relay/Admin → Analytics` 服务。它不会启动本地 Compose，也不会被
日常 `full_test.sh` 或 `.github/workflows/flutter.yml` 自动调用。

## 覆盖范围

- Caddy：Front 根页、Relay `/healthz`、V2/Telemetry/Admin 路由、旧 `/v1` 与
  `/internal` 公网阻断，以及未认证的 JSON 失败边界。
- Relay Bootstrap：畸形请求、错误 token、协议版本错误、成功 enrollment、同
  身份公钥冲突、同公钥重注册、成功 refresh、refresh 签名错误、过期证明、nonce
  replay、未知设备。
- Admin：匿名 session、受保护路由、畸形/错误/成功登录、HttpOnly/Secure
  session cookie、overview、devices、enrollment-token 查询、Origin 与
  Content-Type 防护、未知设备吊销、成功吊销、重复吊销和 logout。
- Telemetry：policy、未注册/错误 proof、proof-bound enroll、重复 enroll、显式
  rotate、旧/新 secret、错误 bearer、设备绑定、空批次、成功/拒绝/重复 ACK、
  identity mismatch、body/batch 上限、overview/events/diagnostics/settings 查询。
- 真实客户端：继续调用现有 Rust/Dart live E2E，覆盖双控制面、discovery/resolve、
  connectivity offer/answer、Realtime signal、reservation、错误角色、opaque
  data、ACK、关闭传播，以及 Admin 吊销活动 control/data socket。

不可逆或会中断现有用户的操作（例如轮换生产 enrollment token、模拟登录封禁、
重启线上 Relay）不默认执行；这些分支由 Relay/Admin 单元/契约测试覆盖。线上
`online-e2e` 只执行可回收的测试设备吊销和必要的 Telemetry 写入。

## Linux/WSL 运行

命令必须显式确认，因为会创建临时设备并写入带 `online-e2e-<run-id>-` 前缀的
Telemetry 记录：

```bash
ONLINE_E2E_CONFIRM=RUN \
ONLINE_E2E_BASE_URL=https://relay.example.com \
RELAY_ENROLLMENT_TOKEN='从部署密钥读取' \
ONLINE_E2E_ADMIN_USER='管理员用户名' \
ONLINE_E2E_ADMIN_PASSWORD='从部署密钥读取' \
bash scripts/bash/e2e/online_e2e.sh full
```

可选的 `ONLINE_E2E_RUN_ID` 只允许 ASCII 字母、数字、`_`、`-`，最长 24
字符；该上限用于让带 run 前缀的 Telemetry `eventId` 保持在 64 字节契约内。

自签名测试环境另外设置 `ONLINE_E2E_CA_FILE`，供 Go/Rust HTTP 客户端加载；Dart
bootstrap 仍要求系统信任该证书。仅对明确隔离的 loopback 部署设置
`ONLINE_E2E_ALLOW_LOCAL=1`。测试结束时脚本通过 Admin API 吊销本次 run 的设备；
Telemetry 事件保留作审计证据，便于在 Events 页面按 run 前缀过滤。

## Windows 与 Android

Windows 原生 PowerShell 7 使用配对入口：

```powershell
$env:ONLINE_E2E_CONFIRM = 'RUN'
$env:ONLINE_E2E_BASE_URL = 'https://relay.example.com'
$env:RELAY_ENROLLMENT_TOKEN = '从部署密钥读取'
$env:ONLINE_E2E_ADMIN_USER = '管理员用户名'
$env:ONLINE_E2E_ADMIN_PASSWORD = '从部署密钥读取'
pwsh .\scripts\powershell\e2e\online_e2e.ps1 full
```

Windows 端命令必须在独立的 `E:\coding\ssh_mobile` checkout 中运行；WSL
checkout 与它只通过 Git 同步，不直接复制或共享文件。若确实需要从 WSL
触发 Windows 测试，只能通过 interop 调用原生 `pwsh.exe`，并把脚本、临时目录、
Flutter/Dart、Rust/MSVC、Android/Gradle、Cargo/Pub 缓存和构建输出全部指向
Windows 侧；不能把 Windows 工具链套在 WSL checkout 上。

该入口在 Windows 主机上运行真实 Dart/Rust 客户端逻辑；要把同一套场景扩展为
Windows 发布包或 Android APK 的 UI/设备测试，还需要可用的 Windows runner 或
Android emulator/ADB，并由平台驱动启动打包后的 App。当前仓库已有 Windows/Android
构建门禁，但 `relay_bootstrap_e2e_test.dart` 是 Dart integration slice，并不自动
安装 APK 或操作 UI；因此没有设备时脚本应报告环境缺口而不是伪造通过。
