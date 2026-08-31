import 'package:app_core/app_core.dart';
import 'package:connection_core/connection_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/terminal_session_metadata_store.dart';

import '../../test_utils/test_storage_adapter.dart';
import '../telemetry/telemetry_test_utils.dart';
import 'ssh_service_scenario_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'restoring a third duplicate uses the next available window name',
    () async {
      final harness = SshServiceScenarioHarness();
      await harness.setUp();
      addTearDown(harness.tearDown);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      await _addConnection(harness.storage, 'server-c');
      for (final id in const ['server-a', 'server-b', 'server-c']) {
        await harness.storage.updateConnection(
          harness.storage
              .getConnection(id)!
              .copyWith(
                launchMode: TerminalLaunchMode.tmux,
                serverPlatform: ServerPlatform.linux,
              ),
        );
        await harness.storage.terminalMetadataStore.saveRestorableTmuxSession(
          RestorableTmuxSession(
            sessionId: 'restore-$id',
            connectionId: id,
            displayName: 'Restored',
            tmuxSessionName: 'tmux-$id',
            fontSize: 14,
            updatedAt: DateTime.utc(2026, 2, 4),
          ),
        );
      }

      await harness.ssh.ensureInitialized();
      await harness.waitUntil(() => harness.ssh.sessions.length == 3);
      expect(harness.ssh.sessions.map((session) => session.displayName), [
        'Restored',
        'Restored (2)',
        'Restored (3)',
      ]);

      await harness.waitUntil(
        () =>
            harness.background.invocations
                .where((method) => method == 'sshConnect')
                .length >=
            3,
      );
      for (final session in harness.ssh.sessions) {
        harness.background.emit('sshStateChanged', {
          'sessionId': session.id,
          'state': 'connected',
        });
      }
      await harness.waitUntil(
        () => harness.ssh.sessions.every((session) => session.isConnected),
      );
    },
  );

  test(
    'Windows tmux downgrades to SSH and names the active notification',
    () async {
      final settings = AppSettings();
      await settings.setShowServerNamesInNotifications(true);
      final harness = SshServiceScenarioHarness(appSettings: settings);
      await harness.setUp();
      addTearDown(() async {
        await harness.tearDown();
        settings.dispose();
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      await harness.storage.updateConnection(
        harness.storage
            .getConnection('server-a')!
            .copyWith(
              launchMode: TerminalLaunchMode.tmux,
              serverPlatform: ServerPlatform.windows,
            ),
      );
      await harness.ssh.ensureInitialized();

      final first = harness.ssh.connect(
        'server-a',
        sessionId: 'windows-tmux',
        displayName: 'Primary',
      );
      harness.pendingConnects.add(first);
      await harness.waitForConnecting('windows-tmux');
      await harness.waitForInvocation('sshConnect');
      harness.background.emit('sshStateChanged', {
        'sessionId': 'windows-tmux',
        'state': 'connected',
      });
      await first;

      final sshConnect = harness.background.invocationRecords
          .where((record) => record.method == 'sshConnect')
          .single
          .args!;
      expect(sshConnect['launchMode'], TerminalLaunchMode.ssh.name);
      expect(harness.ssh.getSession('windows-tmux')!.tmuxSessionName, isNull);

      final second = harness.ssh.connect(
        'server-b',
        sessionId: 'notification-window',
        displayName: 'Secondary',
      );
      harness.pendingConnects.add(second);
      await harness.waitForConnecting('notification-window');
      await harness.waitUntil(
        () =>
            harness.background.invocations
                .where((method) => method == 'sshConnect')
                .length >=
            2,
      );
      final updates = harness.background.invocationRecords
          .where(
            (record) =>
                record.method == 'update' && record.args?['content'] != null,
          )
          .map((record) => record.args!['content'])
          .toList(growable: false);
      expect(updates, contains('Connected to Primary'));
      harness.background.emit('sshStateChanged', {
        'sessionId': 'notification-window',
        'state': 'connected',
      });
      await second;
    },
  );

  test(
    'connected session telemetry keeps the started trace and contract fields',
    () async {
      final telemetry = TelemetryTestHarness();
      final harness = SshServiceScenarioHarness();
      await harness.setUp();
      addTearDown(() async {
        await harness.tearDown();
        await telemetry.dispose();
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      harness.ssh.telemetryClient = telemetry.client;

      await harness.ssh.ensureInitialized();
      final pending = harness.ssh.connect(
        'server-a',
        sessionId: 'telemetry-connected',
        displayName: 'Telemetry Window',
      );
      harness.pendingConnects.add(pending);
      await harness.waitForConnecting('telemetry-connected');
      await harness.waitForInvocation('sshConnect');
      harness.background.emit('sshStateChanged', {
        'sessionId': 'telemetry-connected',
        'state': 'connected',
      });
      await pending;

      final records = await telemetry.recordsByName();
      final started = records[TelemetryEvents.sshSessionStarted.name]!.single;
      final connected =
          records[TelemetryEvents.sshSessionConnected.name]!.single;
      expect(connected.traceId, started.traceId);
      expect(connected.sessionId, started.sessionId);
      expect(connected.properties, containsPair('session_type', 'terminal'));
    },
  );
}

Future<void> _addConnection(TestStorageAdapter storage, String id) async {
  await storage.connectionRepository.addConnection(
    ConnectionConfig(
      id: id,
      name: id,
      host: '198.51.100.10',
      username: 'fixture-user',
      hostKeyFingerprint: 'SHA256:fixture',
    ),
  );
  await storage.credentialRepository.saveCredentials(
    connectionId: id,
    password: 'fixture-password',
  );
}
