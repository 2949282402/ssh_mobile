import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_ai/ai_chat.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'closing a persisted Plan banner never drops a draft on failure',
    () async {
      final controller = TextEditingController(
        text: '/plan  inspect   nginx  ',
      );
      addTearDown(controller.dispose);
      var attempts = 0;

      final failed = await closePlanModeBannerForInput(
        controller: controller,
        persistedPlanMode: true,
        disablePersistedPlanMode: () async {
          attempts += 1;
          return false;
        },
      );
      expect(failed, isFalse);
      expect(controller.text, '/plan  inspect   nginx  ');
      expect(attempts, 1);

      final succeeded = await closePlanModeBannerForInput(
        controller: controller,
        persistedPlanMode: true,
        disablePersistedPlanMode: () async {
          attempts += 1;
          return true;
        },
      );
      expect(succeeded, isTrue);
      expect(controller.text, 'inspect   nginx');
      expect(controller.selection.baseOffset, controller.text.length);
      expect(attempts, 2);
    },
  );

  test(
    'closing a persisted Plan banner preserves edits made during save',
    () async {
      final controller = TextEditingController(text: '/plan inspect nginx');
      addTearDown(controller.dispose);
      final saveGate = Completer<bool>();

      final close = closePlanModeBannerForInput(
        controller: controller,
        persistedPlanMode: true,
        disablePersistedPlanMode: () => saveGate.future,
      );
      controller.value = const TextEditingValue(
        text: 'new ordinary draft',
        selection: TextSelection.collapsed(offset: 5),
      );
      saveGate.complete(true);

      expect(await close, isTrue);
      expect(controller.text, 'new ordinary draft');
      expect(controller.selection.baseOffset, 5);
    },
  );

  testWidgets('Plan banner remains usable on a 320dp 2K viewport at 2x text', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1440, 2560);
    tester.view.devicePixelRatio = 4.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var closeCount = 0;

    await tester.pumpWidget(
      _scaledApp(
        textScale: 2,
        child: ChatPlanModeBanner(
          strings: const AiStrings(AppLanguage.en),
          persistedPlanMode: true,
          busy: false,
          onClose: () => closeCount += 1,
        ),
      ),
    );
    await tester.pump();

    final banner = find.byKey(const ValueKey<String>('plan-mode-banner'));
    final close = find.byKey(const ValueKey<String>('plan-mode-banner-close'));
    expect(banner, findsOneWidget);
    expect(tester.getSize(banner).width, lessThanOrEqualTo(304));
    expect(tester.getSize(close).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(close).height, greaterThanOrEqualTo(48));
    expect(
      find.bySemanticsLabel(
        RegExp(r'Plan Mode.*Read-only analysis and planning', dotAll: true),
      ),
      findsOneWidget,
    );
    await tester.tap(close);
    expect(closeCount, 1);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('Plan approval actions stack safely and expose busy state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 2560);
    tester.view.devicePixelRatio = 4.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final createdAt = DateTime.utc(2026, 7, 13, 12);
    final suffix = createdAt.microsecondsSinceEpoch;
    var approvals = 0;
    var revisions = 0;

    await tester.pumpWidget(
      _scaledApp(
        textScale: 2,
        child: ChatPlanApprovalActions(
          strings: const AiStrings(AppLanguage.en),
          assistantCreatedAt: createdAt,
          busy: false,
          onApprove: () => approvals += 1,
          onRevise: () => revisions += 1,
        ),
      ),
    );
    await tester.pump();

    final approve = find.byKey(ValueKey<String>('plan-approve-$suffix'));
    final revise = find.byKey(ValueKey<String>('plan-revise-$suffix'));
    for (final action in [approve, revise]) {
      expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(action).height, lessThanOrEqualTo(120));
    }
    expect(
      find.byKey(const ValueKey<String>('plan-approval-header')),
      findsNothing,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey<String>('plan-approval-actions')))
          .height,
      lessThanOrEqualTo(260),
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey<String>('plan-approval-area')))
          .height,
      lessThanOrEqualTo(400),
    );
    expect(
      tester.getTopLeft(revise).dy,
      greaterThan(tester.getTopLeft(approve).dy),
    );
    await tester.tap(approve);
    await tester.tap(revise);
    await tester.pumpAndSettle();
    expect(approvals, 1);
    expect(revisions, 1);

    await tester.pumpWidget(
      _scaledApp(
        textScale: 2,
        child: ChatPlanApprovalActions(
          strings: const AiStrings(AppLanguage.en),
          assistantCreatedAt: createdAt,
          busy: true,
          onApprove: () => approvals += 1,
          onRevise: () => revisions += 1,
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(approve, warnIfMissed: false);
    await tester.tap(revise, warnIfMissed: false);
    expect(approvals, 1);
    expect(revisions, 1);
  });
}

Widget _scaledApp({required double textScale, required Widget child}) {
  return MaterialApp(
    builder: (context, appChild) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: appChild!,
    ),
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(8),
        child: Align(alignment: Alignment.topCenter, child: child),
      ),
    ),
  );
}
