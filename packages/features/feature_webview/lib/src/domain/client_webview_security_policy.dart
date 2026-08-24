// Client WebView URL and resolved-address policy.
//
// This unit is platform-independent so every caller applies the same
// canonical host and globally-routable-address checks.

/// WebView 输入、导航和 AI 读取共用的 URL 安全策略。
class ClientWebViewSecurityPolicy {
  static const _blockedSchemes = {'file', 'data', 'javascript', 'intent'};
  static const _blockedHostSuffixes = {
    '.home',
    '.internal',
    '.invalid',
    '.lan',
    '.local',
    '.localdomain',
    '.localhost',
    '.test',
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
    if (hostCandidate.contains('.') ||
        hostCandidate.contains(':') ||
        RegExp(r'^(?:\d+|0x[0-9a-f]+)$').hasMatch(hostCandidate)) {
      final candidate = Uri.tryParse('https://$trimmed');
      if (candidate == null) return 'Blocked invalid URL input.';
      return blockedUriReason(candidate);
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
    if (uri.userInfo.isNotEmpty) {
      return 'Blocked URL credentials.';
    }
    try {
      if (uri.hasPort && (uri.port < 1 || uri.port > 65535)) {
        return 'Blocked invalid URL port.';
      }
    } on FormatException {
      return 'Blocked invalid URL port.';
    }
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return 'Blocked URL without a host.';
    if (_isBlockedHost(host)) {
      return 'Blocked local, private, or metadata host: $host';
    }
    final ipv4 = _parseStrictIpv4(host);
    if (ipv4 == null && _looksLikeNonStandardIpv4(host)) {
      return 'Blocked non-standard IPv4 address: $host';
    }
    if (ipv4 != null && !_isGloballyRoutableIpv4(ipv4)) {
      return 'Blocked non-global IPv4 address: $host';
    }
    final ipv6 = _parseIpv6(host);
    if (ipv6 != null && !_isGloballyRoutableIpv6(ipv6)) {
      return 'Blocked non-global IPv6 address: $host';
    }
    if (host.contains(':') && ipv6 == null) {
      return 'Blocked invalid IPv6 address: $host';
    }
    if (ipv4 == null && ipv6 == null && !_isValidDnsName(host)) {
      return 'Blocked invalid or local DNS host: $host';
    }
    return null;
  }

  /// Validates one address returned by DNS. Every answer must pass before a
  /// request may be connected to an explicitly pinned address.
  static String? blockedResolvedAddressReason(String address) {
    final normalized = address.trim().toLowerCase();
    final ipv4 = _parseStrictIpv4(normalized);
    if (ipv4 != null) {
      return _isGloballyRoutableIpv4(ipv4)
          ? null
          : 'DNS resolved to a non-global IPv4 address.';
    }
    final ipv6 = _parseIpv6(normalized);
    if (ipv6 != null) {
      return _isGloballyRoutableIpv6(ipv6)
          ? null
          : 'DNS resolved to a non-global IPv6 address.';
    }
    return 'DNS returned an invalid IP address.';
  }

  static bool isIpLiteral(String host) {
    final normalized = host.trim().toLowerCase();
    return _parseStrictIpv4(normalized) != null ||
        _parseIpv6(normalized) != null;
  }

  static bool _isBlockedHost(String host) {
    var normalized = host.trim().toLowerCase();
    while (normalized.endsWith('.')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    if (normalized.isEmpty) return false;
    if (normalized == 'localhost' ||
        normalized == 'metadata' ||
        normalized == 'metadata.google.internal' ||
        normalized == 'metadata.azure.internal') {
      return true;
    }
    return _blockedHostSuffixes.any(normalized.endsWith);
  }

  static List<int>? _parseStrictIpv4(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return null;
    final octets = <int>[];
    for (final part in parts) {
      if (part.isEmpty ||
          (part.length > 1 && part.startsWith('0')) ||
          !RegExp(r'^\d+$').hasMatch(part)) {
        return null;
      }
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return null;
      octets.add(value);
    }
    return octets;
  }

  static bool _looksLikeNonStandardIpv4(String host) {
    final normalized = host.endsWith('.')
        ? host.substring(0, host.length - 1)
        : host;
    if (RegExp(r'^\d+(?:\.\d+)*$').hasMatch(normalized)) {
      return true;
    }
    return normalized.contains('0x') &&
        RegExp(
          r'^(?:0x[0-9a-f]+|\d+)(?:\.(?:0x[0-9a-f]+|\d+))*$',
        ).hasMatch(normalized);
  }

  static bool _isGloballyRoutableIpv4(List<int> value) {
    final first = value[0];
    final second = value[1];
    final third = value[2];
    if (first == 0 || first == 10 || first == 127) return false;
    if (first == 100 && second >= 64 && second <= 127) return false;
    if (first == 169 && second == 254) return false;
    if (first == 172 && second >= 16 && second <= 31) return false;
    if (first == 192 && second == 0 && third == 0) return false;
    if (first == 192 && second == 0 && third == 2) return false;
    if (first == 192 && second == 168) return false;
    if (first == 192 && second == 88 && third == 99) return false;
    if (first == 198 && (second == 18 || second == 19)) return false;
    if (first == 198 && second == 51 && third == 100) return false;
    if (first == 203 && second == 0 && third == 113) return false;
    if (first >= 224) return false;
    return true;
  }

  static List<int>? _parseIpv6(String host) {
    var normalized = host;
    if (normalized.startsWith('[') && normalized.endsWith(']')) {
      normalized = normalized.substring(1, normalized.length - 1);
    }
    if (!normalized.contains(':') || normalized.contains('%')) return null;
    if (normalized.contains('.')) return null;
    final compressionIndex = normalized.indexOf('::');
    if (compressionIndex != normalized.lastIndexOf('::')) return null;
    final leftText = compressionIndex < 0
        ? normalized
        : normalized.substring(0, compressionIndex);
    final rightText = compressionIndex < 0
        ? ''
        : normalized.substring(compressionIndex + 2);
    final left = leftText.isEmpty ? <String>[] : leftText.split(':');
    final right = rightText.isEmpty ? <String>[] : rightText.split(':');
    if ([...left, ...right].any(
      (part) =>
          part.isEmpty ||
          part.length > 4 ||
          !RegExp(r'^[0-9a-f]+$').hasMatch(part),
    )) {
      return null;
    }
    if (compressionIndex < 0 && left.length != 8) return null;
    if (compressionIndex >= 0 && left.length + right.length >= 8) return null;
    final groups = <int>[
      for (final part in left) int.parse(part, radix: 16),
      if (compressionIndex >= 0)
        ...List<int>.filled(8 - left.length - right.length, 0),
      for (final part in right) int.parse(part, radix: 16),
    ];
    if (groups.length != 8) return null;
    return [
      for (final group in groups) ...[group >> 8, group & 0xff],
    ];
  }

  static bool _isGloballyRoutableIpv6(List<int> bytes) {
    if (bytes.length != 16 || (bytes[0] & 0xe0) != 0x20) return false;
    if (_hasIpv6Prefix(bytes, [0x20, 0x01, 0x00], 23) ||
        _hasIpv6Prefix(bytes, [0x20, 0x01, 0x0d, 0xb8], 32) ||
        _hasIpv6Prefix(bytes, [0x20, 0x02], 16) ||
        _hasIpv6Prefix(bytes, [0x3f, 0xff, 0x00], 20)) {
      return false;
    }
    return true;
  }

  static bool _hasIpv6Prefix(List<int> address, List<int> prefix, int bits) {
    final fullBytes = bits ~/ 8;
    for (var index = 0; index < fullBytes; index++) {
      if (address[index] != prefix[index]) return false;
    }
    final remainingBits = bits % 8;
    if (remainingBits == 0) return true;
    final mask = 0xff << (8 - remainingBits);
    return (address[fullBytes] & mask) == (prefix[fullBytes] & mask);
  }

  static bool _isValidDnsName(String host) {
    var normalized = host;
    while (normalized.endsWith('.')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    if (normalized.length > 253 || !normalized.contains('.')) return false;
    final labels = normalized.split('.');
    return labels.every(
      (label) =>
          label.isNotEmpty &&
          label.length <= 63 &&
          RegExp(r'^[a-z0-9-]+$').hasMatch(label) &&
          !label.startsWith('-') &&
          !label.endsWith('-'),
    );
  }
}
