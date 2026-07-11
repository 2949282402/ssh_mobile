import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/features/ai_chat/viewmodels/ai_chat_viewmodel.dart';
import 'package:ssh_mobile/features/ai_chat/views/llm_chat_screen.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/playbook_service.dart';
import 'package:ssh_mobile/services/rag_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<_PromptHarness> createHarness() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final storage = StorageService();
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
      sshService = SshService(storage);
    } finally {
      debugDefaultTargetPlatformOverride = originalPlatform;
    }
    final sftpService = SftpService(storage);
    final performanceMonitor = PerformanceMonitorService(sshService, storage);
    final playbookService = PlaybookService(
      storageService: storage,
      sshService: sshService,
    );
    final ragService = RagService(storageService: storage);
    final viewModel = AiChatViewModel(
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
    );
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
    final harness = await createHarness();
    addTearDown(harness.dispose);
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
    final stored = await harness.storage.loadAiConnectionSettings();
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
    final harness = await createHarness();
    addTearDown(harness.dispose);
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
  });

  final StorageService storage;
  final AppSettings appSettings;
  final AiChatViewModel viewModel;

  void dispose() {
    viewModel.dispose();
    appSettings.dispose();
    storage.dispose();
  }
}
