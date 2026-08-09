import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:feature_developer/feature_developer.dart';
import '../support/developer_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('developer logs toolbar adapts to narrow large text', (
    WidgetTester tester,
  ) async {
    final settings = FakeDeveloperSettings();
    final logService = FakeDeveloperLogPort();
    addTearDown(settings.dispose);
    addTearDown(logService.dispose);
    final viewModel = DeveloperLogViewModel(
      logService: logService,
      settings: settings,
    );
    addTearDown(viewModel.dispose);

    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider.value(value: viewModel)],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const Scaffold(body: DeveloperLogPage()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('开发日志'), findsWidgets);
    expect(find.byType(FilterChip), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
