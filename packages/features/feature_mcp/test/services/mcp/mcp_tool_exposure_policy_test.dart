import 'package:flutter_test/flutter_test.dart';
import 'package:feature_mcp/feature_mcp.dart';

void main() {
  group('McpToolExposurePolicy', () {
    const policy = McpToolExposurePolicy();
    const settings = McpServerSettings(token: 'token');

    test('exposes read-only tools', () {
      final decision = policy.evaluate(
        const McpTool(
          name: 'list_servers',
          description: 'List servers.',
          properties: {},
        ),
        settings: settings,
        hasChatSession: false,
      );

      expect(decision.result, McpToolPolicyResult.exposed);
      expect(decision.canList, isTrue);
      expect(decision.canExecute, isTrue);
    });

    test(
      'write and destructive tools remain exposed for invocation policy',
      () {
        final decision = policy.evaluate(
          const McpTool(
            name: 'sftp_delete_entry',
            description: 'Delete.',
            properties: {},
            executionMode: McpToolExecutionMode.stateChanging,
          ),
          settings: settings,
          hasChatSession: false,
        );

        expect(decision.result, McpToolPolicyResult.exposed);
        expect(decision.destructive, isTrue);
        expect(decision.reason, 'exposed');
      },
    );

    test('maps approval types for write-like tools', () {
      const cases = <String, String>{
        'run_command': 'remote_write',
        'sftp_write_text': 'remote_write',
        'ssh_open_session': 'ssh_session_change',
        'monitor_start': 'monitor_state_change',
        'run_playbook': 'playbook_change',
        'app_clear_secret_cache': 'local_app_change',
      };
      cases.forEach((name, approvalType) {
        final decision = policy.evaluate(
          McpTool(
            name: name,
            description: name,
            properties: const {},
            executionMode: McpToolExecutionMode.stateChanging,
          ),
          settings: settings,
          hasChatSession: false,
        );
        expect(decision.result, McpToolPolicyResult.exposed);
        expect(decision.approvalType, approvalType);
      });
    });

    test('hides WebView tools without chat session', () {
      final decision = policy.evaluate(
        const McpTool(
          name: 'web_search',
          description: 'Search.',
          properties: {},
          requiresWebViewSession: true,
        ),
        settings: settings,
        hasChatSession: false,
      );

      expect(decision.result, McpToolPolicyResult.hidden);
      expect(decision.canList, isFalse);
    });

    test('hides internal plan-control tools', () {
      final decision = policy.evaluate(
        const McpTool(
          name: 'client_set_plan_mode',
          description: 'Plan mode.',
          properties: {},
          executionMode: McpToolExecutionMode.planControl,
        ),
        settings: settings,
        hasChatSession: false,
      );

      expect(decision.result, McpToolPolicyResult.hidden);
    });

    test('hides tools outside the explicit exposure set', () {
      const settings = McpServerSettings(
        exposedTools: {'list_servers'},
        exposureToolsConfigured: true,
      );
      final decision = policy.evaluate(
        const McpTool(
          name: 'run_command',
          description: 'Run command.',
          properties: {},
          executionMode: McpToolExecutionMode.stateChanging,
        ),
        settings: settings,
        hasChatSession: false,
      );

      expect(decision.result, McpToolPolicyResult.hidden);
      expect(decision.reason, 'not_exposed_by_user');
      expect(decision.configurable, isTrue);
    });

    test('hard hidden tools stay hidden even when explicitly exposed', () {
      const settings = McpServerSettings(
        exposedTools: {'client_set_plan_mode'},
        exposureToolsConfigured: true,
      );
      final decision = policy.evaluate(
        const McpTool(
          name: 'client_set_plan_mode',
          description: 'Plan mode.',
          properties: {},
          executionMode: McpToolExecutionMode.planControl,
        ),
        settings: settings,
        hasChatSession: false,
      );

      expect(decision.result, McpToolPolicyResult.hidden);
      expect(decision.reason, 'not_useful_in_mcp_context');
      expect(decision.configurable, isFalse);
    });

    test('explicit empty exposure set hides ordinary tools', () {
      const settings = McpServerSettings(
        exposedTools: {},
        exposureToolsConfigured: true,
      );
      final decision = policy.evaluate(
        const McpTool(
          name: 'list_servers',
          description: 'List servers.',
          properties: {},
        ),
        settings: settings,
        hasChatSession: false,
      );

      expect(decision.result, McpToolPolicyResult.hidden);
      expect(decision.reason, 'not_exposed_by_user');
    });
  });
}
