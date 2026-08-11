最新更新时间：2026-08-11

# network_transport

`network_transport` 是 App Scope 唯一网络运行时的稳定 Facade。当前版本只包装
`ssh_mobile_network_native` 已存在的原生运行时，不在本 Step 新增 TCP、UDP、QUIC
或 WebRTC 协议实现。

## 边界

- `NetworkRuntime` 由 AppRuntime 创建和释放，Feature 只能通过依赖注入使用；
- Capability 初始化按需进行，支持并发共享、失败重试和 dispose 后拒绝使用；
- `NetworkRuntime.diagnostics` 只报告 Facade 自己拥有的 ready Capability、native
  handle 和已登记连接；当前具体协议连接仍由各协议 Service Owner 管理，因此
  `activeConnections` 在尚未登记连接时为零；
- 原生 handle 的 `create -> start -> stop -> destroy` 由底层 adapter 明确拥有；
- native 实际绑定端口的查询仅属于 `ssh_mobile_network_native` 的受控测试/诊断能力，
  不进入 `NetworkRuntime`、Feature 或客户端业务合约；
- `TransportEndpoint`、`TransportConnection` 和 metrics 是后续 SSH/SFTP/LAN 模块
  使用的稳定合约，本 Step 不把旧网络业务协议搬入本包；
- `NetworkCommandGateway` 是连接 App Scope Runtime 与现有 v1 命令/事件服务的
  非拥有型桥接；它可以被 App Shell adapter 借用，但不会复制或关闭 native handle；
- 旧 LAN Share 仍暂时保留自己的协议适配，以保持本 Step 的行为范围；后续 LAN
  Step 会通过本 Facade 收敛运行时 Owner。

## 验证

```bash
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
```

## Package contract

- 职责：提供 App Scope 网络 Facade、Capability 初始化、native handle 适配和传输契约。
- 不负责：具体 LAN/SSH/SFTP 业务协议、Feature 连接 Owner 或第二套 native 实现。
- Public API：`package:network_transport/network_transport.dart`，包括
  `NetworkRuntime`、`NetworkCommandGateway` 和传输契约。
- 依赖：`app_core` 和 `ssh_mobile_network_native`。
- 数据库：不拥有数据库。
- 生命周期与资源 Owner：AppRuntime 拥有 `NetworkRuntime`；Runtime/adapter 负责
  native handle 的 `create/start/stop/destroy`，Feature 只能使用注入的 Capability。
  Gateway 及其事件订阅由借用方释放，但借用方不得停止或销毁 Runtime/native handle。
- 测试命令：`flutter analyze --no-pub`、`flutter test --no-pub`；native hook 变更时
  还需运行对应 Rust toolchain 检查。
