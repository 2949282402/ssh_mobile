part of '../client_webview_service.dart';

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
  String _searchEngine = 'baidu';

  ClientWebViewSession._({
    required this.chatId,
    required this.controller,
    required this.createdAt,
    required this.supported,
    required DateTime updatedAt,
    required String? url,
    String searchEngine = 'baidu',
  })  : _updatedAt = updatedAt,
        _url = url,
        _searchEngine = searchEngine;

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

class ClientWebViewSecurityPolicy {
  static const _blockedSchemes = {
    'file',
    'data',
    'javascript',
    'intent',
  };

  const ClientWebViewSecurityPolicy._();

  static String? blockedInputReason(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;
    final parsed = Uri.tryParse(trimmed);
    final scheme = parsed?.scheme.toLowerCase() ?? '';
    if (scheme.isNotEmpty && scheme != 'http' && scheme != 'https') {
      return 'Blocked URL scheme: $scheme';
    }
    if (parsed != null && (scheme == 'http' || scheme == 'https')) {
      return blockedUriReason(parsed);
    }
    if (trimmed.contains(' ')) return null;
    final hostCandidate = trimmed.toLowerCase();
    if (_isBlockedHost(hostCandidate)) {
      return 'Blocked local, private, or metadata host: $trimmed';
    }
    return null;
  }

  static String? blockedUriReason(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    if (_blockedSchemes.contains(scheme)) {
      return 'Blocked URL scheme: $scheme';
    }
    if (scheme != 'http' && scheme != 'https') {
      return 'Unsupported URL scheme: $scheme';
    }
    final host = uri.host.toLowerCase();
    if (_isBlockedHost(host)) {
      return 'Blocked local, private, or metadata host: $host';
    }
    return null;
  }

  static bool _isBlockedHost(String host) {
    final normalized = host.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    if (normalized == 'localhost' ||
        normalized == '0.0.0.0' ||
        normalized == '::1' ||
        normalized == '[::1]' ||
        normalized == 'metadata.google.internal') {
      return true;
    }
    final parts = normalized.split('.');
    if (parts.length != 4) return false;
    final octets = <int>[];
    for (final part in parts) {
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return false;
      octets.add(value);
    }
    if (octets[0] == 10 || octets[0] == 127 || octets[0] == 0) return true;
    if (octets[0] == 192 && octets[1] == 168) return true;
    if (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) {
      return true;
    }
    if (octets[0] == 169 && octets[1] == 254) return true;
    if (octets[0] == 100 &&
        octets[1] == 100 &&
        octets[2] == 100 &&
        octets[3] == 200) {
      return true;
    }
    return false;
  }
}

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
    return {
      'title': title,
      'url': url,
      'snippet': snippet,
    };
  }
}

class _TruncatedText {
  final String value;
  final bool truncated;

  const _TruncatedText(this.value, this.truncated);
}
