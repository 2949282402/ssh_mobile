import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/mcp_activity.dart';
import '../domain/mcp_auth_guard.dart';
import '../domain/mcp_ports.dart';
import 'mcp_json_rpc.dart';

/// The request data consumed by [McpHttpRequestHandler].
///
/// Keeping this boundary independent from [HttpRequest] lets protocol and
/// policy tests run without asking the Flutter test runner to bind a socket.
final class McpHttpRequestData {
  const McpHttpRequestData({
    required this.path,
    required this.method,
    required this.contentType,
    required this.authorization,
    required this.origin,
    required this.body,
  });

  final String path;
  final String method;
  final ContentType? contentType;
  final String? authorization;
  final String? origin;
  final Future<String> body;
}

/// The response data produced by [McpHttpRequestHandler].
final class McpHttpResponseData {
  const McpHttpResponseData({
    required this.statusCode,
    this.body,
    this.contentType,
    this.headers = const {},
  });

  final int statusCode;
  final String? body;
  final ContentType? contentType;
  final Map<String, String> headers;
}

/// Handles MCP HTTP semantics without owning a listening socket.
final class McpHttpRequestHandler {
  McpHttpRequestHandler({
    required this.port,
    required this.token,
    required this.router,
    this.authGuard = const McpAuthGuard(),
    this.activityRecorder,
    this.logger,
  });

  final int port;
  final String token;
  final McpJsonRpcRouter router;
  final McpAuthGuard authGuard;
  final McpActivityRecorder? activityRecorder;
  final McpLoggerPort? logger;

  Future<McpHttpResponseData> handle(McpHttpRequestData request) async {
    try {
      if (request.path != '/mcp') {
        _recordSecurity('invalid_path');
        return const McpHttpResponseData(statusCode: HttpStatus.notFound);
      }

      if (request.method != 'POST') {
        _recordSecurity('method_not_allowed');
        return const McpHttpResponseData(
          statusCode: HttpStatus.methodNotAllowed,
          headers: {HttpHeaders.allowHeader: 'POST'},
        );
      }

      final contentType = request.contentType;
      if (contentType == null ||
          contentType.mimeType.toLowerCase() != 'application/json') {
        _recordSecurity('unsupported_media_type');
        return const McpHttpResponseData(
          statusCode: HttpStatus.unsupportedMediaType,
        );
      }

      final auth = authGuard.authorize(
        authorizationHeader: request.authorization,
        originHeader: request.origin,
        token: token,
        port: port,
      );
      if (!auth.allowed) {
        _recordSecurity(auth.reason);
        logger?.warning(
          'MCP unauthorized request rejected',
          details: 'reason=${auth.reason}',
        );
        return McpHttpResponseData(statusCode: auth.statusCode);
      }

      final body = await request.body;
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
      return McpHttpResponseData(
        statusCode: result.statusCode,
        body: result.hasBody ? jsonEncode(result.body) : null,
        contentType: result.hasBody ? ContentType.json : null,
      );
    } catch (e, stackTrace) {
      _recordSecurity('request_failed', outcome: McpActivityOutcome.failed);
      logger?.error(
        'MCP HTTP request failed',
        error: e,
        stackTrace: stackTrace,
      );
      return const McpHttpResponseData(
        statusCode: HttpStatus.internalServerError,
      );
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

/// The lifecycle surface a controller needs from an MCP HTTP server.
abstract interface class McpHttpServerHandle {
  Future<void> close({bool force = true});
}

class McpHttpServer implements McpHttpServerHandle {
  final HttpServer _server;
  final McpHttpRequestHandler _handler;
  final McpActivityRecorder? _activityRecorder;
  final McpLoggerPort? _logger;
  late final StreamSubscription<HttpRequest> _subscription;

  McpHttpServer._({
    required this._server,
    required this._handler,
    required this._activityRecorder,
    required this._logger,
  }) {
    _subscription = _server.listen(
      _handleRequest,
      onError: (Object error, StackTrace stackTrace) {
        _logger?.error(
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
    final server = await HttpServer.bind(
      host,
      port,
      shared: false,
    ).timeout(const Duration(seconds: 5));
    return McpHttpServer._(
      server: server,
      handler: McpHttpRequestHandler(
        port: server.port,
        token: token,
        router: router,
        authGuard: authGuard,
        activityRecorder: activityRecorder,
        logger: logger,
      ),
      activityRecorder: activityRecorder,
      logger: logger,
    );
  }

  @override
  Future<void> close({bool force = true}) async {
    await _subscription.cancel();
    await _server.close(force: force);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    try {
      final result = await _handler.handle(
        McpHttpRequestData(
          path: request.uri.path,
          method: request.method,
          contentType: request.headers.contentType,
          authorization: request.headers.value(HttpHeaders.authorizationHeader),
          origin: request.headers.value('origin'),
          body: utf8.decoder.bind(request).join(),
        ),
      );
      response.statusCode = result.statusCode;
      for (final entry in result.headers.entries) {
        response.headers.set(entry.key, entry.value);
      }
      if (result.contentType != null) {
        response.headers.contentType = result.contentType;
      }
      if (result.body != null) response.write(result.body);
      await response.close();
    } catch (e, stackTrace) {
      _recordRequestFailure(e, stackTrace);
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

  void _recordRequestFailure(Object error, StackTrace stackTrace) {
    final recorder = _activityRecorder;
    if (recorder != null) {
      unawaited(
        recorder.record(
          kind: McpActivityKind.security,
          outcome: McpActivityOutcome.failed,
          policyReason: 'request_failed',
        ),
      );
    }
    _logger?.error(
      'MCP HTTP request failed',
      error: error,
      stackTrace: stackTrace,
    );
  }
}
