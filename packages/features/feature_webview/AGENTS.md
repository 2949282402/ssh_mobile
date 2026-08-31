最新更新时间：2026-08-30

# feature_webview 维护约束

- Scope: WebView Service/chat-bound sessions, navigation UI, text extraction,
  search parsing, security policy, Ports, and tests; App Shell only injects
  adapters. Depend on `app_core`, `app_ui`, and direct WebView dependencies;
  never import AI/other Feature implementations, App `/src/`, static Services,
  or bypass WebView network policy.
- Public API only `feature_webview.dart`. Changes to `ClientWebViewService`,
  `AiWebViewPort`, or security policy sync AI adapters, navigation/parser tests,
  and security regression docs.
- No Drift DB. AppRuntime owns session state, WebView Service, and Controller
  Sessions; Route VM owns listeners/display state. `dispose()` clears sessions,
  mutex tokens, and Controllers; page text, Cookies, Tokens, and sensitive forms
  never persist.

## 验证（代码变更）

`dart format --output=none --set-exit-if-changed lib test`、`flutter analyze`、
`flutter test`；local aggregate CI 仅按用户明确要求运行。
