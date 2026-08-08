// WebView 页面路由级状态。
//
// ViewModel 只拥有当前聊天页面的输入控制器和展示状态；WebView 会话服务
// 由 AppRuntime 注入，语言由 Feature Port 提供，避免页面直接创建全局资源。

import 'package:app_core/app_core.dart';
import 'package:flutter/material.dart';

import '../domain/webview_ports.dart';
import '../services/client_webview_service.dart';

/// 当前聊天 WebView 路由的 ViewModel。
final class ClientWebViewViewModel extends ChangeNotifier {
  ClientWebViewViewModel({
    required ClientWebViewService webViewService,
    required WebViewSettingsPort settings,
  }) : _webViewService = webViewService,
       _settings = settings;

  final ClientWebViewService _webViewService;
  final WebViewSettingsPort _settings;
  late final String chatId;
  late final ClientWebViewSession session;
  late final TextEditingController urlController;
  late final FocusNode urlFocusNode;

  /// 绑定聊天会话，并创建页面输入资源。
  void init(String id) {
    chatId = id;
    session = _webViewService.sessionFor(chatId);
    urlController = TextEditingController(
      text: session.url ?? ClientWebViewService.defaultUrl,
    );
    urlFocusNode = FocusNode();
    _webViewService.addListener(syncUrlText);
  }

  @override
  void dispose() {
    _webViewService.removeListener(syncUrlText);
    urlController.dispose();
    urlFocusNode.dispose();
    super.dispose();
  }

  AppLanguage get language => _settings.language;

  // WebView state proxies
  bool get supported => session.supported;
  bool get hasController => session.controller != null;
  bool get isAiBrowsing => session.isAiBrowsing;
  bool get isLoading => session.isLoading;
  int get progress => session.progress;
  String? get title => session.title;
  String? get aiBrowsingLabel => session.aiBrowsingLabel;
  String? get lastError => session.lastError;

  void syncUrlText() {
    if (session.isAiBrowsing && urlFocusNode.hasFocus) {
      urlFocusNode.unfocus();
    }
    if (urlFocusNode.hasFocus) return;
    final url = session.url ?? '';
    if (url.isNotEmpty && urlController.text != url) {
      urlController.text = url;
    }
    notifyListeners();
  }

  Future<void> load(String input, {String? engine}) async {
    await _webViewService.load(chatId, input, engine: engine);
    notifyListeners();
  }

  String get searchEngine => session.searchEngine;

  void updateSearchEngine(String engine) {
    if (session.searchEngine == engine) return;
    session.searchEngine = engine;
    _webViewService.notify();

    final inputText = urlController.text.trim();
    if (inputText.isNotEmpty && !_isDirectUrl(inputText)) {
      load(inputText, engine: engine);
    } else {
      notifyListeners();
    }
  }

  bool _isDirectUrl(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return false;
    final parsed = Uri.tryParse(trimmed);
    if (parsed != null &&
        (parsed.scheme.toLowerCase() == 'http' ||
            parsed.scheme.toLowerCase() == 'https')) {
      return true;
    }
    if (!trimmed.contains(' ') && trimmed.contains('.')) {
      return true;
    }
    return false;
  }

  Future<void> goBack() async {
    if (session.isAiBrowsing) return;
    final controller = session.controller;
    if (controller == null) return;
    if (await controller.canGoBack()) {
      await controller.goBack();
    }
  }

  Future<void> goForward() async {
    if (session.isAiBrowsing) return;
    final controller = session.controller;
    if (controller == null) return;
    if (await controller.canGoForward()) {
      await controller.goForward();
    }
  }

  Future<void> refresh() async {
    if (session.isAiBrowsing) return;
    final controller = session.controller;
    if (controller == null) return;
    await controller.reload();
  }

  void interruptAiBrowsing() {
    _webViewService.interruptAiBrowsing(chatId);
    notifyListeners();
  }
}
