import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/features/connection/viewmodels/connection_viewmodel.dart';
import 'package:ssh_mobile/features/sftp/viewmodels/sftp_viewmodel.dart';
import 'package:ssh_mobile/features/sftp/views/sftp_screen.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/theme/app_theme.dart';
import 'package:ssh_mobile/widgets/app_surface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppSettings appSettings;
  late StorageService storageService;
  late SshService sshService;
  late _FilePaneFakeSftpService sftpService;
  late PerformanceMonitorService performanceService;
  late ConnectionViewModel connectionViewModel;
  late SftpViewModel sftpViewModel;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    appSettings = AppSettings();
    await appSettings.init();
    await appSettings.toggleLanguage();

    storageService = StorageService();
    await storageService.init();
    sshService = SshService(storageService);
    sftpService = _FilePaneFakeSftpService(storageService);
    performanceService = PerformanceMonitorService(sshService, storageService);
    connectionViewModel = ConnectionViewModel(
      connectionRepository: storageService,
      sshService: sshService,
      sftpService: sftpService,
      performanceService: performanceService,
    );
    sftpViewModel = SftpViewModel(sftpService: sftpService);

    await storageService.addConnection(
      ConnectionConfig(
        id: 'server-1',
        name: 'Production',
        host: 'prod.example.com',
        port: 2222,
        username: 'deployment-user',
      ),
    );
    await connectionViewModel.fetchConnections();
    debugDefaultTargetPlatformOverride = null;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    sftpViewModel.dispose();
    connectionViewModel.dispose();
    performanceService.dispose();
    sftpService.dispose();
    sshService.dispose();
    storageService.dispose();
    appSettings.dispose();
  });

  Widget host({double textScale = 1, double keyboardInset = 0}) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appSettings),
        ChangeNotifierProvider.value(value: connectionViewModel),
        ChangeNotifierProvider.value(value: sftpViewModel),
      ],
      child: MaterialApp(
        theme: AppTheme.lightThemeFor(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            viewInsets: EdgeInsets.only(bottom: keyboardInset),
          ),
          child: child!,
        ),
        home: const Scaffold(body: SftpScreen()),
      ),
    );
  }

  void useViewport(
    WidgetTester tester, {
    required Size physicalSize,
    required double devicePixelRatio,
  }) {
    tester.view.physicalSize = physicalSize;
    tester.view.devicePixelRatio = devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  List<SftpEntry> entries({bool longLabels = false}) => [
    SftpEntry(
      connectionId: 'server-1',
      name: longLabels
          ? 'application-logs-with-a-very-long-directory-name'
          : 'logs',
      path: '/srv/logs',
      lowerName: 'logs',
      isDirectory: true,
      isLink: false,
      sizeLabel: '-',
      modifiedLabel: '2026-07-15 09:30',
    ),
    SftpEntry(
      connectionId: 'server-1',
      name: longLabels
          ? 'deployment-notes-with-a-very-long-file-name.md'
          : 'notes.md',
      path: '/srv/notes.md',
      lowerName: 'notes.md',
      isDirectory: false,
      isLink: false,
      size: 2048,
      sizeLabel: '2 KB',
      modifiedLabel: '2026-07-15 10:15',
    ),
  ];

  testWidgets('toolbar, file rows, actions, and path history are interactive', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      useViewport(
        tester,
        physicalSize: const Size(1280, 800),
        devicePixelRatio: 1,
      );
      sftpService.show(
        state: SftpConnectionState.connected,
        entries: entries(),
      );

      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sftp-file-toolbar')), findsOneWidget);
      expect(find.text('/srv'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('sftp-parent-directory'))),
        const Size(48, 48),
      );
      final uploadButton = tester.widget<FilledButton>(
        find.byKey(const ValueKey('sftp-upload-file')),
      );
      expect(
        uploadButton.style?.backgroundColor?.resolve({}),
        const Color(0xFF4338CA),
      );
      expect(uploadButton.style?.foregroundColor?.resolve({}), Colors.white);
      expect(
        tester.getSize(
          find.byKey(
            const ValueKey('sftp-entry-actions-server-1:/srv/notes.md'),
          ),
        ),
        const Size(48, 48),
      );

      final directorySemantics = tester.getSemantics(
        find.byKey(const ValueKey('sftp-entry-server-1:/srv/logs')),
      );
      expect(directorySemantics.label, contains('logs'));
      expect(directorySemantics.label, contains('Directory'));

      await tester.tap(find.byKey(const ValueKey('sftp-parent-directory')));
      await tester.pump();
      expect(sftpService.openParentCalls, 1);

      await tester.tap(
        find.byKey(const ValueKey('sftp-entry-server-1:/srv/logs')),
      );
      await tester.pump();
      expect(sftpService.openedPaths, ['/srv/logs']);

      await tester.tap(
        find.byKey(const ValueKey('sftp-entry-actions-server-1:/srv/notes.md')),
      );
      await tester.pumpAndSettle();
      expect(find.text('View file'), findsOneWidget);
      expect(find.text('Download file'), findsOneWidget);
      await tester.tapAt(const Offset(1100, 740));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('sftp-path-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Path history'), findsOneWidget);
      expect(find.byKey(const ValueKey('sftp-path-input')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('sftp-open-path'))),
        const Size(48, 48),
      );
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('loading, empty, error retry, and transfer states are explicit', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      useViewport(
        tester,
        physicalSize: const Size(1280, 800),
        devicePixelRatio: 1,
      );
      sftpService.show(state: SftpConnectionState.loading);

      await tester.pumpWidget(host());
      await tester.pump();
      expect(
        find.byKey(const ValueKey('sftp-directory-loading')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('sftp-directory-loading-spinner')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('sftp-directory-loading')),
          matching: find.byType(AppIconBadge),
        ),
        findsNothing,
      );

      sftpService.show(state: SftpConnectionState.connected);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('sftp-directory-empty')),
        findsOneWidget,
      );

      sftpService.show(
        state: SftpConnectionState.error,
        errorMessage: 'Permission denied',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('sftp-directory-error')),
        findsOneWidget,
      );
      expect(find.text('Permission denied'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sftp-directory-retry')));
      await tester.pump();
      expect(sftpService.refreshCalls, 1);

      sftpService.show(
        state: SftpConnectionState.connected,
        entries: entries(),
        activeTransfer: const SftpTransferState(
          id: 'transfer-1',
          name: 'archive.tar.gz',
          totalBytes: 4096,
          bytesTransferred: 2048,
          isUpload: false,
        ),
      );
      await tester.pumpAndSettle();
      final transferSemantics = tester.getSemantics(
        find.byKey(const ValueKey('sftp-transfer-banner')),
      );
      expect(transferSemantics.label, contains('Downloading archive.tar.gz'));
      expect(transferSemantics.value, contains('50%'));
      expect(
        tester.getSize(find.byKey(const ValueKey('sftp-cancel-transfer'))),
        const Size(48, 48),
      );
      await tester.tap(find.byKey(const ValueKey('sftp-cancel-transfer')));
      await tester.pump(const Duration(milliseconds: 20));
      expect(sftpService.cancelTransferCalls, 1);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('320dp at 200 percent keeps toolbar, transfer, rows, and sheet', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      useViewport(
        tester,
        physicalSize: const Size(1280, 2856),
        devicePixelRatio: 4,
      );
      sftpService.show(
        state: SftpConnectionState.connected,
        entries: entries(longLabels: true),
        currentPath: '/srv/apps/production/releases/current',
        activeTransfer: const SftpTransferState(
          id: 'transfer-2',
          name: 'production-release-archive.tar.gz',
          totalBytes: 8192,
          bytesTransferred: 2048,
          isUpload: true,
        ),
      );

      await tester.pumpWidget(host(textScale: 2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      for (final key in [
        'sftp-parent-directory',
        'sftp-refresh-directory',
        'sftp-disconnect',
        'sftp-cancel-transfer',
      ]) {
        expect(tester.getSize(find.byKey(ValueKey(key))), const Size(48, 48));
      }
      expect(
        tester.getSize(find.byKey(const ValueKey('sftp-path-button'))).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('sftp-upload-file'))).height,
        greaterThanOrEqualTo(48),
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey('sftp-path-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('sftp-path-input')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('sftp-open-path'))),
        const Size(48, 48),
      );
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('path history respects a short keyboard viewport', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      useViewport(
        tester,
        physicalSize: const Size(720, 480),
        devicePixelRatio: 1,
      );
      sftpService.show(
        state: SftpConnectionState.connected,
        entries: entries(),
        currentPath: '/srv/apps/production',
      );

      await tester.pumpWidget(host(textScale: 1.5, keyboardInset: 160));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const ValueKey('sftp-path-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byKey(const ValueKey('sftp-path-input')), findsOneWidget);
      expect(find.byKey(const ValueKey('sftp-open-path')), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

class _FilePaneFakeSftpService extends SftpService {
  _FilePaneFakeSftpService(super.storageService);

  SftpConnectionState _state = SftpConnectionState.connected;
  String? _errorMessage;
  String _currentPath = '/srv';
  List<SftpEntry> _entries = const [];
  int _entriesRevision = 0;
  SftpTransferState? _activeTransfer;

  int openParentCalls = 0;
  int refreshCalls = 0;
  int disconnectCalls = 0;
  int cancelTransferCalls = 0;
  final List<String> openedPaths = [];

  void show({
    required SftpConnectionState state,
    List<SftpEntry> entries = const [],
    String? errorMessage,
    String? currentPath,
    SftpTransferState? activeTransfer,
  }) {
    _state = state;
    _entries = List.unmodifiable(entries);
    _errorMessage = errorMessage;
    _currentPath = currentPath ?? _currentPath;
    _activeTransfer = activeTransfer;
    _entriesRevision++;
    notifyListeners();
  }

  @override
  String? get connectionId => 'server-1';

  @override
  String? get connectionName => 'Production';

  @override
  String get currentPath => _currentPath;

  @override
  SftpConnectionState get state => _state;

  @override
  String? get errorMessage => _errorMessage;

  @override
  int get entriesRevision => _entriesRevision;

  @override
  List<SftpEntry> get entries => _entries;

  @override
  bool get isConnected => _state != SftpConnectionState.disconnected;

  @override
  bool get isBusy =>
      _state == SftpConnectionState.connecting ||
      _state == SftpConnectionState.loading;

  @override
  SftpTransferState? get activeTransfer => _activeTransfer;

  @override
  bool get hasActiveTransfer => _activeTransfer != null;

  @override
  bool isConnectionBusy(String connectionId) => isBusy;

  @override
  bool isConnectionOpen(String connectionId) => isConnected;

  @override
  Future<void> openPath(String path) async {
    openedPaths.add(path);
    _currentPath = path;
    notifyListeners();
  }

  @override
  Future<void> openParent() async {
    openParentCalls++;
  }

  @override
  Future<void> refresh() async {
    refreshCalls++;
  }

  @override
  Future<void> disconnect({bool notify = true}) async {
    disconnectCalls++;
    _state = SftpConnectionState.disconnected;
    if (notify) notifyListeners();
  }

  @override
  void cancelActiveTransfer() {
    cancelTransferCalls++;
    final transfer = _activeTransfer;
    if (transfer != null) {
      _activeTransfer = transfer.copyWith(isCancelled: true);
    }
    notifyListeners();
  }
}
