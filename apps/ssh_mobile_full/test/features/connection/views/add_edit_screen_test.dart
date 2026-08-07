import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/features/connection/viewmodels/connection_viewmodel.dart';
import 'package:ssh_mobile/features/connection/views/add_edit_screen.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('save action stays visible above the mobile keyboard', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    late AppSettings settings;
    late StorageService storage;
    late SshService ssh;
    late SftpService sftp;
    late PerformanceMonitorService performance;
    late ConnectionViewModel viewModel;
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      settings = AppSettings();
      await settings.init();
      storage = StorageService();
      await storage.init();
      ssh = SshService(storage);
      sftp = SftpService(storage);
      performance = PerformanceMonitorService(ssh, storage);
      viewModel = ConnectionViewModel(
        connectionRepository: storage,
        sshService: ssh,
        sftpService: sftp,
        performanceService: performance,
      );
      await storage.addConnection(
        ConnectionConfig(
          id: 'server-1',
          name: 'Production',
          host: 'prod.example.com',
          username: 'root',
        ),
      );
      await viewModel.fetchConnections();
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() async {
      viewModel.dispose();
      performance.dispose();
      sftp.dispose();
      ssh.dispose();
      await storage.shutdown();
      storage.dispose();
      settings.dispose();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: viewModel),
        ],
        child: ShadTheme(
          data: ShadThemeData(brightness: Brightness.light),
          child: MaterialApp(
            theme: AppTheme.lightThemeFor(),
            home: const AddEditScreen(editId: 'server-1'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;

    final saveButton = find.byKey(const ValueKey('connection-save-button'));
    expect(saveButton, findsOneWidget);
    expect(tester.getBottomLeft(saveButton).dy, lessThanOrEqualTo(544));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 200));
  });
}
