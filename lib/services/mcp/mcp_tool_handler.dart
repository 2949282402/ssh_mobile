import 'dart:convert';

import '../ai_tool_service.dart';
import '../app_log_service.dart';
import 'mcp_ai_tool_adapter.dart';
import 'mcp_json_rpc.dart';
import 'mcp_server_settings.dart';
import 'mcp_tool_exposure_policy.dart';

class McpToolHandler {
  final AiToolExecutor aiToolService;
  final McpServerSettings Function() settingsProvider;
  final bool Function() hasChatSession;
  final McpAiToolAdapter adapter;
  final McpToolExposurePolicy exposurePolicy;

  const McpToolHandler({
    required this.aiToolService,
    required this.settingsProvider,
    this.hasChatSession = _defaultNoChatSession,
    this.adapter = const McpAiToolAdapter(),
    this.exposurePolicy = const McpToolExposurePolicy(),
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
    return {'tools': exposed};
  }

  Future<Map<String, dynamic>> _callTool(Map<String, dynamic>? params) async {
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
      return _toolError({
        'error': 'unknown_tool',
        'tool': name,
      });
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
      return _toolError({
        'error': 'tool_not_available',
        'tool': name,
        'reason': decision.reason,
      });
    }
    if (decision.result == McpToolPolicyResult.approvalRequired) {
      AppLogService.instance.warning(
        'MCP dangerous tool blocked',
        details: 'tool=$name reason=${decision.reason}',
      );
      return _approvalRequired(name, decision);
    }

    final approvalRequest =
        await aiToolService.approvalRequestFor(name, arguments);
    if (approvalRequest != null) {
      AppLogService.instance.warning(
        'MCP approval-aware tool blocked',
        details: 'tool=$name approvalType=${approvalRequest.approvalType}',
      );
      return _toolError({
        'error': 'approval_required',
        'tool': name,
        'reason': approvalRequest.reason,
        'approvalType': approvalRequest.approvalType,
        'destructive': approvalRequest.destructive,
      });
    }

    try {
      final text = await aiToolService.execute(name, arguments);
      final isError = _looksLikeToolError(text);
      return {
        'content': [
          {'type': 'text', 'text': text},
        ],
        'isError': isError,
      };
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'MCP tool execution failed',
        error: e,
        stackTrace: stackTrace,
        details: 'tool=$name',
      );
      return _toolError({
        'error': 'tool_execution_failed',
        'tool': name,
        'message': e.toString(),
      });
    }
  }

  Map<String, dynamic> _approvalRequired(
    String name,
    McpToolPolicyDecision decision,
  ) {
    return _toolError({
      'error': 'approval_required',
      'tool': name,
      'reason': decision.reason,
      'approvalType': decision.approvalType,
      'destructive': decision.destructive,
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
}
