import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ssh_mobile/features/terminal/viewmodels/terminal_windows_viewmodel.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storageService;
  late SshService sshService;
  late AppSettings appSettings;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storageService = StorageService();
    await storageService.init();

    sshService = SshService(storageService);

    appSettings = AppSettings();
    await appSettings.init();
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    sshService.dispose();
    appSettings.dispose();
    await storageService.shutdown();
    storageService.dispose();
  });

  group('TerminalWindowsViewModel Tests', () {
    test('Initialization defaults checks', () {
      final viewModel = TerminalWindowsViewModel(
        sshService: sshService,
        appSettings: appSettings,
      );

      expect(viewModel.sessions, isEmpty);
      expect(viewModel.selectedSessionIds, isEmpty);
      expect(viewModel.selectionMode, isFalse);
    });

    test('Toggling custom selections updates selectionMode', () {
      final viewModel = TerminalWindowsViewModel(
        sshService: sshService,
        appSettings: appSettings,
      );

      viewModel.toggleSelection('session_1');
      expect(viewModel.selectedSessionIds, contains('session_1'));
      expect(viewModel.selectionMode, isTrue);

      viewModel.toggleSelection('session_1');
      expect(viewModel.selectedSessionIds, isEmpty);
      expect(viewModel.selectionMode, isFalse);
    });
  });
}
