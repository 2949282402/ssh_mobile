import 'package:feature_playbook/feature_playbook.dart';
import 'package:flutter/foundation.dart';
import '../../test_utils/ai_port_adapters.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:feature_ai/ai_chat.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;

import 'package:ssh_mobile/app/sftp_backend_adapters.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import '../../test_utils/test_storage_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<_PromptHarness> createHarness(WidgetTester tester) async {
    final harness = await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final storage = TestStorageAdapter();
      await storage.init();
      final initial = await storage.loadAiConnectionSettings();
      await storage.saveAiConnectionSettings(
        baseUrl: initial.baseUrl,
        model: initial.model,
        useCustomPrompts: true,
        customSystemPrompt: 'Initial custom prompt',
        customPlannerPrompt: 'Initial planner prompt',
      );

      final appSettings = AppSettings();
      final originalPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      late final SshService sshService;
      try {
        sshService = createTestSshService(storage);
      } finally {
        debugDefaultTargetPlatformOverride = originalPlatform;
      }
      final sftpService = createTestSftpService(storage);
      final performanceMonitor = createTestPerformanceMonitorService(
        sshService,
        storage,
      );
      final playbookService = createTestPlaybook(
        repository: storage.playbookRepository,
        sshService: sshService,
      );
      final ragService = await createTestRagService(storage);
      final viewModel = createAiChatViewModel(
        storageService: storage,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitorService: performanceMonitor,
        playbookService: playbookService,
        ragService: ragService,
        appSettings: appSettings,
      );
      return _PromptHarness(
        storage: storage,
        appSettings: appSettings,
        viewModel: viewModel,
        sshService: sshService,
        sftpService: sftpService,
        performanceMonitor: performanceMonitor,
        playbookService: playbookService,
        ragService: ragService,
      );
    });
    if (harness == null) {
      throw StateError('Prompt harness creation did not complete');
    }
    return harness;
  }

  Widget testApp(_PromptHarness harness) {
    return ChangeNotifierProvider<AiChatViewModel>.value(
      value: harness.viewModel,
      child: ShadTheme(
        data: ShadThemeData(brightness: Brightness.light),
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        fullscreenDialog: true,
                        builder: (_) => PromptCustomizerDialog(
                          strings: AiStrings(AppLanguage.en),
                        ),
                      ),
                    );
                  },
                  child: const Text('Open prompts'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openPrompts(WidgetTester tester, _PromptHarness harness) async {
    await tester.pumpWidget(testApp(harness));
    await tester.tap(find.text('Open prompts'));
    await tester.pumpAndSettle();
    expect(find.byType(PromptCustomizerDialog), findsOneWidget);
  }

  Future<void> cancelDiscardDialog(WidgetTester tester) async {
    await tester.tap(
      find.descendant(
        of: find.byType(ShadDialog),
        matching: find.text('Cancel'),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('prompt edits survive toggles and require exit confirmation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 3120);
    tester.view.devicePixelRatio = 3.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final harness = await createHarness(tester);
    addTearDown(() async {
      await tester.runAsync(harness.dispose);
    });
    await openPrompts(tester, harness);

    final editor = find.byKey(
      const ValueKey<String>('prompt-customizer-editor'),
    );
    final enabled = find.byKey(
      const ValueKey<String>('prompt-customizer-enabled'),
    );
    final save = find.byKey(const ValueKey<String>('prompt-customizer-save'));
    expect(
      tester.widget<TextField>(editor).controller?.text,
      'Initial custom prompt',
    );

    await tester.enterText(editor, 'Edited custom prompt');
    await tester.pump();
    await tester.tap(enabled);
    await tester.pumpAndSettle();
    await tester.tap(enabled);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(editor).controller?.text,
      'Edited custom prompt',
    );

    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(handled, isTrue);
    expect(find.text('Discard prompt changes?'), findsOneWidget);
    await cancelDiscardDialog(tester);
    expect(
      tester.widget<TextField>(editor).controller?.text,
      'Edited custom prompt',
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('prompt-customizer-close')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Discard prompt changes?'), findsOneWidget);
    await cancelDiscardDialog(tester);

    expect(tester.getSize(save).height, greaterThanOrEqualTo(48));
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.byType(PromptCustomizerDialog), findsNothing);
    final stored = await tester.runAsync(
      harness.storage.loadAiConnectionSettings,
    );
    if (stored == null) {
      throw StateError('Prompt settings load did not complete');
    }
    expect(stored.useCustomPrompts, isTrue);
    expect(stored.customSystemPrompt, 'Edited custom prompt');
    expect(tester.takeException(), isNull);
  });

  testWidgets('prompt editor stays reachable in 1.5K landscape with keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2856, 1280);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final harness = await createHarness(tester);
    addTearDown(() async {
      await tester.runAsync(harness.dispose);
    });
    await openPrompts(tester, harness);

    tester.view.viewInsets = const FakeViewPadding(bottom: 660);
    await tester.pumpAndSettle();

    final type = find.byKey(const ValueKey<String>('prompt-customizer-type'));
    final editor = find.byKey(
      const ValueKey<String>('prompt-customizer-editor'),
    );
    final save = find.byKey(const ValueKey<String>('prompt-customizer-save'));
    expect(type, findsOneWidget);
    expect(editor, findsOneWidget);
    expect(save, findsOneWidget);
    expect(tester.getSize(type).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(editor).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(save).height, greaterThanOrEqualTo(48));
    expect(
      find.byKey(const ValueKey<String>('prompt-customizer-enabled')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}

class _PromptHarness {
  const _PromptHarness({
    required this.storage,
    required this.appSettings,
    required this.viewModel,
    required this.sshService,
    required this.sftpService,
    required this.performanceMonitor,
    required this.playbookService,
    required this.ragService,
  });

  final TestStorageAdapter storage;
  final AppSettings appSettings;
  final AiChatViewModel viewModel;
  final SshService sshService;
  final SftpService sftpService;
  final monitoring.MonitoringService performanceMonitor;
  final PlaybookService playbookService;
  final TestRagService ragService;

  Future<void> dispose() async {
    viewModel.dispose();
    ragService.dispose();
    playbookService.dispose();
    performanceMonitor.dispose();
    sftpService.dispose();
    sshService.dispose();
    appSettings.dispose();
    await storage.shutdown();
    storage.dispose();
  }
}
