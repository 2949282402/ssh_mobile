part of '../client_webview_service.dart';

extension ClientWebViewServiceOps on ClientWebViewService {
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
    if (_isCurrentSession(session)) notify();
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

  Future<Map<String, dynamic>> _waitForSearchResults(
    ClientWebViewSession session, {
    required String aiBrowsingToken,
    required int desiredResults,
    Duration timeout = const Duration(seconds: 14),
  }) async {
    final controller = session.controller;
    if (controller == null) return const {};
    final deadline = DateTime.now().add(timeout);
    Map<String, dynamic>? lastPayload;
    Map<String, dynamic>? bestPayload;
    var bestCount = 0;
    DateTime? firstResultAt;
    while (DateTime.now().isBefore(deadline)) {
      if (!_isAiBrowsingCurrent(session, aiBrowsingToken)) return const {};
      try {
        final raw = await controller
            .runJavaScriptReturningResult(_searchResultsScript)
            .timeout(const Duration(seconds: 2));
        if (!_isAiBrowsingCurrent(session, aiBrowsingToken)) return const {};
        final payload = _decodeJavaScriptPayload(raw);
        lastPayload = payload;
        final rawResults = payload['results'];
        final count = rawResults is List ? rawResults.length : 0;
        if (count > bestCount) {
          bestCount = count;
          bestPayload = payload;
        }
        if (count > 0) {
          firstResultAt ??= DateTime.now();
          final settled = DateTime.now().difference(firstResultAt) >=
              const Duration(milliseconds: 1200);
          if (count >= desiredResults || settled) {
            return bestPayload ?? payload;
          }
        }
      } catch (_) {
        // The search page may still be settling or replacing its DOM.
      }
      await Future<void>.delayed(const Duration(milliseconds: 550));
    }
    return bestPayload ?? lastPayload ?? const {};
  }

  String _beginAiBrowsing(ClientWebViewSession session, String label) {
    final token = '${DateTime.now().microsecondsSinceEpoch}';
    session
      .._aiBrowsingToken = token
      .._aiBrowsingLabel = label
      .._aiBrowsingStartedAt = DateTime.now()
      .._updatedAt = DateTime.now();
    notify();
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
    notify();
  }

  bool _isAiBrowsingCurrent(ClientWebViewSession session, String token) {
    return _isCurrentSession(session) && session._aiBrowsingToken == token;
  }

  ClientWebViewSearchResult _interruptedSearchResult(
    ClientWebViewSession session,
    String query, {
    String? engine,
  }) {
    return ClientWebViewSearchResult(
      chatId: session.chatId,
      supported: session.supported,
      query: query,
      searchUrl: session.url,
      title: session.title,
      results: const [],
      engine: engine ?? 'baidu',
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

  Uri _normalizeInput(String input, {String? engine}) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return Uri.parse(ClientWebViewService.defaultUrl);
    final parsed = Uri.tryParse(trimmed);
    if (parsed != null &&
        (parsed.scheme.toLowerCase() == 'http' ||
            parsed.scheme.toLowerCase() == 'https')) {
      return parsed;
    }
    if (!trimmed.contains(' ') && trimmed.contains('.')) {
      return Uri.parse('https://$trimmed');
    }
    return _searchUri(trimmed, engine: engine);
  }

  Uri _searchUri(String query, {String? engine}) {
    final effectiveEngine = engine?.trim().toLowerCase() ?? 'baidu';
    switch (effectiveEngine) {
      case 'google':
        return Uri.https('www.google.com', '/search', {'q': query});
      case 'bing':
        return Uri.https('www.bing.com', '/search', {'q': query});
      case 'baidu':
        return Uri.https('www.baidu.com', '/s', {'wd': query});
      case 'duckduckgo':
        return Uri.https('html.duckduckgo.com', '/html/', {'q': query});
      default:
        return Uri.https('www.baidu.com', '/s', {'wd': query});
    }
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
  const notHidden = (el) => {
    if (!el) return false;
    const style = window.getComputedStyle(el);
    return style.display !== 'none' && style.visibility !== 'hidden';
  };
  const unwrapUrl = (href) => {
    try {
      const parsed = new URL(href, window.location.href);
      const host = parsed.hostname.replace(/^www\./, '').toLowerCase();
      const duckTarget = parsed.searchParams.get('uddg');
      if (host.endsWith('duckduckgo.com') && duckTarget) {
        try {
          return decodeURIComponent(duckTarget);
        } catch (_) {
          return duckTarget;
        }
      }
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
      'privacy', 'privacy policy', 'terms', 'terms of service', 'next',
      'previous', 'feedback', 'help', 'advertise', 'safe search',
      'all regions', 'any time', 'past day', 'past week', 'past month',
      'past year', 'more results'
    ];
    if (junk.includes(lowerTitle)) return false;
    const loweredUrl = url.toLowerCase();
    if (
      loweredUrl.includes('/y.js?') ||
      loweredUrl.includes('ad_domain=') ||
      loweredUrl.includes('/aclick?') ||
      loweredUrl.includes('doubleclick.net')
    ) {
      return false;
    }
    const host = parsed.hostname.replace(/^www\./, '').toLowerCase();
    const path = parsed.pathname.toLowerCase();
    if (host.endsWith('duckduckgo.com')) {
      if (
        path === '/' ||
        path.includes('/html') ||
        path.includes('/l/') ||
        path.includes('/settings') ||
        path.includes('/feedback') ||
        path.includes('/duckduckgo-help-pages')
      ) {
        return false;
      }
    }
    const currentHost = window.location.hostname.replace(/^www\./, '').toLowerCase();
    if (host === currentHost) {
      if (
        path === '/' ||
        path.includes('/search') ||
        path.includes('/images') ||
        path === '/s'
      ) {
        return false;
      }
    }
    return true;
  };
  const results = [];
  const seen = new Set();
  const addResult = (anchor, container) => {
    if (!anchor || !notHidden(anchor)) return;
    if (container && (
      container.classList.contains('result--ad') ||
      container.querySelector('.badge--ad, [class*="badge--ad"], [class*="ad_domain"]')
    )) {
      return;
    }
    const url = unwrapUrl(anchor.href);
    const title = clean(anchor.innerText || anchor.textContent);
    if (!useful(url, title) || seen.has(url)) return;
    seen.add(url);
    const snippetNode = container ? container.querySelector(
      '.result__snippet, .result__body, .result__extras, .b_caption p, .b_snippet, p, [class*="snippet"], [class*="content"]'
    ) : null;
    let snippet = clean(snippetNode && notHidden(snippetNode) ? snippetNode.innerText : '');
    if (!snippet && container) {
      snippet = clean(container.innerText).replace(title, '').trim();
    }
    if (snippet.length > 500) snippet = snippet.substring(0, 500);
    results.push({ title, url, snippet });
  };
  const containers = Array.from(document.querySelectorAll([
    '.result.results_links',
    '.results_links',
    '.web-result',
    '.result',
    'li.b_algo',
    'ol#b_results > li',
    '[data-testid="result"]',
    'article',
    '.g'
  ].join(',')));
  for (const container of containers) {
    const anchor = container.querySelector(
      '.result__a[href], a.result__a[href], h2 a[href], h3 a[href], a[href]'
    );
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
