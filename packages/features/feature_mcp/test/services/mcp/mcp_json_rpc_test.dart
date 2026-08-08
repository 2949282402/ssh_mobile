import 'package:flutter_test/flutter_test.dart';
import 'package:feature_mcp/feature_mcp.dart';

void main() {
  group('McpJsonRpc', () {
    test('parses valid request', () {
      final request = McpJsonRpc.parse(
        '{"jsonrpc":"2.0","id":1,"method":"ping","params":{"a":1}}',
      );

      expect(request.id, 1);
      expect(request.hasId, isTrue);
      expect(request.method, 'ping');
      expect(request.params, {'a': 1});
    });

    test('parses valid notification', () {
      final request = McpJsonRpc.parse(
        '{"jsonrpc":"2.0","method":"notifications/initialized"}',
      );

      expect(request.isNotification, isTrue);
      expect(request.id, isNull);
      expect(request.method, 'notifications/initialized');
    });

    test('rejects invalid JSON', () {
      expect(
        () => McpJsonRpc.parse('{'),
        throwsA(
          isA<McpJsonRpcException>().having(
            (e) => e.code,
            'code',
            McpJsonRpcErrorCodes.parseError,
          ),
        ),
      );
    });

    test('rejects missing jsonrpc', () {
      expect(
        () => McpJsonRpc.parse('{"id":1,"method":"ping"}'),
        throwsA(
          isA<McpJsonRpcException>().having(
            (e) => e.code,
            'code',
            McpJsonRpcErrorCodes.invalidRequest,
          ),
        ),
      );
    });

    test('rejects missing method', () {
      expect(
        () => McpJsonRpc.parse('{"jsonrpc":"2.0","id":1}'),
        throwsA(
          isA<McpJsonRpcException>().having(
            (e) => e.code,
            'code',
            McpJsonRpcErrorCodes.invalidRequest,
          ),
        ),
      );
    });

    test('builds success response', () {
      expect(McpJsonRpc.successResponse('abc', {'ok': true}), {
        'jsonrpc': '2.0',
        'id': 'abc',
        'result': {'ok': true},
      });
    });

    test('builds error response', () {
      expect(
        McpJsonRpc.errorResponse(
          id: null,
          code: McpJsonRpcErrorCodes.methodNotFound,
          message: 'Method not found',
        ),
        {
          'jsonrpc': '2.0',
          'id': null,
          'error': {
            'code': McpJsonRpcErrorCodes.methodNotFound,
            'message': 'Method not found',
          },
        },
      );
    });
  });
}
