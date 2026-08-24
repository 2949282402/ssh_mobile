part of '../client_webview_service.dart';

extension ClientWebViewServiceOps on ClientWebViewService {
  Future<bool> _loadUriThroughProxy(
    ClientWebViewSession session,
    Uri uri,
  ) async {
    final controller = session.controller;
    if (controller == null || !_isCurrentSession(session)) return false;
    final blockedReason = ClientWebViewSecurityPolicy.blockedUriReason(uri);
    if (blockedReason != null) {
      session
        .._lastError = blockedReason
        .._isLoading = false
        .._updatedAt = DateTime.now();
      _notifyIfCurrent(session);
      return false;
    }
    final loadGeneration = ++session._networkLoadGeneration;

    session
      .._url = uri.toString()
      .._lastError = null
      .._isLoading = true
      .._progress = 0
      .._updatedAt = DateTime.now();
    _notifyIfCurrent(session);
    try {
      final page = await _networkLoader.load(uri);
      if (!_isCurrentSession(session) ||
          session._networkLoadGeneration != loadGeneration) {
        return false;
      }
      session
        .._url = page.finalUri.toString()
        .._updatedAt = DateTime.now();
      final ticket = session._internalDocumentLease.issue();
      try {
        await controller.loadHtmlString(
          ClientWebViewService._safeDocumentRenderer.render(page),
          baseUrl: ticket.uri.toString(),
        );
      } catch (_) {
        session._internalDocumentLease.cancel(ticket);
        rethrow;
      }
      return _isCurrentSession(session) &&
          session._networkLoadGeneration == loadGeneration;
    } on ClientWebViewNetworkException catch (error) {
      if (!_isCurrentSession(session) ||
          session._networkLoadGeneration != loadGeneration) {
        return false;
      }
      session
        .._lastError = error.message
        .._isLoading = false
        .._updatedAt = DateTime.now();
      _notifyIfCurrent(session);
      return false;
    } catch (error) {
      if (!_isCurrentSession(session) ||
          session._networkLoadGeneration != loadGeneration) {
        return false;
      }
      _logError(
        'Secure Client WebView load failed',
        details:
            'chatId=${session.chatId} host=${uri.host} errorType=${error.runtimeType}',
      );
      session
        .._lastError = 'Secure WebView request failed.'
        .._isLoading = false
        .._updatedAt = DateTime.now();
      _notifyIfCurrent(session);
      return false;
    }
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
      _logError(
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
    final currentUri = session.url == null ? null : Uri.tryParse(session.url!);
    final blockedReason = currentUri == null
        ? null
        : ClientWebViewSecurityPolicy.blockedUriReason(currentUri);
    if (blockedReason != null) {
      session
        .._lastError = blockedReason
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
        blocked: true,
        error: blockedReason,
      );
    }

    try {
      final raw = await controller.runJavaScriptReturningResult(
        clientWebViewPageTextScript,
      );
      if (!_isCurrentSession(session)) {
        return _closedSnapshot(session, effectiveMaxChars);
      }
      final payload = _decodeJavaScriptPayload(raw);
      final title = (payload['title'] as String?)?.trim();
      final url = (payload['url'] as String?)?.trim();
      final payloadUri = url == null ? null : Uri.tryParse(url);
      final safePayloadUrl =
          payloadUri != null &&
          ClientWebViewSecurityPolicy.blockedUriReason(payloadUri) == null;
      final sensitiveFormDetected = payload['sensitiveFormDetected'] == true;
      if (sensitiveFormDetected) {
        final now = DateTime.now();
        session
          .._title = title?.isNotEmpty == true ? title : session.title
          .._url = safePayloadUrl ? url : session.url
          .._lastText = ''
          .._lastTextLength = 0
          .._lastTextTruncated = false
          .._lastTextCapturedAt = now
          .._lastError = 'Sensitive form detected on the current page.'
          .._updatedAt = now;
        if (notify) _notifyIfCurrent(session);
        return ClientWebViewSnapshot(
          chatId: session.chatId,
          supported: true,
          hasPage: true,
          url: session.url,
          title: session.title,
          text: '',
          textLength: 0,
          maxChars: effectiveMaxChars,
          truncated: false,
          blocked: true,
          sensitiveFormDetected: true,
          capturedAt: now,
          error:
              'Sensitive form detected. AI page-text reading is blocked for this page.',
        );
      }
      final text = payload['text'] as String? ?? '';
      final truncatedText = _truncate(text, effectiveMaxChars);
      final now = DateTime.now();
      session
        .._title = title?.isNotEmpty == true ? title : session.title
        .._url = safePayloadUrl ? url : session.url
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
      _logError(
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
            .runJavaScriptReturningResult(clientWebViewSearchResultsScript)
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
          final settled =
              DateTime.now().difference(firstResultAt) >=
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
