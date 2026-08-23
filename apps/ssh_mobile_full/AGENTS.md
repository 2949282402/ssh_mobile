最新更新时间：2026-08-24

# ssh_mobile_full 维护约束

## 允许修改范围

- App Shell、`AppRuntime`、路由聚合、Port 适配器和迁移兼容桥；
- `network_sdk` 的 App Shell 请求执行器和 Bootstrap/鉴权客户端组装；
- App 专属测试、启动配置和平台集成；
- 发生 Public API 或 Owner 变化时同步本地合同与相关架构文档；只有满足治理门槛的
  跨包当前知识才更新对应 scoped Memory。

## 禁止依赖

- 不得导入 Feature Package 的 `/src/`；
- 不得在 App Shell 复制 Feature、Core 或 Infrastructure 实现；
- 不得新增 `Service.instance`、全局 locator 或第二个 Network/SSH Owner；
- `SdkRequestExecutor` 可以使用 App-owned 的短生命周期 `HttpClient`，但不得把
  控制面 HTTP client 暴露给 Feature 或与 native 数据面合并；
- 不得把密码、私钥、API Key 或 Token 写入 SharedPreferences、数据库或测试日志。

## Public API 修改要求

稳定入口通过 Feature 公共出口、App Port 或路由 metadata 暴露。修改 AppRuntime
构造依赖时必须同步所有 App/Terminal-only 调用方、测试和架构守卫 Allowlist。

## 数据库约束

App Shell 只维护 `app_logs`；Feature/Core 数据库由各自 Module/Repository 拥有。
生产数据库打开失败必须向上抛出，禁止回退到内存数据库或重新引入 `AppDatabase`。

## 资源释放规则

`AppRuntime` 是 App Scope Network、SSH、Logger、Module 和适配器的 Owner；必须提供
`dispose/close/cancel/release`，并在 debug 断言中检查可观测的 Timer、Subscription、
Lease 和 native handle 已释放。Route Scope 只释放自己的 ViewModel 资源。

`BackgroundServiceManager` 只拥有 UI isolate 的通知、权限、power lock 和平台服务
启停；后台入口点创建的 `_BackgroundSshRuntime` 独占后台 session registry、SSH/tmux、
keepalive Timer 和事件订阅。不得把 isolate session 状态放回静态 Manager。

`SshService` 保留 App Scope SSH session/command Owner；后台插件订阅统一归
`_SshBackgroundEventBridge`，UI 快照统一归 `_SshSessionProjection`。Network V2 公开
codec 只能组合 command encoder 和实际 wire tag 对应的 typed decoder，不得复制 schema
或为不存在的 Realtime tag 建立伪适配层。

## 必须运行的测试

```bash
dart run tool/architecture_check.dart
dart format --output=none --set-exit-if-changed lib test tool
flutter analyze
flutter test
```
