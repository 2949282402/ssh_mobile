import '../ai_tool_service.dart';
import 'mcp_server_settings.dart';

enum McpInvocationAction { execute, secondaryApproval, denied }

class McpInvocationDecision {
  final McpInvocationAction action;
  final String reason;

  const McpInvocationDecision({required this.action, required this.reason});
}

/// Decides whether an already-exposed external MCP tool call needs the app's
/// interactive approval queue. Exposure and hard security checks happen
/// before this policy is evaluated.
class McpInvocationPolicy {
  static const Set<String> defaultSecondaryReviewTools = {
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

  const McpInvocationPolicy();

  McpInvocationDecision evaluate({
    required AiTool tool,
    required McpServerSettings settings,
  }) {
    switch (settings.approvalMode) {
      case McpApprovalMode.trustedAgent:
        return const McpInvocationDecision(
          action: McpInvocationAction.execute,
          reason: 'trusted_agent_mode',
        );
      case McpApprovalMode.reviewConfiguredTools:
        if (settings.secondaryReviewTools.contains(tool.name)) {
          return const McpInvocationDecision(
            action: McpInvocationAction.secondaryApproval,
            reason: 'configured_secondary_review',
          );
        }
        return const McpInvocationDecision(
          action: McpInvocationAction.execute,
          reason: 'tool_not_configured_for_secondary_review',
        );
    }
  }
}
