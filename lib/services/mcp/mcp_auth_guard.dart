class McpAuthResult {
  final bool allowed;
  final int statusCode;
  final String reason;

  const McpAuthResult.allowed()
      : allowed = true,
        statusCode = 200,
        reason = 'allowed';

  const McpAuthResult.rejected({
    required this.statusCode,
    required this.reason,
  }) : allowed = false;
}

class McpAuthGuard {
  const McpAuthGuard();

  McpAuthResult authorize({
    required String? authorizationHeader,
    required String? originHeader,
    required String token,
    required int port,
  }) {
    final expectedToken = token.trim();
    if (expectedToken.isEmpty) {
      return const McpAuthResult.rejected(
        statusCode: 401,
        reason: 'missing_server_token',
      );
    }

    final header = authorizationHeader?.trim();
    const prefix = 'Bearer ';
    if (header == null || !header.startsWith(prefix)) {
      return const McpAuthResult.rejected(
        statusCode: 401,
        reason: 'missing_authorization',
      );
    }
    final suppliedToken = header.substring(prefix.length).trim();
    if (!_constantTimeEquals(suppliedToken, expectedToken)) {
      return const McpAuthResult.rejected(
        statusCode: 401,
        reason: 'invalid_token',
      );
    }

    final origin = originHeader?.trim();
    if (origin != null &&
        origin.isNotEmpty &&
        !_isAllowedOrigin(origin, port)) {
      return const McpAuthResult.rejected(
        statusCode: 403,
        reason: 'invalid_origin',
      );
    }

    return const McpAuthResult.allowed();
  }

  bool _isAllowedOrigin(String origin, int port) {
    final uri = Uri.tryParse(origin);
    if (uri == null || uri.scheme != 'http') return false;
    final host = uri.host.toLowerCase();
    if (host != 'localhost' && host != '127.0.0.1') return false;
    return uri.hasPort && uri.port == port;
  }

  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
