最新更新时间：2026-08-12

# Network Fault Matrix

本矩阵是 SSH Mobile 网络 SDK 下一阶段 Step 9 的固定验收入口。每次网络核心、
Relay、Native Realtime、Delivery 或文件 Resume 变更后，按同一场景编号记录证据，
不得只以“连接恢复”判定成功。

## 统一通过条件

每个场景都必须记录：

`SessionId`、当前 `Route`、Delivery 终态、文件 offset（如适用）、应用命令执行
次数、恢复耗时、RTT/loss、进程内存和 Runtime task 数量。

必须同时满足：

- 断网重连后，同一个应用命令至多执行一次；重放只允许产生安全的协议层重 ACK；
- 没有业务 ACK 的 queue acceptance、transport ACK 或 `complete` 事件不能被报告为
  应用成功；
- Route 变化不改变逻辑 `SessionId`、TransferId、Manifest Hash、File Hash 或
  checkpoint offset；
- stop/dispose 返回后，Runtime supervisor、session group、Relay worker 和
  Realtime adapter subscription 均为零；
- 失败证据保留稳定错误码，不记录密码、私钥、Token、SDP 或 ICE secret。

## 固定场景

| ID | 场景与故障注入 | 自动化证据 / 命令 | 必须观察的结果 | 当前状态 |
| --- | --- | --- | --- | --- |
| A | LAN Direct；两端在同一局域网，优先 native QUIC/WebRTC direct | `cargo test -p network-webrtc --locked -- two_local_drivers_exchange_data_channel_payloads`；`cargo test -p network-core --locked --lib` | direct Route、SessionId 不变、DataChannel/Delivery 一次执行、task=0 after stop | CI/native loopback 已覆盖；真实双设备 LAN 仍需设备记录 |
| B | WAN P2P；公网/受限 NAT 下候选交换和 authenticated direct punch | `cargo test -p network-nat --locked`；`cargo test -p network-core --locked --lib direct_wins_when_relay_is_still_starting` | direct nomination、RTT/loss 采样、旧 candidate 不复活、无重复应用执行 | native candidate/QUIC flow 已覆盖；真实公网双设备需设备记录 |
| C | Relay fallback；禁止/失败 direct，使用 WSS Relay | 启动 Relay Compose；`go run ./cmd/relay_smoke -scenario functional -base http://localhost:18080`；TURN：`cargo test -p network-webrtc --locked -- --ignored relay_only_drivers_exchange_data_channel_payloads` | Relay Route、opaque control、业务 ACK 与 queue acceptance 分离、文件/消息 exactly-once | Docker Relay + coturn 已通过 |
| D | Relay → Direct；Relay 保活期间 direct probe 成功并稳定升级 | `cargo test -p network-core --locked --lib relay_route_can_be_promoted_atomically_after_direct_connection_is_ready` | SessionId/Delivery state 保留，stable window 后仅一次 route swap，迁移后恢复/Resume 一次 | native route migration 已通过；真实双设备需设备记录 |
| E | Direct → Relay；direct socket 断开，回落 Relay | `cargo test -p network-core --locked --lib transient_disconnect_keeps_session_id_for_reconnect`；Relay `recover` smoke | SessionId 不变，旧 direct ACK 不误判成功，Relay 重放不重复执行，offset 不回退 | native recovery/Relay harness 已覆盖 |
| F | Wi-Fi disconnect/reconnect；注入 Caddy/链路断开后恢复 | `go run ./cmd/relay_smoke -scenario recover -base http://localhost:18080 -trigger <trigger>`；另起 `docker compose restart caddy` | `NETWORK_RECOVERY_PASS`、稳定 TransferId/offset、recovery time、task count、duplicate count | 本地 Docker fault 已通过；真实 Wi-Fi 需设备记录 |
| G | Wi-Fi → 4G/5G；系统网络接口切换 | Android/iOS physical-device runbook（见下文） | SessionId/Route migration、RTT/loss、后台限制、内存；不能依赖旧 socket token | 需要真实 Android/iOS 设备，未在 Linux CI 伪造 |
| H | Relay restart；Relay 内存状态清空后重新 enrollment | `go run ./cmd/relay_smoke -scenario restart -base http://localhost:18080 -trigger <trigger>`；另起 `docker compose restart relay` | 旧 credential 被拒绝、重新 enrollment、新 socket token、同一 TransferId/offset、无重复完成 | `RESTART_RECOVERY_PASS` harness 已覆盖 |
| I | App background/foreground；挂起/恢复 App | Android/iOS physical-device runbook（见下文） | adapter/session 生命周期、后台策略、恢复时间、task/订阅无泄漏；前台恢复不重复执行命令 | 需要真实 Android/iOS 设备，未在 Linux CI 伪造 |
| J | 1GB+ file resume；在 checkpoint 后断网并继续传输 | `cargo test -p network-transfer -p network-core --locked`；设备上用 1 GiB+ fixture 重复 F/G | offset 单调、Manifest/File Hash 相同、最终 exactly-once、内存不随文件大小线性增长 | native checkpoint/resume 已通过；1 GiB+ physical transfer 需设备记录 |

## Docker Relay 故障运行约定

从 `relay/` 启动 Compose，然后在第二个终端运行 harness。`<trigger>` 是一个仅
用于同步故障窗口的临时文件：

```powershell
$trigger = Join-Path $env:TEMP 'ssh-mobile-relay-fault.trigger'
go run ./cmd/relay_smoke -scenario recover -base http://localhost:18080 -trigger $trigger
New-Item -ItemType File -Path $trigger -Force | Out-Null
docker compose --env-file .env restart caddy
```

Relay 进程重启使用相同命令，将 `recover` 改为 `restart` 并重启 `relay`。成功标志
必须是 harness 输出的 `NETWORK_RECOVERY_PASS` 或 `RESTART_RECOVERY_PASS`，不能用
HTTP 200 或 WebSocket 重连本身替代。

## 设备场景记录格式

真实设备运行 G/I/J 时，附上脱敏后的如下记录：

```text
scenario: G
device_a/device_b: <stable non-secret labels>
session_id: <redacted stable id>
route_before/after: <route>
delivery_result: <completed|failed|paused>
file_offset_before/after: <bytes or n/a>
application_execution_count: <integer>
recovery_ms: <integer>
rtt_ms/loss_pct: <numbers>
peak_memory_mb: <integer>
runtime_tasks_before/after: <integer>/<integer>
evidence: <screen recording or test log path>
```

设备证据不得包含凭据、Token、私钥、原始 SDP/ICE payload 或文件正文。

## Source-level guardrails

固定矩阵的代码断言位于：

- `native/network_core/crates/network-core/src/tests.rs`：Delivery duplicate、
  application ACK、RecoveryEpoch、SessionId 与 direct path metrics；
- `native/network_core/crates/network-core/src/delivery.rs`：
  `DuplicateInFlight`/`DuplicateProcessed` 和 ACK gate；
- `native/network_core/crates/network-transfer/src/{manager,receiver}.rs`：
  checkpoint/offset、Manifest/File Hash 绑定和原子完成；
- `relay/cmd/relay_smoke/`：Relay functional、Caddy recovery 和 Relay restart；
- `packages/infrastructure/network_sdk/`：Feature-facing RealtimeSession lifecycle；
- `packages/infrastructure/network_transport/`：Runtime-owned gateway 和 task/handle
  生命周期。

任何新增场景必须先加入本表并定义可重复的故障注入与通过字符串，再修改实现。
