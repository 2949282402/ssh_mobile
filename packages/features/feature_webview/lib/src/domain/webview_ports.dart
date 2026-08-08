// WebView Feature 的跨层 Port。
//
// 语言设置属于 App Scope，但 Feature 不应反向依赖 AppSettings 实现；
// 因此页面只消费这个最小可监听契约。

import 'package:app_core/app_core.dart';
import 'package:flutter/foundation.dart';

/// WebView 页面展示所需的应用语言设置。
abstract interface class WebViewSettingsPort extends Listenable {
  /// 当前应用语言。
  AppLanguage get language;
}
