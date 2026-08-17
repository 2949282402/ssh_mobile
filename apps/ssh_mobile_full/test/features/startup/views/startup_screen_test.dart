import 'dart:async';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/features/startup/viewmodels/startup_viewmodel.dart';
import 'package:ssh_mobile/features/startup/views/startup_screen.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import '../../../test_utils/test_storage_adapter.dart';
import 'package:app_ui/app_ui.dart';

const _powerChannel = MethodChannel('ssh_mobile/power');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_powerChannel, null);
  });

  testWidgets('English guide remains reachable at 320dp and 200% text', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(bottom: 24);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);

      late _StartupFixture fixture;
      await tester.runAsync(() async {
        fixture = await _createFixture(language: AppLanguage.en);
      });
      addTearDown(fixture.dispose);
      await tester.pumpWidget(_guideHost(fixture.viewModel, textScale: 2));
      await tester.pumpAndSettle();

      expect(find.text('Keep SSH connected in the background'), findsOneWidget);
      expect(find.text('Recommended settings'), findsOneWidget);
      expect(find.text('Review battery settings'), findsOneWidget);
      expect(find.text('Open app settings'), findsOneWidget);
      expect(find.text('Continue for now'), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(const ValueKey('power-guide-title'))),
        matchesSemantics(
          label: 'Keep SSH connected in the background',
          isHeader: true,
        ),
      );

      final status = find.byKey(const ValueKey('power-guide-status'));
      await tester.ensureVisible(status);
      await tester.pump();
      expect(
        tester.getSemantics(status),
        matchesSemantics(
          label: 'Battery restriction status needs review',
          isLiveRegion: true,
        ),
      );

      for (final action in const [
        (
          key: ValueKey('power-guide-battery-action'),
          label: 'Review battery settings',
        ),
        (
          key: ValueKey('power-guide-settings-action'),
          label: 'Open app settings',
        ),
        (
          key: ValueKey('power-guide-continue-action'),
          label: 'Continue for now',
        ),
      ]) {
        final finder = find.byKey(action.key);
        expect(finder, findsOneWidget);
        expect(tester.getSize(finder).height, greaterThanOrEqualTo(48));
        _expectButtonSemantics(tester, finder, action.label);
      }

      final continueAction = find.byKey(
        const ValueKey('power-guide-continue-action'),
      );
      await tester.ensureVisible(continueAction);
      await tester.pump();
      expect(tester.getBottomRight(continueAction).dy, lessThanOrEqualTo(544));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('Chinese guide respects 1.5K landscape safe areas', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2856, 1280);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(
      left: 600,
      right: 72,
      bottom: 144,
    );
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);

    late _StartupFixture fixture;
    await tester.runAsync(() async {
      fixture = await _createFixture(language: AppLanguage.zh);
    });
    addTearDown(fixture.dispose);
    await tester.pumpWidget(_guideHost(fixture.viewModel));
    await tester.pumpAndSettle();

    final content = find.byKey(const ValueKey('power-guide-content'));
    expect(tester.getSize(content).width, lessThanOrEqualTo(640));
    expect(tester.getRect(content).left, greaterThanOrEqualTo(200));
    expect(find.text('让 SSH 在后台保持连接'), findsOneWidget);
    expect(find.text('建议设置'), findsOneWidget);
    expect(find.text('需要检查电池限制状态'), findsOneWidget);
    expect(find.text('检查电池设置'), findsOneWidget);
    expect(find.text('打开应用设置'), findsOneWidget);
    expect(find.text('暂时继续'), findsOneWidget);

    final note = find.byKey(const ValueKey('power-guide-note'));
    await tester.ensureVisible(note);
    await tester.pump();
    final noteRect = tester.getRect(note);
    expect(noteRect.left, greaterThanOrEqualTo(200));
    expect(noteRect.right, lessThanOrEqualTo(928));
    expect(noteRect.bottom, lessThanOrEqualTo(1280 / 3 - 48));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('StartupScreen loads the guide and continue skips this launch', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final statusGate = Completer<bool>();
    late _StartupFixture fixture;
    await tester.runAsync(() async {
      fixture = await _createFixture(
        language: AppLanguage.en,
        checkStatus: false,
        statusGate: statusGate,
      );
    });
    addTearDown(fixture.dispose);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.pumpWidget(_startupHost(fixture.viewModel));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(fixture.powerCalls, ['isIgnoringBatteryOptimizations']);

      statusGate.complete(false);
      await tester.pumpAndSettle();
      expect(find.text('Keep SSH connected in the background'), findsOneWidget);
      expect(fixture.powerCalls, ['isIgnoringBatteryOptimizations']);

      final continueAction = find.byKey(
        const ValueKey('power-guide-continue-action'),
      );
      await tester.ensureVisible(continueAction);
      await tester.tap(continueAction);
      await tester.pumpAndSettle();

      expect(find.text('Home placeholder'), findsOneWidget);
      expect(fixture.storageService.powerGuideSeen, isFalse);
      expect(fixture.powerCalls, ['isIgnoringBatteryOptimizations']);
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('battery action refreshes status and promotes continue', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    late _StartupFixture fixture;
    await tester.runAsync(() async {
      fixture = await _createFixture(language: AppLanguage.en);
    });
    addTearDown(fixture.dispose);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.pumpWidget(_guideHost(fixture.viewModel));
      await tester.pumpAndSettle();

      final batteryAction = find.byKey(
        const ValueKey('power-guide-battery-action'),
      );
      await tester.ensureVisible(batteryAction);
      await tester.pumpAndSettle();
      await tester.tap(batteryAction);
      await tester.pumpAndSettle();

      expect(fixture.powerCalls, [
        'isIgnoringBatteryOptimizations',
        'requestBatteryOptimizationExemption',
        'isIgnoringBatteryOptimizations',
      ]);
      final continueAction = find.byKey(
        const ValueKey('power-guide-continue-action'),
      );
      expect(continueAction, findsOneWidget);
      expect(
        find.byKey(const ValueKey('power-guide-battery-action')),
        findsNothing,
      );
      expect(tester.widget<FilledButton>(continueAction), isA<FilledButton>());
      expect(find.text('Continue to app'), findsOneWidget);
      _expectButtonSemantics(tester, continueAction, 'Continue to app');
      expect(
        tester.getSemantics(find.byKey(const ValueKey('power-guide-status'))),
        matchesSemantics(
          label: 'Battery restrictions are relaxed',
          isLiveRegion: true,
        ),
      );

      final settingsAction = find.byKey(
        const ValueKey('power-guide-settings-action'),
      );
      await tester.ensureVisible(settingsAction);
      await tester.pumpAndSettle();
      await tester.tap(settingsAction);
      await tester.pump();
      expect(fixture.powerCalls.last, 'openAppSettings');
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      debugDefaultTargetPlatformOverride = null;
      semantics.dispose();
    }
  });
}

class _StartupFixture {
  final TestStorageAdapter storageService;
  final AppSettings appSettings;
  final StartupViewModel viewModel;
  final List<String> powerCalls;

  const _StartupFixture({
    required this.storageService,
    required this.appSettings,
    required this.viewModel,
    required this.powerCalls,
  });

  Future<void> dispose() async {
    viewModel.dispose();
    appSettings.dispose();
    await storageService.shutdown();
    storageService.dispose();
  }
}

Future<_StartupFixture> _createFixture({
  required AppLanguage language,
  bool isExempt = false,
  bool checkStatus = true,
  Completer<bool>? statusGate,
}) async {
  SharedPreferences.setMockInitialValues({'app_language': language.name});
  FlutterSecureStorage.setMockInitialValues({});

  final powerCalls = <String>[];
  var currentExemption = isExempt;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_powerChannel, (call) async {
        powerCalls.add(call.method);
        switch (call.method) {
          case 'isIgnoringBatteryOptimizations':
            if (statusGate != null && !statusGate.isCompleted) {
              return statusGate.future;
            }
            return currentExemption;
          case 'requestBatteryOptimizationExemption':
            currentExemption = true;
            return true;
          case 'openAppSettings':
            return true;
          default:
            return null;
        }
      });

  final storageService = TestStorageAdapter();
  await storageService.init();
  final appSettings = AppSettings();
  await appSettings.init();
  final viewModel = StartupViewModel(appSettings: appSettings);
  if (checkStatus) {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await viewModel.checkPowerGuideStatus();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  return _StartupFixture(
    storageService: storageService,
    appSettings: appSettings,
    viewModel: viewModel,
    powerCalls: powerCalls,
  );
}

Widget _guideHost(StartupViewModel viewModel, {double textScale = 1}) {
  return MaterialApp(
    theme: AppTheme.lightThemeFor(),
    home: Builder(
      builder: (context) {
        final mediaQuery = MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale));
        return MediaQuery(
          data: mediaQuery,
          child: AnimatedBuilder(
            animation: viewModel,
            builder: (context, _) => PowerGuideScreen(viewModel: viewModel),
          ),
        );
      },
    ),
  );
}

Widget _startupHost(StartupViewModel viewModel) {
  return MaterialApp(
    theme: AppTheme.lightThemeFor(),
    home: ChangeNotifierProvider<StartupViewModel>.value(
      value: viewModel,
      child: StartupScreen(
        homeBuilder: (_) =>
            const Scaffold(body: Center(child: Text('Home placeholder'))),
      ),
    ),
  );
}

void _expectButtonSemantics(WidgetTester tester, Finder finder, String label) {
  final semantics = tester.getSemantics(finder).getSemanticsData();
  expect(semantics.label, label);
  expect(semantics.flagsCollection.isButton, isTrue);
  expect(semantics.hasAction(SemanticsAction.tap), isTrue);
}
