import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:feature_mcp/feature_mcp.dart';

import '../../../support/mcp_test_fakes.dart';

void main() {
  late FakeMcpSettingsPort settings;
  late McpServerController controller;
  late McpConsoleViewModel viewModel;

  setUp(() {
    settings = FakeMcpSettingsPort();
    controller = createTestMcpController(settings, FakeMcpToolExecutor.new);
    viewModel = McpConsoleViewModel(controller, settings);
  });

  tearDown(() {
    viewModel.dispose();
    controller.dispose();
    settings.dispose();
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
      settings.toggleLanguage();
      await tester.pumpAndSettle();
      expect(find.text('List saved servers.'), findsOneWidget);
    },
  );

  testWidgets('configures exposure and review per mode', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    final runExposure = find.byKey(const ValueKey('mcp-exposure-run_command'));
    final runReview = find.byKey(const ValueKey('mcp-review-run_command'));
    expect(runExposure, findsOneWidget);
    expect(runReview, findsOneWidget);
    expect(find.byKey(const ValueKey('mcp-review-list_servers')), findsNothing);
    expect(find.text('需先配置二次审核'), findsOneWidget);
    final hiddenExposure = find.byKey(
      const ValueKey('mcp-exposure-client_set_plan_mode'),
    );
    expect(hiddenExposure, findsOneWidget);
    final disabledHidden = tester.widget<Checkbox>(
      find.descendant(of: hiddenExposure, matching: find.byType(Checkbox)),
    );
    expect(disabledHidden.onChanged, isNull);
    expect(find.text('隐藏'), findsOneWidget);

    await tester.tap(
      find.descendant(of: runExposure, matching: find.byType(Checkbox)),
    );
    await tester.pumpAndSettle();

    expect(settings.mcpSettings.exposureToolsConfigured, isTrue);
    expect(settings.mcpSettings.exposedTools, isNot(contains('run_command')));
    expect(find.text('未对外暴露'), findsWidgets);
    final disabledReview = tester.widget<Checkbox>(
      find.descendant(of: runReview, matching: find.byType(Checkbox)),
    );
    expect(disabledReview.onChanged, isNull);

    await settings.setMcpApprovalMode(McpApprovalMode.trustedAgent);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mcp-review-run_command')), findsNothing);
    expect(runExposure, findsOneWidget);
  });

  testWidgets('tool controls remain usable at 200 percent text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: viewModel,
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: const McpConsoleScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('mcp-exposure-run_command')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
