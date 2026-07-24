import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('legacy disabled MCP write approval is migrated to required', () async {
    SharedPreferences.setMockInitialValues({
      'mcp_require_approval_for_write_tools': false,
    });
    final settings = AppSettings();
    addTearDown(settings.dispose);

    await settings.ensureCoreLoaded();

    expect(settings.mcpRequireApprovalForWriteTools, isTrue);
    expect(settings.mcpSettings.requireApprovalForWriteTools, isTrue);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool('mcp_require_approval_for_write_tools'), isTrue);
  });
}
