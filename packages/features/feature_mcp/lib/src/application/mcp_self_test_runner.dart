// MCP loopback 协议自检及其短生命周期 HTTP transport。

import 'dart:async';
import 'dart:io';

import '../domain/mcp_activity.dart';
import 'mcp_lifecycle_handler.dart';

/// MCP 自检结果。
class McpSelfTestResult {
  const McpSelfTestResult({
    required this.serverReachable,
    required this.authenticated,
    required this.initialized,
    required this.toolsListed,
    required this.durationMs,
    this.failureCode,
  });

  final bool serverReachable;
  final bool authenticated;
  final bool initialized;
  final bool toolsListed;
  final int durationMs;
  final String? failureCode;

  bool get succeeded =>
      serverReachable && authenticated && initialized && toolsListed;
}

/// 自检 transport 单次请求的稳定结果。
final class McpSelfTestResponse {
  const McpSelfTestResponse({
    required this.reachable,
    required this.statusCode,
    required this.succeeded,
  });

  final bool reachable;
  final int? statusCode;
  final bool succeeded;
}

/// MCP 自检使用的最小请求边界。
abstract interface class McpSelfTestTransport {
  Future<McpSelfTestResponse> postJson({
    required Uri url,
    required String token,
    required Map<String, dynamic> body,
  });
}

/// 编排 MCP initialize 与 tools/list，并只记录稳定协议结果。
final class McpSelfTestRunner {
  const McpSelfTestRunner({
    required this.transport,
    required this.activityRecorder,
  });

  final McpSelfTestTransport transport;
  final McpActivityRecorder activityRecorder;

  Future<McpSelfTestResult> run({
    required bool serverRunning,
    required Uri url,
    required Future<String> Function() loadToken,
  }) async {
    final watch = Stopwatch()..start();
    if (!serverRunning) {
      return _failure(
        watch,
        'server_not_running',
        serverReachable: false,
        authenticated: false,
      );
    }

    final token = await loadToken();
    final initialize = await transport.postJson(
      url: url,
      token: token,
      body: const {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {'protocolVersion': McpLifecycleHandler.protocolVersion},
      },
    );
    if (!initialize.reachable) {
      return _failure(
        watch,
        'connection_failed',
        serverReachable: false,
        authenticated: false,
      );
    }
    if (initialize.statusCode == HttpStatus.unauthorized ||
        initialize.statusCode == HttpStatus.forbidden) {
      return _failure(
        watch,
        'authentication_failed',
        serverReachable: true,
        authenticated: false,
      );
    }
    if (!initialize.succeeded) {
      return _failure(
        watch,
        'initialize_failed',
        serverReachable: true,
        authenticated: true,
      );
    }

    final toolsListed = await transport.postJson(
      url: url,
      token: token,
      body: const {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
    );
    if (!toolsListed.succeeded) {
      return _failure(
        watch,
        'tools_list_failed',
        serverReachable: toolsListed.reachable,
        authenticated: toolsListed.reachable,
        initialized: true,
      );
    }

    watch.stop();
    final result = McpSelfTestResult(
      serverReachable: true,
      authenticated: true,
      initialized: true,
      toolsListed: true,
      durationMs: watch.elapsedMilliseconds,
    );
    unawaited(
      activityRecorder.record(
        kind: McpActivityKind.protocol,
        outcome: McpActivityOutcome.success,
        method: 'self_test',
        durationMs: result.durationMs,
      ),
    );
    return result;
  }

  McpSelfTestResult _failure(
    Stopwatch watch,
    String code, {
    required bool serverReachable,
    required bool authenticated,
    bool initialized = false,
  }) {
    watch.stop();
    final result = McpSelfTestResult(
      serverReachable: serverReachable,
      authenticated: authenticated,
      initialized: initialized,
      toolsListed: false,
      durationMs: watch.elapsedMilliseconds,
      failureCode: code,
    );
    unawaited(
      activityRecorder.record(
        kind: McpActivityKind.protocol,
        outcome: McpActivityOutcome.failed,
        method: 'self_test',
        policyReason: code,
        durationMs: result.durationMs,
      ),
    );
    return result;
  }
}
