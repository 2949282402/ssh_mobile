import 'package:flutter_test/flutter_test.dart';
import 'package:feature_mcp/feature_mcp.dart';

void main() {
  group('McpLifecycleHandler', () {
    const handler = McpLifecycleHandler();

    test('initialize returns protocolVersion and tools capability', () {
      final result = handler.handle(
        const McpJsonRpcRequest(id: 1, hasId: true, method: 'initialize'),
      );

      final body = result.result as Map<String, dynamic>;
      expect(body['protocolVersion'], McpLifecycleHandler.protocolVersion);
      expect(body['capabilities'], {
        'tools': {'listChanged': false},
      });
      expect(body['serverInfo'], containsPair('name', 'ssh_mobile'));
    });

    test('initialized notification returns no response', () {
      final result = handler.handle(
        const McpJsonRpcRequest(
          id: null,
          hasId: false,
          method: 'notifications/initialized',
        ),
      );

      expect(result.noResponse, isTrue);
    });

    test('ping returns empty result', () {
      final result = handler.handle(
        const McpJsonRpcRequest(id: 'p', hasId: true, method: 'ping'),
      );

      expect(result.result, isEmpty);
    });
  });
}
