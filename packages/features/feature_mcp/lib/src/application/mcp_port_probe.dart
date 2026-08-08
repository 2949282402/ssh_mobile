import 'dart:io';

import '../domain/mcp_server_settings.dart';

/// 只允许回环地址的端口探测器；探测 socket 会在 finally 中关闭。
enum McpPortProbeReason {
  available,
  invalidHostOrPort,
  portOccupiedOrUnavailable,
}

class McpPortProbeResult {
  final String host;
  final int port;
  final bool available;
  final McpPortProbeReason reason;
  final String? message;

  const McpPortProbeResult({
    required this.host,
    required this.port,
    required this.available,
    required this.reason,
    this.message,
  });

  Map<String, dynamic> toJson() {
    return {
      'host': host,
      'port': port,
      'available': available,
      'reason': reason.name,
      if (message != null) 'message': message,
    };
  }
}

class McpPortProbe {
  const McpPortProbe();

  Future<McpPortProbeResult> check({
    required String host,
    required int port,
  }) async {
    final normalizedHost = McpServerSettings.normalizeHost(host);
    if (!McpServerSettings.isAllowedHost(normalizedHost) ||
        !McpServerSettings.isValidPort(port)) {
      return McpPortProbeResult(
        host: normalizedHost,
        port: port,
        available: false,
        reason: McpPortProbeReason.invalidHostOrPort,
        message: 'invalid_host_or_port',
      );
    }

    ServerSocket? socket;
    try {
      socket = await ServerSocket.bind(normalizedHost, port, shared: false);
      return McpPortProbeResult(
        host: normalizedHost,
        port: port,
        available: true,
        reason: McpPortProbeReason.available,
      );
    } on SocketException catch (e) {
      return McpPortProbeResult(
        host: normalizedHost,
        port: port,
        available: false,
        reason: McpPortProbeReason.portOccupiedOrUnavailable,
        message: e.message,
      );
    } finally {
      await socket?.close();
    }
  }
}
