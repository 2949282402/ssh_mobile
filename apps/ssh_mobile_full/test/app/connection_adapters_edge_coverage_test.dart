import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:connection_core/connection_core.dart';
import 'package:feature_connection/feature_connection.dart';
import 'package:feature_monitoring/feature_monitoring.dart' as monitoring;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:provider/provider.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;
import 'package:ssh_mobile/app/connection_repository_adapters.dart';
import 'package:ssh_mobile/app/connection_runtime_adapters.dart';
import 'package:ssh_mobile/app/connection_ui_adapters.dart';
import 'package:ssh_mobile/app/network_sdk_adapters.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/ssh_service.dart';

import 'support/sftp_service_test_fakes.dart';
import 'support/ssh_terminal_test_fakes.dart';
import '../test_utils/test_storage_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'repository adapters forward storage, credentials, and host keys',
    () async {
      final storage = TestStorageAdapter();
      addTearDown(storage.dispose);
      final repository = AppConnectionRepositoryAdapter(
        primary: storage.connectionRepository,
      );
      final credentials = AppConnectionCredentialAdapter(
        primary: storage.credentialRepository,
      );
      final hostKeys = AppConnectionHostKeyAdapter(
        primary: storage.hostKeyRepository,
      );
      final first = _connection('first');
      final second = _connection('second');

      expect(repository.connections, isEmpty);
      await repository.initialize();
      await repository.addConnection(first);
      await repository.addConnection(second);
      expect((await repository.loadConnections()).map((item) => item.id), [
        'first',
        'second',
      ]);
      expect(repository.getConnection('first')!.name, 'first');

      await repository.updateConnection(first.copyWith(name: 'renamed'));
      await repository.reorderConnections(0, 1);
      expect(repository.connections.map((item) => item.name), [
        'second',
        'renamed',
      ]);

      await credentials.saveCredentials(
        connectionId: 'first',
        password: 'secret',
        privateKey: 'key',
      );
      expect(await credentials.getPassword('first'), 'secret');
      expect(await credentials.getPrivateKey('first'), 'key');
      await credentials.deleteCredentials('first');
      expect(await credentials.getPassword('first'), isNull);

      final trustedAt = DateTime.utc(2026, 8, 30);
      await hostKeys.trustHostKey(
        'first',
        algorithm: 'ssh-ed25519',
        fingerprint: 'SHA256:test',
        trustedAt: trustedAt,
      );
      final trusted = repository.getConnection('first')!;
      expect(trusted.hostKeyAlgorithm, 'ssh-ed25519');
      expect(trusted.hostKeyFingerprint, 'SHA256:test');
      expect(trusted.hostKeyTrustedAt, trustedAt);

      await repository.deleteConnection('second');
      await repository.deleteConnections(<String>['first']);
      expect(repository.connections, isEmpty);
    },
  );

  test('runtime adapter keeps optional service owners non-owning', () async {
    final adapter = AppConnectionRuntimeAdapter();

    expect(adapter.errorMessage, isNull);
    expect(await adapter.activeWindowCount('missing'), 0);
    await adapter.disconnectSessionsForConnection('missing');
    await adapter.cleanupConnectionResources('missing');
    expect(await adapter.openTerminalSession('missing', 'window'), isNull);
  });

  test(
    'runtime adapter forwards lifecycle and host-key prompt contracts',
    () async {
      final ssh = FakeSshService()
        ..errorMessage = 'last error'
        ..sessions = <SshSession>[]
        ..sessionCountResult = 3
        ..sessionConnectedResult = true
        ..openSessionResult = 'session-42'
        ..invokeUnknownHostKey = true
        ..unknownHostKeyRequest = const ssh_core.SshHostKeyPromptRequest(
          connectionId: 'server-1',
          connectionName: 'Server 1',
          host: 'server.example.test',
          port: 22,
          username: 'operator',
          algorithm: 'ssh-ed25519',
          fingerprint: 'SHA256:test',
        );
      final sftp = FakeSftpService();
      final monitoringService = _RecordingMonitoringService();
      final adapter = AppConnectionRuntimeAdapter(
        sshServiceFactory: () => ssh,
        sftpServiceFactory: () => sftp,
        monitoringServiceFactory: () => monitoringService,
      );

      expect(adapter.errorMessage, 'last error');
      expect(await adapter.activeWindowCount('server-1'), 3);
      expect(ssh.ensureInitializedCalls, 1);
      await adapter.disconnectSessionsForConnection('server-1');
      expect(ssh.disconnectSessionsForConnectionCalls, 1);
      expect(ssh.ensureInitializedCalls, 2);

      await adapter.cleanupConnectionResources('server-1');
      expect(ssh.disconnectSessionsForConnectionCalls, 2);
      expect(sftp.connectionDisconnects.single, (
        connectionId: 'server-1',
        notify: true,
        forgetPath: true,
      ));
      expect(monitoringService.stoppedIds, ['server-1']);

      ConnectionHostKeyPrompt? seenPrompt;
      final sessionId = await adapter.openTerminalSession(
        'server-1',
        'window',
        onUnknownHostKey: (prompt) async {
          seenPrompt = prompt;
          return true;
        },
      );
      expect(sessionId, 'session-42');
      expect(seenPrompt?.host, 'server.example.test');
      expect(seenPrompt?.fingerprint, 'SHA256:test');
      expect(ssh.capturedUnknownHostKey, isNotNull);
    },
  );

  test('verification adapter uses the injected client and closes it', () async {
    final storage = TestStorageAdapter();
    addTearDown(storage.dispose);
    final clients = <_RecordingVerificationClient>[];
    ssh_core.SshCredentials? seenCredentials;
    ssh_core.SshHostKeyPromptRequest? seenRequest;
    final adapter = AppConnectionVerificationAdapter(
      credentialRepository: storage.credentialRepository,
      hostKeyRepository: storage.hostKeyRepository,
      logger: AppLogService.instance,
      connector: (config, credentials, onUnknownHostKey) async {
        expect(config.id, 'verify-1');
        seenCredentials = credentials;
        if (onUnknownHostKey != null) {
          final accepted = await onUnknownHostKey(
            const ssh_core.SshHostKeyPromptRequest(
              connectionId: 'verify-1',
              connectionName: 'Verify',
              host: 'verify.example.test',
              port: 22,
              username: 'operator',
              algorithm: 'ssh-ed25519',
              fingerprint: 'SHA256:verify',
            ),
          );
          expect(accepted, isTrue);
          seenRequest = const ssh_core.SshHostKeyPromptRequest(
            connectionId: 'verify-1',
            connectionName: 'Verify',
            host: 'verify.example.test',
            port: 22,
            username: 'operator',
            algorithm: 'ssh-ed25519',
            fingerprint: 'SHA256:verify',
          );
        }
        final client = _RecordingVerificationClient();
        clients.add(client);
        return client;
      },
    );
    final config = _connection('verify-1')
      ..hostKeyAlgorithm = 'ssh-ed25519'
      ..hostKeyFingerprint = 'SHA256:stored'
      ..hostKeyTrustedAt = DateTime.utc(2026, 8, 30);

    final result = await adapter.verify(
      config,
      password: 'password',
      privateKey: 'private-key',
      onUnknownHostKey: (prompt) async {
        expect(prompt.connectionId, 'verify-1');
        expect(prompt.algorithm, 'ssh-ed25519');
        return true;
      },
    );
    expect(seenCredentials?.password, 'password');
    expect(seenCredentials?.privateKey, 'private-key');
    expect(seenRequest?.fingerprint, 'SHA256:verify');
    expect(result.algorithm, 'ssh-ed25519');
    expect(result.fingerprint, 'SHA256:stored');
    expect(result.trustedAt, DateTime.utc(2026, 8, 30));
    expect(clients.single.pingCalls, 1);
    expect(clients.single.closed, isTrue);

    final failing = _RecordingVerificationClient(
      pingError: StateError('ping failed'),
    );
    final failingAdapter = AppConnectionVerificationAdapter(
      credentialRepository: storage.credentialRepository,
      hostKeyRepository: storage.hostKeyRepository,
      logger: AppLogService.instance,
      connector: (_, __, ___) async => failing,
    );
    await expectLater(
      failingAdapter.verify(config, password: null, privateKey: null),
      throwsA(isA<StateError>()),
    );
    expect(failing.closed, isTrue);
  });

  testWidgets('UI adapter maps host-key prompts and logs both save contexts', (
    tester,
  ) async {
    final settings = AppSettings();
    addTearDown(settings.dispose);
    final adapter = AppConnectionUiAdapter();
    final prompt = const ConnectionHostKeyPrompt(
      connectionId: 'server-1',
      connectionName: 'Server 1',
      host: 'server.example.test',
      port: 22,
      username: 'operator',
      algorithm: 'ssh-ed25519',
      fingerprint: 'SHA256:test',
    );
    adapter.logSaveFailure(
      error: StateError('save failed'),
      stackTrace: StackTrace.current,
      config: null,
    );
    adapter.logSaveFailure(
      error: StateError('save failed'),
      stackTrace: StackTrace.current,
      config: _connection('server-1'),
    );

    Future<bool>? confirmation;
    await tester.pumpWidget(
      ChangeNotifierProvider<AppSettings>.value(
        value: settings,
        child: MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                confirmation = adapter.confirmHostKey(context, prompt);
              },
              child: const Text('confirm'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('confirm'));
    await tester.pumpAndSettle();
    expect(find.text('信任 SSH 主机密钥？'), findsOneWidget);
    expect(find.textContaining('server.example.test'), findsOneWidget);
    await tester.tap(find.text('信任密钥'));
    await tester.pumpAndSettle();
    expect(await confirmation, isTrue);
  });

  test(
    'SDK HTTP executor forwards requests and enforces response limits',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        if (request.uri.path == '/large') {
          request.response.add(Uint8List.fromList(List<int>.filled(8, 1)));
        } else {
          request.response.statusCode = 201;
          request.response.headers.set('x-echo', body);
          request.response.add(utf8.encode('reply:$body'));
        }
        await request.response.close();
      });

      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        final executor = const AppSdkRequestExecutor(maxResponseBytes: 64);
        final response = await executor.execute(
          SdkRequest(
            method: 'POST',
            uri: Uri.parse('http://127.0.0.1:${server.port}/echo'),
            headers: const <String, String>{
              'X-Test': 'yes',
              'Content-Length': '999',
            },
            body: Uint8List.fromList(utf8.encode('payload')),
          ),
        );
        expect(response.statusCode, 201);
        expect(response.headers['x-echo'], 'payload');
        expect(utf8.decode(response.body), 'reply:payload');

        final empty = await executor.execute(
          SdkRequest(
            method: 'GET',
            uri: Uri.parse('http://127.0.0.1:${server.port}/empty'),
          ),
        );
        expect(empty.statusCode, 201);

        final limited = const AppSdkRequestExecutor(maxResponseBytes: 4);
        await expectLater(
          limited.execute(
            SdkRequest(
              method: 'GET',
              uri: Uri.parse('http://127.0.0.1:${server.port}/large'),
            ),
          ),
          throwsA(isA<FormatException>()),
        );
      } finally {
        HttpOverrides.global = previousOverrides;
      }
    },
  );
}

ConnectionConfig _connection(String id) => ConnectionConfig(
  id: id,
  name: id,
  host: '$id.example.test',
  username: 'operator',
);

final class _RecordingMonitoringService extends Fake
    implements monitoring.MonitoringService {
  final List<String> stoppedIds = <String>[];

  @override
  void stopForConnection(String connectionId) => stoppedIds.add(connectionId);
}

final class _RecordingVerificationClient
    implements AppConnectionVerificationClient {
  _RecordingVerificationClient({this.pingError});

  final Object? pingError;
  int pingCalls = 0;
  bool closed = false;

  @override
  Future<void> ping() async {
    pingCalls++;
    final error = pingError;
    if (error != null) throw error;
  }

  @override
  void close() => closed = true;
}
