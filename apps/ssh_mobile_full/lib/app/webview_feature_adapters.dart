// WebView Feature 的 App Shell 适配器。
//
// Feature 只依赖 WebViewSettingsPort；本文件把 AppSettings 的语言通知转换为
// 可监听 Port，并由 AppRuntime 持有其生命周期，避免 Feature 反向引用 App 实现。

import 'package:feature_webview/feature_webview.dart' as webview;
import 'package:flutter/foundation.dart';

import '../services/app_settings.dart';

/// 将 AppSettings 暴露为 WebView 页面所需的最小设置 Port。
final class AppWebViewSettingsAdapter extends ChangeNotifier
    implements webview.WebViewSettingsPort {
  /// 创建不拥有 [settings] 的适配器。
  AppWebViewSettingsAdapter(this._settings) {
    _settings.addListener(_forwardSettingsChange);
  }

  final AppSettings _settings;

  @override
  AppLanguage get language => _settings.language;

  void _forwardSettingsChange() => notifyListeners();

  /// 解除对 AppSettings 的监听并释放 Route 可观察资源。
  @override
  void dispose() {
    _settings.removeListener(_forwardSettingsChange);
    super.dispose();
  }
}
