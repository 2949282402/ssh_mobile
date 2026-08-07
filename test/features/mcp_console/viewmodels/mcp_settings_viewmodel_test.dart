import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ssh_mobile/features/mcp_console/viewmodels/mcp_settings_viewmodel.dart';
import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/mcp/mcp_server_controller.dart';
import 'package:ssh_mobile/services/mcp/mcp_server_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppSettings appSettings;
  late McpServerController controller;
  late McpSettingsViewModel viewModel;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    appSettings = AppSettings();
    await appSettings.init();
    controller = McpServerController(
      appSettings: appSettings,
      toolServiceFactory: _FakeToolExecutor.new,
    );
    viewModel = McpSettingsViewModel(
      appSettings: appSettings,
      controller: controller,
    );
  });

  tearDown(() {
    viewModel.dispose();
    controller.dispose();
    appSettings.dispose();
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
    final token = appSettings.mcpServerToken;
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

class _FakeToolExecutor implements AiToolExecutor {
  @override
  Future<List<AiTool>> tools() async => [
    AiTool(
      name: 'list_servers',
      description: 'List saved servers.',
      properties: const {},
      handler: (_) async => jsonEncode({'servers': []}),
    ),
  ];

  @override
  Future<List<Map<String, dynamic>>> toolDefinitions() async =>
      (await tools()).map((tool) => tool.definition).toList();

  @override
  Future<AiToolApprovalRequest?> approvalRequestFor(
    String name,
    Map<String, dynamic> arguments,
  ) async => null;

  @override
  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async => jsonEncode({'servers': []});

  @override
  AiCommandReview reviewCommand(String command, {ServerPlatform? platform}) {
    return const AiCommandReview.readOnly();
  }
}
