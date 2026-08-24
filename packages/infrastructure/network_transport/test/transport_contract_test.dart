import 'package:network_transport/network_transport.dart';
import 'package:test/test.dart';

void main() {
  test('TransportEndpoint round-trips every supported URI scheme', () {
    final cases = <(String, TransportProtocol, String)>[
      ('tcp://host.example:22', TransportProtocol.tcp, ''),
      ('udp://127.0.0.1:5353', TransportProtocol.udp, ''),
      ('quic://peer.example:443', TransportProtocol.quic, ''),
      (
        'wss://relay.example:8443/v2/relay/session-a',
        TransportProtocol.webSocketRelay,
        '/v2/relay/session-a',
      ),
    ];

    for (final (wire, protocol, path) in cases) {
      final endpoint = TransportEndpoint.fromUri(Uri.parse(wire));

      expect(endpoint.protocol, protocol);
      expect(endpoint.path, path);
      expect(endpoint.uri.toString(), wire);
      expect(endpoint.toString(), wire);
    }
  });

  test('TransportEndpoint rejects unknown, missing, and extreme ports', () {
    expect(
      () => TransportEndpoint.fromUri(Uri.parse('ftp://host.example:21')),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => TransportEndpoint.fromUri(Uri.parse('tcp://:22')),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => TransportEndpoint.fromUri(Uri.parse('tcp://host.example')),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => TransportEndpoint.fromUri(Uri.parse('tcp://host.example:65536')),
      throwsA(isA<FormatException>()),
    );
    expect(
      () =>
          TransportEndpoint(protocol: TransportProtocol.tcp, host: '', port: 1),
      throwsA(isA<AssertionError>()),
    );
    expect(
      () => TransportEndpoint(
        protocol: TransportProtocol.tcp,
        host: 'host.example',
        port: 0,
      ),
      throwsA(isA<AssertionError>()),
    );
    expect(
      () => TransportEndpoint(
        protocol: TransportProtocol.tcp,
        host: 'host.example',
        port: 65536,
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test(
    'TransportEndpoint equality and hash include protocol, host, port, path',
    () {
      const first = TransportEndpoint(
        protocol: TransportProtocol.webSocketRelay,
        host: 'relay.example',
        port: 443,
        path: '/v2/relay/a',
      );
      const equal = TransportEndpoint(
        protocol: TransportProtocol.webSocketRelay,
        host: 'relay.example',
        port: 443,
        path: '/v2/relay/a',
      );
      const different = TransportEndpoint(
        protocol: TransportProtocol.webSocketRelay,
        host: 'relay.example',
        port: 443,
        path: '/v2/relay/b',
      );

      expect(first, equal);
      expect(first.hashCode, equal.hashCode);
      expect(first, isNot(different));
      expect(first, isNot(equals(Object())));
    },
  );

  test(
    'NetworkMetricSnapshot preserves optional latency and byte extremes',
    () {
      final capturedAt = DateTime.utc(2026, 8, 22);
      final empty = NetworkMetricSnapshot(capturedAt: capturedAt);
      final full = NetworkMetricSnapshot(
        capturedAt: capturedAt,
        roundTripTime: const Duration(microseconds: 1),
        bytesSent: 1 << 40,
        bytesReceived: 1 << 40,
      );

      expect(empty.roundTripTime, isNull);
      expect(empty.bytesSent, 0);
      expect(empty.bytesReceived, 0);
      expect(full.capturedAt, capturedAt);
      expect(full.roundTripTime, const Duration(microseconds: 1));
      expect(full.bytesSent, 1 << 40);
      expect(full.bytesReceived, 1 << 40);
      expect(
        () => NetworkMetricSnapshot(capturedAt: capturedAt, bytesSent: -1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => NetworkMetricSnapshot(capturedAt: capturedAt, bytesReceived: -1),
        throwsA(isA<AssertionError>()),
      );
    },
  );
}
