> 最新更新时间：2026-08-27

# ADR-031：Relay 设备签名证明时效性

## Status

Superseded for Relay Bootstrap by Relay Bootstrap V2 (2026-08-26/27)：
- 证明时效性机制与防重放规则仍然有效并完全保留。
- 刷新端点与 Transcript 路径已升级为 `POST /v2/devices/refresh`，完整契约见 [RELAY_BOOTSTRAP_V2_CONTRACT.md](../../protocol/RELAY_BOOTSTRAP_V2_CONTRACT.md)。
- 历史 `/v1/devices/*` 路径已退出运行时代码。

## 背景

`POST /v1/devices/refresh` 与 v2 Control/RelayData WebSocket upgrade 原先只
签名方法、路径与随机 nonce。nonce 在 Cache 正常时可防止同一共享状态中的
重放，但已签名请求没有自身失效时间；一旦 nonce 状态丢失或过期，历史证明
可在任意久以后再次被提交。凭据续签和新 socket 准入都是安全边界，必须同时
绑定设备密钥、请求内容、短时效窗口和由 Cache owner 承担的原子防重放写入。

## 决策

- refresh JSON 请求固定为
  `{device_id, public_key, timestamp, nonce, signature}`。`timestamp` 必填，
  类型为 Unix 秒的有符号 64 位整数；缺失或非正数时返回 HTTP 400 /
  `invalidArgument`。
- `GET /v2/control` 与 `GET /v2/relay/{reservation_id}` 必须携带
  `X-Relay-Timestamp`、`X-Relay-Nonce` 与 `X-Relay-Signature`。时间戳必须是
  正整数 Unix 秒的规范十进制文本；缺失、非法、非规范、过时或超前时均返回
  HTTP 401 / `authenticationFailed`，不区分具体原因。
- Ed25519 签名 transcript（V2）：
  `POST\n/v2/devices/refresh\n<timestamp>\n<nonce>`，末尾没有换行。
  v2 WebSocket transcript 是
  `GET\n<path>\n<timestamp>\n<nonce>`，其中 `<path>` 是实际 Control 或
  RelayData 路径；同样没有末尾换行。时间戳按规范十进制整数文本编码。
- Relay 用当前 Unix 秒校验时间戳；`now - 300 <= timestamp <= now + 300`
  的上下边界均允许。过时或超前证明返回 HTTP 401 /
  `authenticationFailed`，不泄露设备是否已注册。
- 任一设备证明通过签名与时效性校验后，nonce 必须在 Cache 中原子消费，
  绝对失效时间为
  `time.Unix(timestamp, 0).Add(300 * time.Second).Add(time.Second)`。额外
  1 秒保证下边界请求在秒精度时钟下仍能写入。
- Cache 消费失败必须 fail closed：refresh 返回 HTTP 503 / `relayError` 与
  `retryWithBackoff` 且不签发凭据；WebSocket upgrade 返回 HTTP 401 /
  `authenticationFailed` 且不升级。已消费 nonce 也返回 HTTP 401 /
  `authenticationFailed`。
- 同一设备与同一公钥的重复 enrollment 可刷新凭据，但不得清除已消费的
  refresh 或 WebSocket 证明 nonce；否则同一已签名请求会在时效窗口内恢复
  可用。
- 这是开发期安全契约的硬切换。Relay 不接受任何旧 transcript，Dart SDK 不
  序列化无时间戳 refresh，Rust 的 Control 与 RelayData 共享构造器必须同步
  写入并签名时间戳；不提供 legacy fallback。

`/v1/devices/refresh` 中的 `v1` 是 Bootstrap HTTP API 版本，不是已退役的
transport v1 数据面回退。

## 后果

被捕获的 refresh 或 WebSocket upgrade 最多只在五分钟时钟偏差内有效，
并且仍只能消费一次。Client 与 Relay 需要基本正常的系统时钟；时钟偏差
超过窗口时会以认证失败显式暴露，而不是降级到不受限制的续签或 socket
准入。Redis/Cache 故障期间无法 refresh 或建立新 v2 socket，但不会扩大为
重放窗口。

## 验证

- Relay 组件测试：缺失/非正数时间戳、±300 秒包含边界、±301 秒拒绝、
  旧 transcript 拒绝、签名时间绑定的 nonce 失效时间、重放、同密钥重复
  enrollment 不重开已消费请求，以及 Cache 503。
- Relay v2 组件测试：Control 与 RelayData 缺失/非法/过期时间戳统一返回 401，
  旧三段 transcript 与末尾换行拒绝，nonce 失效时间绑定签名时间戳，Cache
  故障拒绝 upgrade。
- `network_sdk` 契约测试：`timestamp` 必填并以 JSON 整数序列化，零值在
  发起 I/O 前失败。
- LAN Share 独立测试：签名覆盖时间戳与 nonce，并证明旧 transcript
  不能验证同一签名。
- 真实 Dart/Rust 客户端—Relay E2E 按新请求形状运行，Dart 还验证过时证明
  返回类型化认证失败。
- Rust `network-relay` 独立测试验证 Control/RelayData 请求均携带规范 Unix 秒
  header，且签名精确覆盖方法、实际路径、时间戳和 nonce。
