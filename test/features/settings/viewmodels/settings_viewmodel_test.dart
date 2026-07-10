import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/features/settings/viewmodels/settings_viewmodel.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storageService;
  late AppSettings appSettings;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
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

  group('SettingsViewModel Tests', () {
    test('Initialization status and settings exposure', () {
      final viewModel = SettingsViewModel(
        appSettings: appSettings,
        storageService: storageService,
      );

      expect(viewModel.language, equals(AppLanguage.zh));
      expect(viewModel.themeMode, equals(ThemeMode.light));
      expect(viewModel.isImporting, isFalse);
      expect(viewModel.isExporting, isFalse);
      expect(viewModel.lastOperationMessage, isNull);
    });

    test('changeLanguage toggles settings language', () async {
      final viewModel = SettingsViewModel(
        appSettings: appSettings,
        storageService: storageService,
      );

      expect(viewModel.language, equals(AppLanguage.zh));
      await viewModel.changeLanguage(AppLanguage.en);
      expect(viewModel.language, equals(AppLanguage.en));
    });

    test('changeThemeMode updates AppSettings', () {
      final viewModel = SettingsViewModel(
        appSettings: appSettings,
        storageService: storageService,
      );

      viewModel.changeThemeMode(ThemeMode.dark);
      expect(viewModel.themeMode, equals(ThemeMode.dark));
    });

    test('configureSecretCache and clearSecretCache works', () async {
      final viewModel = SettingsViewModel(
        appSettings: appSettings,
        storageService: storageService,
      );

      expect(viewModel.secretCacheEnabled, isTrue);
      await viewModel.configureSecretCache(false, 30);
      expect(viewModel.secretCacheEnabled, isFalse);
      expect(viewModel.secretCacheTtlMinutes, equals(30));

      await viewModel.clearSecretCache();
      expect(viewModel.secretCacheEnabled, isFalse);
    });

    test(
      'exportAppData and importAppData handle state transitions and callbacks',
      () async {
        final viewModel = SettingsViewModel(
          appSettings: appSettings,
          storageService: storageService,
        );

        List<int>? exportedBytes;
        bool saveCallbackCalled = false;
        final exportSuccess = await viewModel.exportAppData((
          fileName,
          bytes,
        ) async {
          saveCallbackCalled = true;
          expect(fileName, startsWith('ssh_mobile_backup_'));
          expect(bytes, isNotEmpty);
          exportedBytes = bytes;
          return 'mock_path';
        });

        expect(exportSuccess, isTrue);
        expect(saveCallbackCalled, isTrue);
        expect(viewModel.isExporting, isFalse);
        expect(viewModel.lastOperationMessage, equals('success'));

        bool pickCallbackCalled = false;
        final importSuccess = await viewModel.importAppData(() async {
          pickCallbackCalled = true;
          return exportedBytes;
        });

        expect(importSuccess, isTrue);
        expect(pickCallbackCalled, isTrue);
        expect(viewModel.isImporting, isFalse);
        expect(viewModel.lastOperationMessage, equals('success'));
      },
    );
  });
}
