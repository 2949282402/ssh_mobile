import 'dart:async';
import 'dart:io';

import '../domain/mcp_server_settings.dart';

/// A short-lived reservation created while checking whether a port is free.
abstract interface class McpPortReservation {
  Future<void> close();
}

/// Binds a port for [McpPortProbe].
typedef McpPortBinder =
    Future<McpPortReservation> Function(String host, int port);

Future<McpPortReservation> _bindPort(String host, int port) async {
  return _ServerSocketReservation(
    await ServerSocket.bind(host, port, shared: false),
  );
}

final class _ServerSocketReservation implements McpPortReservation {
  _ServerSocketReservation(this._socket);

  final ServerSocket _socket;

  @override
  Future<void> close() => _socket.close();
}

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
  const McpPortProbe({this.bind = _bindPort});

  final McpPortBinder bind;

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

    McpPortReservation? reservation;
    try {
      final pendingReservation = bind(normalizedHost, port);
      try {
        reservation = await pendingReservation.timeout(
          const Duration(seconds: 5),
        );
      } on TimeoutException {
        // A timed-out bind may still complete later. Close that late
        // reservation so the bounded probe does not leak a listening socket.
        unawaited(
          pendingReservation.then<void>(
            (lateReservation) => lateReservation.close(),
            onError: (Object _, StackTrace _) {},
          ),
        );
        return McpPortProbeResult(
          host: normalizedHost,
          port: port,
          available: false,
          reason: McpPortProbeReason.portOccupiedOrUnavailable,
          message: 'port_probe_timeout',
        );
      }
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
      await reservation?.close();
    }
  }
}
