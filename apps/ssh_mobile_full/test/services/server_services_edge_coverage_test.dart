import 'dart:async';

import 'package:connection_core/connection_core.dart';
import 'package:feature_monitoring/feature_monitoring.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/services/connection_target_binding.dart';
import 'package:ssh_mobile/services/remote_target_scope.dart';
import 'package:ssh_mobile/services/server_catalog_service.dart';
import 'package:ssh_mobile/services/server_diagnostics_service.dart';
import 'package:ssh_mobile/services/server_status_probe.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/core/services/ssh_host_key_policy.dart';

import '../app/support/sftp_service_test_fakes.dart';
import '../test_utils/test_storage_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'catalog projects, validates metadata, reorders, and deletes safely',
    () async {
      final storage = TestStorageAdapter();
      final ssh = _CatalogSshAdapter();
      final sftp = FakeSftpService();
      addTearDown(() async {
        await storage.shutdown();
        storage.dispose();
      });

      final first = ConnectionConfig(
        id: 'one',
        name: 'One',
        host: 'one.example.test',
        username: 'root',
        group: 'ops',
        keepAlive: true,
        keepAliveInterval: 20,
        terminalWidth: 120,
        terminalHeight: 40,
        jumpHost: 'jump.example.test',
        jumpPort: 2200,
        jumpUsername: 'jump',
      );
      final second = ConnectionConfig(
        id: 'two',
        name: 'Two',
        host: 'two.example.test',
        username: 'operator',
      );
      final third = ConnectionConfig(
        id: 'three',
        name: 'Three',
        host: 'three.example.test',
        username: 'operator',
      );
      await storage.addConnection(first);
      await storage.addConnection(second);
      await storage.addConnection(third);

      ssh.sessionCounts['one'] = 2;
      ssh.connected['one'] = true;
      final latest = SshSession(
        id: 'session-one',
        connectionId: 'one',
        connectionName: 'One',
        outputController: StreamController<String>.broadcast(),
        state: SshConnectionState.connected,
      );
      ssh.latestSessions['one'] = latest;
      addTearDown(latest.outputController.close);
      final catalog = ServerCatalogService(
        connectionRepository: storage.connectionRepository,
        credentialRepository: storage.credentialRepository,
        hostKeyRepository: storage.hostKeyRepository,
        sshService: ssh,
        sftpService: sftp,
      );

      final summaries = catalog.listServerSummaries();
      expect(summaries, hasLength(3));
      expect(summaries.first['id'], 'one');
      expect(summaries.first['launchMode'], 'ssh');
      expect(summaries.first['serverPlatform'], 'linux');

      final details = catalog.getServerDetails('one');
      expect(details?['server']['jumpHost'], 'jump.example.test');
      expect(details?['sessionOverview']['activeSessionCount'], 2);
      expect(details?['sessionOverview']['hasConnectedSession'], isTrue);
      expect(details?['sessionOverview']['latestSessionId'], 'session-one');
      expect(details?['sessionOverview']['latestSessionState'], 'connected');
      expect(catalog.getServerDetails('missing'), isNull);

      final candidate = ServerCatalogService.buildUpdateCandidate(first, {
        'name': ' Updated ',
        'host': 'updated.example.test',
        'port': '2201',
        'username': ' deploy ',
        'group': ' platform ',
        'serverPlatform': 'windows',
        'launchMode': 'tmux',
        'tmuxAutoDeleteSeconds': 120.9,
        'keepAlive': 'yes',
        'keepAliveInterval': '30',
        'terminalWidth': 140,
        'terminalHeight': '45',
        'jumpHost': 'jump2.example.test',
        'jumpPort': '2222',
        'jumpUsername': 'admin',
      });
      expect(candidate.name, 'Updated');
      expect(candidate.username, 'deploy');
      expect(candidate.port, 2201);
      expect(candidate.serverPlatform, ServerPlatform.windows);
      expect(candidate.launchMode, TerminalLaunchMode.ssh);
      expect(candidate.keepAlive, isTrue);
      expect(candidate.keepAliveInterval, 30);
      expect(candidate.tmuxAutoDeleteSeconds, 120);
      expect(candidate.jumpPort, 2222);

      expect(
        () =>
            ServerCatalogService.buildUpdateCandidate(first, {'password': 'x'}),
        throwsA(isA<StateError>()),
      );
      expect(
        () =>
            ServerCatalogService.buildUpdateCandidate(first, {'unknown': 'x'}),
        throwsA(isA<StateError>()),
      );
      expect(
        () => ServerCatalogService.buildUpdateCandidate(first, {
          'port': Object(),
        }),
        throwsA(isA<StateError>()),
      );
      expect(
        () => ServerCatalogService.buildUpdateCandidate(first, {
          'keepAlive': 'maybe',
        }),
        throwsA(isA<StateError>()),
      );
      expect(
        () => ServerCatalogService.buildUpdateCandidate(first, {
          'name': Object(),
        }),
        throwsA(isA<StateError>()),
      );

      await expectLater(
        catalog.updateServerMetadata(
          connectionId: 'one',
          changes: const <String, dynamic>{'password': 'x'},
        ),
        throwsA(isA<StateError>()),
      );

      final target = ConnectionTargetBinding.fromConfig(first);
      await expectLater(
        catalog.updateServerMetadata(
          connectionId: 'one',
          changes: const <String, dynamic>{},
          approvedTarget: ConnectionTargetBinding.fromConfig(
            first.copyWith(host: 'changed.example.test'),
          ),
        ),
        throwsA(isA<RemoteTargetScopeException>()),
      );
      await expectLater(
        catalog.updateServerMetadata(
          connectionId: 'one',
          changes: const <String, dynamic>{},
          approvedCurrent: first.copyWith(name: 'stale'),
        ),
        throwsA(isA<RemoteTargetScopeException>()),
      );
      await expectLater(
        catalog.updateServerMetadata(
          connectionId: 'one',
          changes: const <String, dynamic>{},
          approvedCandidate: first.copyWith(id: 'other'),
        ),
        throwsA(isA<StateError>()),
      );
      expect(target.matches(storage.getConnection('one')), isTrue);

      final reordered = await catalog.reorderServers(<String>[
        'three',
        'one',
        'two',
      ]);
      expect(reordered['reordered'], isTrue);
      expect(storage.connections.map((item) => item.id), [
        'three',
        'one',
        'two',
      ]);
      await expectLater(
        catalog.reorderServers(<String>['one', 'one', 'two']),
        throwsA(isA<StateError>()),
      );

      await catalog.deleteServer('two');
      expect(ssh.disconnectedIds, contains('two'));
      expect(sftp.connectionDisconnects.single.connectionId, 'two');
      expect(storage.getConnection('two'), isNull);

      final stale = ConnectionConfig(
        id: 'stale',
        name: 'Stale',
        host: 'stale.example.test',
        username: 'operator',
      );
      await storage.addConnection(stale);
      ssh.onDisconnect = (id) async {
        if (id == 'stale') {
          await storage.updateConnection(
            stale.copyWith(host: 'changed.example.test'),
          );
        }
      };
      await expectLater(
        catalog.deleteServer('stale'),
        throwsA(isA<RemoteTargetScopeException>()),
      );
      expect(storage.getConnection('stale'), isNotNull);
    },
  );

  test('diagnostics chooses Linux, Windows, and fallback paths', () async {
    final storage = TestStorageAdapter();
    final ssh = _CatalogSshAdapter();
    addTearDown(() async {
      await storage.shutdown();
      storage.dispose();
    });

    final linux = ConnectionConfig(
      id: 'linux',
      name: 'Linux',
      host: 'linux.example.test',
      username: 'operator',
    );
    final windows = ConnectionConfig(
      id: 'windows',
      name: 'Windows',
      host: 'windows.example.test',
      username: 'operator',
      serverPlatform: ServerPlatform.windows,
    );
    await storage.addConnection(linux);
    await storage.addConnection(windows);
    final diagnostics = ServerDiagnosticsService(
      connectionRepository: storage.connectionRepository,
      sshService: ssh,
    );

    ssh.responses[ServerStatusProbe.performanceCommand] =
        const RemoteCommandResult(
          exitCode: 0,
          stdout: _performanceOutput,
          stderr: 'performance warning',
        );
    ssh.responses[ServerStatusProbe.portsCommand] = const RemoteCommandResult(
      exitCode: 0,
      stdout: _portsOutput,
      stderr: 'ports warning',
    );
    ssh.responses[ServerStatusProbe.applicationsCommand] =
        const RemoteCommandResult(
          exitCode: 0,
          stdout: _applicationsOutput,
          stderr: 'apps warning',
        );

    final status = await diagnostics.getStatus(connectionId: 'linux');
    expect(status['os']['os'], 'linux');
    expect(status['performance']['memoryPercent'], greaterThan(80));
    expect(status['ports'], isNotEmpty);
    expect(status['applications'], isNotEmpty);
    expect(status['portsStderr'], 'ports warning');
    expect(status['applicationsStderr'], 'apps warning');

    final performanceOnly = await diagnostics.getStatus(
      connectionId: 'linux',
      mode: 'performance',
    );
    expect(performanceOnly.containsKey('performance'), isTrue);
    expect(performanceOnly.containsKey('ports'), isFalse);
    final appsOnly = await diagnostics.getStatus(
      connectionId: 'linux',
      mode: 'apps',
    );
    expect(appsOnly.containsKey('applications'), isTrue);

    final report = await diagnostics.generateOpsReport('linux');
    expect(report['health']['risks'], contains('High memory usage'));
    expect(report['health']['risks'], contains('High disk usage'));
    expect(
      report['health']['risks'],
      contains('A process is consuming high CPU'),
    );
    expect(report['health']['level'], 'critical');

    ssh.responses['cmd /c ver'] = const RemoteCommandResult(
      exitCode: 0,
      stdout: 'Microsoft Windows [Version 10.0]',
      stderr: '',
    );
    expect((await diagnostics.detectOs('unknown-windows'))['os'], 'windows');
    ssh.responses['cmd /c ver'] = const RemoteCommandResult(
      exitCode: 1,
      stdout: '',
      stderr: 'not found',
    );
    ssh.responses['uname -a'] = const RemoteCommandResult(
      exitCode: 0,
      stdout: 'Linux host 6.1',
      stderr: '',
    );
    expect((await diagnostics.detectOs('unknown-linux'))['os'], 'linux');
    ssh.responses['uname -a'] = const RemoteCommandResult(
      exitCode: 1,
      stdout: '',
      stderr: 'not found',
    );
    expect((await diagnostics.detectOs('unknown'))['os'], 'unknown');

    ssh.responses[ServerStatusProbe.windowsStatusCommand] =
        const RemoteCommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'Access is denied',
        );
    final permission = await diagnostics.getStatus(connectionId: 'windows');
    expect(permission['permissionError'], isTrue);

    ssh.responses[ServerStatusProbe.windowsStatusCommand] =
        const RemoteCommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'command failed',
        );
    final failed = await diagnostics.getStatus(connectionId: 'windows');
    expect(failed['error'], 'command failed');

    ssh.responses[ServerStatusProbe.windowsStatusCommand] =
        const RemoteCommandResult(
          exitCode: 0,
          stdout: 'invalid json',
          stderr: '',
        );
    final raw = await diagnostics.getStatus(
      connectionId: 'windows',
      mode: 'all',
    );
    expect(raw['windowsStatus']['raw'], 'invalid json');

    ssh.responses[ServerStatusProbe.windowsStatusCommand] =
        const RemoteCommandResult(
          exitCode: 0,
          stdout: '{"cpuPercent":12,"memoryPercent":20}',
          stderr: 'windows warning',
        );
    final parsed = await diagnostics.getStatus(
      connectionId: 'windows',
      mode: '',
    );
    expect(parsed['windowsStatus']['cpuPercent'], 12);
    expect(parsed['stderr'], 'windows warning');
  });
}

final class _CatalogSshAdapter extends Fake implements SshClientAdapter {
  final Map<String, int> sessionCounts = <String, int>{};
  final Map<String, bool> connected = <String, bool>{};
  final Map<String, SshSession?> latestSessions = <String, SshSession?>{};
  final Set<String> disconnectedIds = <String>{};
  final Map<String, RemoteCommandResult> responses =
      <String, RemoteCommandResult>{};
  Future<void> Function(String id)? onDisconnect;

  @override
  bool hasConnectedSession(String connectionId) =>
      connected[connectionId] ?? false;

  @override
  int sessionCountForConnection(String connectionId) =>
      sessionCounts[connectionId] ?? 0;

  @override
  SshSession? latestSessionForConnection(String connectionId) =>
      latestSessions[connectionId];

  @override
  Future<void> disconnectSessionsForConnection(String connectionId) async {
    disconnectedIds.add(connectionId);
    await onDisconnect?.call(connectionId);
  }

  @override
  Future<RemoteCommandResult> runOneShotCommand({
    required String connectionId,
    required String command,
    Duration timeout = const Duration(seconds: 15),
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    return responses[command] ??
        const RemoteCommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'not configured',
        );
  }
}

const _performanceOutput = '''
__PROC__
cpu 100 0 0 10 0 0 0 0 0 0
MemTotal: 1000 kB
MemAvailable: 50 kB
8 0 sda 0 0 100 0 0 0 100 0 0 0 0
eth0: 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16
__DF__
Filesystem 1B-blocks Used Available Use% Mounted on
/dev/sda 1000 900 100 90% /
''';

const _portsOutput =
    'tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))';

const _applicationsOutput = '''
PID COMMAND RSS %MEM %CPU
100 worker 2048 1.0 90.0
''';
