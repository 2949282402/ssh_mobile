import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/features/settings/viewmodels/settings_viewmodel.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import '../../../test_utils/test_storage_adapter.dart';
import 'package:app_ui/app_ui.dart';

import '../../../test_utils/ai_port_adapters.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStorageAdapter storageService;
  late AppSettings appSettings;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storageService = TestStorageAdapter();
    await storageService.init();
    attachTestAiRepository(storageService);

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
        aiStorage: storageService.aiStorage,
      );

      expect(viewModel.language, equals(AppLanguage.zh));
      expect(viewModel.themeMode, equals(ThemeMode.light));
      expect(viewModel.colorPalette, AppColorPalette.monochrome);
      expect(viewModel.isImporting, isFalse);
      expect(viewModel.isExporting, isFalse);
      expect(viewModel.lastOperationMessage, isNull);
    });

    test('dispose detaches settings listeners cleanly', () {
      final viewModel = SettingsViewModel(
        appSettings: appSettings,
        aiStorage: storageService.aiStorage,
      );
      viewModel.dispose();
      appSettings.setThemeMode(ThemeMode.dark);
    });

    test('changeLanguage toggles settings language', () async {
      final viewModel = SettingsViewModel(
        appSettings: appSettings,
        aiStorage: storageService.aiStorage,
      );

      expect(viewModel.language, equals(AppLanguage.zh));
      await viewModel.changeLanguage(AppLanguage.en);
      expect(viewModel.language, equals(AppLanguage.en));
    });

    test(
      'exposes and updates visual, notification, and developer settings',
      () async {
        final viewModel = SettingsViewModel(
          appSettings: appSettings,
          aiStorage: storageService.aiStorage,
        );

        expect(viewModel.isEnglish, isFalse);
        expect(viewModel.isDarkMode, isFalse);
        expect(viewModel.showServerNamesInNotifications, isFalse);
        expect(viewModel.oledDark, isFalse);
        expect(viewModel.developerMode, isFalse);
        expect(viewModel.developerPanelFloating, isFalse);
        expect(viewModel.secretCacheTtl, const Duration(minutes: 15));
        expect(viewModel.secretCacheTtlOptionsMinutes, isNotEmpty);

        await viewModel.changeLanguage(appSettings.language);
        await viewModel.changeLanguage(AppLanguage.en);
        viewModel.changeThemeMode(ThemeMode.dark);
        await viewModel.setOledDark(true);
        await viewModel.setColorPalette(AppColorPalette.ocean);
        await viewModel.setDeveloperMode(true);
        await viewModel.setDeveloperPanelFloating(true);
        await viewModel.setShowServerNamesInNotifications(true);

        expect(viewModel.isEnglish, isTrue);
        expect(viewModel.themeMode, ThemeMode.dark);
        expect(viewModel.isDarkMode, isTrue);
        expect(viewModel.oledDark, isTrue);
        expect(viewModel.colorPalette, AppColorPalette.ocean);
        expect(viewModel.developerMode, isTrue);
        expect(viewModel.developerPanelFloating, isTrue);
        expect(viewModel.showServerNamesInNotifications, isTrue);
      },
    );

    test('changeThemeMode updates AppSettings', () {
      final viewModel = SettingsViewModel(
        appSettings: appSettings,
        aiStorage: storageService.aiStorage,
      );

      viewModel.changeThemeMode(ThemeMode.dark);
      expect(viewModel.themeMode, equals(ThemeMode.dark));
    });

    test('setColorPalette updates and persists AppSettings', () async {
      final viewModel = SettingsViewModel(
        appSettings: appSettings,
        aiStorage: storageService.aiStorage,
      );

      await viewModel.setColorPalette(AppColorPalette.rose);

      expect(viewModel.colorPalette, AppColorPalette.rose);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('color_palette'), 'rose');
    });

    test('configureSecretCache and clearSecretCache works', () async {
      final viewModel = SettingsViewModel(
        appSettings: appSettings,
        aiStorage: storageService.aiStorage,
      );

      expect(viewModel.secretCacheEnabled, isTrue);
      await viewModel.configureSecretCache(false, 30);
      expect(viewModel.secretCacheEnabled, isFalse);
      expect(viewModel.secretCacheTtlMinutes, equals(30));

      await viewModel.clearSecretCache();
      expect(viewModel.secretCacheEnabled, isFalse);
    });

    test(
      'backup wrappers and picker cancellation preserve operation state',
      () async {
        final viewModel = SettingsViewModel(
          appSettings: appSettings,
          aiStorage: storageService.aiStorage,
        );

        final backup = await viewModel.exportBackup();
        expect(backup, contains('connections'));
        await viewModel.importBackup(backup);

        expect(await viewModel.exportAppData((_, __) async => null), isFalse);
        expect(viewModel.isExporting, isFalse);
        expect(viewModel.lastOperationMessage, isNull);
        expect(await viewModel.importAppData(() async => null), isFalse);
        expect(viewModel.isImporting, isFalse);
        expect(viewModel.lastOperationMessage, isNull);
      },
    );

    test(
      'backup callbacks surface errors and always reset busy flags',
      () async {
        final viewModel = SettingsViewModel(
          appSettings: appSettings,
          aiStorage: storageService.aiStorage,
        );
        final saveError = StateError('save failed');
        await expectLater(
          viewModel.exportAppData((_, __) async => throw saveError),
          throwsA(same(saveError)),
        );
        expect(viewModel.isExporting, isFalse);
        expect(viewModel.lastOperationMessage, contains('save failed'));

        await expectLater(
          viewModel.importAppData(() async => <int>[0xff, 0xfe]),
          throwsA(anything),
        );
        expect(viewModel.isImporting, isFalse);
        expect(viewModel.lastOperationMessage, isNotNull);
      },
    );

    test(
      'exportAppData and importAppData handle state transitions and callbacks',
      () async {
        final viewModel = SettingsViewModel(
          appSettings: appSettings,
          aiStorage: storageService.aiStorage,
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
