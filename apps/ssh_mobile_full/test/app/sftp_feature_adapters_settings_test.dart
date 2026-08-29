import 'package:connection_core/connection_core.dart';
import 'package:feature_sftp/feature_sftp.dart' as feature_sftp;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;
import 'package:ssh_mobile/app/sftp_feature_adapters.dart';
import 'package:ssh_mobile/services/app_settings.dart';

import 'support/feature_adapter_test_fakes.dart';

void main() {
  test('SFTP settings adapter maps language and forwards writes', () async {
    final settings = FakeAppSettings()..language = AppLanguage.zh;
    final adapter = AppSftpSettingsAdapter(settings);
    var notifications = 0;
    adapter.addListener(() => notifications++);

    expect(adapter.language, feature_sftp.SftpLanguage.chinese);
    expect(adapter.sftpDownloadLimitBytes, settings.sftpDownloadLimitBytes);
    expect(
      adapter.sftpTextPreviewLimitBytes,
      settings.sftpTextPreviewLimitBytes,
    );
    expect(
      adapter.sftpRichPreviewLimitBytes,
      settings.sftpRichPreviewLimitBytes,
    );
    expect(adapter.sftpTextEditLimitBytes, settings.sftpTextEditLimitBytes);

    settings.language = AppLanguage.en;
    settings.emitChange();
    expect(adapter.language, feature_sftp.SftpLanguage.english);
    expect(notifications, 1);

    await adapter.setSftpDownloadLimitBytes(1);
    await adapter.setSftpTextPreviewLimitBytes(2);
    await adapter.setSftpRichPreviewLimitBytes(3);
    await adapter.setSftpTextEditLimitBytes(4);
    expect(settings.sftpDownloadLimits, <int>[1]);
    expect(settings.sftpTextPreviewLimits, <int>[2]);
    expect(settings.sftpRichPreviewLimits, <int>[3]);
    expect(settings.sftpTextEditLimits, <int>[4]);

    adapter.dispose();
    adapter.dispose();
    settings.emitChange();
    expect(notifications, 1);
  });

  test(
    'connection catalog forwards snapshots and listener lifecycle',
    () async {
      final viewModel = FakeConnectionViewModel(
        isLoading: true,
        connections: <ConnectionConfig>[
          ConnectionConfig(
            id: 'c1',
            name: 'Server A',
            host: '10.0.0.1',
            port: 22,
            username: 'root',
          ),
        ],
      );
      final adapter = AppSftpConnectionCatalogAdapter(viewModel);
      var notifications = 0;
      adapter.addListener(() => notifications++);

      expect(adapter.isLoading, isTrue);
      final connection = adapter.connections.single;
      expect(connection.id, 'c1');
      expect(connection.name, 'Server A');
      expect(connection.host, '10.0.0.1');
      expect(connection.port, 22);
      expect(connection.username, 'root');

      await adapter.reorderConnections(0, 1);
      expect(viewModel.reorderCalls.single.oldIndex, 0);
      expect(viewModel.reorderCalls.single.newIndex, 1);

      viewModel.emitChange();
      expect(notifications, 1);
      adapter.dispose();
      adapter.dispose();
      viewModel.emitChange();
      expect(notifications, 1);
    },
  );

  test(
    'connection catalog stays empty when no view model is supplied',
    () async {
      final adapter = AppSftpConnectionCatalogAdapter(null);

      expect(adapter.isLoading, isFalse);
      expect(adapter.connections, isEmpty);
      await expectLater(adapter.reorderConnections(0, 1), completes);
      adapter.dispose();
    },
  );

  testWidgets('host key confirmation adapts the request and trusts the key', (
    tester,
  ) async {
    final settings = FakeAppSettings()..language = AppLanguage.en;
    late BuildContext capturedContext;
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AppSettings>.value(
          value: settings,
          child: Builder(
            builder: (context) {
              capturedContext = context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    final adapter = AppSftpHostKeyConfirmationAdapter(() => capturedContext);
    final confirmation = adapter.confirm(_coreHostKeyRequest());
    await tester.pumpAndSettle();
    expect(find.text('Trust SSH host key?'), findsOneWidget);

    await tester.tap(find.text('Trust key'));
    await tester.pumpAndSettle();
    expect(await confirmation, isTrue);
  });

  testWidgets('host key confirmation returns false when the user cancels', (
    tester,
  ) async {
    final settings = FakeAppSettings()..language = AppLanguage.en;
    late BuildContext capturedContext;
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<AppSettings>.value(
          value: settings,
          child: Builder(
            builder: (context) {
              capturedContext = context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    final adapter = AppSftpHostKeyConfirmationAdapter(() => capturedContext);
    final confirmation = adapter.confirm(_coreHostKeyRequest());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await confirmation, isFalse);
  });

  test('logger adapter forwards structured error calls', () {
    final logger = FakeAppLogService();
    final adapter = AppSftpLoggerAdapter(logger);
    final stackTrace = StackTrace.current;
    final failure = StateError('boom');

    adapter.error(
      'sftp failed',
      error: failure,
      stackTrace: stackTrace,
      details: 'detail',
    );

    expect(logger.calls, hasLength(1));
    final call = logger.calls.single;
    expect(call.level, 'error');
    expect(call.message, 'sftp failed');
    expect(call.error, same(failure));
    expect(call.stackTrace, same(stackTrace));
    expect(call.details, 'detail');
  });
}

ssh_core.SshHostKeyPromptRequest _coreHostKeyRequest() {
  return ssh_core.SshHostKeyPromptRequest(
    connectionId: 'c1',
    connectionName: 'Server A',
    host: '10.0.0.1',
    port: 22,
    username: 'root',
    algorithm: 'ssh-ed25519',
    fingerprint: 'SHA256:abc',
  );
}
