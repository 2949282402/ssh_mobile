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
}
