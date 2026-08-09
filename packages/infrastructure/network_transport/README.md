最新更新时间：2026-08-09

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
- `TransportEndpoint`、`TransportConnection` 和 metrics 是后续 SSH/SFTP/LAN 模块
  使用的稳定合约，本 Step 不把旧网络业务协议搬入本包；
- 旧 LAN Share 仍暂时保留自己的协议适配，以保持本 Step 的行为范围；后续 LAN
  Step 会通过本 Facade 收敛运行时 Owner。

## 验证

```bash
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
```
