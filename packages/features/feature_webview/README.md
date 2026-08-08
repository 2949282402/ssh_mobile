最新更新时间：2026-08-08

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

## 公共入口

调用方只能导入 `package:feature_webview/feature_webview.dart`，不得引用 `lib/src/`。
主要 API 包括 `ClientWebViewService`、`ClientWebViewAdapter`、
`ClientWebViewScreen`、`ClientWebViewViewModel` 和 `WebViewSettingsPort`。

## 验证

```text
dart format --output=none --set-exit-if-changed lib test
dart analyze lib test
flutter test --no-pub
```
