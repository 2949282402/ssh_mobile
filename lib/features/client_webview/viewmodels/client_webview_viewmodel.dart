import 'package:flutter/material.dart';
import '../../../services/client_webview_service.dart';
import '../../../services/app_settings.dart';

class ClientWebViewViewModel extends ChangeNotifier {
  final ClientWebViewService _webViewService = ClientWebViewService.instance;
  final AppSettings _appSettings;

  late final String chatId;
  late final ClientWebViewSession session;
  late final TextEditingController urlController;
  late final FocusNode urlFocusNode;

  ClientWebViewViewModel({
    required AppSettings appSettings,
  }) : _appSettings = appSettings;

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

  AppLanguage get language => _appSettings.language;

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
