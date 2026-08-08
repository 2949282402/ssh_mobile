import 'package:flutter_test/flutter_test.dart';
import 'package:feature_mcp/feature_mcp.dart';

void main() {
  group('McpAuthGuard', () {
    const guard = McpAuthGuard();

    test('rejects missing Authorization', () {
      final result = guard.authorize(
        authorizationHeader: null,
        originHeader: null,
        token: 'secret',
        port: 38321,
      );

      expect(result.allowed, isFalse);
      expect(result.statusCode, 401);
    });

    test('rejects wrong Bearer token', () {
      final result = guard.authorize(
        authorizationHeader: 'Bearer wrong',
        originHeader: null,
        token: 'secret',
        port: 38321,
      );

      expect(result.allowed, isFalse);
      expect(result.statusCode, 401);
    });

    test('accepts correct Bearer token', () {
      final result = guard.authorize(
        authorizationHeader: 'Bearer secret',
        originHeader: null,
        token: 'secret',
        port: 38321,
      );

      expect(result.allowed, isTrue);
    });

    test('rejects invalid Origin', () {
      final result = guard.authorize(
        authorizationHeader: 'Bearer secret',
        originHeader: 'http://192.168.1.20:38321',
        token: 'secret',
        port: 38321,
      );

      expect(result.allowed, isFalse);
      expect(result.statusCode, 403);
    });

    test('accepts localhost Origin', () {
      final result = guard.authorize(
        authorizationHeader: 'Bearer secret',
        originHeader: 'http://localhost:38321',
        token: 'secret',
        port: 38321,
      );

      expect(result.allowed, isTrue);
    });

    test('accepts missing Origin', () {
      final result = guard.authorize(
        authorizationHeader: 'Bearer secret',
        originHeader: null,
        token: 'secret',
        port: 38321,
      );

      expect(result.allowed, isTrue);
    });
  });
}
