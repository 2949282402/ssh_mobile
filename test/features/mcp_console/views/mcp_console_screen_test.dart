import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/features/mcp_console/viewmodels/mcp_console_viewmodel.dart';
import 'package:ssh_mobile/features/mcp_console/views/mcp_console_screen.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/mcp/mcp_server_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppSettings appSettings;
  late McpServerController controller;
  late McpConsoleViewModel viewModel;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    appSettings = AppSettings();
    await appSettings.init();
    controller = McpServerController(
      appSettings: appSettings,
      toolServiceFactory: _FakeToolExecutor.new,
    );
    viewModel = McpConsoleViewModel(controller, appSettings);
  });

  tearDown(() {
    viewModel.dispose();
    controller.dispose();
    appSettings.dispose();
  });

  Widget buildSubject() {
    return ChangeNotifierProvider.value(
      value: viewModel,
      child: const MaterialApp(home: McpConsoleScreen()),
    );
  }

  testWidgets(
    'keeps the desktop top cards equal and moves activity to header',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(buildSubject());
      await tester.pumpAndSettle();

      final statusCard = find.byKey(const ValueKey('mcp-server-status-card'));
      final clientCard = find.byKey(
        const ValueKey('mcp-client-configuration-card'),
      );
      expect(statusCard, findsOneWidget);
      expect(clientCard, findsOneWidget);
      expect(
        tester.getSize(statusCard).height,
        tester.getSize(clientCard).height,
      );
      expect(find.text('列出 SSH Mobile 中保存的服务器连接。'), findsOneWidget);
      expect(find.byKey(const ValueKey('mcp-open-activity')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('mcp-recent-activity-card')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('mcp-open-activity')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('mcp-activity-list')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('mcp-recent-activity-card')),
        findsOneWidget,
      );

      await tester.pageBack();
      await tester.pumpAndSettle();
      await appSettings.toggleLanguage();
      await tester.pumpAndSettle();
      expect(find.text('List saved servers.'), findsOneWidget);
    },
  );
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
  }) async => jsonEncode({'ok': true});

  @override
  AiCommandReview reviewCommand(String command, {ServerPlatform? platform}) =>
      const AiCommandReview.readOnly();
}
