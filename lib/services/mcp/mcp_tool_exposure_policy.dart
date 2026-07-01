import '../ai_tool_service.dart';
import 'mcp_ai_tool_adapter.dart';
import 'mcp_server_settings.dart';

enum McpToolPolicyResult {
  exposed,
  hidden,
  approvalRequired,
  blocked,
}

class McpToolPolicyDecision {
  final McpToolPolicyResult result;
  final String reason;
  final String approvalType;
  final bool destructive;

  const McpToolPolicyDecision({
    required this.result,
    required this.reason,
    this.approvalType = 'mcp_write_tool',
    this.destructive = false,
  });

  bool get canList =>
      result == McpToolPolicyResult.exposed ||
      result == McpToolPolicyResult.approvalRequired;
  bool get canExecute => result == McpToolPolicyResult.exposed;
}

class McpToolExposurePolicy {
  static const Set<String> defaultRequireApprovalTools = {
    'run_command',
    'ssh_open_session',
    'ssh_close_session',
    'ssh_close_server_sessions',
    'ssh_restore_tmux_sessions',
    'ssh_delete_terminal_history_record',
    'sftp_read_text',
    'sftp_download_file',
    'sftp_write_text',
    'sftp_upload_local_file',
    'sftp_create_directory',
    'sftp_rename_entry',
    'sftp_delete_entry',
    'update_server_metadata',
    'delete_server',
    'reorder_servers',
    'create_playbook',
    'run_playbook',
    'app_update_operational_settings',
    'app_clear_secret_cache',
    'client_import_app_backup',
    'client_clear_logs',
    'client_delete_log_entries',
    'client_save_experience_skill',
    'client_update_skill',
    'client_task_skip',
    'monitor_start',
    'monitor_stop',
    'monitor_stop_for_connection',
    'monitor_set_interval',
    'monitor_set_history_window',
    'monitor_set_selected_servers',
    'monitor_clear_selection',
  };

  static const Set<String> defaultHideTools = {
    'client_set_plan_mode',
    'client_task_create',
    'client_task_update',
    'client_task_retry',
  };

  final McpAiToolAdapter adapter;

  const McpToolExposurePolicy({
    this.adapter = const McpAiToolAdapter(),
  });

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

    final destructive = _isDestructive(tool);
    final writeLike = _isWriteLike(tool) ||
        destructive ||
        defaultRequireApprovalTools.contains(tool.name);
    if (writeLike) {
      if (!settings.allowWriteTools) {
        return McpToolPolicyDecision(
          result: McpToolPolicyResult.approvalRequired,
          reason: 'write_tools_disabled',
          approvalType: _approvalTypeFor(tool),
          destructive: destructive,
        );
      }
      if (settings.requireApprovalForWriteTools || destructive) {
        return McpToolPolicyDecision(
          result: McpToolPolicyResult.approvalRequired,
          reason: destructive
              ? 'destructive_tool_requires_approval'
              : 'write_tool_requires_approval',
          approvalType: _approvalTypeFor(tool),
          destructive: destructive,
        );
      }
    }

    return const McpToolPolicyDecision(
      result: McpToolPolicyResult.exposed,
      reason: 'safe_read_only',
    );
  }

  bool _isWriteLike(AiTool tool) {
    return tool.executionMode == AiToolExecutionMode.stateChanging ||
        tool.executionMode == AiToolExecutionMode.executionOnly;
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
