import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ssh_mobile/features/terminal/views/terminal_app_bar.dart';
import 'package:ssh_mobile/features/terminal/views/terminal_connection_overlay.dart';
import 'package:ssh_mobile/features/terminal/views/terminal_shortcut_panel.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/shortcut_command_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:app_ui/app_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void useViewport(
    WidgetTester tester, {
    required Size physicalSize,
    double devicePixelRatio = 1,
  }) {
    tester.view.physicalSize = physicalSize;
    tester.view.devicePixelRatio = devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget appHost({required Widget home, double textScale = 1}) {
    return MaterialApp(
      theme: AppTheme.lightThemeFor(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: home,
    );
  }

  group('terminal workspace chrome', () {
    testWidgets('app bar exposes endpoint, real status, and 48dp actions', (
      tester,
    ) async {
      useViewport(tester, physicalSize: const Size(320, 640));
      var switchCalls = 0;
      var reconnectCalls = 0;

      await tester.pumpWidget(
        appHost(
          textScale: 2,
          home: Scaffold(
            appBar: TerminalScreenAppBar(
              strings: const TerminalStrings(AppLanguage.en),
              displayName: 'Production shell with a long session name',
              serverName: 'Production',
              serverEndpoint: 'deployment@prod.example.com:2222',
              connectionState: SshConnectionState.error,
              isDarkMode: false,
              reconnectInProgress: false,
              onReconnect: () => reconnectCalls++,
              onToggleTheme: () {},
              onSwitchWindow: () => switchCalls++,
              onCloseWindow: () {},
              onOpenSiblingSession: () {},
              onSmallerFont: () {},
              onLargerFont: () {},
            ),
            body: const SizedBox.expand(),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const ValueKey('terminal-switch-window'))),
        const Size(48, 48),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('terminal-more-actions'))),
        const Size(48, 48),
      );
      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey('terminal-connection-status')),
            )
            .label,
        contains('Error'),
      );

      await tester.tap(find.byKey(const ValueKey('terminal-switch-window')));
      expect(switchCalls, 1);

      await tester.tap(find.byKey(const ValueKey('terminal-more-actions')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reconnect'));
      await tester.pumpAndSettle();
      expect(reconnectCalls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('error overlay remains usable at 320dp and 200% text', (
      tester,
    ) async {
      useViewport(tester, physicalSize: const Size(320, 720));
      var reconnectCalls = 0;
      var switchCalls = 0;
      var closeCalls = 0;

      await tester.pumpWidget(
        appHost(
          textScale: 2,
          home: Scaffold(
            body: TerminalConnectionOverlay(
              strings: const TerminalStrings(AppLanguage.en),
              connectionState: SshConnectionState.error,
              reconnectInProgress: false,
              terminalBackground: const Color(0xFF09090B),
              endpoint: 'deployment@prod.example.com:2222',
              errorMessage: 'Host key negotiation failed after timeout',
              onReconnect: () => reconnectCalls++,
              onSwitchWindow: () => switchCalls++,
              onCloseWindow: () => closeCalls++,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Could not connect to the terminal'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('terminal-reconnect'))).height,
        greaterThanOrEqualTo(48),
      );

      await tester.ensureVisible(
        find.byKey(const ValueKey('terminal-reconnect')),
      );
      await tester.tap(find.byKey(const ValueKey('terminal-reconnect')));
      await tester.ensureVisible(
        find.byKey(const ValueKey('terminal-manage-windows')),
      );
      await tester.tap(find.byKey(const ValueKey('terminal-manage-windows')));
      await tester.ensureVisible(
        find.byKey(const ValueKey('terminal-close-window')),
      );
      await tester.tap(find.byKey(const ValueKey('terminal-close-window')));

      expect(reconnectCalls, 1);
      expect(switchCalls, 1);
      expect(closeCalls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('connecting overlay fits a short landscape viewport', (
      tester,
    ) async {
      useViewport(tester, physicalSize: const Size(640, 320));

      await tester.pumpWidget(
        appHost(
          home: Scaffold(
            body: TerminalConnectionOverlay(
              strings: const TerminalStrings(AppLanguage.en),
              connectionState: SshConnectionState.connecting,
              reconnectInProgress: false,
              terminalBackground: const Color(0xFF09090B),
              endpoint: 'ops@staging.example.com:22',
              onReconnect: () {},
              onSwitchWindow: () {},
              onCloseWindow: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Connecting to the terminal'), findsOneWidget);
      expect(find.byKey(const ValueKey('terminal-reconnect')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('terminal shortcut panel', () {
    late StorageService storageService;
    late SshService sshService;
    late ShortcutCommandService shortcutService;
    late TextEditingController inputController;
    late FocusNode focusNode;

    setUp(() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      storageService = StorageService();
      await storageService.init();
      sshService = SshService(storageService);
      debugDefaultTargetPlatformOverride = null;
      shortcutService = ShortcutCommandService();
      await shortcutService.init();
      inputController = TextEditingController();
      focusNode = FocusNode();
    });

    tearDown(() async {
      focusNode.dispose();
      inputController.dispose();
      shortcutService.dispose();
      sshService.dispose();
      await storageService.shutdown();
      storageService.dispose();
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets(
      'compact 200% layout keeps actions tappable and sheet scrollable',
      (tester) async {
        useViewport(tester, physicalSize: const Size(320, 720));
        String? submittedCommand;

        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: shortcutService),
              ChangeNotifierProvider.value(value: sshService),
            ],
            child: appHost(
              textScale: 2,
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: TerminalShortcutPanel(
                    sessionId: 'session-1',
                    strings: const TerminalStrings(AppLanguage.en),
                    toolbarColor: const Color(0xFF09090B),
                    complexInputController: inputController,
                    onSendComplexInput: (value) => submittedCommand = value,
                    onTerminalStroke: (_) {},
                    terminalFocusNode: focusNode,
                    ctrlActive: false,
                    onToggleCtrl: () {},
                    altActive: false,
                    onToggleAlt: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(find.byKey(const ValueKey('terminal-add-shortcut'))),
          const Size(48, 48),
        );
        expect(
          tester.getSize(
            find.byKey(const ValueKey('terminal-advanced-keyboard')),
          ),
          const Size(48, 48),
        );

        await tester.tap(
          find.byKey(const ValueKey('terminal-advanced-keyboard')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Windows Keyboard'), findsOneWidget);
        expect(find.text('Function Keys'), findsOneWidget);
        final symbolsLayer = find.byKey(
          const ValueKey('terminal-keyboard-layer-symbols'),
        );
        await tester.ensureVisible(symbolsLayer);
        await tester.pumpAndSettle();
        await tester.tap(symbolsLayer);
        await tester.pump();
        await tester.ensureVisible(
          find.byKey(const ValueKey('terminal-custom-key-pipe')),
        );
        await tester.tap(
          find.byKey(const ValueKey('terminal-custom-key-pipe')),
        );
        expect(inputController.text, '|');

        await tester.enterText(
          find.byKey(const ValueKey('terminal-custom-keyboard-input')),
          'printf "first"\nprintf "second"',
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('terminal-custom-keyboard-send')),
        );
        await tester.tap(
          find.byKey(const ValueKey('terminal-custom-keyboard-send')),
        );
        await tester.pumpAndSettle();
        expect(submittedCommand, 'printf "first"\nprintf "second"');
        expect(inputController.text, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
