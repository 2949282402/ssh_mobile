import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ssh_mobile/features/startup/viewmodels/startup_viewmodel.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storageService;
  late AppSettings appSettings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storageService = StorageService();
    await storageService.init();

    appSettings = AppSettings();
    await appSettings.init();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    storageService.dispose();
  });

  group('StartupViewModel Tests', () {
    test('Initialization status should be true once services initialize', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final viewModel = StartupViewModel(
        storageService: storageService,
        appSettings: appSettings,
      );

      expect(viewModel.storageInitialized, isTrue);
      expect(viewModel.settingsInitialized, isTrue);
      expect(viewModel.checkingPowerStatus, isFalse);
    });

    test('Non-Android platform skips power guide automatically', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final viewModel = StartupViewModel(
        storageService: storageService,
        appSettings: appSettings,
      );

      await viewModel.checkPowerGuideStatus();

      expect(viewModel.isAndroidTarget, isFalse);
      expect(viewModel.shouldShowPowerGuide, isFalse);
      expect(viewModel.powerStatusChecked, isTrue);
    });

    test('Android target correctly flags isAndroidTarget', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final viewModel = StartupViewModel(
        storageService: storageService,
        appSettings: appSettings,
      );

      expect(viewModel.isAndroidTarget, isTrue);
    });
  });
}
