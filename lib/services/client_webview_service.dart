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
    if (session.isAiBrowsing) return;
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

  Future<ClientWebViewSearchResult> searchWeb(
    String chatId,
    String query, {
    int maxResults = 5,
  }) async {
    final trimmedQuery = query.trim();
    final effectiveMaxResults = maxResults.clamp(1, 10).toInt();
    if (trimmedQuery.isEmpty) {
      return ClientWebViewSearchResult(
        chatId: chatId,
        supported: _supportsWebView,
        query: trimmedQuery,
        results: const [],
        error: 'Search query is empty.',
      );
    }

    final session = sessionFor(chatId);
    final controller = session.controller;
    if (!session.supported || controller == null) {
      return ClientWebViewSearchResult(
        chatId: chatId,
        supported: false,
        query: trimmedQuery,
        results: const [],
        error:
            'Client WebView search is only available on supported mobile targets.',
      );
    }

    final uri = _searchUri(trimmedQuery);
    final token = _beginAiBrowsing(
      session,
      'Searching "$trimmedQuery"',
    );
    try {
      final now = DateTime.now();
      session
        .._lastError = null
        .._url = uri.toString()
        .._isLoading = true
        .._progress = 0
        .._updatedAt = now;
      notifyListeners();
      await controller.loadRequest(uri);
      if (!_isAiBrowsingCurrent(session, token)) {
        return _interruptedSearchResult(session, trimmedQuery);
      }
      await _waitForPageReady(session, aiBrowsingToken: token);
      if (!_isCurrentSession(session)) {
        return ClientWebViewSearchResult(
          chatId: chatId,
          supported: true,
          query: trimmedQuery,
          results: const [],
          error: 'WebView session was closed before search finished.',
        );
      }
      if (!_isAiBrowsingCurrent(session, token)) {
        return _interruptedSearchResult(session, trimmedQuery);
      }

      final raw = await controller.runJavaScriptReturningResult(
        _searchResultsScript,
      );
      if (!_isCurrentSession(session)) {
        return ClientWebViewSearchResult(
          chatId: chatId,
          supported: true,
          query: trimmedQuery,
          results: const [],
          error: 'WebView session was closed before search results were read.',
        );
      }
      if (!_isAiBrowsingCurrent(session, token)) {
        return _interruptedSearchResult(session, trimmedQuery);
      }
      final payload = _decodeJavaScriptPayload(raw);
      final title = (payload['title'] as String?)?.trim();
      final url = (payload['url'] as String?)?.trim();
      final rawResults = payload['results'];
      final results = <ClientWebViewSearchItem>[];
      if (rawResults is List) {
        for (final item in rawResults) {
          if (item is! Map) continue;
          final result = ClientWebViewSearchItem.fromJson(item);
          if (result.title.isEmpty || result.url.isEmpty) continue;
          results.add(result);
          if (results.length >= effectiveMaxResults) break;
        }
      }
      final capturedAt = DateTime.now();
      session
        .._title = title?.isNotEmpty == true ? title : session.title
        .._url = url?.isNotEmpty == true ? url : session.url
        .._isLoading = false
        .._progress = 100
        .._lastError = null
        .._updatedAt = capturedAt;
      notifyListeners();
      return ClientWebViewSearchResult(
        chatId: chatId,
        supported: true,
        query: trimmedQuery,
        searchUrl: session.url,
        title: session.title,
        results: results,
        capturedAt: capturedAt,
        error: results.isEmpty
            ? 'No readable search results were found on the loaded page.'
            : null,
      );
    } catch (e, stackTrace) {
      if (!_isCurrentSession(session)) {
        return ClientWebViewSearchResult(
          chatId: chatId,
          supported: true,
          query: trimmedQuery,
          results: const [],
          error: 'WebView session was closed before search finished.',
        );
      }
      AppLogService.instance.error(
        'Client WebView search failed',
        error: e,
        stackTrace: stackTrace,
        details: 'chatId=${session.chatId} query=$trimmedQuery',
      );
      session
        .._isLoading = false
        .._lastError = e.toString()
        .._updatedAt = DateTime.now();
      notifyListeners();
      return ClientWebViewSearchResult(
        chatId: chatId,
        supported: true,
        query: trimmedQuery,
        searchUrl: session.url,
        title: session.title,
        results: const [],
        error: e.toString(),
      );
    } finally {
      _endAiBrowsing(session, token);
    }
  }

  void interruptAiBrowsing(String chatId) {
    final session = _sessions[chatId];
    if (session == null || !session.isAiBrowsing) return;
    session
      .._aiBrowsingToken = null
      .._aiBrowsingLabel = null
      .._aiBrowsingStartedAt = null
      .._updatedAt = DateTime.now();
    notifyListeners();
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

  Future<void> _waitForPageReady(
    ClientWebViewSession session, {
    Duration timeout = const Duration(seconds: 12),
    String? aiBrowsingToken,
  }) async {
    final controller = session.controller;
    if (controller == null) return;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!_isCurrentSession(session)) return;
      if (aiBrowsingToken != null &&
          !_isAiBrowsingCurrent(session, aiBrowsingToken)) {
        return;
      }
      try {
        final raw = await controller
            .runJavaScriptReturningResult('document.readyState')
            .timeout(const Duration(seconds: 1));
        final state = _decodeJavaScriptString(raw).toLowerCase();
        if (state == 'complete' || state == 'interactive') {
          await Future<void>.delayed(const Duration(milliseconds: 600));
          return;
        }
      } catch (_) {
        // The page may still be navigating; retry until the timeout.
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  String _beginAiBrowsing(ClientWebViewSession session, String label) {
    final token = '${DateTime.now().microsecondsSinceEpoch}';
    session
      .._aiBrowsingToken = token
      .._aiBrowsingLabel = label
      .._aiBrowsingStartedAt = DateTime.now()
      .._updatedAt = DateTime.now();
    notifyListeners();
    return token;
  }

  void _endAiBrowsing(ClientWebViewSession session, String token) {
    if (!_isCurrentSession(session) || session._aiBrowsingToken != token) {
      return;
    }
    session
      .._aiBrowsingToken = null
      .._aiBrowsingLabel = null
      .._aiBrowsingStartedAt = null
      .._updatedAt = DateTime.now();
    notifyListeners();
  }

  bool _isAiBrowsingCurrent(ClientWebViewSession session, String token) {
    return _isCurrentSession(session) && session._aiBrowsingToken == token;
  }

  ClientWebViewSearchResult _interruptedSearchResult(
    ClientWebViewSession session,
    String query,
  ) {
    return ClientWebViewSearchResult(
      chatId: session.chatId,
      supported: session.supported,
      query: query,
      searchUrl: session.url,
      title: session.title,
      results: const [],
      error: 'AI WebView browsing was interrupted by the user.',
    );
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

  Uri _searchUri(String query) {
    return Uri.https('www.bing.com', '/search', {'q': query});
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

  String _decodeJavaScriptString(Object raw) {
    if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
        final decoded = jsonDecode(trimmed);
        return decoded is String ? decoded : '$decoded';
      }
      return trimmed;
    }
    return '$raw';
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
  String? _aiBrowsingToken;
  String? _aiBrowsingLabel;
  DateTime? _aiBrowsingStartedAt;
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
  bool get isAiBrowsing => _aiBrowsingToken != null;
  String? get aiBrowsingLabel => _aiBrowsingLabel;
  DateTime? get aiBrowsingStartedAt => _aiBrowsingStartedAt;
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

class ClientWebViewSearchResult {
  final String chatId;
  final bool supported;
  final String query;
  final String? searchUrl;
  final String? title;
  final List<ClientWebViewSearchItem> results;
  final DateTime? capturedAt;
  final String? error;

  const ClientWebViewSearchResult({
    required this.chatId,
    required this.supported,
    required this.query,
    required this.results,
    this.searchUrl,
    this.title,
    this.capturedAt,
    this.error,
  });

  Map<String, dynamic> toJson() {
    return {
      'execution': 'client',
      'target': 'client_webview',
      'provider': 'local_webview',
      'engine': 'bing',
      'chatSessionId': chatId,
      'supported': supported,
      'query': query,
      'searchUrl': searchUrl,
      'title': title,
      'results': results.map((item) => item.toJson()).toList(),
      'resultCount': results.length,
      'capturedAtLocal': capturedAt?.toIso8601String(),
      if (error != null) 'error': error,
      'note':
          'Search was performed by the SSH Mobile client WebView for the current chat session. Result extraction reads visible search-result titles, links, and snippets from the loaded search page.',
    };
  }
}

class ClientWebViewSearchItem {
  final String title;
  final String url;
  final String snippet;

  const ClientWebViewSearchItem({
    required this.title,
    required this.url,
    required this.snippet,
  });

  factory ClientWebViewSearchItem.fromJson(Map<dynamic, dynamic> json) {
    return ClientWebViewSearchItem(
      title: '${json['title'] ?? ''}'.trim(),
      url: '${json['url'] ?? ''}'.trim(),
      snippet: '${json['snippet'] ?? ''}'.trim(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'url': url,
      if (snippet.isNotEmpty) 'snippet': snippet,
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

const String _searchResultsScript = r'''
(() => {
  const clean = (value) => (value || '').replace(/\s+/g, ' ').trim();
  const visible = (el) => {
    if (!el) return false;
    const style = window.getComputedStyle(el);
    if (style.display === 'none' || style.visibility === 'hidden') return false;
    const rect = el.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  };
  const unwrapUrl = (href) => {
    try {
      const parsed = new URL(href, window.location.href);
      if (parsed.hostname.includes('bing.com') && parsed.pathname.includes('/ck/')) {
        const encoded = parsed.searchParams.get('u');
        if (encoded) {
          let value = encoded;
          if (value.startsWith('a1')) value = value.substring(2);
          try {
            const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
            return atob(normalized);
          } catch (_) {
            return decodeURIComponent(encoded);
          }
        }
      }
      return parsed.href;
    } catch (_) {
      return '';
    }
  };
  const useful = (url, title) => {
    if (!url || !title || title.length < 3) return false;
    let parsed;
    try {
      parsed = new URL(url);
    } catch (_) {
      return false;
    }
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return false;
    const lowerTitle = title.toLowerCase();
    const junk = [
      'images', 'videos', 'maps', 'news', 'shopping', 'settings', 'sign in',
      'privacy', 'terms', 'next', 'previous', 'feedback'
    ];
    if (junk.includes(lowerTitle)) return false;
    const host = parsed.hostname.replace(/^www\./, '');
    const currentHost = window.location.hostname.replace(/^www\./, '');
    if (host === currentHost) {
      const path = parsed.pathname.toLowerCase();
      if (path === '/' || path.includes('/search') || path.includes('/images')) {
        return false;
      }
    }
    return true;
  };
  const results = [];
  const seen = new Set();
  const addResult = (anchor, container) => {
    if (!anchor || !visible(anchor)) return;
    const url = unwrapUrl(anchor.href);
    const title = clean(anchor.innerText || anchor.textContent);
    if (!useful(url, title) || seen.has(url)) return;
    seen.add(url);
    const snippetNode = container ? container.querySelector(
      '.b_caption p, .b_snippet, p, [class*="snippet"], [class*="content"]'
    ) : null;
    let snippet = clean(snippetNode && visible(snippetNode) ? snippetNode.innerText : '');
    if (!snippet && container) {
      snippet = clean(container.innerText).replace(title, '').trim();
    }
    if (snippet.length > 500) snippet = snippet.substring(0, 500);
    results.push({ title, url, snippet });
  };
  const containers = Array.from(document.querySelectorAll([
    'li.b_algo',
    'ol#b_results > li',
    '[data-testid="result"]',
    'article',
    '.result',
    '.g'
  ].join(',')));
  for (const container of containers) {
    const anchor = container.querySelector('h2 a[href], h3 a[href], a[href]');
    addResult(anchor, container);
    if (results.length >= 12) break;
  }
  if (results.length < 3) {
    for (const anchor of Array.from(document.querySelectorAll('a[href]'))) {
      addResult(anchor, anchor.closest('li, article, div') || anchor.parentElement);
      if (results.length >= 12) break;
    }
  }
  return JSON.stringify({
    title: document.title || '',
    url: window.location ? window.location.href : '',
    results
  });
})()
''';
