import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../app_log_service.dart';
import 'mcp_auth_guard.dart';
import 'mcp_json_rpc.dart';

class McpHttpServer {
  final HttpServer _server;
  final String token;
  final McpJsonRpcRouter router;
  final McpAuthGuard authGuard;
  late final StreamSubscription<HttpRequest> _subscription;

  McpHttpServer._({
    required this._server,
    required this.token,
    required this.router,
    required this.authGuard,
  }) {
    _subscription = _server.listen(
      _handleRequest,
      onError: (Object error, StackTrace stackTrace) {
        AppLogService.instance.error(
          'MCP HTTP server request stream failed',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
  }

  int get port => _server.port;
  InternetAddress get address => _server.address;

  static Future<McpHttpServer> bind({
    required String host,
    required int port,
    required String token,
    required McpJsonRpcRouter router,
    McpAuthGuard authGuard = const McpAuthGuard(),
  }) async {
    final server = await HttpServer.bind(host, port, shared: false);
    return McpHttpServer._(
      server: server,
      token: token,
      router: router,
      authGuard: authGuard,
    );
  }

  Future<void> close({bool force = true}) async {
    await _subscription.cancel();
    await _server.close(force: force);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.uri.path != '/mcp') {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      if (request.method != 'POST') {
        response.statusCode = HttpStatus.methodNotAllowed;
        response.headers.set(HttpHeaders.allowHeader, 'POST');
        await response.close();
        return;
      }

      final contentType = request.headers.contentType;
      if (contentType == null ||
          contentType.mimeType.toLowerCase() != 'application/json') {
        response.statusCode = HttpStatus.unsupportedMediaType;
        await response.close();
        return;
      }

      final auth = authGuard.authorize(
        authorizationHeader: request.headers.value(
          HttpHeaders.authorizationHeader,
        ),
        originHeader: request.headers.value('origin'),
        token: token,
        port: _server.port,
      );
      if (!auth.allowed) {
        AppLogService.instance.warning(
          'MCP unauthorized request rejected',
          details: 'reason=${auth.reason}',
        );
        response.statusCode = auth.statusCode;
        await response.close();
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      final result = await router.route(body);
      response.statusCode = result.statusCode;
      if (result.hasBody) {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(result.body));
      }
      await response.close();
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'MCP HTTP request failed',
        error: e,
        stackTrace: stackTrace,
      );
      try {
        response.statusCode = HttpStatus.internalServerError;
      } catch (_) {
        // The response may already be closing after a partial write.
      }
      try {
        await response.close();
      } catch (_) {}
    }
  }
}
