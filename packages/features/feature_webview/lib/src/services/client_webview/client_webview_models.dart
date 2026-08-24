part of '../client_webview_service.dart';

/// 一个聊天绑定的 WebView 会话及其可观察状态。
class ClientWebViewSession {
  final String chatId;
  final WebViewController? controller;
  final DateTime createdAt;
  final bool supported;
  final ClientWebViewInternalDocumentLease _internalDocumentLease =
      ClientWebViewInternalDocumentLease();

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
  String _searchEngine = 'baidu';
  int _networkLoadGeneration = 0;

  ClientWebViewSession._({
    required this.chatId,
    required this.controller,
    required this.createdAt,
    required this.supported,
    required this._updatedAt,
    required this._url,
  }) : _searchEngine = 'baidu';

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
  String get searchEngine => _searchEngine;

  set searchEngine(String val) {
    _searchEngine = val;
    _updatedAt = DateTime.now();
  }
}

/// AI 读取当前 WebView 可见纯文本后的不可变结果。
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
  final bool blocked;
  final bool sensitiveFormDetected;
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
    this.blocked = false,
    this.sensitiveFormDetected = false,
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
      'blocked': blocked,
      'sensitiveFormDetected': sensitiveFormDetected,
      'capturedAtLocal': capturedAt?.toIso8601String(),
      if (error != null) 'error': error,
      'note':
          'This is visible plain text read from the WebView bound to the current chat session. It does not include images, hidden DOM data, passwords, or cross-origin iframe contents.',
    };
  }
}

/// 当前聊天 WebView 的导航、加载和 AI 浏览状态快照。
class ClientWebViewStateSnapshot {
  final String chatId;
  final bool supported;
  final bool hasPage;
  final String? url;
  final String? title;
  final int progress;
  final bool isLoading;
  final bool isAiBrowsing;
  final String? aiBrowsingLabel;
  final DateTime? aiBrowsingStartedAt;
  final String? lastError;
  final bool canGoBack;
  final bool canGoForward;
  final DateTime? lastTextCapturedAt;
  final int lastTextLength;
  final bool lastTextTruncated;
  final DateTime? updatedAt;
  final String? error;

  const ClientWebViewStateSnapshot({
    required this.chatId,
    required this.supported,
    required this.hasPage,
    required this.progress,
    required this.isLoading,
    required this.isAiBrowsing,
    required this.canGoBack,
    required this.canGoForward,
    required this.lastTextLength,
    required this.lastTextTruncated,
    this.url,
    this.title,
    this.aiBrowsingLabel,
    this.aiBrowsingStartedAt,
    this.lastError,
    this.lastTextCapturedAt,
    this.updatedAt,
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
      'progress': progress,
      'isLoading': isLoading,
      'isAiBrowsing': isAiBrowsing,
      'aiBrowsingLabel': aiBrowsingLabel,
      'aiBrowsingStartedAtLocal': aiBrowsingStartedAt?.toIso8601String(),
      'lastError': lastError,
      'canGoBack': canGoBack,
      'canGoForward': canGoForward,
      'lastTextCapturedAtLocal': lastTextCapturedAt?.toIso8601String(),
      'lastTextLength': lastTextLength,
      'lastTextTruncated': lastTextTruncated,
      'updatedAtLocal': updatedAt?.toIso8601String(),
      if (error != null) 'error': error,
      'note':
          'This describes the WebView bound to the current chat session on the client device.',
    };
  }
}

/// 一次客户端 WebView 导航操作的结果。
class ClientWebViewNavigationResult {
  final String chatId;
  final bool supported;
  final String action;
  final String? input;
  final bool navigated;
  final bool blocked;
  final String? error;
  final ClientWebViewStateSnapshot? state;

  const ClientWebViewNavigationResult({
    required this.chatId,
    required this.supported,
    required this.action,
    required this.navigated,
    required this.blocked,
    this.input,
    this.error,
    this.state,
  });

  Map<String, dynamic> toJson() {
    return {
      'execution': 'client',
      'target': 'client_webview',
      'chatSessionId': chatId,
      'supported': supported,
      'action': action,
      'input': input,
      'navigated': navigated,
      'blocked': blocked,
      if (error != null) 'error': error,
      if (state != null) 'state': state!.toJson(),
      'note':
          'Navigation acts on the WebView bound to the current chat session on the client device.',
    };
  }
}

/// 一次客户端 WebView 搜索操作及其公开结果。
class ClientWebViewSearchResult {
  final String chatId;
  final bool supported;
  final String query;
  final String engine;
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
    this.engine = 'baidu',
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
      'engine': '${engine}_html',
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
          'Search was performed by the SSH Mobile client WebView for the current chat session. Result extraction reads search-result titles, links, and snippets from a lightweight search page.',
    };
  }
}

/// 搜索页面中经安全过滤后可返回给 AI 的结果条目。
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
      title: json['title'] as String? ?? '',
      url: json['url'] as String? ?? '',
      snippet: json['snippet'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {'title': title, 'url': url, 'snippet': snippet};
  }
}

class _TruncatedText {
  final String value;
  final bool truncated;

  const _TruncatedText(this.value, this.truncated);
}
