> 最新更新时间：2026-08-12

# Docker Relay 联调客户端

`main.go` 是保留的 Relay v1 协议联调 harness，不属于生产 Relay 或 Flutter
客户端。它会生成临时 Ed25519 设备身份，通过 Docker 暴露的 HTTP/WSS 前置端点
执行 enrollment、签名 WebSocket 握手、在线查询、offer/accept、二进制分块和
complete/ack、Candidate Offer/Answer 以及 WebRTC Offer/Answer/ICE/Restart/Close
信令验证。

## 前置条件

从 `relay/` 目录启动 Compose：

```powershell
docker compose --env-file .env up -d --build
```

本地 `.env` 需要使用测试密钥，不要把真实凭据写入命令行日志或提交到 Git。

## 基线回环

PowerShell 中从 `relay/` 执行：

```powershell
$tokenLine = Get-Content .env | Where-Object { $_ -match '^RELAY_ENROLLMENT_TOKEN=' }
$env:RELAY_ENROLLMENT_TOKEN = $tokenLine.Substring('RELAY_ENROLLMENT_TOKEN='.Length)
go run ./cmd/relay_smoke -scenario functional -base http://localhost:18080
```

成功标志为 `FUNCTIONAL_PASS`，并且应看到两个设备的 `READY`、`LOOKUP_OK`、
Candidate/WebRTC 控制帧确认、其他控制帧确认和 `BINARY_OK`。

## 故障场景

先启动 harness；它会在 `FAULT_WINDOW_OPEN` 后等待触发文件：

```powershell
$trigger = Join-Path $env:TEMP 'ssh-mobile-relay-caddy.trigger'
go run ./cmd/relay_smoke -scenario recover -base http://localhost:18080 -trigger $trigger
```

另开一个 PowerShell 窗口执行故障注入：

```powershell
New-Item -ItemType File -Path $trigger -Force | Out-Null
docker compose --env-file .env restart caddy
```

`recover` 验证 Caddy/链路中断、客户端重连、稳定 TransferId/Manifest 的重新
Offer、接收方 offset accept、序号连续的后续分块以及 complete/ack。成功标志为
`NETWORK_RECOVERY_PASS`。

验证 Relay 进程重启及其内存状态边界：

```powershell
go run ./cmd/relay_smoke -scenario restart -base http://localhost:18080 -trigger $trigger
New-Item -ItemType File -Path $trigger -Force | Out-Null
docker compose --env-file .env restart relay
```

`restart` 应报告旧凭据被拒绝、重新 enrollment、使用同一 TransferId 重新建立
offer/accept、返回 checkpoint offset 和数据回环，成功标志为
`RESTART_RECOVERY_PASS`。Relay 进程重启会清空内存中的设备注册和传输 session，
因此客户端必须创建新的 socket session token，不能依赖旧 token 直接 `resume`。

## 注意事项

- 当前本地 Compose 配置是 `http://localhost:18080`，harness 使用对应的
  `ws://` 测试连接；生产客户端设置和 Rust `RelayClient` 只接受 HTTPS/WSS，
  要做真实 Flutter 客户端联调，需要先配置受信任的本地 TLS 证书。
- Relay 只做透明转发；应用层 ACK、去重、重传和文件断点状态属于客户端。
  harness 验证的是 Relay 不篡改帧、重新 Offer/offset 控制帧方向和 session 恢复边界。
- 延迟、丢包、乱序需要在 Docker Desktop/宿主机网络层或独立 traffic proxy
  中注入；本 harness 已覆盖代理重启和 Relay 进程重启两类可重复故障。完整 A-J 固定
  验收字段和人工设备记录格式见 `docs/NETWORK_FAULT_MATRIX.md`。
