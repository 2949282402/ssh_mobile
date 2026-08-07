import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/features/developer_log/viewmodels/developer_log_viewmodel.dart';
import 'package:ssh_mobile/features/developer_log/views/developer_log_screen.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('developer logs toolbar adapts to narrow large text', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final appSettings = AppSettings();
    await tester.runAsync(appSettings.init);
    addTearDown(appSettings.dispose);
    final logService = AppLogService()..clear();
    final viewModel = DeveloperLogViewModel(
      appSettings: appSettings,
      logService: logService,
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
