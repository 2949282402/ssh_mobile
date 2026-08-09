最新更新时间：2026-08-09

# ssh_mobile_terminal

Terminal-only App 是模块化编译裁剪验证用的最小 Flutter App。它只声明并
装配 `app_core`、`app_ui`、`connection_core`、`network_transport`、
`ssh_core`、`feature_connection` 和 `feature_terminal`，不会引入 Full App
的 AI、RAG、MCP、WebView、LAN Share 或 SFTP 依赖。

## 生命周期

- `TerminalAppRuntime` 持有 Connection、Network、SSH 和 Logger App Scope 资源；
- `TerminalModule` 独占 `terminal.db`，由 Runtime 在退出时释放；
- `TerminalFeatureScope` 只注入公开 Port，不拥有 App Scope 资源；
- 未选择的 Feature 不会创建数据库、初始化 SDK 或注册路由。

本 App 是依赖裁剪和生命周期验证切片。真实 SSH 连接实现仍由 Full App 的
App Shell 负责；Terminal-only 切片使用安全空 Capability 展示无会话状态，
避免为了验证编译图而复制第二套 SSH Owner。

## 验证

```bash
flutter pub deps
flutter analyze
flutter test
```

`flutter pub deps` 输出中不应出现 `feature_ai`、`feature_rag`、
`feature_mcp`、`feature_webview`、`feature_lan_share` 或 `feature_sftp`。

## Package contract

- 职责：验证最小 Terminal App Shell 的依赖裁剪和生命周期组合。
- 不负责：Full App 业务、真实 SSH 兼容实现或未选择 Feature 的初始化。
- Public API：`TerminalAppRuntime`、`TerminalFeatureScope` 及 App 的启动入口。
- 依赖：`app_core`、`app_ui`、`connection_core`、`network_transport`、`ssh_core`、
  `feature_connection`、`feature_terminal` 和 Flutter SDK。
- 数据库：只由 `TerminalModule` 拥有 `terminal.db`。
- 生命周期与资源 Owner：Runtime 负责 App Scope；Module 负责数据库；Route Scope
  负责 ViewModel 和页面资源。
- 测试命令：`flutter pub deps`、`flutter analyze`、`flutter test`。
