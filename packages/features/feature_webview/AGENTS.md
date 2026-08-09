最新更新时间：2026-08-09

# feature_webview 维护约束

## 允许修改范围

允许修改 WebView Service、chat-bound session、导航 UI、文本提取、搜索解析、
安全策略、公共 Port 和本 Package 测试；App Shell 只维护注入适配器。

## 禁止依赖

只依赖 `app_core`、`app_ui` 和 WebView 直接依赖；禁止导入 AI 或其他 Feature 的
实现、App `/src/`、静态全局 Service，或绕过 WebView 安全策略访问网络。

## Public API 修改要求

调用方只能使用 `package:feature_webview/feature_webview.dart`。修改
`ClientWebViewService`、`AiWebViewPort` 或安全策略时，必须同步 AI App 适配器、
导航/解析测试和安全回归文档。

## 数据库约束

本 Feature 不拥有 Drift 数据库；会话状态由 AppRuntime 持有，不能把页面正文、
Cookie、Token 或敏感表单写入持久化存储。

## 资源释放规则

AppRuntime 负责 WebView Service 和 Controller Session 生命周期；Route ViewModel
只负责自己的监听和展示状态。`dispose()` 必须清理会话、互斥令牌和 Controller。

## 必须运行的测试

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test --no-pub
```
