import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:ssh_mobile/features/terminal/views/terminal_windows_screen.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/theme/app_theme.dart';

SshSession _buildSession({
  required String id,
  required String connectionId,
  required String connectionName,
  required String displayName,
  required SshConnectionState state,
  String? errorMessage,
  String? tmuxSessionName,
}) {
  return SshSession(
    id: id,
    connectionId: connectionId,
    connectionName: connectionName,
    displayName: displayName,
    tmuxSessionName: tmuxSessionName,
    tmuxAutoDeleteSeconds: tmuxSessionName == null ? null : 600,
    state: state,
    errorMessage: errorMessage,
    outputController: StreamController<String>.broadcast(),
    createdAt: DateTime(2026, 7, 15, 9, 30),
    updatedAt: DateTime(2026, 7, 15, 10, 0),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storageService;
  late _TerminalWindowsFakeSshService sshService;
  late AppSettings appSettings;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storageService = StorageService();
    await storageService.init();
    appSettings = AppSettings();
    await appSettings.init();
    if (appSettings.language != AppLanguage.en) {
      await appSettings.toggleLanguage();
    }
    sshService = _TerminalWindowsFakeSshService(
      storageService,
      sessions: [
        _buildSession(
          id: 'api-shell',
          connectionId: 'server-1',
          connectionName: 'Production',
          displayName: 'API maintenance window with a long descriptive name',
          state: SshConnectionState.connected,
          tmuxSessionName: 'ssh_mobile_api',
        ),
        _buildSession(
          id: 'worker-shell',
          connectionId: 'server-1',
          connectionName: 'Production',
          displayName: 'Worker diagnostics',
          state: SshConnectionState.error,
          errorMessage:
              'Connection timed out while negotiating the SSH transport.',
        ),
        _buildSession(
          id: 'staging-shell',
          connectionId: 'server-2',
          connectionName: 'Staging',
          displayName: 'Release verification',
          state: SshConnectionState.connecting,
        ),
      ],
    );
    debugDefaultTargetPlatformOverride = null;
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await sshService.closeFakeSessions();
    sshService.dispose();
    appSettings.dispose();
    storageService.dispose();
  });

  void useViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget host({String? connectionId, double textScale = 1}) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SshService>.value(value: sshService),
        ChangeNotifierProvider.value(value: appSettings),
      ],
      child: ShadTheme(
        data: ShadThemeData(brightness: Brightness.light),
        child: MaterialApp(
          theme: AppTheme.lightThemeFor(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          routes: {
            '/history': (_) => const Scaffold(body: Text('History route')),
            '/terminal': (_) => const Scaffold(body: Text('Terminal route')),
          },
          home: Scaffold(body: TerminalWindowsPage(connectionId: connectionId)),
        ),
      ),
    );
  }

  testWidgets('groups sessions and exposes status, tmux mode, and actions', (
    tester,
  ) async {
    useViewport(tester, const Size(1280, 800));
    await tester.pumpWidget(host());
    await tester.pump();

    expect(find.text('Production'), findsWidgets);
    expect(find.text('Staging'), findsWidgets);
    expect(find.textContaining('tmux'), findsWidgets);
    expect(find.textContaining('SSH'), findsWidgets);
    expect(
      find.text('Connection timed out while negotiating the SSH transport.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    expect(
      tester.getSize(
        find.byKey(const ValueKey('terminal-window-status-api-shell')),
      ),
      const Size(48, 48),
    );
    expect(
      tester.getSize(
        find.byKey(const ValueKey('terminal-window-menu-api-shell')),
      ),
      const Size(48, 48),
    );
    expect(
      tester
          .getSize(
            find.byKey(const ValueKey('terminal-window-cleanup-api-shell')),
          )
          .height,
      greaterThanOrEqualTo(48),
    );

    await tester.tap(
      find.byKey(const ValueKey('terminal-window-menu-worker-shell')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename window'));
    await tester.pumpAndSettle();
    expect(find.text('Rename window'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);

    await tester.enterText(find.byType(EditableText), 'Renamed worker shell');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Renamed worker shell'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection mode provides 48dp batch actions', (tester) async {
    useViewport(tester, const Size(900, 700));
    await tester.pumpWidget(host());
    await tester.pump();

    await tester.longPress(
      find.byKey(const ValueKey('terminal-window-card-api-shell')),
    );
    await tester.pump();

    expect(find.text('1 selected'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('terminal-windows-select-all'))),
      const Size(48, 48),
    );
    expect(
      tester.getSize(
        find.byKey(const ValueKey('terminal-windows-close-selected')),
      ),
      const Size(48, 48),
    );
    expect(
      find.byKey(const ValueKey('terminal-window-status-api-shell')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('320dp and 200% text uses a scroll-safe single-column layout', (
    tester,
  ) async {
    useViewport(tester, const Size(320, 720));
    await tester.pumpWidget(host(connectionId: 'server-1', textScale: 2));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey('terminal-windows-new'))),
      const Size(48, 48),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('terminal-windows-history'))),
      const Size(48, 48),
    );

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -520));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('terminal-window-card-worker-shell')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

class _TerminalWindowsFakeSshService extends SshService {
  _TerminalWindowsFakeSshService(
    super.storageService, {
    required List<SshSession> sessions,
  }) : _fakeSessions = sessions;

  final List<SshSession> _fakeSessions;

  @override
  List<SshSession> get sessions => List.unmodifiable(_fakeSessions);

  @override
  bool renameSession(String sessionId, String name) {
    final normalized = name.trim();
    if (normalized.isEmpty) return false;
    final session = _fakeSessions
        .where((item) => item.id == sessionId)
        .firstOrNull;
    if (session == null) return false;
    final duplicate = _fakeSessions.any(
      (item) =>
          item.id != sessionId &&
          item.displayName.trim().toLowerCase() == normalized.toLowerCase(),
    );
    if (duplicate) return false;
    session.displayName = normalized;
    notifyListeners();
    return true;
  }

  @override
  Future<void> disconnectSession(String sessionId) async {
    final session = _fakeSessions
        .where((item) => item.id == sessionId)
        .firstOrNull;
    if (session != null) {
      _fakeSessions.remove(session);
      await session.close();
      notifyListeners();
    }
  }

  Future<void> closeFakeSessions() async {
    for (final session in List<SshSession>.of(_fakeSessions)) {
      await session.close();
    }
    _fakeSessions.clear();
  }
}
