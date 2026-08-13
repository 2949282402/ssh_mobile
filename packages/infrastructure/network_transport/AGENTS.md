最新更新时间：2026-08-13

# network_transport Package Guidelines

## 职责

本 Package 只提供 App Scope 网络运行时、Capability Lazy Init、传输端点/连接
合约和原生网络 adapter。它不实现具体 TCP、UDP、QUIC、WebRTC 协议，也不放置
Feature UI、SSH 会话或 LAN 业务规则。

## 依赖与边界

- 生产代码只依赖 `app_core` 和 `ssh_mobile_network_native`；
- Feature 不得直接引用本 Package 的 `/src/`，只使用 `network_transport.dart`；
- `NetworkRuntimeImpl` 只能由 AppRuntime/Composition Root 创建，Feature 不得自行
  `new` 全局网络实现；
- `NativeNetworkAdapter` 不拥有跨 App 的静态单例，handle 的释放由创建它的
  `NetworkRuntimeImpl` 负责。
- `NetworkRuntime.diagnostics` 是只读生命周期观察契约；它只能报告
  `NetworkRuntimeImpl` 直接拥有的 native handle 和已登记的连接/Capability，
  不得为了填充诊断数字而接管 Feature 协议连接。
- `NetworkCommandGateway` 只是 Runtime-owned native v1 handle 的借用型命令/事件
  入口；它不得拥有、复制或关闭 handle，也不得在其中加入业务协议规则。
- `NetworkRealtimeGateway` 同样是 Runtime-owned handle 的借用型入口；它只能
  编解码 native typed Realtime command/event，不能把 PeerConnection、ICE、SDP、
  socket 或 signaling policy 放进 Feature 或 gateway。Realtime start/stop 必须返回
  `NativeCommandTicket`，把 queue acceptance 与 `NativeCommandResultEvent` 的操作完成
  分开；结果关联、超时和 pending map 由 App Shell adapter 负责。

## 生命周期

- Capability 首次使用时才创建 native handle；相同 Capability 的并发初始化共享同一
  Future；失败会清除 in-flight 状态并允许重试；
- Runtime dispose 会等待未完成的 handle 创建，然后显式 close；dispose 后所有新的
  Capability 请求必须失败；
- `openCommandGateway()` 返回的 gateway 由 Runtime 绑定，调用方只负责取消自己的
  事件订阅；AppRuntime/NetworkRuntime 仍是 native handle 的唯一释放 Owner；
- `openRealtimeGateway()` 返回的 gateway 不拥有 native handle；App Shell adapter
  负责事件订阅和 SDK session 映射，必须在 Runtime dispose 前取消订阅。
- handle 的底层顺序必须保持 `create -> start -> stop -> destroy`，Finalizer 不替代
  显式 close。

## 必须验证

```bash
flutter analyze --no-pub
flutter test --no-pub
```

修改公共 API 或 AppRuntime Owner 时，必须同步 package/root contracts 与相关
Architecture；只有满足治理门槛的跨包当前知识才更新 Client/SDK scoped Memory。

## Package contract fields

- 允许修改范围：Network Runtime/Facade、Capability、native adapter、传输契约和测试。
- 禁止依赖：Feature、App Shell 业务实现或其他 Package 的 `/src/`；不得新增第二套协议实现。
- Public API 修改要求：同步 `network_transport.dart`、AppRuntime、Feature adapters、测试和架构文档。
  `NetworkCommandGateway` 或 `NetworkRealtimeGateway` 的新增或修改必须明确借用关系、
  ticket/result 语义和释放责任。
- 数据库约束：不拥有数据库，不保存配对凭据或业务历史。
- 资源释放规则：AppRuntime 拥有 Runtime；adapter 按 `create/start/stop/destroy` 管理 native handle。
- 必须运行的测试：`flutter analyze --no-pub`、`flutter test --no-pub`，native hook 变更还要运行 Rust 检查。
