import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ssh_mobile/services/ssh_service.dart';

import 'ssh_service_scenario_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SshService background bridge and overview', () {
    late SshServiceScenarioHarness harness;

    setUp(() async {
      harness = SshServiceScenarioHarness();
      await harness.setUp();
    });

    tearDown(() async {
      await harness.tearDown();
    });

    test(
      'background state, output, overview, resize, input, and disconnectAll',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        await harness.ssh.ensureInitialized();
        final connect = harness.ssh.connect(
          'server-a',
          sessionId: 'bg-session',
        );
        harness.pendingConnects.add(connect);
        await harness.waitForConnecting('bg-session');
        await harness.waitForInvocation('sshConnect');

        harness.background.emit('sshStateChanged', {
          'sessionId': 'bg-session',
          'state': 'connected',
        });
        await connect;

        final session = harness.ssh.getSession('bg-session')!;
        expect(session.isConnected, isTrue);

        harness.ssh.resizeTerminal('bg-session', 120, 40);
        harness.ssh.sendData('bg-session', 'echo hello\r');
        harness.ssh.sendBytes(
          'bg-session',
          Uint8List.fromList('abc'.codeUnits),
        );
        expect(
          harness.background.invocations,
          containsAll(<String>['sshConnect', 'sshResize', 'sshInput']),
        );

        harness.background.emit('sshDataReceived', {
          'sessionId': 'bg-session',
          'data': 'output-line',
        });
        await pumpEventLoop();
        expect(session.outputText, contains('output-line'));

        harness.background.emit('sshOverviewUpdated', {
          'overview': {
            'server-a': {'count': 7, 'latestState': null, 'hasConnected': true},
          },
          'windowCount': 7,
        });
        await pumpEventLoop();
        expect(
          harness.ssh.serverOverviewSnapshot.forConnection('server-a').count,
          7,
        );

        await harness.ssh.disconnect();
        expect(harness.background.invocations, contains('sshDisconnectAll'));
        expect(harness.ssh.sessions, isEmpty);
        expect(harness.ssh.serverOverviewSnapshot.windowCount, 0);
      },
    );

    test(
      'background error state reports failure and leaves an error session',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        await harness.ssh.ensureInitialized();
        final connect = harness.ssh.connect('server-a', sessionId: 'bg-error');
        harness.pendingConnects.add(connect);
        await harness.waitForConnecting('bg-error');
        await harness.waitForInvocation('sshConnect');

        harness.background.emit('sshStateChanged', {
          'sessionId': 'bg-error',
          'state': 'error',
          'errorMessage': 'remote rejected',
        });
        // The background connect failure stays on the session state contract.
        await connect;

        final session = harness.ssh.getSession('bg-error')!;
        expect(session.state, SshConnectionState.error);
        expect(session.errorMessage, contains('remote rejected'));
      },
    );

    test(
      'disconnect while a background connect is pending completes it',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        await harness.ssh.ensureInitialized();
        final connect = harness.ssh.connect(
          'server-a',
          sessionId: 'early-close',
        );
        harness.pendingConnects.add(connect);
        await harness.waitForConnecting('early-close');
        await harness.waitForInvocation('sshConnect');

        await harness.ssh.disconnectSession('early-close');
        await connect;

        expect(harness.ssh.getSession('early-close'), isNull);
        expect(harness.background.invocations, contains('sshDisconnect'));
      },
    );

    test('failed background open removes the error session', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await harness.ssh.ensureInitialized();
      final opening = harness.ssh.openSession('server-a');
      await harness.waitForInvocation('sshConnect');
      final failedSessionId = harness.ssh.sessions.single.id;
      harness.background.emit('sshStateChanged', {
        'sessionId': failedSessionId,
        'state': 'error',
        'errorMessage': 'auth rejected',
      });

      expect(await opening, isNull);
      expect(harness.ssh.getSession(failedSessionId), isNull);
    });

    test(
      'overview merges background and native sessions for one connection',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        await harness.ssh.ensureInitialized();
        final backgroundConnect = harness.ssh.connect(
          'server-a',
          sessionId: 'merge-bg',
        );
        harness.pendingConnects.add(backgroundConnect);
        await harness.waitForConnecting('merge-bg');
        await harness.waitForInvocation('sshConnect');
        harness.background.emit('sshStateChanged', {
          'sessionId': 'merge-bg',
          'state': 'connected',
        });
        await backgroundConnect;

        harness.background.emit('sshOverviewUpdated', {
          'overview': {
            'server-a': {'count': 1, 'latestState': null, 'hasConnected': true},
          },
          'windowCount': 1,
        });
        await pumpEventLoop();

        harness.resolveServerANative = true;
        final nativeConnect = harness.ssh.connect(
          'server-a',
          sessionId: 'merge-native',
        );
        harness.pendingConnects.add(nativeConnect);
        await harness.waitForConnecting('merge-native');
        await harness.waitUntil(
          () =>
              harness.ssh.serverOverviewSnapshot
                  .forConnection('server-a')
                  .count ==
              2,
        );
        expect(
          harness.ssh.serverOverviewSnapshot
              .forConnection('server-a')
              .latestState,
          SshConnectionState.connecting,
        );

        harness.background.emit('sshOverviewUpdated', {
          'overview': {
            'server-a': {
              'count': 1,
              'latestState': 'connected',
              'hasConnected': true,
            },
          },
          'windowCount': 1,
        });
        await pumpEventLoop();
        expect(
          harness.ssh.serverOverviewSnapshot
              .forConnection('server-a')
              .latestState,
          SshConnectionState.connected,
        );
      },
    );
  });
}
