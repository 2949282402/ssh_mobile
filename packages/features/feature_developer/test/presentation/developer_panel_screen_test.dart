import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:feature_developer/feature_developer.dart';
import '../support/developer_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders lifecycle diagnostics from the public Port', (
    tester,
  ) async {
    final diagnostics = FakeDeveloperDiagnostics();
    addTearDown(diagnostics.dispose);

    await tester.pumpWidget(
      ListenableProvider<DeveloperDiagnosticsPort>.value(
        value: diagnostics,
        child: const MaterialApp(home: DeveloperPanelScreen()),
      ),
    );
    await tester.pump();

    // Lifecycle 卡片位于滚动列表中段，先滚动到对应的 Lazy child。
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pump();

    expect(find.text('Lifecycle Diagnostics'), findsOneWidget);
    expect(find.text('Modules'), findsOneWidget);
    expect(find.text('feature_playbook'), findsNWidgets(2));
    expect(find.text('SSH'), findsOneWidget);
    expect(find.text('Active sessions'), findsOneWidget);
    expect(find.text('Network'), findsOneWidget);
    expect(find.text('Native handles'), findsOneWidget);
    expect(find.text('Databases'), findsOneWidget);
    expect(find.text('playbook.db'), findsOneWidget);
    expect(find.text('Timers'), findsOneWidget);
    expect(find.text('Streams'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
