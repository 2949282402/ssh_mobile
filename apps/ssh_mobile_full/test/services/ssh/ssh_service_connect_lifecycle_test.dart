import 'package:connection_core/connection_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ssh_service_scenario_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SshService connect lifecycle', () {
    late SshServiceScenarioHarness harness;

    setUp(() async {
      harness = SshServiceScenarioHarness();
      await harness.setUp();
    });

    tearDown(() async {
      await harness.tearDown();
    });

    test('disconnectAll closes a pending local connect', () async {
      await harness.ssh.ensureInitialized();
      final connect = harness.ssh.connect('server-a', sessionId: 'local-close');
      harness.pendingConnects.add(connect);
      await harness.waitForConnecting('local-close');

      await harness.ssh.disconnect();

      expect(harness.ssh.sessions, isEmpty);
      await connect;
    });

    test('duplicate connect to a different target fails fast', () async {
      await harness.ssh.ensureInitialized();
      final firstConnect = harness.ssh.connect(
        'server-a',
        sessionId: 'same-session',
      );
      harness.pendingConnects.add(firstConnect);
      await harness.waitForConnecting('same-session');

      await expectLater(
        harness.ssh.connect('server-b', sessionId: 'same-session'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('already connecting to a different target'),
          ),
        ),
      );
    });

    test(
      'tmux naming and unique collision use per-session tmux names',
      () async {
        await harness.storage.updateConnection(
          harness.storage
              .getConnection('server-a')!
              .copyWith(
                launchMode: TerminalLaunchMode.tmux,
                serverPlatform: ServerPlatform.linux,
              ),
        );
        await harness.storage.updateConnection(
          harness.storage
              .getConnection('server-b')!
              .copyWith(
                launchMode: TerminalLaunchMode.tmux,
                serverPlatform: ServerPlatform.linux,
              ),
        );
        await harness.ssh.ensureInitialized();
        final firstConnect = harness.ssh.connect(
          'server-a',
          sessionId: 'tmux-a',
        );
        harness.pendingConnects.add(firstConnect);
        await harness.waitForConnecting('tmux-a');
        await harness.waitUntil(
          () => harness.ssh.getSession('tmux-a')!.tmuxSessionName != null,
        );
        final first = harness.ssh.getSession('tmux-a')!;
        expect(first.tmuxSessionName, isNotNull);

        final secondConnect = harness.ssh.connect(
          'server-b',
          sessionId: 'tmux-b',
        );
        harness.pendingConnects.add(secondConnect);
        await harness.waitForConnecting('tmux-b');
        await harness.waitUntil(
          () => harness.ssh.getSession('tmux-b')?.tmuxSessionName != null,
        );
        final second = harness.ssh.getSession('tmux-b')!;
        expect(second.tmuxSessionName, isNot(first.tmuxSessionName));
      },
    );
  });
}
