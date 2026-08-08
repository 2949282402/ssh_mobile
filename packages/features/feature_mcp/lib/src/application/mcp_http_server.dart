import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/mcp_ports.dart';
import '../domain/mcp_auth_guard.dart';
import '../domain/mcp_activity.dart';
import 'mcp_json_rpc.dart';

class McpHttpServer {
  final HttpServer _server;
  final String token;
  final McpJsonRpcRouter router;
  final McpAuthGuard authGuard;
  final McpActivityRecorder? activityRecorder;
  final McpLoggerPort? logger;
  late final StreamSubscription<HttpRequest> _subscription;

  McpHttpServer._({
    required this._server,
    required this.token,
    required this.router,
    required this.authGuard,
    this.activityRecorder,
    this.logger,
  }) {
    _subscription = _server.listen(
      _handleRequest,
      onError: (Object error, StackTrace stackTrace) {
        logger?.error(
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
    McpActivityRecorder? activityRecorder,
    McpLoggerPort? logger,
  }) async {
    final server = await HttpServer.bind(host, port, shared: false);
    return McpHttpServer._(
      server: server,
      token: token,
      router: router,
      authGuard: authGuard,
      activityRecorder: activityRecorder,
      logger: logger,
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
        _recordSecurity('invalid_path');
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      if (request.method != 'POST') {
        _recordSecurity('method_not_allowed');
        response.statusCode = HttpStatus.methodNotAllowed;
        response.headers.set(HttpHeaders.allowHeader, 'POST');
        await response.close();
        return;
      }

      final contentType = request.headers.contentType;
      if (contentType == null ||
          contentType.mimeType.toLowerCase() != 'application/json') {
        _recordSecurity('unsupported_media_type');
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
        _recordSecurity(auth.reason);
        logger?.warning(
          'MCP unauthorized request rejected',
          details: 'reason=${auth.reason}',
        );
        response.statusCode = auth.statusCode;
        await response.close();
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      final method = _methodFromBody(body);
      final watch = Stopwatch()..start();
      final result = await router.route(body);
      watch.stop();
      if (method != null && !method.startsWith('tools/')) {
        final failed =
            result.body is Map && (result.body as Map)['error'] != null;
        _record(
          kind: McpActivityKind.protocol,
          outcome: failed
              ? McpActivityOutcome.failed
              : McpActivityOutcome.success,
          method: method,
          policyReason: failed ? 'json_rpc_error' : null,
          durationMs: watch.elapsedMilliseconds,
        );
      }
      response.statusCode = result.statusCode;
      if (result.hasBody) {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(result.body));
      }
      await response.close();
    } catch (e, stackTrace) {
      _recordSecurity('request_failed', outcome: McpActivityOutcome.failed);
      logger?.error(
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

  String? _methodFromBody(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map && decoded['method'] is String
          ? decoded['method'] as String
          : null;
    } catch (_) {
      return null;
    }
  }

  void _recordSecurity(
    String reason, {
    McpActivityOutcome outcome = McpActivityOutcome.denied,
  }) {
    _record(
      kind: McpActivityKind.security,
      outcome: outcome,
      policyReason: reason,
    );
  }

  void _record({
    required McpActivityKind kind,
    required McpActivityOutcome outcome,
    String? method,
    String? policyReason,
    int? durationMs,
  }) {
    final recorder = activityRecorder;
    if (recorder == null) return;
    unawaited(
      recorder.record(
        kind: kind,
        outcome: outcome,
        method: method,
        policyReason: policyReason,
        durationMs: durationMs,
      ),
    );
  }
}
