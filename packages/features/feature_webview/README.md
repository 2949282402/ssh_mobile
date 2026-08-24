最新更新时间：2026-08-24

# feature_webview

客户端 WebView Feature，负责聊天绑定的 WebView 会话、页面导航、公开网页搜索、
可见纯文本读取和敏感页面安全阻断。

## 边界

- `ClientWebViewService` 由 AppRuntime 持有，按聊天 ID 管理
  `WebViewController`、加载状态和 AI 浏览互斥令牌；服务释放时清理所有会话。
- Feature 通过 `WebViewSettingsPort` 读取语言，不依赖 AppSettings 实现；日志通过
  `AppLogger` 注入，不使用 `Service.instance` 全局实现。
- `webview_flutter` 是本 Feature 的直接插件依赖；App Shell 只通过
  `package:feature_webview/feature_webview.dart` 使用页面和服务。
- AI 不依赖本 Feature 的实现，仍通过 `AiWebViewPort` 由 App Shell 做适配；因此
  WebView 页面和 AI 工具的边界不会反向耦合。
- URL 只允许 HTTP/HTTPS，并阻断 localhost、私有网段、metadata 地址、敏感表单
  页面和非安全 Scheme；这些限制同时适用于 UI 导航和 AI 工具调用。
- WebView 不直接访问远端网络。App 注入的受控 Loader 对每个初始请求和重定向
  重新解析 DNS、拒绝任一非全球可路由地址，并把实际 socket 固定到已验证 IP；
  Feature 只把转义后的纯文本和安全链接渲染为无远端子资源的本地 HTML。生成
  文档使用按会话与代次绑定的一次性导航 lease，其他 `about:`/`data:` 导航仍拒绝。

## 公共入口

调用方只能导入 `package:feature_webview/feature_webview.dart`，不得引用 `lib/src/`。
主要 API 包括 `ClientWebViewService`、`ClientWebViewAdapter`、
`ClientWebViewSafeNetworkLoader`、`ClientWebViewSafeDocumentRenderer`、
`ClientWebViewScreen`、`ClientWebViewViewModel` 和 `WebViewSettingsPort`。

## 验证

```text
dart format --output=none --set-exit-if-changed lib test
dart analyze lib test
flutter test --no-pub
```

## Package contract

- 职责：提供聊天绑定 WebView、导航、可见文本提取、搜索解析和 WebView 安全策略。
- 不负责：AI 编排、远端 SSH、其他 Feature 实现或把敏感页面正文写入持久化存储。
- Public API：`package:feature_webview/feature_webview.dart`，包括 Service、页面、
  ViewModel、Adapter 和 Settings Port。
- 依赖：`app_core`、`app_ui`、Provider、`webview_flutter`。
- 数据库：不拥有数据库；会话和 Controller 由 AppRuntime 运行时持有。
- 生命周期与资源 Owner：AppRuntime 负责 ClientWebViewService、Controller Session
  和互斥令牌；Route Scope 负责 ViewModel 监听。
- 测试命令：`dart format --output=none --set-exit-if-changed lib test`、
  `flutter analyze --no-pub`、`flutter test --no-pub`。
