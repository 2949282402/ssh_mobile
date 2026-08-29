import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ssh_mobile/services/ssh_service.dart';

import 'ssh_service_scenario_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SshService ensure connected paths', () {
    late SshServiceScenarioHarness harness;

    setUp(() async {
      harness = SshServiceScenarioHarness();
      await harness.setUp();
    });

    tearDown(() async {
      await harness.tearDown();
    });

    test(
      'ensureSessionConnected handles mismatch and connected sessions',
      () async {
        await harness.ssh.ensureInitialized();
        final connectA = harness.ssh.connect(
          'server-a',
          sessionId: 'session-a',
        );
        harness.pendingConnects.add(connectA);
        await harness.waitForConnecting('session-a');
        final sessionA = harness.ssh.getSession('session-a')!;
        sessionA.state = SshConnectionState.connected;

        final connectB = harness.ssh.connect(
          'server-b',
          sessionId: 'session-b',
        );
        harness.pendingConnects.add(connectB);
        await harness.waitForConnecting('session-b');
        final sessionB = harness.ssh.getSession('session-b')!;
        sessionB.state = SshConnectionState.connected;

        expect(
          await harness.ssh.ensureSessionConnected('session-b', 'server-a'),
          isFalse,
        );
        expect(
          await harness.ssh.ensureSessionConnected('session-a', 'server-a'),
          isTrue,
        );
        expect(await harness.ssh.ensureConnected('server-a'), isTrue);
        expect(harness.ssh.currentSession?.id, 'session-a');
      },
    );

    test('ensureSessionConnected reconnects a disconnected session', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await harness.ssh.ensureInitialized();
      final connect = harness.ssh.connect(
        'server-a',
        sessionId: 'reconnect-me',
      );
      harness.pendingConnects.add(connect);
      await harness.waitForConnecting('reconnect-me');
      await harness.waitForInvocation('sshConnect');
      harness.background.emit('sshStateChanged', {
        'sessionId': 'reconnect-me',
        'state': 'error',
        'errorMessage': 'temporary failure',
      });
      await connect;
      expect(
        harness.ssh.getSession('reconnect-me')!.state,
        SshConnectionState.error,
      );

      final reconnected = harness.ssh.ensureSessionConnected(
        'reconnect-me',
        'server-a',
      );
      await harness.waitForConnecting('reconnect-me');
      await harness.waitUntil(
        () =>
            harness.background.invocations
                .where((name) => name == 'sshConnect')
                .length >=
            2,
      );
      harness.background.emit('sshStateChanged', {
        'sessionId': 'reconnect-me',
        'state': 'connected',
      });

      expect(await reconnected, isTrue);
      expect(harness.ssh.getSession('reconnect-me')!.isConnected, isTrue);
    });

    test(
      'ensureConnected falls through to openSession when not connected',
      () async {
        await harness.ssh.ensureInitialized();
        final connect = harness.ssh.connect(
          'missing-connection',
          sessionId: 'not-connected',
        );
        harness.pendingConnects.add(connect);
        await connect;
        harness.ssh.getSession('not-connected')!.state =
            SshConnectionState.error;

        expect(
          await harness.ssh.ensureSessionConnected('no-session', 'server-a'),
          isFalse,
        );
        expect(
          await harness.ssh.ensureSessionConnected('no-session', 'server-a'),
          isFalse,
        );
        expect(
          await harness.ssh.ensureConnected('missing-connection'),
          isFalse,
        );
      },
    );
  });
}
