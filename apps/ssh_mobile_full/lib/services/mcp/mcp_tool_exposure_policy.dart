import '../ai_tool_service.dart';
import 'mcp_ai_tool_adapter.dart';
import 'mcp_server_settings.dart';

enum McpToolPolicyResult { exposed, hidden, blocked }

class McpToolPolicyDecision {
  final McpToolPolicyResult result;
  final String reason;
  final String approvalType;
  final bool destructive;
  final bool configurable;

  const McpToolPolicyDecision({
    required this.result,
    required this.reason,
    this.approvalType = 'mcp_write_tool',
    this.destructive = false,
    this.configurable = false,
  });

  bool get canList => result == McpToolPolicyResult.exposed;
  bool get canExecute => result == McpToolPolicyResult.exposed;
}

class McpToolExposurePolicy {
  static const Set<String> defaultHideTools = {
    'client_set_plan_mode',
    'client_task_create',
    'client_task_update',
    'client_task_retry',
  };

  final McpAiToolAdapter adapter;

  const McpToolExposurePolicy({this.adapter = const McpAiToolAdapter()});

  McpToolPolicyDecision evaluate(
    AiTool tool, {
    required McpServerSettings settings,
    required bool hasChatSession,
  }) {
    if (tool.needsWebViewSession && !hasChatSession) {
      return const McpToolPolicyDecision(
        result: McpToolPolicyResult.hidden,
        reason: 'webview_session_missing',
      );
    }

    if (defaultHideTools.contains(tool.name) ||
        tool.executionMode == AiToolExecutionMode.planOnly ||
        tool.executionMode == AiToolExecutionMode.planControl) {
      return const McpToolPolicyDecision(
        result: McpToolPolicyResult.hidden,
        reason: 'not_useful_in_mcp_context',
      );
    }

    if (settings.exposureToolsConfigured &&
        !settings.exposedTools.contains(tool.name)) {
      return const McpToolPolicyDecision(
        result: McpToolPolicyResult.hidden,
        reason: 'not_exposed_by_user',
        configurable: true,
      );
    }

    final destructive = _isDestructive(tool);
    return McpToolPolicyDecision(
      result: McpToolPolicyResult.exposed,
      reason: 'exposed',
      approvalType: _approvalTypeFor(tool),
      destructive: destructive,
      configurable: true,
    );
  }

  bool _isDestructive(AiTool tool) {
    final annotations = adapter.toMcpTool(tool)['annotations'];
    return annotations is Map && annotations['destructiveHint'] == true;
  }

  String _approvalTypeFor(AiTool tool) {
    final name = tool.name;
    if (name.startsWith('sftp_') || name == 'run_command') {
      return 'remote_write';
    }
    if (name.startsWith('ssh_')) {
      return 'ssh_session_change';
    }
    if (name.startsWith('monitor_')) {
      return 'monitor_state_change';
    }
    if (name.contains('playbook')) {
      return 'playbook_change';
    }
    if (name.startsWith('client_') || name.startsWith('app_')) {
      return 'local_app_change';
    }
    return 'mcp_write_tool';
  }
}
