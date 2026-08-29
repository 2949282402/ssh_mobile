import 'package:connection_core/connection_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/terminal_session_metadata_store.dart'
    show RestorableTmuxSession;

import 'ssh_service_scenario_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SshService tmux restore', () {
    late SshServiceScenarioHarness harness;

    setUp(() async {
      harness = SshServiceScenarioHarness();
      await harness.setUp();
    });

    tearDown(() async {
      await harness.tearDown();
    });

    test('restore removes stale restorable tmux metadata', () async {
      await harness.storage.terminalMetadataStore.saveRestorableTmuxSession(
        RestorableTmuxSession(
          sessionId: 'stale-restore',
          connectionId: 'server-a',
          displayName: 'Stale Window',
          tmuxSessionName: 'stale-tmux',
          fontSize: 14,
          updatedAt: DateTime.now(),
        ),
      );

      await harness.ssh.ensureInitialized();

      expect(harness.ssh.getSession('stale-restore'), isNull);
      expect(
        (await harness.storage.terminalMetadataStore
                .loadRestorableTmuxSessions())
            .where((entry) => entry.sessionId == 'stale-restore'),
        isEmpty,
      );
    });

    test('restore recreates tmux sessions and reconnects them', () async {
      await harness.storage.updateConnection(
        harness.storage
            .getConnection('server-a')!
            .copyWith(
              launchMode: TerminalLaunchMode.tmux,
              serverPlatform: ServerPlatform.linux,
            ),
      );
      await harness.storage.terminalMetadataStore.saveRestorableTmuxSession(
        RestorableTmuxSession(
          sessionId: 'restored-a',
          connectionId: 'server-a',
          displayName: 'Restored A',
          tmuxSessionName: 'tmux-restored',
          fontSize: 16,
          updatedAt: DateTime.now(),
        ),
      );

      await harness.ssh.ensureInitialized();

      final restored = harness.ssh.getSession('restored-a');
      expect(restored, isNotNull);
      expect(restored!.connectionId, 'server-a');
      expect(restored.displayName, 'Restored A');
      expect(restored.tmuxSessionName, 'tmux-restored');
      expect(restored.fontSize, 16);
      expect(restored.state, SshConnectionState.disconnected);

      await harness.waitForConnecting('restored-a');
    });
  });
}
