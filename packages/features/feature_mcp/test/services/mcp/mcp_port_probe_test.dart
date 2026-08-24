import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:feature_mcp/feature_mcp.dart';

void main() {
  group('McpPortProbe', () {
    const probe = McpPortProbe();

    test('available unused port returns available', () async {
      var bindCalls = 0;
      final reservation = _FakeReservation();
      final probe = McpPortProbe(
        bind: (host, port) async {
          bindCalls++;
          return reservation;
        },
      );

      const port = 38321;
      final result = await probe.check(host: '127.0.0.1', port: port);

      expect(result.available, isTrue);
      expect(result.reason, McpPortProbeReason.available);
      expect(bindCalls, 1);
      expect(reservation.closed, isTrue);
    });

    test('occupied port returns unavailable', () async {
      final probe = McpPortProbe(
        bind: (host, port) async {
          throw SocketException('address already in use');
        },
      );

      final result = await probe.check(host: '127.0.0.1', port: 38321);

      expect(result.available, isFalse);
      expect(result.reason, McpPortProbeReason.portOccupiedOrUnavailable);
      expect(result.message, 'address already in use');
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

class _FakeReservation implements McpPortReservation {
  var closed = false;

  @override
  Future<void> close() async {
    closed = true;
  }
}
