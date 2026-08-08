// WebView Feature 的唯一公共入口。
//
// 页面、会话服务和设置 Port 都由本 Package 持有；App Shell 只负责注入
// App Scope 的日志、设置以及 AI 所需的能力适配器，不直接引用 src/。
library;

export 'src/domain/webview_ports.dart';
export 'src/presentation/client_webview_screen.dart';
export 'src/presentation/client_webview_viewmodel.dart';
export 'src/services/client_webview_service.dart';
