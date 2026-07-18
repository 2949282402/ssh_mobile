import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ssh_mobile/features/startup/viewmodels/startup_viewmodel.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const powerChannel = MethodChannel('ssh_mobile/power');

  late StorageService storageService;
  late AppSettings appSettings;
  late List<StartupViewModel> viewModels;

  StartupViewModel createViewModel() {
    final viewModel = StartupViewModel(
      storageService: storageService,
      appSettings: appSettings,
    );
    viewModels.add(viewModel);
    return viewModel;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storageService = StorageService();
    await storageService.init();

    appSettings = AppSettings();
    await appSettings.init();
    viewModels = [];
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(powerChannel, null);
    for (final viewModel in viewModels.reversed) {
      viewModel.dispose();
    }
    appSettings.dispose();
    await storageService.shutdown();
    storageService.dispose();
  });

  group('StartupViewModel Tests', () {
    test('Initialization status should be true once services initialize', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final viewModel = createViewModel();

      expect(viewModel.storageInitialized, isTrue);
      expect(viewModel.settingsInitialized, isTrue);
      expect(viewModel.checkingPowerStatus, isFalse);
    });

    test('Non-Android platform skips power guide automatically', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final viewModel = createViewModel();

      await viewModel.checkPowerGuideStatus();

      expect(viewModel.isAndroidTarget, isFalse);
      expect(viewModel.shouldShowPowerGuide, isFalse);
      expect(viewModel.powerStatusChecked, isTrue);
    });

    test('Android target correctly flags isAndroidTarget', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final viewModel = createViewModel();

      expect(viewModel.isAndroidTarget, isTrue);
    });

    test('Android power status checks are single-flight', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final result = Completer<bool>();
      var queryCount = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(powerChannel, (call) async {
            if (call.method == 'isIgnoringBatteryOptimizations') {
              queryCount++;
              return result.future;
            }
            return null;
          });
      final viewModel = createViewModel();

      final first = viewModel.checkPowerGuideStatus();
      final second = viewModel.checkPowerGuideStatus();
      await Future<void>.delayed(Duration.zero);

      expect(queryCount, 1);
      expect(viewModel.checkingPowerStatus, isTrue);
      result.complete(false);
      await Future.wait([first, second]);

      expect(queryCount, 1);
      expect(viewModel.checkingPowerStatus, isFalse);
      expect(viewModel.powerStatusChecked, isTrue);
      expect(viewModel.shouldShowPowerGuide, isTrue);
    });

    testWidgets('duplicate power guide schedules coalesce in one frame', (
      tester,
    ) async {
      final viewModel = createViewModel();
      var callbackCount = 0;
      await tester.pumpWidget(const SizedBox.shrink());

      viewModel.schedulePowerGuideCheck(() => callbackCount++);
      viewModel.schedulePowerGuideCheck(() => callbackCount++);
      expect(viewModel.powerStatusCheckScheduled, isTrue);

      tester.binding.scheduleFrame();
      await tester.pump();

      expect(callbackCount, 1);
      expect(viewModel.powerStatusCheckScheduled, isFalse);
      await tester.pump(const Duration(milliseconds: 200));
    });
  });
}
