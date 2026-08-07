import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/mcp/mcp_invocation_policy.dart';
import 'package:ssh_mobile/services/mcp/mcp_server_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'missing MCP policy settings default to review and safe tool set',
    () async {
      SharedPreferences.setMockInitialValues({
        'mcp_require_approval_for_write_tools': false,
      });
      final settings = AppSettings();
      addTearDown(settings.dispose);

      await settings.ensureCoreLoaded();

      expect(settings.mcpApprovalMode, McpApprovalMode.reviewConfiguredTools);
      expect(
        settings.mcpSecondaryReviewTools,
        McpInvocationPolicy.defaultSecondaryReviewTools,
      );
      expect(settings.mcpExposureToolsConfigured, isFalse);
      expect(settings.mcpExposedTools, isEmpty);

      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getBool('mcp_require_approval_for_write_tools'),
        isFalse,
      );
      expect(preferences.getString('mcp_approval_mode'), isNull);
    },
  );

  test('MCP mode and tool set persist in stable sorted order', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = AppSettings();
    addTearDown(settings.dispose);

    await settings.ensureCoreLoaded();
    await settings.setMcpApprovalMode(McpApprovalMode.trustedAgent);
    await settings.setMcpSecondaryReviewTools({'z_tool', 'a_tool'});

    expect(settings.mcpSettings.approvalMode, McpApprovalMode.trustedAgent);
    expect(settings.mcpSecondaryReviewTools, {'a_tool', 'z_tool'});
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getStringList('mcp_secondary_review_tools'), [
      'a_tool',
      'z_tool',
    ]);
  });

  test(
    'exposure set persists sorted names, unknown names, and empty values',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = AppSettings();
      addTearDown(settings.dispose);

      await settings.ensureCoreLoaded();
      await settings.setMcpExposedTools({'z_tool', 'future_tool', 'a_tool'});

      expect(settings.mcpExposureToolsConfigured, isTrue);
      expect(settings.mcpExposedTools, {'a_tool', 'future_tool', 'z_tool'});
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getStringList('mcp_exposed_tools'), [
        'a_tool',
        'future_tool',
        'z_tool',
      ]);

      await settings.setMcpExposedTools({});
      expect(settings.mcpExposedTools, isEmpty);
      expect(preferences.getStringList('mcp_exposed_tools'), isEmpty);
    },
  );

  test(
    'first exposure toggle materializes current tools and hides future tools',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = AppSettings();
      addTearDown(settings.dispose);

      await settings.ensureCoreLoaded();
      await settings.setMcpToolExposure(
        'run_command',
        false,
        availableToolNames: {'list_servers', 'run_command'},
      );

      expect(settings.mcpExposureToolsConfigured, isTrue);
      expect(settings.mcpExposedTools, {'list_servers'});
      expect(settings.mcpSettings.isToolExposed('new_tool'), isFalse);

      final restored = AppSettings();
      addTearDown(restored.dispose);
      await restored.ensureCoreLoaded();
      expect(restored.mcpExposedTools, {'list_servers'});
      expect(restored.mcpExposureToolsConfigured, isTrue);
    },
  );
}
