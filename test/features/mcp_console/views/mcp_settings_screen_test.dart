import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/features/mcp_console/viewmodels/mcp_settings_viewmodel.dart';
import 'package:ssh_mobile/features/mcp_console/views/mcp_settings_screen.dart';
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

  Widget buildSubject() {
    return ChangeNotifierProvider.value(
      value: viewModel,
      child: MaterialApp(home: const McpSettingsScreen()),
    );
  }

  testWidgets('shows review mode and directs Tool policy to the console', (
    tester,
  ) async {
    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    expect(find.text('危险操作二次审核'), findsOneWidget);
    expect(find.text('在本地 MCP 控制台配置 Tool 策略'), findsOneWidget);
    expect(find.text('需要二次审核的 Tools'), findsNothing);
    expect(find.text('run_command'), findsNothing);
  });

  testWidgets('canceling trusted-agent warning leaves the mode unchanged', (
    tester,
  ) async {
    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    await tester.tap(find.text('完整权限（信任 Agent）'));
    await tester.pumpAndSettle();
    expect(find.text('启用外部 Agent 完整权限？'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(viewModel.approvalMode, McpApprovalMode.reviewConfiguredTools);
    expect(find.text('在本地 MCP 控制台配置 Tool 策略'), findsOneWidget);
  });

  testWidgets('confirming trusted-agent warning changes mode immediately', (
    tester,
  ) async {
    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    await tester.tap(find.text('完整权限（信任 Agent）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('启用完整权限'));
    await tester.pumpAndSettle();

    expect(viewModel.approvalMode, McpApprovalMode.trustedAgent);
    expect(find.text('已启用自动执行'), findsOneWidget);
    expect(find.text('需要二次审核的 Tools'), findsNothing);
    expect(find.text('在本地 MCP 控制台配置 Tool 策略'), findsOneWidget);
  });

  testWidgets('Windows layout keeps fields separated and avoids overflow', (
    tester,
  ) async {
    final originalPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    try {
      await appSettings.setMcpApprovalMode(McpApprovalMode.trustedAgent);
      await tester.pumpWidget(buildSubject());
      await tester.pumpAndSettle();

      final host = tester.getRect(find.text('主机: 127.0.0.1'));
      final portField = tester.getRect(find.byType(TextField));
      expect(portField.top - host.bottom, greaterThanOrEqualTo(8));
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = originalPlatform;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });
}

class _FakeToolExecutor implements AiToolExecutor {
  @override
  Future<List<AiTool>> tools() async => [
    AiTool(
      name: 'run_command',
      description: 'Run a remote command.',
      properties: const {},
      executionMode: AiToolExecutionMode.stateChanging,
      handler: (_) async => jsonEncode({'ok': true}),
    ),
    AiTool(
      name: 'list_servers',
      description: 'List servers.',
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
  }) async => jsonEncode({'ok': true});

  @override
  AiCommandReview reviewCommand(String command, {ServerPlatform? platform}) =>
      const AiCommandReview.readOnly();
}
