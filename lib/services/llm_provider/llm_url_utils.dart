import 'dart:core';

class LlmUrlUtils {
  static String resolveOpenAiCompatibleUrl(String baseUrl, String path) {
    final trimmedBase = baseUrl
        .trim()
        .split(RegExp(r'[?#]'))
        .first
        .replaceFirst(RegExp(r'/+$'), '');
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final uri = Uri.tryParse(trimmedBase);
    if (uri == null) return '$trimmedBase$normalizedPath';

    final basePath = uri.path.replaceFirst(RegExp(r'/+$'), '');
    if (basePath.endsWith(normalizedPath)) return trimmedBase;
    const chatPath = '/chat/completions';
    const modelsPath = '/models';
    if (normalizedPath == modelsPath && basePath.endsWith(chatPath)) {
      final nextPath =
          '${basePath.substring(0, basePath.length - chatPath.length)}$modelsPath';
      return uri
          .replace(path: nextPath, query: null, fragment: null)
          .toString();
    }
    if (normalizedPath == chatPath && basePath.endsWith(modelsPath)) {
      final nextPath =
          '${basePath.substring(0, basePath.length - modelsPath.length)}$chatPath';
      return uri
          .replace(path: nextPath, query: null, fragment: null)
          .toString();
    }
    return '$trimmedBase$normalizedPath';
  }

  static bool looksLikeToolUnsupportedError(String body) {
    final lower = body.toLowerCase();
    return lower.contains('tool_choice') ||
        lower.contains('"tools"') ||
        lower.contains("'tools'") ||
        lower.contains('tools is not supported') ||
        lower.contains('tool calls') ||
        lower.contains('function calling');
  }

  static String resolveAnthropicUrl(String baseUrl, String path) {
    final cleanBase = baseUrl
        .trim()
        .split(RegExp(r'[?#]'))
        .first
        .replaceFirst(RegExp(r'/+$'), '');
    final targetEndpoint = path.replaceFirst(RegExp(r'^/v1/'), '');
    if (cleanBase.endsWith('/v1/messages') ||
        cleanBase.endsWith('/v1/models')) {
      final baseWithoutEndpoint =
          cleanBase.substring(0, cleanBase.lastIndexOf('/'));
      return '$baseWithoutEndpoint/$targetEndpoint';
    } else if (cleanBase.endsWith('/v1')) {
      return '$cleanBase/$targetEndpoint';
    } else {
      final normalizedPath = path.startsWith('/') ? path : '/$path';
      return '$cleanBase$normalizedPath';
    }
  }
}
