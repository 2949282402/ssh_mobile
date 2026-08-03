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
    final settings = const McpServerSettings(secondaryReviewTools: {});
    expect(
      policy.evaluate(tool: toolValue, settings: settings).action,
      McpInvocationAction.execute,
    );
    final updated = settings.copyWith(secondaryReviewTools: {'run_command'});
    expect(
      policy.evaluate(tool: toolValue, settings: updated).action,
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
}
