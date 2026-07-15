import 'dart:ui' show Tristate;

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
  late _FakeSftpService sftpService;
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
    sftpService = _FakeSftpService(storageService);
    performanceService = PerformanceMonitorService(sshService, storageService);
    connectionViewModel = ConnectionViewModel(
      connectionRepository: storageService,
      sshService: sshService,
      sftpService: sftpService,
      performanceService: performanceService,
    );
    sftpViewModel = SftpViewModel(sftpService: sftpService);
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

  Widget host({double textScale = 1}) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appSettings),
        ChangeNotifierProvider.value(value: connectionViewModel),
        ChangeNotifierProvider.value(value: sftpViewModel),
      ],
      child: MaterialApp(
        theme: AppTheme.lightThemeFor(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const Scaffold(body: SftpScreen()),
      ),
    );
  }

  Future<void> addServers({bool longLabels = false}) async {
    await storageService.addConnection(
      ConnectionConfig(
        id: 'server-1',
        name: longLabels
            ? 'Production gateway with a very long server name'
            : 'Production',
        host: longLabels ? '2001:db8:85a3::8a2e:370:7334' : 'prod.example.com',
        port: 2222,
        username: 'deployment-user',
      ),
    );
    await storageService.addConnection(
      ConnectionConfig(
        id: 'server-2',
        name: 'Staging',
        host: 'staging.example.com',
        username: 'operator',
      ),
    );
    await connectionViewModel.fetchConnections();
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

  testWidgets('empty state uses the shared SFTP page surface', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      useViewport(
        tester,
        physicalSize: const Size(1280, 2856),
        devicePixelRatio: 4,
      );

      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      expect(find.byType(AppPageSurface), findsOneWidget);
      expect(find.text('Select a server for SFTP'), findsOneWidget);
      expect(find.text('Add connection'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'desktop server cards expose status, semantics, and 48dp reorder',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        useViewport(
          tester,
          physicalSize: const Size(1200, 800),
          devicePixelRatio: 1,
        );
        await addServers();
        sftpService.setStatus('server-1', connected: true);

        await tester.pumpWidget(host());
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('sftp-server-pane')), findsOneWidget);
        expect(find.text('Connected'), findsOneWidget);
        expect(find.text('Disconnected'), findsOneWidget);
        expect(
          tester.getSize(
            find.byKey(const ValueKey('sftp-server-drag-server-1')),
          ),
          const Size(48, 48),
        );

        final semantics = tester.getSemantics(
          find.byKey(const ValueKey('sftp-server-tile-server-1')),
        );
        expect(semantics.label, contains('Production'));
        expect(semantics.label, contains('Connected'));
        expect(
          semantics.label,
          contains('deployment-user@prod.example.com:2222'),
        );
        expect(semantics.flagsCollection.isSelected, Tristate.isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('server cards connect and desktop rail collapses and expands', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      useViewport(
        tester,
        physicalSize: const Size(1200, 800),
        devicePixelRatio: 1,
      );
      await addServers();
      sftpService.setStatus('server-1', connected: true);

      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('sftp-server-tile-server-2')));
      await tester.pumpAndSettle();

      expect(sftpService.connectCalls, ['server-2']);
      expect(sftpService.connectionId, 'server-2');
      expect(sftpService.isConnectionOpen('server-2'), isTrue);
      expect(find.byKey(const ValueKey('sftp-server-pane')), findsNothing);
      expect(find.byTooltip('Expand server list'), findsOneWidget);

      await tester.tap(find.byTooltip('Expand server list'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sftp-server-pane')), findsOneWidget);
      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey('sftp-server-tile-server-1')),
            )
            .flagsCollection
            .isSelected,
        Tristate.isFalse,
      );
      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey('sftp-server-tile-server-2')),
            )
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    '320dp mobile layout supports 200 percent text and collapse state',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        useViewport(
          tester,
          physicalSize: const Size(1280, 2856),
          devicePixelRatio: 4,
        );
        await addServers(longLabels: true);
        sftpService.setStatus('server-1', connected: true);

        await tester.pumpWidget(host(textScale: 2));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('sftp-mobile-server-strip')),
          findsOneWidget,
        );
        expect(
          tester
              .getSize(find.byKey(const ValueKey('sftp-mobile-server-strip')))
              .height,
          110,
        );
        expect(
          tester.getSize(
            find.byKey(const ValueKey('sftp-server-collapse-mobile')),
          ),
          const Size(48, 48),
        );
        final cardSize = tester.getSize(
          find.byKey(const ValueKey('sftp-server-tile-server-1')),
        );
        expect(cardSize.width, 210);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byTooltip('Collapse server list'));
        await tester.pumpAndSettle();

        expect(
          tester.getSize(
            find.byKey(const ValueKey('sftp-server-expand-mobile')),
          ),
          const Size(48, 48),
        );
        final collapsedSummary = tester.getSemantics(
          find.byKey(const ValueKey('sftp-collapsed-server-summary')),
        );
        expect(
          collapsedSummary.label,
          contains('Production gateway with a very long server name'),
        );
        expect(collapsedSummary.label, contains('Connected'));
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}

class _FakeSftpService extends SftpService {
  _FakeSftpService(super.storageService);

  final List<String> connectCalls = [];
  final Set<String> _busyConnections = {};
  final Set<String> _openConnections = {};
  String? _selectedConnectionId;

  void setStatus(
    String connectionId, {
    bool busy = false,
    bool connected = false,
  }) {
    _selectedConnectionId = connectionId;
    if (busy) {
      _busyConnections.add(connectionId);
    } else {
      _busyConnections.remove(connectionId);
    }
    if (connected) {
      _openConnections.add(connectionId);
    } else {
      _openConnections.remove(connectionId);
    }
    notifyListeners();
  }

  @override
  String? get connectionId => _selectedConnectionId;

  @override
  SftpConnectionState get state {
    final id = _selectedConnectionId;
    if (id == null) return SftpConnectionState.disconnected;
    if (_busyConnections.contains(id)) return SftpConnectionState.connecting;
    if (_openConnections.contains(id)) return SftpConnectionState.connected;
    return SftpConnectionState.disconnected;
  }

  @override
  bool get isConnected {
    final id = _selectedConnectionId;
    return id != null && _openConnections.contains(id);
  }

  @override
  bool get isBusy {
    final id = _selectedConnectionId;
    return id != null && _busyConnections.contains(id);
  }

  @override
  bool isConnectionBusy(String connectionId) =>
      _busyConnections.contains(connectionId);

  @override
  bool isConnectionOpen(String connectionId) =>
      _openConnections.contains(connectionId);

  @override
  Future<void> connect(String connectionId, {dynamic onUnknownHostKey}) async {
    connectCalls.add(connectionId);
    _selectedConnectionId = connectionId;
    _busyConnections.add(connectionId);
    notifyListeners();
    await Future<void>.delayed(Duration.zero);
    _busyConnections.remove(connectionId);
    _openConnections.add(connectionId);
    notifyListeners();
  }
}
