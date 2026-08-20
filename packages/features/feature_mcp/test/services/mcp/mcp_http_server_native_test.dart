@Tags(['native-loopback'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:feature_mcp/feature_mcp.dart';

void main() {
  test('McpHttpServer serves initialize over native loopback', () async {
    final server = await McpHttpServer.bind(
      host: '127.0.0.1',
      port: 0,
      token: 'secret',
      router: McpJsonRpcRouter(
        lifecycleHandler: const McpLifecycleHandler(),
        toolHandler: McpToolHandler(
          aiToolService: _NativeTestToolExecutor(),
          settingsProvider: () => const McpServerSettings(token: 'secret'),
        ),
      ),
    );
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..findProxy = (_) => 'DIRECT';

    try {
      final request = await client
          .postUrl(Uri.parse('http://127.0.0.1:${server.port}/mcp'))
          .timeout(const Duration(seconds: 5));
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer secret');
      request.write(
        jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'}),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      final body = jsonDecode(await utf8.decoder.bind(response).join()) as Map;

      expect(response.statusCode, HttpStatus.ok);
      expect(body['result']['serverInfo']['name'], 'ssh_mobile');
    } finally {
      client.close(force: true);
      await server.close();
    }
  });
}

class _NativeTestToolExecutor implements McpToolExecutor {
  @override
  Future<List<McpTool>> tools() async => const [];

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async => const [];

  @override
  Future<McpApprovalRequest?> approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    return null;
  }

  @override
  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async {
    return '{}';
  }
}
