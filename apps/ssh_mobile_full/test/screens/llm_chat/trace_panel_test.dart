import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:feature_ai/ai_chat.dart';
import 'package:feature_ai/feature_ai.dart' as ai;
import 'package:ssh_mobile/services/app_settings.dart';

import '../../test_utils/ai_port_adapters.dart';

void main() {
  testWidgets('trace rows stay tappable, localized, and height bounded', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(280, 620);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final settings = AppSettings();
    addTearDown(settings.dispose);
    final trace = AiMessageTrace(
      id: 'reasoning-1',
      kind: 'reasoning',
      title: 'Reasoning',
      content: List.generate(
        100,
        (index) => 'Reasoning line $index with a long diagnostic value',
      ).join('\n'),
      createdAt: DateTime(2026),
    );

    await tester.pumpWidget(
      ListenableProvider<ai.AiSettingsPort>.value(
        value: aiSettingsPort(settings),
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: TracePanel(
                traces: [trace],
                storageKey: 'trace-panel-test',
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('执行详情 (1)'), findsOneWidget);
    expect(find.byType(ExpansionTile), findsOneWidget);
    expect(
      tester.getSize(find.byType(ExpansionTile)).height,
      greaterThanOrEqualTo(48),
    );

    await tester.tap(find.text('执行详情 (1)'));
    await tester.pumpAndSettle();
    expect(find.text('1. 深度思考'), findsOneWidget);
    expect(find.byType(ExpansionTile), findsNWidgets(2));
    expect(
      tester.getSize(find.byType(ExpansionTile).at(1)).height,
      greaterThanOrEqualTo(48),
    );

    await tester.tap(find.text('1. 深度思考'));
    await tester.pumpAndSettle();
    final content = find.byKey(
      const ValueKey<String>('trace-content-reasoning-1'),
    );
    expect(content, findsOneWidget);
    expect(tester.getSize(content).height, lessThanOrEqualTo(280));
    await tester.drag(content, const Offset(0, -160));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await settings.toggleLanguage();
    await tester.pumpAndSettle();
    expect(find.text('Execution details (1)'), findsOneWidget);
    expect(find.text('1. Deep reasoning'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
