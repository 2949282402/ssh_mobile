import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/mcp/mcp_server_settings.dart';
import 'package:ssh_mobile/services/mcp/mcp_tool_exposure_policy.dart';

void main() {
  group('McpToolExposurePolicy', () {
    const policy = McpToolExposurePolicy();
    const settings = McpServerSettings(token: 'token');

    test('exposes read-only tools', () {
      final decision = policy.evaluate(
        AiTool(
          name: 'list_servers',
          description: 'List servers.',
          properties: const {},
          handler: (_) async => '{}',
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
          AiTool(
            name: 'sftp_delete_entry',
            description: 'Delete.',
            properties: const {},
            executionMode: AiToolExecutionMode.stateChanging,
            handler: (_) async => '{}',
          ),
          settings: settings,
          hasChatSession: false,
        );

        expect(decision.result, McpToolPolicyResult.exposed);
        expect(decision.destructive, isTrue);
        expect(decision.reason, 'exposed');
      },
    );

    test('does not return an approvalRequired exposure result', () {
      expect(
        McpToolPolicyResult.values.map((item) => item.name),
        isNot(contains('approvalRequired')),
      );
    });

    test('hides WebView tools without chat session', () {
      final decision = policy.evaluate(
        AiTool(
          name: 'web_search',
          description: 'Search.',
          properties: const {},
          requiresWebViewSession: true,
          handler: (_) async => '{}',
        ),
        settings: settings,
        hasChatSession: false,
      );

      expect(decision.result, McpToolPolicyResult.hidden);
      expect(decision.canList, isFalse);
    });

    test('hides internal plan-control tools', () {
      final decision = policy.evaluate(
        AiTool(
          name: 'client_set_plan_mode',
          description: 'Plan mode.',
          properties: const {},
          executionMode: AiToolExecutionMode.planControl,
          handler: (_) async => '{}',
        ),
        settings: settings,
        hasChatSession: false,
      );

      expect(decision.result, McpToolPolicyResult.hidden);
    });
  });
}
