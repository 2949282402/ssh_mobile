import 'dart:convert';

class ToolSecretPolicy {
  static const String redacted = '[REDACTED]';

  static final RegExp _pemPrivateKeyPattern = RegExp(
    r'-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----',
    caseSensitive: false,
  );
  static final RegExp _bearerTokenPattern = RegExp(
    r'Bearer\s+[A-Za-z0-9._~+/=-]+',
    caseSensitive: false,
  );
  static final RegExp _basicAuthPattern = RegExp(
    r'Basic\s+[A-Za-z0-9._~+/=-]+',
    caseSensitive: false,
  );
  static final List<RegExp> _headerSecretPatterns = [
    RegExp(
      r'\bAuthorization\s*:\s*(Bearer|Basic)\s+[^\r\n,;]+',
      caseSensitive: false,
    ),
    RegExp(
      r'\b(x-api-key|api-key)\s*:\s*[^\r\n,;]+',
      caseSensitive: false,
    ),
    RegExp(
      r'\b(Cookie|Set-Cookie)\s*:\s*[^\r\n]+',
      caseSensitive: false,
    ),
  ];
  static final RegExp _urlSecretQueryPattern = RegExp(
    r'([?&](?:access_token|refresh_token|client_secret|api[_-]?key|x-api-key|token)=)[^&#\s]+',
    caseSensitive: false,
  );
  static final List<RegExp> _secretAssignmentPatterns = [
    RegExp(
      r'\b(password|passwd|pwd|private[_-]?key|api[_-]?key|x-api-key|access[_-]?token|refresh[_-]?token|client[_-]?secret|token|secret)\b\s*[:=]\s*([^\s,;}\]]+)',
      caseSensitive: false,
    ),
    RegExp(
      r'\b(password|passwd|pwd|private[_-]?key|api[_-]?key|x-api-key|access[_-]?token|refresh[_-]?token|client[_-]?secret|token|secret)\b\s+"([^"]+)"',
      caseSensitive: false,
    ),
    RegExp(
      r"\b(password|passwd|pwd|private[_-]?key|api[_-]?key|x-api-key|access[_-]?token|refresh[_-]?token|client[_-]?secret|token|secret)\b\s+'([^']+)'",
      caseSensitive: false,
    ),
  ];
  static final List<RegExp> _standaloneTokenPatterns = [
    RegExp(r'\bsk-[A-Za-z0-9]{16,}\b'),
    RegExp(r'\bghp_[A-Za-z0-9]{20,}\b', caseSensitive: false),
    RegExp(r'\bgithub_pat_[A-Za-z0-9_]{20,}\b', caseSensitive: false),
    RegExp(r'\bAKIA[0-9A-Z]{16}\b'),
    RegExp(r'\bxox[baprs]-[A-Za-z0-9-]{20,}\b', caseSensitive: false),
  ];
  static final List<RegExp> _suspiciousPathPatterns = [
    RegExp(r'(^|/)\.ssh($|/)'),
    RegExp(r'(^|/)\.aws($|/)'),
    RegExp(r'(^|/)\.kube($|/)'),
    RegExp(r'(^|/)\.docker($|/)'),
    RegExp(r'(^|/)\.env($|[./])'),
    RegExp(r'(^|/)[^/]*\.env($|[./])'),
    RegExp(r'(^|/)[^/]*id_rsa(\.pub)?$'),
    RegExp(r'(^|/)[^/]*id_ed25519(\.pub)?$'),
    RegExp(r'\.(pem|key|p12|jks|keystore)$'),
    RegExp(r'(^|/)etc/(shadow|sudoers)$'),
    RegExp(r'(^|/)proc/[^/]+/environ$'),
    RegExp(
      r'(^|/)[^/]*(token|secret|api[_-]?key|apikey|credentials)[^/]*($|/)',
    ),
  ];
  static final List<RegExp> _environmentDumpPatterns = [
    RegExp(r'(^|\s)env(\s|$)'),
    RegExp(r'(^|\s)printenv(\s|$)'),
    RegExp(r'(^|\s)set(\s|$)'),
    RegExp(r'(^|\s)export(\s|$)'),
    RegExp(r'(^|\s)cmd\s*/c\s+set(\s|$)'),
    RegExp(r'get-childitem\s+env:', caseSensitive: false),
    RegExp(r'get-item\s+env:', caseSensitive: false),
    RegExp(
      r'\[system\.environment\]::getenvironmentvariables\(',
      caseSensitive: false,
    ),
  ];
  static final List<RegExp> _metadataEndpointPatterns = [
    RegExp(r'(^|[^\d])169\.254\.169\.254([^\d]|$)'),
    RegExp(r'(^|[^\d])100\.100\.100\.200([^\d]|$)'),
    RegExp(r'metadata\.google\.internal', caseSensitive: false),
  ];

  const ToolSecretPolicy();

  bool isSensitiveKey(String key) {
    final normalized = key.trim().toLowerCase();
    return normalized == 'password' ||
        normalized == 'passwd' ||
        normalized == 'pwd' ||
        normalized == 'privatekey' ||
        normalized == 'private_key' ||
        normalized == 'token' ||
        normalized == 'access_token' ||
        normalized == 'refresh_token' ||
        normalized == 'apikey' ||
        normalized == 'api_key' ||
        normalized == 'x-api-key' ||
        normalized == 'client_secret' ||
        normalized == 'secret';
  }

  String redactText(String value) {
    var text = value;
    text = text.replaceAll(_pemPrivateKeyPattern, redacted);
    for (final pattern in _headerSecretPatterns) {
      text = text.replaceAllMapped(pattern, (match) {
        final value = match.group(0) ?? '';
        final index = value.indexOf(':');
        if (index <= 0) return redacted;
        return '${value.substring(0, index + 1)} $redacted';
      });
    }
    text = text.replaceAllMapped(_bearerTokenPattern, (_) => redacted);
    text = text.replaceAllMapped(_basicAuthPattern, (_) => redacted);
    for (final pattern in _secretAssignmentPatterns) {
      text = text.replaceAllMapped(pattern, (match) {
        final key = match.group(1) ?? 'secret';
        return '$key=$redacted';
      });
    }
    text = text.replaceAllMapped(_urlSecretQueryPattern, (match) {
      return '${match.group(1)}$redacted';
    });
    for (final pattern in _standaloneTokenPatterns) {
      text = text.replaceAllMapped(pattern, (_) => redacted);
    }
    final normalized = text.replaceAll('\\', '/').toLowerCase();
    if (_looksLikePath(normalized)) {
      for (final pattern in _suspiciousPathPatterns) {
        text = text.replaceAllMapped(pattern, (_) => redacted);
      }
    }
    return text;
  }

  String previewText(String value, {int maxChars = 200}) {
    final redactedText = redactText(value);
    if (redactedText.length <= maxChars) return redactedText;
    return '${redactedText.substring(0, maxChars)}...[truncated]';
  }

  Object? redactValue(
    Object? value, {
    bool truncateLongStrings = false,
    int maxChars = 300,
  }) {
    if (value == null) return null;
    if (value is Map) {
      final output = <String, dynamic>{};
      for (final entry in value.entries) {
        final key = entry.key.toString();
        if (isSensitiveKey(key)) {
          output[key] = redacted;
          continue;
        }
        output[key] = redactValue(
          entry.value,
          truncateLongStrings: truncateLongStrings,
          maxChars: maxChars,
        );
      }
      return output;
    }
    if (value is List) {
      return value
          .map(
            (item) => redactValue(
              item,
              truncateLongStrings: truncateLongStrings,
              maxChars: maxChars,
            ),
          )
          .toList(growable: false);
    }
    if (value is String) {
      if (isSuspiciousPath(value)) {
        return redacted;
      }
      final redactedText = redactText(value);
      if (!truncateLongStrings || redactedText.length <= maxChars) {
        return redactedText;
      }
      return '${redactedText.substring(0, maxChars)}...[truncated]';
    }
    return value;
  }

  String safeJson(
    Object? value, {
    bool truncateLongStrings = false,
    int maxChars = 300,
  }) {
    return jsonEncode(
      redactValue(
        value,
        truncateLongStrings: truncateLongStrings,
        maxChars: maxChars,
      ),
    );
  }

  String redactJsonText(String value) {
    try {
      final decoded = jsonDecode(value);
      return jsonEncode(redactValue(decoded));
    } catch (_) {
      return redactText(value);
    }
  }

  String? suspiciousPathReason(String path) {
    final normalized = path.trim().replaceAll('\\', '/').toLowerCase();
    if (normalized.isEmpty) return null;
    if (!_looksLikeSensitivePathCandidate(normalized)) return null;
    for (final pattern in _suspiciousPathPatterns) {
      if (pattern.hasMatch(normalized)) {
        return 'This path appears to contain secrets or credential material and is blocked by the tool secret policy.';
      }
    }
    return null;
  }

  bool isSuspiciousPath(String path) => suspiciousPathReason(path) != null;

  bool _looksLikePath(String normalized) {
    return normalized.contains('/') ||
        normalized.startsWith('.') ||
        normalized.startsWith('~') ||
        normalized.contains('.env') ||
        normalized.contains('id_rsa') ||
        normalized.contains('id_ed25519') ||
        normalized.endsWith('.pem') ||
        normalized.endsWith('.key') ||
        normalized.endsWith('.p12') ||
        normalized.endsWith('.jks') ||
        normalized.endsWith('.keystore');
  }

  bool _looksLikeSensitivePathCandidate(String normalized) {
    if (normalized == 'tool_secret_policy') return false;
    if (_looksLikePath(normalized)) return true;
    if (RegExp(r'\s').hasMatch(normalized)) return false;
    return normalized.contains('credentials') ||
        normalized.contains('token') ||
        normalized.contains('secret') ||
        normalized.contains('api_key') ||
        normalized.contains('apikey');
  }

  String? blockedCommandReason(String command) {
    final normalized = command.trim().replaceAll('\\', '/').toLowerCase();
    if (normalized.isEmpty) {
      return null;
    }
    for (final pattern in _environmentDumpPatterns) {
      if (pattern.hasMatch(normalized)) {
        return 'Environment variable dumps are blocked by the tool secret policy.';
      }
    }
    if (_metadataEndpointPatterns
        .any((pattern) => pattern.hasMatch(normalized))) {
      return 'Cloud instance metadata endpoints are blocked by the tool secret policy.';
    }
    if (_suspiciousPathPatterns
        .any((pattern) => pattern.hasMatch(normalized))) {
      return 'Commands that reference secret-bearing paths are blocked by the tool secret policy.';
    }
    return null;
  }
}
