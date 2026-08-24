// WebView Feature 的会话服务。
//
// 本文件负责创建并维护按聊天会话隔离的 WebView Controller，同时集中执行
// URL 安全校验、AI 浏览互斥、页面文本读取和搜索结果提取。服务由 AppRuntime
// 持有，日志通过 AppLogger 注入，避免 Feature 创建全局 Service 单例。

import 'dart:async';
import 'dart:convert';

import 'package:app_core/app_core.dart';
import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../domain/client_webview_network.dart';
import '../domain/client_webview_safe_document.dart';
import '../domain/client_webview_security_policy.dart';

part 'client_webview/client_webview_models.dart';
part 'client_webview/client_webview_ops.dart';

/// 提供给 AI/MCP 等调用方的最小 WebView 能力契约。
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

/// 按聊天会话拥有 WebView Controller 和页面状态的 App Scope 服务。
final class ClientWebViewService extends ChangeNotifier
    implements ClientWebViewAdapter {
  static const String defaultUrl = 'https://www.baidu.com';
  static const int defaultMaxChars = 40000;
  static const _safeDocumentRenderer = ClientWebViewSafeDocumentRenderer();

  ClientWebViewService({
    required AppLogger logger,
    required ClientWebViewNetworkLoader networkLoader,
  }) : _logger = logger.scope('client_webview'),
       _networkLoader = networkLoader;

  final AppLogger _logger;
  final ClientWebViewNetworkLoader _networkLoader;
  final Map<String, ClientWebViewSession> _sessions = {};

  /// 释放所有会话状态，并停止向已销毁的页面发送通知。
  @override
  void dispose() {
    for (final session in _sessions.values) {
      session._internalDocumentLease.clear();
    }
    _sessions.clear();
    super.dispose();
  }

  /// 获取或创建指定聊天的会话；Controller 只在首次进入该聊天时创建。
  ClientWebViewSession sessionFor(String chatId) {
    return _sessions.putIfAbsent(chatId, () => _createSession(chatId));
  }

  /// 查询已创建的聊天会话，不会因为查询而创建平台 Controller。
  ClientWebViewSession? sessionOf(String chatId) => _sessions[chatId];

  /// 通知页面和 AI 适配器重新读取当前会话状态。
  void notify() => notifyListeners();

  /// 将地址或搜索词加载到当前聊天的 WebView，并先执行安全策略。
  Future<void> load(String chatId, String input, {String? engine}) async {
    final session = sessionFor(chatId);
    if (session.isAiBrowsing) return;
    final controller = session.controller;
    if (controller == null) return;
    final blockedReason = ClientWebViewSecurityPolicy.blockedInputReason(input);
    if (blockedReason != null) {
      session
        .._lastError = blockedReason
        .._updatedAt = DateTime.now();
      notifyListeners();
      return;
    }
    final uri = _normalizeInput(input, engine: engine ?? session.searchEngine);
    final blockedUriReason = ClientWebViewSecurityPolicy.blockedUriReason(uri);
    if (blockedUriReason != null) {
      session
        .._lastError = blockedUriReason
        .._updatedAt = DateTime.now();
      notifyListeners();
      return;
    }
    await _loadUriThroughProxy(session, uri);
  }

  @override
  /// 读取页面可见纯文本；实时读取失败时可按调用方要求返回缓存文本。
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
  /// 在当前聊天 WebView 中执行公开网页搜索并提取安全 URL 结果。
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
        engine: engine ?? 'baidu',
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
        engine: engine ?? 'baidu',
        error:
            'Client WebView search is only available on supported mobile targets.',
      );
    }

    final uri = _searchUri(trimmedQuery, engine: engine);
    final token = _beginAiBrowsing(session, 'Searching "$trimmedQuery"');
    try {
      final loaded = await _loadUriThroughProxy(session, uri);
      if (!loaded) {
        return ClientWebViewSearchResult(
          chatId: chatId,
          supported: true,
          query: trimmedQuery,
          searchUrl: session.url,
          results: const [],
          engine: engine ?? 'baidu',
          error: session.lastError ?? 'Secure WebView request was blocked.',
        );
      }
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
          engine: engine ?? 'baidu',
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
          engine: engine ?? 'baidu',
          error: 'WebView session was closed before search results were read.',
        );
      }
      if (!_isAiBrowsingCurrent(session, token)) {
        return _interruptedSearchResult(session, trimmedQuery, engine: engine);
      }
      final title = (payload['title'] as String?)?.trim();
      final url = (payload['url'] as String?)?.trim();
      final payloadUri = url == null ? null : Uri.tryParse(url);
      final safePayloadUrl =
          payloadUri != null &&
          ClientWebViewSecurityPolicy.blockedUriReason(payloadUri) == null;
      final rawResults = payload['results'];
      final results = <ClientWebViewSearchItem>[];
      if (rawResults is List) {
        for (final item in rawResults) {
          if (item is! Map) continue;
          final result = ClientWebViewSearchItem.fromJson(item);
          if (result.title.isEmpty || result.url.isEmpty) continue;
          final resultUri = Uri.tryParse(result.url);
          if (resultUri == null ||
              ClientWebViewSecurityPolicy.blockedUriReason(resultUri) != null) {
            continue;
          }
          results.add(result);
          if (results.length >= effectiveMaxResults) break;
        }
      }
      final capturedAt = DateTime.now();
      session
        .._title = title?.isNotEmpty == true ? title : session.title
        .._url = safePayloadUrl ? url : session.url
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
        results: results,
        capturedAt: capturedAt,
        engine: engine ?? 'baidu',
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
          engine: engine ?? 'baidu',
          error: 'WebView session was closed before search finished.',
        );
      }
      _logError(
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
        engine: engine ?? 'baidu',
        error: e.toString(),
      );
    } finally {
      _endAiBrowsing(session, token);
    }
  }

  @override
  /// 中断当前聊天的 AI 浏览，释放互斥令牌但保留页面。
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
  /// 清除聊天会话状态；页面离开或聊天删除时由上层调用。
  void clearSession(String chatId) {
    final removed = _sessions.remove(chatId);
    if (removed != null) {
      removed._internalDocumentLease.clear();
      notifyListeners();
    }
  }

  @override
  /// 返回当前页面状态，并查询平台提供的前进/后退能力。
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
  /// 执行打开、后退、前进或刷新，并阻止与 AI 浏览并发的手工操作。
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
          final blockedReason = ClientWebViewSecurityPolicy.blockedInputReason(
            trimmedInput,
          );
          if (blockedReason != null) {
            session
              .._lastError = blockedReason
              .._updatedAt = DateTime.now();
            notifyListeners();
            return ClientWebViewNavigationResult(
              chatId: chatId,
              supported: true,
              action: normalizedAction,
              input: input,
              navigated: false,
              blocked: true,
              error: blockedReason,
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
      _logError(
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
            if (uri != null && session._internalDocumentLease.consume(uri)) {
              return NavigationDecision.navigate;
            }
            final blockedReason = uri == null
                ? 'Invalid URL: ${request.url}'
                : ClientWebViewSecurityPolicy.blockedUriReason(uri);
            if (blockedReason != null) {
              session._lastError = blockedReason;
              _notifyIfCurrent(session);
              return NavigationDecision.prevent;
            }
            unawaited(_loadUriThroughProxy(session, uri!));
            return NavigationDecision.prevent;
          },
          onPageStarted: (url) {
            if (!_isCurrentSession(session)) return;
            final startedUri = Uri.tryParse(url);
            session
              .._url =
                  startedUri != null &&
                      session._internalDocumentLease.isIssuedDocument(
                        startedUri,
                      )
                  ? session.url
                  : url
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
            final finishedUri = Uri.tryParse(url);
            session
              .._url =
                  finishedUri != null &&
                      session._internalDocumentLease.isIssuedDocument(
                        finishedUri,
                      )
                  ? session.url
                  : url
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
      );

    unawaited(_loadUriThroughProxy(session, Uri.parse(defaultUrl)));

    return session;
  }

  /// 统一将服务错误写入 App Scope 日志，避免依赖具体日志实现。
  void _logError(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {
    _logger.log(
      LogRecord(
        timestamp: DateTime.now(),
        level: LogLevel.error,
        message: message,
        details: details,
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }
}
