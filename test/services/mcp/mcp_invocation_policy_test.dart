import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/mcp/mcp_invocation_policy.dart';
import 'package:ssh_mobile/services/mcp/mcp_server_settings.dart';

void main() {
  const policy = McpInvocationPolicy();

  AiTool tool(
    String name, {
    AiToolExecutionMode mode = AiToolExecutionMode.readOnly,
  }) {
    return AiTool(
      name: name,
      description: name,
      properties: const {},
      executionMode: mode,
      handler: (_) async => '{}',
    );
  }

  test(
    'trustedAgent executes read-only, state-changing, and destructive tools',
    () {
      const settings = McpServerSettings(
        approvalMode: McpApprovalMode.trustedAgent,
      );
      for (final value in [
        tool('list_servers'),
        tool('monitor_start', mode: AiToolExecutionMode.stateChanging),
        tool('sftp_delete_entry', mode: AiToolExecutionMode.stateChanging),
      ]) {
        expect(
          policy.evaluate(tool: value, settings: settings).action,
          McpInvocationAction.execute,
        );
      }
    },
  );

  test('review mode reviews configured tools', () {
    const settings = McpServerSettings(secondaryReviewTools: {'monitor_start'});
    expect(
      policy
          .evaluate(
            tool: tool(
              'monitor_start',
              mode: AiToolExecutionMode.stateChanging,
            ),
            settings: settings,
          )
          .action,
      McpInvocationAction.secondaryApproval,
    );
    expect(
      policy.evaluate(tool: tool('list_servers'), settings: settings).action,
      McpInvocationAction.execute,
    );
  });

  test('changing the configured set changes the decision immediately', () {
    final toolValue = AiTool(
      name: 'run_command',
      description: 'Run command',
      properties: const {},
      executionMode: AiToolExecutionMode.stateChanging,
      handler: (_) async => '{}',
    );
    // A state-changing tool outside the configured review set is denied
    // (fail-closed) rather than executed silently.
    final settings = const McpServerSettings(secondaryReviewTools: {});
    expect(
      policy.evaluate(tool: toolValue, settings: settings).action,
      McpInvocationAction.denied,
    );
    final updated = settings.copyWith(secondaryReviewTools: {'run_command'});
    expect(
      policy.evaluate(tool: toolValue, settings: updated).action,
      McpInvocationAction.secondaryApproval,
    );
  });

  test('review mode denies state-changing tools outside the review set', () {
    const settings = McpServerSettings(secondaryReviewTools: {'run_command'});
    expect(
      policy
          .evaluate(
            tool: tool(
              'ssh_rename_session',
              mode: AiToolExecutionMode.stateChanging,
            ),
            settings: settings,
          )
          .action,
      McpInvocationAction.denied,
    );
  });

  test('review mode executes read-only tools outside the review set', () {
    const settings = McpServerSettings(secondaryReviewTools: {});
    expect(
      policy.evaluate(tool: tool('list_servers'), settings: settings).action,
      McpInvocationAction.execute,
    );
  });

  test('read-only execution mode is authoritative over MCP annotations', () {
    const settings = McpServerSettings(secondaryReviewTools: {});
    expect(
      policy
          .evaluate(tool: tool('client_clear_logs'), settings: settings)
          .action,
      McpInvocationAction.execute,
    );
  });

  test('default review set includes SSH session connection tools', () {
    expect(
      McpInvocationPolicy.defaultSecondaryReviewTools,
      contains('ssh_ensure_session_connected'),
    );
    const settings = McpServerSettings();
    expect(
      policy
          .evaluate(
            tool: tool(
              'ssh_ensure_session_connected',
              mode: AiToolExecutionMode.stateChanging,
            ),
            settings: settings,
          )
          .action,
      McpInvocationAction.secondaryApproval,
    );
  });

  test('MCP settings expose an immutable secondary review set', () {
    final settings = McpServerSettings(secondaryReviewTools: {'run_command'});

    expect(
      () => settings.secondaryReviewTools.add('monitor_start'),
      throwsUnsupportedError,
    );
  });

  test('MCP settings expose an immutable explicit exposure set', () {
    final settings = McpServerSettings(
      exposedTools: {'run_command'},
      exposureToolsConfigured: true,
    );

    expect(
      () => settings.exposedTools.add('monitor_start'),
      throwsUnsupportedError,
    );
    expect(settings.isToolExposed('run_command'), isTrue);
    expect(settings.isToolExposed('monitor_start'), isFalse);
  });
}
