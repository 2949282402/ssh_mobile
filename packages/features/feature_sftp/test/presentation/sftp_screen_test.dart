import 'package:app_core/app_core.dart';
import 'package:app_ui/app_ui.dart';
import 'package:drift/native.dart';
import 'package:feature_sftp/feature_sftp.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ssh_core/ssh_core.dart';

import '../fakes/sftp_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders the connected directory through Feature ports', (
    tester,
  ) async {
    final fixture = await _SftpScreenFixture.create();
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.host());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('sftp-file-toolbar')), findsOneWidget);
    expect(find.text('/srv'), findsOneWidget);
    expect(find.text('notes.md'), findsOneWidget);
    expect(find.text('logs'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('server selector uses the injected connection catalog', (
    tester,
  ) async {
    final fixture = await _SftpScreenFixture.create();
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.host());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('sftp-server-tile-server-1')),
      findsOneWidget,
    );
    expect(find.text('Production'), findsOneWidget);
    expect(find.text('deployment-user@prod.example.com:2222'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'renders skeleton loading state when directory is busy and entries are empty',
    (tester) async {
      final fixture = await _SftpScreenFixture.create();
      addTearDown(fixture.dispose);
      fixture.backend.state = SftpConnectionState.loading;
      fixture.backend.entries = const [];
      fixture.backend.isBusy = true;
      fixture.backend.notifyListeners();

      await tester.pumpWidget(fixture.host());
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.byKey(const ValueKey('sftp-directory-loading')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'renders catalog skeleton loading state when storage is not ready',
    (tester) async {
      final fixture = await _SftpScreenFixture.create();
      addTearDown(fixture.dispose);
      fixture.catalog.isLoading = true;
      fixture.catalog.notifyListeners();

      await tester.pumpWidget(fixture.host());
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(AppSkeletonizer), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'retains real entries and displays progress indicator when directory refreshes with existing items',
    (tester) async {
      final fixture = await _SftpScreenFixture.create();
      addTearDown(fixture.dispose);
      fixture.backend.state = SftpConnectionState.loading;
      fixture.backend.isBusy = true;
      fixture.backend.notifyListeners();

      await tester.pumpWidget(fixture.host());
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('notes.md'), findsOneWidget);
      expect(find.text('logs'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(
        find.byKey(const ValueKey('sftp-directory-loading')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

final class _SftpScreenFixture {
  _SftpScreenFixture._({
    required this.module,
    required this.viewModel,
    required this.backend,
    required this.settings,
    required this.catalog,
  });

  final SftpModule module;
  final SftpViewModel viewModel;
  final FakeSftpBackend backend;
  final _FakeSftpSettings settings;
  final _FakeSftpCatalog catalog;

  static Future<_SftpScreenFixture> create() async {
    final backend = FakeSftpBackend()
      ..connectionId = 'server-1'
      ..connectionName = 'Production'
      ..currentPath = '/srv'
      ..state = SftpConnectionState.connected
      ..isConnected = true
      ..entries = [
        const SftpEntry(
          connectionId: 'server-1',
          targetFingerprint: 'target-1',
          name: 'logs',
          path: '/srv/logs',
          lowerName: 'logs',
          isDirectory: true,
          isLink: false,
          sizeLabel: '-',
        ),
        const SftpEntry(
          connectionId: 'server-1',
          targetFingerprint: 'target-1',
          name: 'notes.md',
          path: '/srv/notes.md',
          lowerName: 'notes.md',
          isDirectory: false,
          isLink: false,
          size: 2048,
          sizeLabel: '2 KB',
        ),
      ];
    final module = SftpModule(
      databaseFactory: () => SftpDatabase.forTesting(NativeDatabase.memory()),
    );
    await module.register(
      ModuleContext.fromMap(<Type, Object>{
        SshSessionManager: FakeSshSessionManager(),
        SftpBackend: backend,
      }),
    );
    await module.initialize();
    await module.activate();

    return _SftpScreenFixture._(
      module: module,
      viewModel: SftpViewModel(module.service),
      backend: backend,
      settings: _FakeSftpSettings(),
      catalog: _FakeSftpCatalog(),
    );
  }

  Widget host() => MultiProvider(
    providers: [
      ChangeNotifierProvider<SftpViewModel>.value(value: viewModel),
      ListenableProvider<SftpSettingsPort>.value(value: settings),
      ChangeNotifierProvider<_FakeSftpCatalog>.value(value: catalog),
      ListenableProvider<SftpConnectionCatalogPort>.value(value: catalog),
      Provider<SftpHostKeyConfirmationPort>.value(
        value: const _FakeSftpHostKeyConfirmation(),
      ),
    ],
    child: const MaterialApp(home: Scaffold(body: SftpScreen())),
  );

  Future<void> dispose() async {
    viewModel.dispose();
    await module.dispose();
  }
}

final class _FakeSftpCatalog extends ChangeNotifier
    implements SftpConnectionCatalogPort {
  @override
  bool isLoading = false;

  @override
  List<SftpConnectionInfo> connections = const [
    SftpConnectionInfo(
      id: 'server-1',
      name: 'Production',
      host: 'prod.example.com',
      port: 2222,
      username: 'deployment-user',
    ),
  ];

  @override
  Future<void> reorderConnections(int oldIndex, int newIndex) async {}
}

final class _FakeSftpSettings extends ChangeNotifier
    implements SftpSettingsPort {
  @override
  SftpLanguage language = SftpLanguage.english;

  @override
  int sftpDownloadLimitBytes = 64 * 1024 * 1024;

  @override
  int sftpTextPreviewLimitBytes = 4 * 1024 * 1024;

  @override
  int sftpRichPreviewLimitBytes = 16 * 1024 * 1024;

  @override
  int sftpTextEditLimitBytes = 4 * 1024 * 1024;

  @override
  Future<void> setSftpDownloadLimitBytes(int bytes) async {
    sftpDownloadLimitBytes = bytes;
  }

  @override
  Future<void> setSftpTextPreviewLimitBytes(int bytes) async {
    sftpTextPreviewLimitBytes = bytes;
  }

  @override
  Future<void> setSftpRichPreviewLimitBytes(int bytes) async {
    sftpRichPreviewLimitBytes = bytes;
  }

  @override
  Future<void> setSftpTextEditLimitBytes(int bytes) async {
    sftpTextEditLimitBytes = bytes;
  }
}

final class _FakeSftpHostKeyConfirmation
    implements SftpHostKeyConfirmationPort {
  const _FakeSftpHostKeyConfirmation();

  @override
  Future<bool> confirm(SshHostKeyPromptRequest request) async => true;
}
