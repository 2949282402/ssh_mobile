import 'package:flutter_test/flutter_test.dart';
import 'package:feature_mcp/feature_mcp.dart';

import '../../../support/mcp_test_fakes.dart';

void main() {
  late FakeMcpSettingsPort settings;
  late McpServerController controller;
  late McpSettingsViewModel viewModel;

  setUp(() {
    settings = FakeMcpSettingsPort();
    controller = createTestMcpController(settings, FakeMcpToolExecutor.new);
    viewModel = McpSettingsViewModel(
      settingsPort: settings,
      controller: controller,
    );
  });

  tearDown(() {
    viewModel.dispose();
    controller.dispose();
    settings.dispose();
  });

  test('feature settings update persisted MCP policy options', () async {
    await viewModel.setPort(39001);
    await viewModel.setApprovalMode(McpApprovalMode.trustedAgent);
    await viewModel.setToolSecondaryReview('list_servers', true);
    await viewModel.setEnabled(false);

    expect(viewModel.settings.port, 39001);
    expect(viewModel.settings.approvalMode, McpApprovalMode.trustedAgent);
    expect(viewModel.settings.secondaryReviewTools, contains('list_servers'));
    expect(viewModel.running, isFalse);
  });

  test('token regeneration exposes only a masked preview', () async {
    await viewModel.regenerateToken();
    final token = settings.mcpSettings.token;
    final masked = viewModel.maskedToken;

    // Exactly 8 bullets followed by the final 4 characters: no prefix, no
    // middle segment, no full-token leakage can satisfy this format.
    expect(masked.length, 12);
    expect(masked.substring(0, 8), '••••••••');
    expect(masked.substring(8), token.substring(token.length - 4));
    expect(masked, isNot(contains(token)));
  });

  test('regenerating the token produces a fresh masked preview', () async {
    await viewModel.regenerateToken();
    final first = viewModel.maskedToken;
    await viewModel.regenerateToken();
    expect(viewModel.maskedToken, isNot(equals(first)));
  });
}
