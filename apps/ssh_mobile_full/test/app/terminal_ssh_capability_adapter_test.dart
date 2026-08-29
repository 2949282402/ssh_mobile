// Terminal SSH Capability 与 Session Manager 包装器测试。

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;
import 'package:ssh_mobile/app/terminal_ssh_capability_adapter.dart';
import 'package:ssh_mobile/services/ssh_service.dart';

import 'support/feature_adapter_test_fakes.dart';

void main() {
  test(
    'capability exposes session snapshots and forwards every operation',
    () async {
      final controller = StreamController<String>.broadcast();
      addTearDown(controller.close);
      final session = SshSession(
        id: 's1',
        connectionId: 'c1',
        connectionName: 'Server A',
        displayName: 'win',
        tmuxSessionName: 't1',
        tmuxAutoDeleteSeconds: 30,
        fontSize: 10,
        outputController: controller,
        state: SshConnectionState.connected,
        errorMessage: null,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(2),
      );
      final service = FakeSshService()
        ..sessions = <SshSession>[session]
        ..sessionsById['s1'] = session
        ..sessionNameAvailable = false
        ..renameResult = false;
      final capability = AppTerminalSshCapability(service);
      final events = <void>[];
      final subscription = capability.changes.listen((_) => events.add(null));
      addTearDown(subscription.cancel);

      service.emitChange();
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));

      final snapshot = capability.sessions.single;
      expect(snapshot.id, 's1');
      expect(snapshot.connectionId, 'c1');
      expect(snapshot.connectionName, 'Server A');
      expect(snapshot.displayName, 'win');
      expect(snapshot.tmuxSessionName, 't1');
      expect(snapshot.tmuxAutoDeleteSeconds, 30);
      expect(snapshot.fontSize, 10);
      expect(snapshot.state, ssh_core.SshConnectionState.connected);
      expect(snapshot.errorMessage, isNull);
      expect(snapshot.createdAt, DateTime.fromMillisecondsSinceEpoch(1));
      expect(snapshot.updatedAt, DateTime.fromMillisecondsSinceEpoch(2));
      expect(snapshot.estimatedMemoryBytes, 0);

      final found = capability.getSession('s1')!;
      expect(found.id, 's1');
      expect(capability.getSession('missing'), isNull);

      expect(capability.errorMessage, isNull);
      expect(await capability.loadSessionHistoryText('s1'), 'history');
      expect(await capability.ensureSessionConnected('s1', 'c1'), isTrue);
      capability.setSessionFontSize('s1', 12);
      capability.sendData('s1', 'echo');
      capability.resizeTerminal('s1', 80, 24);
      await capability.disconnectSession('s1');
      await capability.disconnect();
      expect(capability.renameSession('s1', 'other'), isFalse);
      expect(await capability.openSession('c1'), 'session-1');
      expect(await capability.ensureConnected('c1'), isTrue);

      expect(service.fontSizeUpdates.single.fontSize, 12);
      expect(service.sentData.single.data, 'echo');
      expect(service.resizes.single.width, 80);
      expect(service.resizes.single.height, 24);
      expect(service.disconnectedSessions, <String>['s1']);
      expect(service.disconnectCalls, 1);
      expect(service.renames.single.name, 'other');
      expect(service.capturedUnknownHostKey, isNull);
    },
  );

  test(
    'capability delegates name availability to the legacy service',
    () async {
      final capability = AppTerminalSshCapability(TestSshService());

      expect(capability.isSessionNameAvailable('window'), isTrue);
      expect(capability.isSessionNameAvailable(''), isFalse);

      await capability.dispose();
    },
  );

  test(
    'capability stops forwarding changes after idempotent dispose',
    () async {
      final service = FakeSshService();
      final capability = AppTerminalSshCapability(service);
      final events = <void>[];
      final subscription = capability.changes.listen((_) => events.add(null));

      await capability.dispose();
      await capability.dispose();
      service.emitChange();
      await Future<void>.delayed(Duration.zero);

      expect(events, isEmpty);
      await subscription.cancel();
    },
  );

  test('session manager forwards lifecycle and closes the terminal', () async {
    final service = FakeSshService()..initialized = true;
    final manager = AppTerminalSshSessionManager(service);
    final done = expectLater(manager.terminal.changes, emitsDone);

    expect(manager.terminalCapability, same(manager.terminal));
    expect(manager.initialized, isTrue);
    await manager.ensureInitialized();
    final lease = await manager.acquire(
      sessionId: 's1',
      create: () async => ssh_core.SshSession(
        id: 's1',
        connectionId: 'c1',
        connectionName: 'Server A',
      ),
    );
    expect(lease.session.id, 's1');

    await manager.close();
    await done;
    expect(service.closeCalls, 1);
  });

  test(
    'session manager disposes the terminal when service close fails',
    () async {
      final service = FakeSshService()..closeError = StateError('close failed');
      final manager = AppTerminalSshSessionManager(service);
      final done = expectLater(manager.terminal.changes, emitsDone);

      await expectLater(manager.close(), throwsA(isA<StateError>()));
      await done;

      expect(service.closeCalls, 1);
      service.emitChange();
      await Future<void>.delayed(Duration.zero);
    },
  );
}
