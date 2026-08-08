import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_ai/ai_chat.dart';
import 'package:ssh_mobile/features/playbook/models/playbook.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('keeps long todo content usable on a 280dp viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(280, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final longCommand = List.generate(
      90,
      (index) => 'printf "line-$index-${List.filled(80, 'x').join()}"',
    ).join('\n');
    final longLogs = List.generate(
      120,
      (index) => 'stdout-$index-${List.filled(90, 'y').join()}',
    ).join('\n');
    final message = AiChatMessageRecord(
      role: 'assistant',
      text: 'Plan',
      createdAt: DateTime.utc(2026, 7, 13),
      todoSteps: [
        AiTodoStep(
          id: 'step-long',
          name:
              'Inspect an extremely long production service name without overflowing the row',
          command: longCommand,
          description:
              'This description is intentionally long so the mobile row must share its width safely with the server chip.',
          status: StepStatus.failed,
          stdout: longLogs,
          stderr: 'permission denied',
          connectionId: 'server-long',
        ),
      ],
    );

    await tester.pumpWidget(
      _todoTestApp(
        message: message,
        strings: const AiStrings(AppLanguage.en),
        serverDisplayNameFor: (_) =>
            'production-server-with-an-extremely-long-display-name.example.com',
      ),
    );
    await tester.pumpAndSettle();

    final step = find.byKey(const ValueKey('todo-step-step-long'));
    final serverChip = find.byKey(const ValueKey('todo-server-step-long'));
    expect(tester.getSize(step).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(serverChip).width, lessThanOrEqualTo(84));
    final serverText = tester.widget<Text>(
      find.descendant(of: serverChip, matching: find.byType(Text)),
    );
    expect(serverText.maxLines, 1);
    expect(serverText.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);

    await tester.tap(step);
    await tester.pumpAndSettle();

    for (final key in const [
      'todo-retry-step-long',
      'todo-skip-step-long',
      'todo-revise-step-long',
    ]) {
      expect(
        tester.getSize(find.byKey(ValueKey(key))).height,
        greaterThanOrEqualTo(48),
      );
    }
    expect(
      tester
          .getSize(find.byKey(const ValueKey('todo-command-step-long')))
          .height,
      lessThanOrEqualTo(160),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('todo-logs-step-long'))).height,
      lessThanOrEqualTo(180),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps skip reason actions above a 1.5K landscape keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2856, 1280);
    tester.view.devicePixelRatio = 3;
    tester.view.viewInsets = const FakeViewPadding(bottom: 660);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    String? skippedStepId;
    String? skippedReason;
    final message = AiChatMessageRecord(
      role: 'assistant',
      text: '计划',
      createdAt: DateTime.utc(2026, 7, 13),
      todoSteps: const [
        AiTodoStep(
          id: 'step-skip',
          name: '检查服务',
          command: 'systemctl status nginx',
          description: '确认服务状态',
          status: StepStatus.failed,
          connectionId: 'missing-server',
        ),
      ],
    );

    await tester.pumpWidget(
      _todoTestApp(
        message: message,
        strings: const AiStrings(AppLanguage.zh),
        serverDisplayNameFor: (_) => null,
        onSkipStep: (stepId, reason) async {
          skippedStepId = stepId;
          skippedReason = reason;
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('服务器'), findsOneWidget);
    expect(find.text('Server'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('todo-step-step-skip')));
    await tester.pumpAndSettle();

    final skip = find.byKey(const ValueKey('todo-skip-step-skip'));
    await tester.ensureVisible(skip);
    await tester.pumpAndSettle();
    await tester.tap(skip);
    await tester.pumpAndSettle();

    final field = find.byKey(const ValueKey('todo-skip-reason-field'));
    final cancel = find.byKey(const ValueKey('todo-skip-cancel'));
    final confirm = find.byKey(const ValueKey('todo-skip-confirm'));
    expect(field, findsOneWidget);
    expect(tester.getSize(cancel).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(confirm).height, greaterThanOrEqualTo(48));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    final visibleBottom =
        tester.view.physicalSize.height / tester.view.devicePixelRatio -
        tester.view.viewInsets.bottom / tester.view.devicePixelRatio;
    expect(tester.getBottomRight(field).dy, lessThanOrEqualTo(visibleBottom));
    expect(tester.getBottomRight(confirm).dy, lessThanOrEqualTo(visibleBottom));

    await tester.enterText(field, '  已手动完成  ');
    await tester.pump();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('todo-skip-dialog')), findsNothing);
    expect(skippedStepId, 'step-skip');
    expect(skippedReason, '已手动完成');
    expect(tester.takeException(), isNull);
  });
}

Widget _todoTestApp({
  required AiChatMessageRecord message,
  required AiStrings strings,
  required String? Function(String connectionId) serverDisplayNameFor,
  Future<void> Function(String stepId)? onRetryStep,
  Future<void> Function(String stepId, String reason)? onSkipStep,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(8),
        child: ChatTodoPanel(
          message: message,
          strings: strings,
          serverDisplayNameFor: serverDisplayNameFor,
          onRetryStep: onRetryStep ?? (_) async {},
          onSkipStep: onSkipStep ?? (_, _) async {},
          onRevisePlan: () {},
        ),
      ),
    ),
  );
}
