import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'app_log_service.dart';

class ClientWebViewService extends ChangeNotifier {
  static final ClientWebViewService instance = ClientWebViewService._();

  static const String defaultUrl = 'https://www.bing.com';
  static const int defaultMaxChars = 40000;

  final Map<String, ClientWebViewSession> _sessions = {};

  ClientWebViewService._();

  ClientWebViewSession sessionFor(String chatId) {
    return _sessions.putIfAbsent(chatId, () => _createSession(chatId));
  }

  ClientWebViewSession? sessionOf(String chatId) => _sessions[chatId];

  Future<void> load(String chatId, String input) async {
    final session = sessionFor(chatId);
    final controller = session.controller;
    if (controller == null) return;
    final uri = _normalizeInput(input);
    session._lastError = null;
    session._url = uri.toString();
    session._updatedAt = DateTime.now();
    notifyListeners();
    await controller.loadRequest(uri);
  }

  Future<ClientWebViewSnapshot> readPlainText(
    String chatId, {
    int maxChars = defaultMaxChars,
  }) async {
    final session = _sessions[chatId];
    if (session == null) {
      return ClientWebViewSnapshot(
        chatId: chatId,
        supported: _supportsWebView,
        hasPage: false,
        text: '',
        textLength: 0,
        maxChars: maxChars,
        truncated: false,
        error: 'No WebView page is open for this chat session.',
      );
    }
    return _capturePageText(
      session,
      maxChars: maxChars,
      notify: true,
      preferCachedOnFailure: true,
    );
  }

  void clearSession(String chatId) {
    if (_sessions.remove(chatId) != null) {
      notifyListeners();
    }
  }

  ClientWebViewSession _createSession(String chatId) {
    if (!_supportsWebView) {
      return ClientWebViewSession._(
        chatId: chatId,
        controller: null,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        supported: false,
        url: null,
      );
    }

    late final ClientWebViewSession session;
    final controller = WebViewController();
    session = ClientWebViewSession._(
      chatId: chatId,
      controller: controller,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      supported: true,
      url: defaultUrl,
    );

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            if (!_isCurrentSession(session)) {
              return NavigationDecision.prevent;
            }
            final uri = Uri.tryParse(request.url);
            final scheme = uri?.scheme.toLowerCase();
            if (scheme != 'http' && scheme != 'https') {
              session._lastError = 'Unsupported URL scheme: ${request.url}';
              _notifyIfCurrent(session);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onPageStarted: (url) {
            if (!_isCurrentSession(session)) return;
            session
              .._url = url
              .._progress = 0
              .._isLoading = true
              .._lastError = null
              .._updatedAt = DateTime.now();
            _notifyIfCurrent(session);
          },
          onProgress: (progress) {
            if (!_isCurrentSession(session)) return;
            session
              .._progress = progress
              .._updatedAt = DateTime.now();
            _notifyIfCurrent(session);
          },
          onPageFinished: (url) {
            if (!_isCurrentSession(session)) return;
            session
              .._url = url
              .._progress = 100
              .._isLoading = false
              .._updatedAt = DateTime.now();
            _notifyIfCurrent(session);
            unawaited(_refreshTitle(session));
            unawaited(
              _capturePageText(
                session,
                maxChars: defaultMaxChars,
                notify: true,
                preferCachedOnFailure: false,
              ),
            );
          },
          onWebResourceError: (error) {
            if (!_isCurrentSession(session) || error.isForMainFrame == false) {
              return;
            }
            session
              .._isLoading = false
              .._lastError = error.description
              .._updatedAt = DateTime.now();
            _notifyIfCurrent(session);
          },
        ),
      )
      ..loadRequest(Uri.parse(defaultUrl));

    return session;
  }

  Future<void> _refreshTitle(ClientWebViewSession session) async {
    final controller = session.controller;
    if (controller == null) return;
    try {
      if (!_isCurrentSession(session)) return;
      final title = await controller.getTitle();
      if (!_isCurrentSession(session)) return;
      session
        .._title = title
        .._updatedAt = DateTime.now();
      _notifyIfCurrent(session);
    } catch (e, stackTrace) {
      if (!_isCurrentSession(session)) return;
      AppLogService.instance.error(
        'Client WebView title read failed',
        error: e,
        stackTrace: stackTrace,
        details: 'chatId=${session.chatId}',
      );
    }
  }

  Future<ClientWebViewSnapshot> _capturePageText(
    ClientWebViewSession session, {
    required int maxChars,
    required bool notify,
    required bool preferCachedOnFailure,
  }) async {
    final effectiveMaxChars = maxChars.clamp(1000, 100000).toInt();
    final controller = session.controller;
    if (!session.supported || controller == null) {
      return ClientWebViewSnapshot(
        chatId: session.chatId,
        supported: false,
        hasPage: false,
        url: session.url,
        title: session.title,
        text: '',
        textLength: 0,
        maxChars: effectiveMaxChars,
        truncated: false,
        error: 'Client WebView is only available on supported mobile targets.',
      );
    }

    try {
      final raw = await controller.runJavaScriptReturningResult(
        _pageTextScript,
      );
      if (!_isCurrentSession(session)) {
        return _closedSnapshot(session, effectiveMaxChars);
      }
      final payload = _decodeJavaScriptPayload(raw);
      final title = (payload['title'] as String?)?.trim();
      final url = (payload['url'] as String?)?.trim();
      final text = payload['text'] as String? ?? '';
      final truncatedText = _truncate(text, effectiveMaxChars);
      final now = DateTime.now();
      session
        .._title = title?.isNotEmpty == true ? title : session.title
        .._url = url?.isNotEmpty == true ? url : session.url
        .._lastText = truncatedText.value
        .._lastTextLength = text.length
        .._lastTextTruncated = truncatedText.truncated
        .._lastTextCapturedAt = now
        .._lastError = null
        .._updatedAt = now;
      if (notify) _notifyIfCurrent(session);
      return ClientWebViewSnapshot(
        chatId: session.chatId,
        supported: true,
        hasPage: true,
        url: session.url,
        title: session.title,
        text: truncatedText.value,
        textLength: text.length,
        maxChars: effectiveMaxChars,
        truncated: truncatedText.truncated,
        capturedAt: now,
      );
    } catch (e, stackTrace) {
      if (!_isCurrentSession(session)) {
        return _closedSnapshot(session, effectiveMaxChars);
      }
      AppLogService.instance.error(
        'Client WebView text read failed',
        error: e,
        stackTrace: stackTrace,
        details: 'chatId=${session.chatId} url=${session.url ?? ''}',
      );
      final cachedText = session.lastText;
      if (preferCachedOnFailure && cachedText.isNotEmpty) {
        return ClientWebViewSnapshot(
          chatId: session.chatId,
          supported: true,
          hasPage: true,
          url: session.url,
          title: session.title,
          text: cachedText,
          textLength: session.lastTextLength,
          maxChars: effectiveMaxChars,
          truncated: session.lastTextTruncated,
          capturedAt: session.lastTextCapturedAt,
          error: 'Live WebView read failed, returned last captured text.',
        );
      }
      session
        .._lastError = e.toString()
        .._updatedAt = DateTime.now();
      if (notify) _notifyIfCurrent(session);
      return ClientWebViewSnapshot(
        chatId: session.chatId,
        supported: true,
        hasPage: session.url != null,
        url: session.url,
        title: session.title,
        text: '',
        textLength: 0,
        maxChars: effectiveMaxChars,
        truncated: false,
        error: e.toString(),
      );
    }
  }

  bool _isCurrentSession(ClientWebViewSession session) {
    return identical(_sessions[session.chatId], session);
  }

  void _notifyIfCurrent(ClientWebViewSession session) {
    if (_isCurrentSession(session)) notifyListeners();
  }

  ClientWebViewSnapshot _closedSnapshot(
    ClientWebViewSession session,
    int maxChars,
  ) {
    return ClientWebViewSnapshot(
      chatId: session.chatId,
      supported: session.supported,
      hasPage: false,
      url: session.url,
      title: session.title,
      text: '',
      textLength: 0,
      maxChars: maxChars,
      truncated: false,
      error: 'WebView session was closed before the page text read finished.',
    );
  }

  Uri _normalizeInput(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return Uri.parse(defaultUrl);
    final parsed = Uri.tryParse(trimmed);
    if (parsed != null &&
        (parsed.scheme.toLowerCase() == 'http' ||
            parsed.scheme.toLowerCase() == 'https')) {
      return parsed;
    }
    if (!trimmed.contains(' ') && trimmed.contains('.')) {
      return Uri.parse('https://$trimmed');
    }
    return Uri.https('www.bing.com', '/search', {'q': trimmed});
  }

  Map<String, dynamic> _decodeJavaScriptPayload(Object raw) {
    Object decoded = raw;
    if (decoded is String) {
      final trimmed = decoded.trim();
      decoded = trimmed.startsWith('"') && trimmed.endsWith('"')
          ? jsonDecode(trimmed)
          : trimmed;
      if (decoded is String) {
        decoded = jsonDecode(decoded);
      }
    }
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
    throw FormatException('Unexpected WebView text payload: $raw');
  }

  _TruncatedText _truncate(String text, int maxChars) {
    if (text.length <= maxChars) {
      return _TruncatedText(text, false);
    }
    return _TruncatedText(text.substring(0, maxChars), true);
  }

  bool get _supportsWebView {
    return !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
  }
}

class ClientWebViewSession {
  final String chatId;
  final WebViewController? controller;
  final DateTime createdAt;
  final bool supported;

  String? _url;
  String? _title;
  int _progress = 0;
  bool _isLoading = false;
  String? _lastError;
  String _lastText = '';
  int _lastTextLength = 0;
  bool _lastTextTruncated = false;
  DateTime? _lastTextCapturedAt;
  DateTime _updatedAt;

  ClientWebViewSession._({
    required this.chatId,
    required this.controller,
    required this.createdAt,
    required this.supported,
    required DateTime updatedAt,
    required String? url,
  })  : _updatedAt = updatedAt,
        _url = url;

  String? get url => _url;
  String? get title => _title;
  int get progress => _progress;
  bool get isLoading => _isLoading;
  String? get lastError => _lastError;
  String get lastText => _lastText;
  int get lastTextLength => _lastTextLength;
  bool get lastTextTruncated => _lastTextTruncated;
  DateTime? get lastTextCapturedAt => _lastTextCapturedAt;
  DateTime get updatedAt => _updatedAt;
}

class ClientWebViewSnapshot {
  final String chatId;
  final bool supported;
  final bool hasPage;
  final String? url;
  final String? title;
  final String text;
  final int textLength;
  final int maxChars;
  final bool truncated;
  final DateTime? capturedAt;
  final String? error;

  const ClientWebViewSnapshot({
    required this.chatId,
    required this.supported,
    required this.hasPage,
    required this.text,
    required this.textLength,
    required this.maxChars,
    required this.truncated,
    this.url,
    this.title,
    this.capturedAt,
    this.error,
  });

  Map<String, dynamic> toJson() {
    return {
      'execution': 'client',
      'target': 'client_webview',
      'chatSessionId': chatId,
      'supported': supported,
      'hasPage': hasPage,
      'url': url,
      'title': title,
      'text': text,
      'textLength': textLength,
      'maxChars': maxChars,
      'truncated': truncated,
      'capturedAtLocal': capturedAt?.toIso8601String(),
      if (error != null) 'error': error,
      'note':
          'This is visible plain text read from the WebView bound to the current chat session. It does not include images, hidden DOM data, passwords, or cross-origin iframe contents.',
    };
  }
}

class _TruncatedText {
  final String value;
  final bool truncated;

  const _TruncatedText(this.value, this.truncated);
}

const String _pageTextScript = r'''
(() => {
  const title = document.title || '';
  const url = window.location ? window.location.href : '';
  const body = document.body;
  const text = body ? (body.innerText || '') : '';
  return JSON.stringify({ title, url, text });
})()
''';
