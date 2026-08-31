import 'package:connection_core/connection_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ssh_mobile/services/connection_target_binding.dart';
import 'package:ssh_mobile/services/remote_target_scope.dart';

import '../../test_utils/test_storage_adapter.dart';
import 'ssh_service_scenario_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SshService command binding paths', () {
    late SshServiceScenarioHarness harness;

    setUp(() async {
      harness = SshServiceScenarioHarness();
      await harness.setUp();
    });

    tearDown(() async {
      await harness.tearDown();
    });

    test('shutdown rejects new connects and owned commands', () async {
      await harness.ssh.ensureInitialized();
      await harness.ssh.close();

      await expectLater(
        harness.ssh.connect('server-a', sessionId: 'late-session'),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        harness.ssh.runOneShotCommand(
          connectionId: 'server-a',
          command: 'whoami',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('runOneShotCommand and binding report missing targets', () async {
      await harness.ssh.ensureInitialized();

      await expectLater(
        harness.ssh.runOneShotCommand(
          connectionId: 'missing-connection',
          command: 'pwd',
        ),
        throwsA(
          isA<RemoteTargetScopeException>().having(
            (error) => error.code,
            'code',
            'connection_not_found',
          ),
        ),
      );

      final binding = ConnectionTargetBinding.fromConfig(
        harness.storage.getConnection('server-a')!,
      );
      final throwingConnector = ThrowingNativeConnector();
      final commandSsh = createTestSshService(
        harness.storage,
        nativeStreamConnector: throwingConnector,
        peerIdResolver: (config) => 'peer-${config.id}',
      );
      try {
        await expectLater(
          commandSsh.runOneShotCommandForBinding(
            binding: binding,
            command: 'pwd',
          ),
          throwsA(isA<StateError>()),
        );
        expect(throwingConnector.openedPeerIds, contains('peer-server-a'));

        final staleBinding = ConnectionTargetBinding.fromConfig(
          harness.storage.getConnection('server-a')!,
        );
        await harness.storage.updateConnection(
          harness.storage
              .getConnection('server-a')!
              .copyWith(host: '203.0.113.10'),
        );
        await expectLater(
          commandSsh.runOneShotCommandForBinding(
            binding: staleBinding,
            command: 'pwd',
          ),
          throwsA(
            isA<RemoteTargetScopeException>().having(
              (error) => error.code,
              'code',
              'approval_target_changed',
            ),
          ),
        );

        final ghostBinding = ConnectionTargetBinding.fromConfig(
          ConnectionConfig(
            id: 'ghost-connection',
            name: 'Ghost',
            host: '198.51.100.99',
            username: 'nobody',
            hostKeyFingerprint: 'SHA256:ghost',
          ),
        );
        await expectLater(
          commandSsh.runOneShotCommandForBinding(
            binding: ghostBinding,
            command: 'pwd',
          ),
          throwsA(
            isA<RemoteTargetScopeException>().having(
              (error) => error.code,
              'code',
              'connection_not_found',
            ),
          ),
        );

        await expectLater(
          commandSsh.runOneShotCommand(
            connectionId: 'server-a',
            command: 'pwd',
          ),
          throwsA(isA<StateError>()),
        );
        expect(throwingConnector.openedPeerIds, contains('peer-server-a'));
      } finally {
        await commandSsh.close();
      }
    });
  });
}
