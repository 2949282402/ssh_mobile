import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'app_log_service.dart';

part 'client_webview/client_webview_models.dart';
part 'client_webview/client_webview_ops.dart';

abstract interface class ClientWebViewAdapter {
  Future<ClientWebViewSnapshot> readPlainText(
    String chatId, {
    int maxChars = ClientWebViewService.defaultMaxChars,
  });

  Future<ClientWebViewSearchResult> searchWeb(
    String chatId,
    String query, {
    int maxResults = 5,
    String? engine,
  });

  Future<ClientWebViewStateSnapshot> getState(String chatId);

  Future<ClientWebViewNavigationResult> navigate(
    String chatId, {
    required String action,
    String? input,
  });

  void interruptAiBrowsing(String chatId);

  void clearSession(String chatId);
}

class ClientWebViewService extends ChangeNotifier
    implements ClientWebViewAdapter {
  static final ClientWebViewService instance = ClientWebViewService._();

  static const String defaultUrl = 'https://html.duckduckgo.com/html/';
  static const int defaultMaxChars = 40000;

  final Map<String, ClientWebViewSession> _sessions = {};

  ClientWebViewService._();

  ClientWebViewSession sessionFor(String chatId) {
    return _sessions.putIfAbsent(chatId, () => _createSession(chatId));
  }

  ClientWebViewSession? sessionOf(String chatId) => _sessions[chatId];

  void notify() => notifyListeners();

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

  @override
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

  @override
  Future<ClientWebViewSearchResult> searchWeb(
    String chatId,
    String query, {
    int maxResults = 5,
    String? engine,
  }) async {
    final trimmedQuery = query.trim();
    final effectiveMaxResults = maxResults.clamp(1, 10).toInt();
    if (trimmedQuery.isEmpty) {
      return ClientWebViewSearchResult(
        chatId: chatId,
        supported: _supportsWebView,
        query: trimmedQuery,
        results: const [],
        engine: engine ?? 'duckduckgo',
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
        engine: engine ?? 'duckduckgo',
        error:
            'Client WebView search is only available on supported mobile targets.',
      );
    }

    final uri = _searchUri(trimmedQuery, engine: engine);
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
        return _interruptedSearchResult(session, trimmedQuery, engine: engine);
      }
      await _waitForPageReady(session, aiBrowsingToken: token);
      if (!_isCurrentSession(session)) {
        return ClientWebViewSearchResult(
          chatId: chatId,
          supported: true,
          query: trimmedQuery,
          results: const [],
          engine: engine ?? 'duckduckgo',
          error: 'WebView session was closed before search finished.',
        );
      }
      if (!_isAiBrowsingCurrent(session, token)) {
        return _interruptedSearchResult(session, trimmedQuery, engine: engine);
      }

      final payload = await _waitForSearchResults(
        session,
        aiBrowsingToken: token,
        desiredResults: effectiveMaxResults,
      );
      if (!_isCurrentSession(session)) {
        return ClientWebViewSearchResult(
          chatId: chatId,
          supported: true,
          query: trimmedQuery,
          results: const [],
          engine: engine ?? 'duckduckgo',
          error: 'WebView session was closed before search results were read.',
        );
      }
      if (!_isAiBrowsingCurrent(session, token)) {
        return _interruptedSearchResult(session, trimmedQuery, engine: engine);
      }
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
        results: results,
        capturedAt: capturedAt,
        engine: engine ?? 'duckduckgo',
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
          engine: engine ?? 'duckduckgo',
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
        engine: engine ?? 'duckduckgo',
        error: e.toString(),
      );
    } finally {
      _endAiBrowsing(session, token);
    }
  }

  @override
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

  @override
  void clearSession(String chatId) {
    if (_sessions.remove(chatId) != null) {
      notifyListeners();
    }
  }

  @override
  Future<ClientWebViewStateSnapshot> getState(String chatId) async {
    final session = _sessions[chatId];
    if (session == null) {
      return ClientWebViewStateSnapshot(
        chatId: chatId,
        supported: _supportsWebView,
        hasPage: false,
        progress: 0,
        isLoading: false,
        isAiBrowsing: false,
        canGoBack: false,
        canGoForward: false,
        lastTextLength: 0,
        lastTextTruncated: false,
        error: 'No WebView page is open for this chat session.',
      );
    }
    final controller = session.controller;
    bool canGoBack = false;
    bool canGoForward = false;
    if (session.supported && controller != null) {
      try {
        canGoBack = await controller.canGoBack();
      } catch (_) {}
      try {
        canGoForward = await controller.canGoForward();
      } catch (_) {}
    }
    return ClientWebViewStateSnapshot(
      chatId: chatId,
      supported: session.supported,
      hasPage: session.url != null,
      url: session.url,
      title: session.title,
      progress: session.progress,
      isLoading: session.isLoading,
      isAiBrowsing: session.isAiBrowsing,
      aiBrowsingLabel: session.aiBrowsingLabel,
      aiBrowsingStartedAt: session.aiBrowsingStartedAt,
      lastError: session.lastError,
      canGoBack: canGoBack,
      canGoForward: canGoForward,
      lastTextCapturedAt: session.lastTextCapturedAt,
      lastTextLength: session.lastTextLength,
      lastTextTruncated: session.lastTextTruncated,
      updatedAt: session.updatedAt,
      error: session.url == null
          ? 'Open the WebView from the current AI chat first.'
          : null,
    );
  }

  @override
  Future<ClientWebViewNavigationResult> navigate(
    String chatId, {
    required String action,
    String? input,
  }) async {
    final normalizedAction = action.trim().toLowerCase();
    final session = _sessions[chatId];
    if (session == null) {
      return ClientWebViewNavigationResult(
        chatId: chatId,
        supported: _supportsWebView,
        action: normalizedAction,
        input: input,
        navigated: false,
        blocked: false,
        error:
            'No WebView page is open for this chat session. Open the WebView from the current AI chat first.',
      );
    }
    final controller = session.controller;
    if (!session.supported || controller == null) {
      return ClientWebViewNavigationResult(
        chatId: chatId,
        supported: false,
        action: normalizedAction,
        input: input,
        navigated: false,
        blocked: false,
        error:
            'Client WebView navigation is only available on supported mobile targets.',
      );
    }
    if (session.isAiBrowsing) {
      return ClientWebViewNavigationResult(
        chatId: chatId,
        supported: true,
        action: normalizedAction,
        input: input,
        navigated: false,
        blocked: true,
        error:
            'AI WebView browsing is active. Interrupt it before navigating manually.',
        state: await getState(chatId),
      );
    }

    try {
      switch (normalizedAction) {
        case 'open':
          final trimmedInput = input?.trim();
          if (trimmedInput == null || trimmedInput.isEmpty) {
            return ClientWebViewNavigationResult(
              chatId: chatId,
              supported: true,
              action: normalizedAction,
              input: input,
              navigated: false,
              blocked: false,
              error: 'Provide input when action=open.',
              state: await getState(chatId),
            );
          }
          await load(chatId, trimmedInput);
          break;
        case 'back':
          if (!await controller.canGoBack()) {
            return ClientWebViewNavigationResult(
              chatId: chatId,
              supported: true,
              action: normalizedAction,
              input: input,
              navigated: false,
              blocked: false,
              error: 'The current page cannot go back.',
              state: await getState(chatId),
            );
          }
          await controller.goBack();
          break;
        case 'forward':
          if (!await controller.canGoForward()) {
            return ClientWebViewNavigationResult(
              chatId: chatId,
              supported: true,
              action: normalizedAction,
              input: input,
              navigated: false,
              blocked: false,
              error: 'The current page cannot go forward.',
              state: await getState(chatId),
            );
          }
          await controller.goForward();
          break;
        case 'refresh':
          await controller.reload();
          break;
        default:
          return ClientWebViewNavigationResult(
            chatId: chatId,
            supported: true,
            action: normalizedAction,
            input: input,
            navigated: false,
            blocked: false,
            error: 'Unsupported navigation action: $normalizedAction',
            state: await getState(chatId),
          );
      }
      return ClientWebViewNavigationResult(
        chatId: chatId,
        supported: true,
        action: normalizedAction,
        input: input,
        navigated: true,
        blocked: false,
        state: await getState(chatId),
      );
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Client WebView navigation failed',
        error: e,
        stackTrace: stackTrace,
        details: 'chatId=$chatId action=$normalizedAction input=${input ?? ''}',
      );
      return ClientWebViewNavigationResult(
        chatId: chatId,
        supported: true,
        action: normalizedAction,
        input: input,
        navigated: false,
        blocked: false,
        error: e.toString(),
        state: await getState(chatId),
      );
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
}
