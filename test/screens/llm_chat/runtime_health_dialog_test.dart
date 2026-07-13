import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/features/ai_chat/views/llm_chat_screen.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/client_health_advisor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('blocking runtime dialog is localized and accessible on mobile', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var settingsOpened = 0;
    bool? result;
    final report = ClientRuntimeHealthReport(
      status: ClientRuntimeHealthStatus.blocking,
      issues: const [
        ClientRuntimeHealthIssue(
          code: 'network_disconnected',
          severity: ClientRuntimeHealthStatus.blocking,
          title: 'RAW ENGLISH TITLE',
          detail: 'RAW ENGLISH DETAIL',
          recommendation: 'RAW ENGLISH RECOMMENDATION',
        ),
      ],
      raw: const {},
    );

    await tester.pumpWidget(
      _runtimeHealthHost(
        report: report,
        allowContinue: false,
        strings: const AiStrings(AppLanguage.zh),
        textScale: 1.3,
        onOpenSettings: () async => settingsOpened += 1,
        onResult: (value) => result = value,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-runtime-health')));
    await tester.pumpAndSettle();

    expect(find.text('运行环境检查阻止执行'), findsOneWidget);
    expect(find.text('客户端未连接网络'), findsOneWidget);
    expect(find.text('阻断'), findsOneWidget);
    expect(find.textContaining('RAW ENGLISH'), findsNothing);
    expect(find.byKey(const ValueKey('runtime-health-continue')), findsNothing);
    final issue = find.byKey(
      const ValueKey('runtime-health-issue-network_disconnected'),
    );
    expect(
      tester.getSemantics(issue),
      matchesSemantics(
        label: '阻断: 客户端未连接网络. Android 设备当前没有活动网络连接。 请先连接稳定网络，再执行计划。',
      ),
    );

    final close = find.byKey(const ValueKey('runtime-health-close'));
    final settings = find.byKey(const ValueKey('runtime-health-settings'));
    expect(tester.getSize(close).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(settings).height, greaterThanOrEqualTo(48));
    await tester.tap(settings);
    await tester.pumpAndSettle();

    expect(settingsOpened, 1);
    expect(result, isFalse);
    expect(find.byKey(const ValueKey('runtime-health-dialog')), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('warning dialog remains usable above a 1.5K landscape keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2856, 1280);
    tester.view.devicePixelRatio = 3;
    tester.view.viewInsets = const FakeViewPadding(bottom: 660);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    bool? result;
    final report = ClientRuntimeHealthReport(
      status: ClientRuntimeHealthStatus.warning,
      issues: const [
        ClientRuntimeHealthIssue(
          code: 'network_status_unavailable',
          severity: ClientRuntimeHealthStatus.warning,
          title: 'raw',
          detail: 'raw',
          recommendation: 'raw',
        ),
        ClientRuntimeHealthIssue(
          code: 'metered_network',
          severity: ClientRuntimeHealthStatus.warning,
          title: 'raw',
          detail: 'raw',
          recommendation: 'raw',
        ),
        ClientRuntimeHealthIssue(
          code: 'vpn_active',
          severity: ClientRuntimeHealthStatus.warning,
          title: 'raw',
          detail: 'raw',
          recommendation: 'raw',
        ),
        ClientRuntimeHealthIssue(
          code: 'battery_optimization_active',
          severity: ClientRuntimeHealthStatus.warning,
          title: 'raw',
          detail: 'raw',
          recommendation: 'raw',
        ),
        ClientRuntimeHealthIssue(
          code: 'power_save_mode',
          severity: ClientRuntimeHealthStatus.warning,
          title: 'raw',
          detail: 'raw',
          recommendation: 'raw',
        ),
      ],
      raw: const {},
    );

    await tester.pumpWidget(
      _runtimeHealthHost(
        report: report,
        allowContinue: true,
        strings: const AiStrings(AppLanguage.en),
        onOpenSettings: () async {},
        onResult: (value) => result = value,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-runtime-health')));
    await tester.pumpAndSettle();

    expect(find.text('Runtime warnings'), findsOneWidget);
    final issues = find.byKey(const ValueKey('runtime-health-issues'));
    expect(issues, findsOneWidget);
    final issuesScroll = find.descendant(
      of: issues,
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.byKey(
        const ValueKey('runtime-health-issue-network_status_unavailable'),
      ),
      80,
      scrollable: issuesScroll,
    );
    expect(find.text('Warning'), findsWidgets);
    final close = find.byKey(const ValueKey('runtime-health-close'));
    final settings = find.byKey(const ValueKey('runtime-health-settings'));
    final continueAction = find.byKey(
      const ValueKey('runtime-health-continue'),
    );
    for (final action in [close, settings, continueAction]) {
      expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
    }
    final visibleBottom =
        tester.view.physicalSize.height / tester.view.devicePixelRatio -
        tester.view.viewInsets.bottom / tester.view.devicePixelRatio;
    expect(
      tester.getBottomRight(continueAction).dy,
      lessThanOrEqualTo(visibleBottom),
    );
    expect(tester.takeException(), isNull);

    await tester.tap(continueAction);
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(find.byKey(const ValueKey('runtime-health-dialog')), findsNothing);
  });
}

Widget _runtimeHealthHost({
  required ClientRuntimeHealthReport report,
  required bool allowContinue,
  required AiStrings strings,
  required Future<void> Function() onOpenSettings,
  required ValueChanged<bool> onResult,
  double textScale = 1,
}) {
  return MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(
      body: Builder(
        builder: (context) => FilledButton(
          key: const ValueKey('open-runtime-health'),
          onPressed: () async {
            final result = await showRuntimeHealthPreflightDialog(
              context: context,
              report: report,
              allowContinue: allowContinue,
              strings: strings,
              onOpenSystemSettings: onOpenSettings,
            );
            onResult(result);
          },
          child: const Text('Open'),
        ),
      ),
    ),
  );
}
