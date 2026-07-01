import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

class McpServerSettings {
  static const String defaultHost = '127.0.0.1';
  static const int defaultPort = 38321;
  static const int minPort = 1024;
  static const int maxPort = 65535;

  final bool enabled;
  final String host;
  final int port;
  final String token;
  final bool allowWriteTools;
  final bool requireApprovalForWriteTools;
  final bool enableSse;

  const McpServerSettings({
    this.enabled = false,
    this.host = defaultHost,
    this.port = defaultPort,
    this.token = '',
    this.allowWriteTools = false,
    this.requireApprovalForWriteTools = true,
    this.enableSse = false,
  });

  String get url => 'http://$host:$port/mcp';
  bool get hasToken => token.trim().isNotEmpty;
  bool get hasValidHost => isAllowedHost(host);
  bool get hasValidPort => isValidPort(port);

  McpServerSettings copyWith({
    bool? enabled,
    String? host,
    int? port,
    String? token,
    bool? allowWriteTools,
    bool? requireApprovalForWriteTools,
    bool? enableSse,
  }) {
    return McpServerSettings(
      enabled: enabled ?? this.enabled,
      host: host == null ? this.host : normalizeHost(host),
      port: port ?? this.port,
      token: token ?? this.token,
      allowWriteTools: allowWriteTools ?? this.allowWriteTools,
      requireApprovalForWriteTools:
          requireApprovalForWriteTools ?? this.requireApprovalForWriteTools,
      enableSse: enableSse ?? this.enableSse,
    );
  }

  static String normalizeHost(String host) {
    final normalized = host.trim().toLowerCase();
    return normalized == 'localhost' ? 'localhost' : normalized;
  }

  static bool isAllowedHost(String host) {
    final normalized = normalizeHost(host);
    return normalized == '127.0.0.1' || normalized == 'localhost';
  }

  static bool isValidPort(int port) {
    return port >= minPort && port <= maxPort;
  }

  static int normalizePort(int? port) {
    if (port == null || !isValidPort(port)) {
      return defaultPort;
    }
    return port;
  }

  static String generateToken({int bytes = 32}) {
    final random = Random.secure();
    final data = Uint8List.fromList(
      List<int>.generate(bytes, (_) => random.nextInt(256)),
    );
    return base64UrlEncode(data).replaceAll('=', '');
  }
}
