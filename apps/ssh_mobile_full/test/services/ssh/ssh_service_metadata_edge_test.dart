import 'package:connection_core/connection_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/terminal_session_metadata_store.dart';

import '../../test_utils/test_storage_adapter.dart';
import 'ssh_service_scenario_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'session naming, launch-mode fallback, and background error mapping',
    () async {
      final harness = SshServiceScenarioHarness();
      await harness.setUp();
      addTearDown(harness.tearDown);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      await harness.ssh.ensureInitialized();
      expect(
        harness.ssh.defaultDisplayNameForConnection('server-a'),
        'server-a',
      );
      expect(harness.ssh.defaultDisplayNameForConnection('missing'), 'SSH');
      expect(harness.ssh.isSessionNameAvailable('  '), isFalse);
      expect(harness.ssh.isSessionNameAvailable('Window'), isTrue);

      await _connectBackground(
        harness,
        connectionId: 'server-a',
        sessionId: 'metadata-primary',
        displayName: 'Window',
      );
      expect(harness.ssh.isSessionNameAvailable(' window '), isFalse);

      // An explicit duplicate name is rejected without disturbing the existing
      // connected window.
      await harness.ssh.connect(
        'server-b',
        sessionId: 'metadata-duplicate',
        displayName: 'Window',
      );
      expect(
        harness.ssh.getSession('metadata-duplicate')?.errorMessage,
        'Window name already exists',
      );

      // Exercise each user-visible background error mapping while a session is
      // already registered, so the event is observational and cannot reject a
      // pending connect Future.
      for (final entry in const [
        ('metadata-auth', 'authentication failed'),
        ('metadata-host-key', 'host key mismatch'),
        ('metadata-timeout', 'connection timeout'),
        ('metadata-other', 'remote rejected'),
      ]) {
        await _connectBackground(
          harness,
          connectionId: 'server-b',
          sessionId: entry.$1,
          displayName: entry.$1,
        );
        harness.background.emit('sshStateChanged', {
          'sessionId': entry.$1,
          'state': 'error',
          'errorMessage': entry.$2,
        });
        await pumpEventLoop();
        expect(
          harness.ssh.getSession(entry.$1)!.state,
          SshConnectionState.error,
        );
      }
    },
  );

  test('restoring duplicate tmux labels assigns unique window names', () async {
    final harness = SshServiceScenarioHarness();
    await harness.setUp();
    addTearDown(harness.tearDown);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    final firstConfig = harness.storage.getConnection('server-a')!;
    final secondConfig = harness.storage.getConnection('server-b')!;
    firstConfig.launchMode = TerminalLaunchMode.tmux;
    secondConfig.launchMode = TerminalLaunchMode.tmux;
    await harness.storage.terminalMetadataStore.saveRestorableTmuxSession(
      RestorableTmuxSession(
        sessionId: 'restore-a',
        connectionId: firstConfig.id,
        displayName: 'Restored',
        tmuxSessionName: 'restore-tmux-a',
        fontSize: 14,
        updatedAt: DateTime.utc(2026, 2, 4),
      ),
    );
    await harness.storage.terminalMetadataStore.saveRestorableTmuxSession(
      RestorableTmuxSession(
        sessionId: 'restore-b',
        connectionId: secondConfig.id,
        displayName: 'Restored',
        tmuxSessionName: 'restore-tmux-b',
        fontSize: 14,
        updatedAt: DateTime.utc(2026, 2, 4),
      ),
    );

    await harness.ssh.ensureInitialized();
    await harness.waitUntil(() => harness.ssh.sessions.length == 2);
    expect(harness.ssh.sessions.map((session) => session.displayName), [
      'Restored',
      'Restored (2)',
    ]);
    await harness.waitUntil(
      () =>
          harness.background.invocations
              .where((method) => method == 'sshConnect')
              .length >=
          2,
    );
    for (final session in harness.ssh.sessions) {
      harness.background.emit('sshStateChanged', {
        'sessionId': session.id,
        'state': 'connected',
      });
    }
    await pumpEventLoop();
  });

  test(
    'notification summaries and tmux names handle active collisions',
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

      for (final id in const ['server-a', 'server-b']) {
        final config = harness.storage.getConnection(id)!;
        config.name = 'Same Server';
        config.launchMode = TerminalLaunchMode.tmux;
        config.serverPlatform = ServerPlatform.linux;
      }
      await harness.ssh.ensureInitialized();
      await _connectBackground(
        harness,
        connectionId: 'server-a',
        sessionId: 'tmux-collision-a',
        displayName: 'A',
      );
      await _connectBackground(
        harness,
        connectionId: 'server-b',
        sessionId: 'tmux-collision-b',
        displayName: 'B',
      );
      await _connectBackground(
        harness,
        connectionId: 'server-a',
        sessionId: 'tmux-collision-c',
        displayName: 'C',
      );
      expect(
        harness.ssh.getSession('tmux-collision-b')!.tmuxSessionName,
        'ssh_mobile_same_server_2',
      );
      expect(
        harness.ssh.getSession('tmux-collision-c')!.tmuxSessionName,
        'ssh_mobile_same_server_3',
      );

      harness.background.emit('sshStateChanged', {
        'sessionId': 'tmux-collision-a',
        'state': 'disconnected',
      });
      await pumpEventLoop();
      expect(harness.ssh.isSessionNameAvailable('A'), isFalse);
    },
  );
}

Future<void> _connectBackground(
  SshServiceScenarioHarness harness, {
  required String connectionId,
  required String sessionId,
  required String displayName,
}) async {
  final pending = harness.ssh.connect(
    connectionId,
    sessionId: sessionId,
    displayName: displayName,
  );
  harness.pendingConnects.add(pending);
  await harness.waitForConnecting(sessionId);
  await harness.waitForInvocation('sshConnect');
  harness.background.emit('sshStateChanged', {
    'sessionId': sessionId,
    'state': 'connected',
  });
  await pending;
}
