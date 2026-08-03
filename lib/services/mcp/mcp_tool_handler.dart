import 'dart:convert';
import 'dart:async';

import '../ai_tool_service.dart';
import '../app_log_service.dart';
import 'mcp_ai_tool_adapter.dart';
import 'mcp_activity.dart';
import 'mcp_approval_queue.dart';
import 'mcp_invocation_policy.dart';
import 'mcp_json_rpc.dart';
import 'mcp_server_settings.dart';
import 'mcp_tool_exposure_policy.dart';

class McpToolHandler {
  final AiToolExecutor aiToolService;
  final McpServerSettings Function() settingsProvider;
  final bool Function() hasChatSession;
  final McpAiToolAdapter adapter;
  final McpToolExposurePolicy exposurePolicy;
  final McpInvocationPolicy invocationPolicy;
  final McpActivityRecorder? activityRecorder;
  final McpApprovalQueue? approvalQueue;

  const McpToolHandler({
    required this.aiToolService,
    required this.settingsProvider,
    this.hasChatSession = _defaultNoChatSession,
    this.adapter = const McpAiToolAdapter(),
    this.exposurePolicy = const McpToolExposurePolicy(),
    this.invocationPolicy = const McpInvocationPolicy(),
    this.activityRecorder,
    this.approvalQueue,
  });

  static bool _defaultNoChatSession() => false;

  bool canHandle(String method) {
    return method == 'tools/list' || method == 'tools/call';
  }

  Future<McpJsonRpcHandlerResult> handle(McpJsonRpcRequest request) async {
    switch (request.method) {
      case 'tools/list':
        return McpJsonRpcHandlerResult.result(await _listTools());
      case 'tools/call':
        return McpJsonRpcHandlerResult.result(await _callTool(request.params));
    }
    throw McpJsonRpcException(
      McpJsonRpcErrorCodes.methodNotFound,
      'Method not found',
      id: request.id,
    );
  }

  Future<Map<String, dynamic>> _listTools() async {
    final watch = Stopwatch()..start();
    AppLogService.instance.info('MCP tools/list called');
    final settings = settingsProvider();
    final tools = await aiToolService.tools();
    final exposed = <Map<String, dynamic>>[];
    for (final tool in tools) {
      final decision = exposurePolicy.evaluate(
        tool,
        settings: settings,
        hasChatSession: hasChatSession(),
      );
      if (decision.canList) {
        exposed.add(adapter.toMcpTool(tool));
      }
    }
    watch.stop();
    _record(
      kind: McpActivityKind.protocol,
      outcome: McpActivityOutcome.success,
      method: 'tools/list',
      durationMs: watch.elapsedMilliseconds,
    );
    return {'tools': exposed};
  }

  Future<Map<String, dynamic>> _callTool(Map<String, dynamic>? params) async {
    final watch = Stopwatch()..start();
    AppLogService.instance.info('MCP tools/call called');
    if (params == null) {
      throw const McpJsonRpcException(
        McpJsonRpcErrorCodes.invalidParams,
        'Invalid params',
      );
    }
    final name = params['name'];
    if (name is! String || name.trim().isEmpty) {
      throw const McpJsonRpcException(
        McpJsonRpcErrorCodes.invalidParams,
        'Invalid params',
      );
    }
    final rawArguments = params['arguments'];
    if (rawArguments != null && rawArguments is! Map) {
      throw const McpJsonRpcException(
        McpJsonRpcErrorCodes.invalidParams,
        'Invalid params',
      );
    }
    final arguments = <String, dynamic>{};
    if (rawArguments is Map) {
      for (final entry in rawArguments.entries) {
        if (entry.key is String) {
          arguments[entry.key as String] = entry.value;
        }
      }
    }

    final tools = await aiToolService.tools();
    final matches = tools.where((tool) => tool.name == name).toList();
    if (matches.isEmpty) {
      watch.stop();
      _record(
        kind: McpActivityKind.tool,
        outcome: McpActivityOutcome.denied,
        method: 'tools/call',
        toolName: name,
        policyReason: 'unknown_tool',
        durationMs: watch.elapsedMilliseconds,
      );
      return _toolError({'error': 'unknown_tool', 'tool': name});
    }

    final tool = matches.first;
    final settings = settingsProvider();
    final decision = exposurePolicy.evaluate(
      tool,
      settings: settings,
      hasChatSession: hasChatSession(),
    );
    if (decision.result == McpToolPolicyResult.hidden ||
        decision.result == McpToolPolicyResult.blocked) {
      AppLogService.instance.warning(
        'MCP hidden tool blocked',
        details: 'tool=$name reason=${decision.reason}',
      );
      watch.stop();
      _record(
        kind: McpActivityKind.tool,
        outcome: McpActivityOutcome.denied,
        method: 'tools/call',
        toolName: name,
        policyReason: decision.reason,
        durationMs: watch.elapsedMilliseconds,
      );
      return _toolError({
        'error': 'tool_not_available',
        'tool': name,
        'reason': decision.reason,
      });
    }
    final invocation = invocationPolicy.evaluate(
      tool: tool,
      settings: settings,
    );
    switch (invocation.action) {
      case McpInvocationAction.execute:
        return _executeDirectlyAuthorized(
          name: name,
          arguments: arguments,
          policyReason: invocation.reason,
          decision: decision,
          watch: watch,
        );
      case McpInvocationAction.secondaryApproval:
        return _executeWithSecondaryApproval(
          name: name,
          arguments: arguments,
          policyReason: invocation.reason,
          decision: decision,
          watch: watch,
        );
      case McpInvocationAction.denied:
        watch.stop();
        _record(
          kind: McpActivityKind.tool,
          outcome: McpActivityOutcome.denied,
          method: 'tools/call',
          toolName: name,
          policyReason: invocation.reason,
          durationMs: watch.elapsedMilliseconds,
        );
        return _toolError({
          'error': 'tool_not_available',
          'tool': name,
          'reason': invocation.reason,
        });
    }
  }

  Future<Map<String, dynamic>> _executeDirectlyAuthorized({
    required String name,
    required Map<String, dynamic> arguments,
    required String policyReason,
    required McpToolPolicyDecision decision,
    required Stopwatch watch,
  }) async {
    try {
      final approvalRequest = await aiToolService.approvalRequestFor(
        name,
        arguments,
      );
      final text = approvalRequest == null
          ? await aiToolService.execute(name, arguments, approvedWrite: true)
          : await _executeWithBinding(approvalRequest, arguments, name: name);
      return _toolResult(
        name: name,
        text: text,
        policyReason: policyReason,
        watch: watch,
      );
    } on _ApprovalGuardUnavailableException {
      return _finishError(
        name: name,
        error: 'approval_guard_unavailable',
        policyReason: 'approval_guard_unavailable',
        decision: decision,
        watch: watch,
      );
    } catch (e, stackTrace) {
      return _finishExecutionError(
        name: name,
        error: e,
        stackTrace: stackTrace,
        policyReason: 'tool_execution_failed',
        watch: watch,
      );
    }
  }

  Future<Map<String, dynamic>> _executeWithSecondaryApproval({
    required String name,
    required Map<String, dynamic> arguments,
    required String policyReason,
    required McpToolPolicyDecision decision,
    required Stopwatch watch,
  }) async {
    try {
      final approvalRequest = await aiToolService.approvalRequestFor(
        name,
        arguments,
      );
      if (approvalRequest == null) {
        final text = await aiToolService.execute(
          name,
          arguments,
          approvedWrite: true,
        );
        return _toolResult(
          name: name,
          text: text,
          policyReason: 'configured_secondary_review_not_required',
          watch: watch,
        );
      }

      final queue = approvalQueue;
      final approvalGuard = aiToolService is AiToolApprovalTargetGuard
          ? aiToolService as AiToolApprovalTargetGuard
          : null;
      if (queue == null || approvalGuard == null) {
        return _finishError(
          name: name,
          error: 'approval_required',
          policyReason: 'approval_queue_unavailable',
          decision: decision,
          watch: watch,
        );
      }
      final text = await queue.enqueue(
        request: approvalRequest,
        executeApproved: () =>
            approvalGuard.executeApproved(approvalRequest, arguments),
      );
      return _toolResult(
        name: name,
        text: text,
        policyReason: _looksLikeToolError(text)
            ? 'secondary_approval_rejected'
            : 'secondary_approval_approved',
        watch: watch,
      );
    } catch (e, stackTrace) {
      return _finishExecutionError(
        name: name,
        error: e,
        stackTrace: stackTrace,
        policyReason: 'tool_execution_failed',
        watch: watch,
      );
    }
  }

  Future<String> _executeWithBinding(
    AiToolApprovalRequest request,
    Map<String, dynamic> arguments, {
    required String name,
  }) {
    final guard = aiToolService is AiToolApprovalTargetGuard
        ? aiToolService as AiToolApprovalTargetGuard
        : null;
    if (guard == null) throw _ApprovalGuardUnavailableException(name);
    return guard.executeApproved(request, arguments);
  }

  Map<String, dynamic> _toolResult({
    required String name,
    required String text,
    required String policyReason,
    required Stopwatch watch,
  }) {
    final isError = _looksLikeToolError(text);
    watch.stop();
    _record(
      kind: McpActivityKind.tool,
      outcome: isError ? McpActivityOutcome.failed : McpActivityOutcome.success,
      method: 'tools/call',
      toolName: name,
      policyReason: policyReason,
      durationMs: watch.elapsedMilliseconds,
    );
    return {
      'content': [
        {'type': 'text', 'text': text},
      ],
      'isError': isError,
    };
  }

  Map<String, dynamic> _finishError({
    required String name,
    required String error,
    required String policyReason,
    required McpToolPolicyDecision decision,
    required Stopwatch watch,
  }) {
    watch.stop();
    _record(
      kind: McpActivityKind.tool,
      outcome: McpActivityOutcome.denied,
      method: 'tools/call',
      toolName: name,
      policyReason: policyReason,
      durationMs: watch.elapsedMilliseconds,
    );
    return _toolError({
      'error': error,
      'tool': name,
      'reason': policyReason,
      'approvalType': decision.approvalType,
      'destructive': decision.destructive,
    });
  }

  Map<String, dynamic> _finishExecutionError({
    required String name,
    required Object error,
    required StackTrace stackTrace,
    required String policyReason,
    required Stopwatch watch,
  }) {
    AppLogService.instance.error(
      'MCP tool execution failed',
      error: error,
      stackTrace: stackTrace,
      details: 'tool=$name',
    );
    watch.stop();
    _record(
      kind: McpActivityKind.tool,
      outcome: McpActivityOutcome.failed,
      method: 'tools/call',
      toolName: name,
      policyReason: policyReason,
      durationMs: watch.elapsedMilliseconds,
    );
    return _toolError({
      'error': 'tool_execution_failed',
      'tool': name,
      'message': error.toString(),
    });
  }

  Map<String, dynamic> _toolError(Map<String, dynamic> error) {
    return {
      'content': [
        {'type': 'text', 'text': jsonEncode(error)},
      ],
      'isError': true,
    };
  }

  bool _looksLikeToolError(String text) {
    try {
      final decoded = jsonDecode(text);
      return decoded is Map && decoded.containsKey('error');
    } catch (_) {
      return false;
    }
  }

  void _record({
    required McpActivityKind kind,
    required McpActivityOutcome outcome,
    required String method,
    String? toolName,
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
        toolName: toolName,
        policyReason: policyReason,
        durationMs: durationMs,
      ),
    );
  }
}

class _ApprovalGuardUnavailableException implements Exception {
  final String toolName;

  const _ApprovalGuardUnavailableException(this.toolName);
}
