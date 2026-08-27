import 'telemetry_catalog.dart';

/// The result of applying the telemetry schema and privacy boundary.
///
/// Telemetry is deliberately fail closed: an event with an unknown property,
/// a value of the wrong schema type, or an unsafe identifier is rejected by
/// the caller instead of being uploaded with an unreviewed shape.
final class TelemetryRedactor {
  const TelemetryRedactor();

  /// Stable replacement used for secret and private-data fragments.
  static const String redacted = '[REDACTED]';

  /// Keep diagnostic values bounded even when an exception contains a large
  /// response body or a generated command transcript.
  static const int maxTextLength = 512;

  static final RegExp _pemPrivateKey = RegExp(
    r'-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----',
    caseSensitive: false,
  );
  static final RegExp _bearerOrBasic = RegExp(
    r'\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+',
    caseSensitive: false,
  );
  static final RegExp _jwt = RegExp(
    r'\b[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b',
  );
  static final RegExp _authorizationHeader = RegExp(
    r'\bAuthorization\s*:\s*[^\r\n,;]+',
    caseSensitive: false,
  );
  static final RegExp _cookieHeader = RegExp(
    r'\b(?:Cookie|Set-Cookie)\s*:\s*[^\r\n]+',
    caseSensitive: false,
  );
  static final RegExp _apiKeyHeader = RegExp(
    r'\b(?:x-api-key|api-key)\s*:\s*[^\r\n,;]+',
    caseSensitive: false,
  );
  static final RegExp _secretAssignment = RegExp(
    r'''(["']?\b(?:password|passwd|pwd|passphrase|private[_-]?key|api[_-]?key|x-api-key|access[_-]?token|refresh[_-]?token|client[_-]?secret|token|secret|username|user[_-]?name|user|login|host|host[_-]?name|ssh[_-]?host|ip|ip[_-]?address|command|command[_-]?line|args?|arguments?|content|path|filename|credential(?:s)?|auth(?:orization)?|jwt|bearer)["']?\s*[:=]\s*)("[^"]*"|'[^']*'|[^,\s}\]]+)''',
    caseSensitive: false,
  );
  static final RegExp _secretWord = RegExp(
    r'''(\b(?:password|passwd|pwd|passphrase|private[_-]?key|api[_-]?key|x-api-key|access[_-]?token|refresh[_-]?token|client[_-]?secret|token|secret|username|user[_-]?name|user|login|host|host[_-]?name|ssh[_-]?host|ip|ip[_-]?address|command|command[_-]?line|args?|arguments?|content|path|filename|credential(?:s)?|auth(?:orization)?|jwt|bearer)\s+)("[^"]*"|'[^']*'|[^,\s}\]]+)''',
    caseSensitive: false,
  );
  static final RegExp _urlSecretQuery = RegExp(
    r'([?&](?:password|passwd|pwd|passphrase|username|user[_-]?name|user|host|host[_-]?name|ssh[_-]?host|ip|ip[_-]?address|command|command[_-]?line|args?|arguments?|content|path|access_token|refresh_token|client_secret|api[_-]?key|x-api-key|token|secret|credential(?:s)?|auth(?:orization)?|jwt|bearer)=)[^&#\s]+',
    caseSensitive: false,
  );
  static final RegExp _uriAuthority = RegExp(
    r'\b([a-z][a-z0-9+.-]*://)[^/\s]+(?:/[^\s]*)?',
    caseSensitive: false,
  );
  static final RegExp _userAtHost = RegExp(
    r'\b[A-Za-z0-9._-]{1,64}@[A-Za-z0-9._:-]{1,255}\b',
  );
  static final RegExp _ipv4 = RegExp(
    r'(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])',
  );
  static final RegExp _ipv6 = RegExp(
    r'(?<![A-Za-z0-9])[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?![A-Za-z0-9])',
  );
  static final RegExp _unixPath = RegExp(
    r'(?<![A-Za-z0-9])/(?:[^\s/]+/)*[^\s/]+(?:/[^\s]*)?',
  );
  static final RegExp _windowsPath = RegExp(r'\b[A-Za-z]:\\[^\s]+');
  static final RegExp _homePath = RegExp(r'(?<![A-Za-z0-9])~[/\\][^\s]+');
  static final RegExp _uncPath = RegExp(r'(?<![A-Za-z0-9])\\\\[^\s]+');
  static final RegExp _packagePath = RegExp(r'\bpackage:[^\s)]+');
  static final RegExp _pathWithSpaces = RegExp(
    r'''(?<![A-Za-z0-9])(?:[A-Za-z]:\\|\\\\|~[/\\]|\.\.?[/\\]|/(?:[^/|;,\r\n]+/)*|(?:[A-Za-z0-9_.-]+[/\\])+)[^|;,\r\n]+''',
  );
  static final RegExp _relativePath = RegExp(
    r'(?<![A-Za-z0-9._-])(?:\.{1,2}/|(?:lib|bin|src|packages|apps|home|tmp|var|etc|users|data)/)[^\s]+',
    caseSensitive: false,
  );
  static final RegExp _dnsHost = RegExp(
    r'(?<![A-Za-z0-9.-])(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,63}(?::\d{1,5})?(?![A-Za-z0-9.-])',
    caseSensitive: false,
  );
  static final RegExp _localhostHost = RegExp(
    r'(?<![A-Za-z0-9.-])localhost(?::\d{1,5})?(?![A-Za-z0-9.-])',
    caseSensitive: false,
  );
  static final RegExp _bareHostWithPort = RegExp(
    r'(?<![A-Za-z0-9.-])[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?:\d{1,5}(?![A-Za-z0-9.-])',
    caseSensitive: false,
  );
  static final RegExp _bareHost = RegExp(
    r'(?<![A-Za-z0-9._-])[A-Za-z0-9-]*(?:host|server|node|gateway|router|machine|jumpbox)[A-Za-z0-9-]*(?![A-Za-z0-9._-])',
    caseSensitive: false,
  );
  static final RegExp _knownToken = RegExp(
    r'\b(?:sk-(?:proj-)?[A-Za-z0-9_-]{12,}|ASIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{16,})\b',
    caseSensitive: false,
  );
  static final RegExp _environmentSecretAssignment = RegExp(
    r'''(["']?\b(?:OPENAI_API_KEY|AWS_SECRET_ACCESS_KEY|AWS_ACCESS_KEY_ID|AZURE_CLIENT_SECRET|GOOGLE_APPLICATION_CREDENTIALS)["']?\s*[:=]\s*)("[^"]*"|'[^']*'|[^,\s}\]]+)''',
    caseSensitive: false,
  );
  static final RegExp _shellCommand = RegExp(
    r'(?<![A-Za-z0-9])(?:sudo\s+)?(?:ssh|scp|sftp|curl|wget|nc|netcat|rm|cat|echo|bash|sh|zsh|powershell|cmd(?:\.exe)?|chmod|chown|find|grep|git|python(?:3)?|node(?:js)?|kubectl)\b[^\r\n]*',
    caseSensitive: false,
  );
  static final RegExp _safeLabel = RegExp(r'^[A-Za-z][A-Za-z0-9_.:_-]{0,63}$');
  static final RegExp _safeIdentifier = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$',
  );

  /// Applies the event's explicit property allowlist and primitive types.
  ///
  /// A `null` result means the input must not be recorded. The returned map is
  /// a fresh map, so callers cannot mutate a value after it enters the record
  /// queue. Nested objects and arrays are intentionally not supported by the
  /// telemetry contract.
  Map<String, dynamic>? sanitizeProperties(
    TelemetryEventDefinition event,
    Map<String, dynamic> properties,
  ) {
    final output = <String, dynamic>{};
    for (final entry in properties.entries) {
      final key = entry.key;
      final type = event.propertyTypes[key];
      if (!event.allowedProperties.contains(key) || type == null) {
        return null;
      }

      final value = entry.value;
      switch (type) {
        case 'string':
          if (value is! String) return null;
          final sanitized = sanitizePropertyText(key, value);
          if (sanitized == null) return null;
          output[key] = sanitized;
        case 'integer':
          // bool is not an int in Dart, but keeping this explicit documents the
          // wire contract and rejects doubles before JSON encoding can coerce.
          if (value is! int || value is bool) return null;
          output[key] = value;
        case 'boolean':
          if (value is! bool) return null;
          output[key] = value;
        default:
          return null;
      }
    }

    for (final required in event.requiredProperties) {
      if (!output.containsKey(required)) return null;
    }
    return Map<String, dynamic>.unmodifiable(output);
  }

  /// Redacts a free-form property while retaining harmless diagnostic labels.
  String? sanitizePropertyText(String key, String value) {
    if (!_safeLabel.hasMatch(key) || value.isEmpty) {
      return value.isEmpty ? '' : null;
    }

    // Labels such as stage/provider/direction have no reason to carry free
    // form text. Rejecting them avoids smuggling a host or username through a
    // field that appears harmless to downstream consumers.
    final freeForm =
        key == 'message' ||
        key == 'details' ||
        key == 'reason' ||
        key == 'direct_error';
    if (!freeForm && !_safeLabel.hasMatch(value)) return null;
    return sanitizeText(value);
  }

  /// Redacts exception text without serializing the original exception object.
  String? sanitizeExceptionText(String? value) {
    if (value == null || value.isEmpty) return null;
    return sanitizeText(value);
  }

  /// Redacts a stack trace before it becomes part of a diagnostic envelope.
  String? sanitizeStackTrace(String? value) {
    if (value == null || value.isEmpty) return null;
    return sanitizeText(value);
  }

  /// Validates an ID that is carried as diagnostic correlation metadata.
  ///
  /// IDs are not free-form text. Rejecting rather than redacting them keeps
  /// event correlation deterministic and prevents a credential from entering
  /// a trace/session field.
  String? sanitizeIdentifier(String? value) {
    if (value == null || value.isEmpty || !_safeIdentifier.hasMatch(value)) {
      return null;
    }
    if (_containsSensitiveFragment(value)) return null;
    return value;
  }

  /// Returns a bounded, privacy-safe representation of free-form text.
  String sanitizeText(String value) {
    var text = value;
    text = text.replaceAll(_pemPrivateKey, redacted);
    text = text.replaceAll(_authorizationHeader, 'Authorization: $redacted');
    text = text.replaceAll(_cookieHeader, 'Cookie: $redacted');
    text = text.replaceAll(_apiKeyHeader, 'api-key: $redacted');
    text = text.replaceAll(_bearerOrBasic, redacted);
    text = text.replaceAll(_jwt, redacted);
    text = text.replaceAll(_knownToken, redacted);
    text = text.replaceAllMapped(_environmentSecretAssignment, (match) {
      return '${match.group(1)}$redacted';
    });
    text = text.replaceAllMapped(_secretAssignment, (match) {
      return '${match.group(1)}$redacted';
    });
    text = text.replaceAllMapped(_secretWord, (match) {
      return '${match.group(1)}$redacted';
    });
    text = text.replaceAllMapped(_urlSecretQuery, (match) {
      return '${match.group(1)}$redacted';
    });
    text = text.replaceAllMapped(_uriAuthority, (match) {
      return '${match.group(1)}$redacted';
    });
    text = text.replaceAll(_userAtHost, redacted);
    text = text.replaceAll(_ipv4, redacted);
    text = text.replaceAll(_ipv6, redacted);
    text = text.replaceAll(_dnsHost, redacted);
    text = text.replaceAll(_localhostHost, redacted);
    text = text.replaceAll(_bareHostWithPort, redacted);
    text = text.replaceAll(_bareHost, redacted);
    text = text.replaceAll(_packagePath, redacted);
    text = text.replaceAll(_pathWithSpaces, redacted);
    text = text.replaceAll(_windowsPath, redacted);
    text = text.replaceAll(_homePath, redacted);
    text = text.replaceAll(_uncPath, redacted);
    text = text.replaceAll(_relativePath, redacted);
    text = text.replaceAll(_unixPath, redacted);
    text = text.replaceAll(_shellCommand, redacted);

    if (text.length <= maxTextLength) return text;
    return '${text.substring(0, maxTextLength)}...[truncated]';
  }

  bool _containsSensitiveFragment(String value) {
    final normalized = value.toLowerCase();
    return normalized.contains('password') ||
        normalized.contains('token') ||
        normalized.contains('secret') ||
        normalized.contains('credential') ||
        normalized.contains('authorization') ||
        normalized.contains('private') ||
        normalized.contains('bearer') ||
        normalized.contains('username') ||
        normalized.contains('command') ||
        normalized.contains('content') ||
        normalized.contains('path') ||
        _knownToken.hasMatch(value) ||
        _localhostHost.hasMatch(value) ||
        _bareHostWithPort.hasMatch(value) ||
        _bareHost.hasMatch(value) ||
        _dnsHost.hasMatch(value) ||
        _ipv4.hasMatch(value) ||
        _ipv6.hasMatch(value);
  }
}
