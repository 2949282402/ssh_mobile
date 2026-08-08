// AI WebView Port 使用的结果模型。
//
// 这里只保存工具需要的结构化快照，不引入 webview_flutter；实际页面、
// Controller 生命周期和 URL 安全策略属于后续 WebView Module。

const int aiWebViewDefaultMaxChars = 40000;

final class AiWebViewSnapshot {
  const AiWebViewSnapshot({
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

  Map<String, dynamic> toJson() => {
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
  };
}

final class AiWebViewStateSnapshot {
  const AiWebViewStateSnapshot({
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

  Map<String, dynamic> toJson() => {
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
  };
}

final class AiWebViewNavigationResult {
  const AiWebViewNavigationResult({
    required this.chatId,
    required this.supported,
    required this.action,
    required this.navigated,
    required this.blocked,
    this.input,
    this.error,
    this.state,
  });

  final String chatId;
  final bool supported;
  final String action;
  final String? input;
  final bool navigated;
  final bool blocked;
  final String? error;
  final AiWebViewStateSnapshot? state;

  Map<String, dynamic> toJson() => {
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
  };
}

final class AiWebViewSearchResult {
  const AiWebViewSearchResult({
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

  final String chatId;
  final bool supported;
  final String query;
  final String engine;
  final String? searchUrl;
  final String? title;
  final List<AiWebViewSearchItem> results;
  final DateTime? capturedAt;
  final String? error;

  Map<String, dynamic> toJson() => {
    'execution': 'client',
    'target': 'client_webview',
    'provider': 'local_webview',
    'engine': '${engine}_html',
    'chatSessionId': chatId,
    'supported': supported,
    'query': query,
    'searchUrl': searchUrl,
    'title': title,
    'results': results.map((item) => item.toJson()).toList(growable: false),
    'resultCount': results.length,
    'capturedAtLocal': capturedAt?.toIso8601String(),
    if (error != null) 'error': error,
  };
}

final class AiWebViewSearchItem {
  const AiWebViewSearchItem({
    required this.title,
    required this.url,
    required this.snippet,
  });

  final String title;
  final String url;
  final String snippet;

  Map<String, dynamic> toJson() => {
    'title': title,
    'url': url,
    'snippet': snippet,
  };
}
