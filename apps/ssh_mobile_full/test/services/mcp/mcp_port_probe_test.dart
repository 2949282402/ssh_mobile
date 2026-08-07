import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/mcp/mcp_port_probe.dart';

void main() {
  group('McpPortProbe', () {
    const probe = McpPortProbe();

    Future<int> findFreePort() async {
      final socket = await ServerSocket.bind('127.0.0.1', 0);
      final port = socket.port;
      await socket.close();
      return port;
    }

    test('available unused port returns available', () async {
      final port = await findFreePort();
      final result = await probe.check(host: '127.0.0.1', port: port);

      expect(result.available, isTrue);
      expect(result.reason, McpPortProbeReason.available);
    });

    test('occupied port returns unavailable', () async {
      final socket = await ServerSocket.bind('127.0.0.1', 0);
      try {
        final result = await probe.check(host: '127.0.0.1', port: socket.port);

        expect(result.available, isFalse);
        expect(result.reason, McpPortProbeReason.portOccupiedOrUnavailable);
      } finally {
        await socket.close();
      }
    });

    test('invalid port below 1024 returns invalid', () async {
      final result = await probe.check(host: '127.0.0.1', port: 80);

      expect(result.available, isFalse);
      expect(result.reason, McpPortProbeReason.invalidHostOrPort);
    });

    test('invalid port above 65535 returns invalid', () async {
      final result = await probe.check(host: '127.0.0.1', port: 65536);

      expect(result.available, isFalse);
      expect(result.reason, McpPortProbeReason.invalidHostOrPort);
    });

    test('invalid host returns invalid', () async {
      final result = await probe.check(host: '0.0.0.0', port: 38321);

      expect(result.available, isFalse);
      expect(result.reason, McpPortProbeReason.invalidHostOrPort);
    });
  });
}
