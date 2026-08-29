import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;
import 'package:ssh_mobile/services/ssh_service.dart';

import 'ssh_service_scenario_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'manager state projection and session-pool leases stay consistent',
    () async {
      final harness = SshServiceScenarioHarness();
      await harness.setUp();
      addTearDown(harness.tearDown);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      final service = harness.ssh;
      expect(service.initialized, isFalse);
      expect(service.terminalCapability, isNull);
      expect(service.canUseNativeTransport, isTrue);
      expect(service.sessions, isEmpty);
      expect(service.activeSessionCount, 0);
      expect(service.idleSessionCount, 0);
      expect(service.leaseCount, 0);
      expect(service.activeSubscriptionCount, 0);
      expect(service.activeTimerCount, 0);
      expect(service.isConnected, isFalse);
      expect(service.state, SshConnectionState.disconnected);
      expect(service.errorMessage, isNull);
      expect(service.currentSession, isNull);
      expect(service.activeConnectionId, isNull);
      expect(service.getSession('missing'), isNull);

      await service.ensureInitialized();
      expect(service.initialized, isTrue);
      expect(service.activeSubscriptionCount, greaterThan(0));

      final lease = await service.acquire(
        sessionId: 'pool-session',
        create: () async => ssh_core.SshSession(
          id: 'pool-session',
          connectionId: 'server-a',
          connectionName: 'server-a',
        ),
      );
      expect(service.leaseCount, 1);
      expect(lease.isReleased, isFalse);
      await lease.release();
      expect(lease.isReleased, isTrue);
      await lease.release();
      expect(service.leaseCount, 0);

      final connecting = service.connect('server-a', sessionId: 'contract-a');
      harness.pendingConnects.add(connecting);
      await harness.waitForConnecting('contract-a');
      expect(service.activeSessionCount, 1);
      expect(service.idleSessionCount, 0);
      await harness.waitForInvocation('sshConnect');
      harness.background.emit('sshStateChanged', {
        'sessionId': 'contract-a',
        'state': 'connected',
      });
      await connecting;
      expect(service.isConnected, isTrue);
      expect(service.state, SshConnectionState.connected);
      expect(service.currentSession?.id, 'contract-a');
      expect(service.activeConnectionId, 'server-a');
      expect(service.errorMessage, isNull);

      await service.close();
      await expectLater(
        service.acquire(
          sessionId: 'late-lease',
          create: () async => ssh_core.SshSession(
            id: 'late-lease',
            connectionId: 'server-a',
            connectionName: 'server-a',
          ),
        ),
        throwsA(isA<StateError>()),
      );
    },
  );
}
