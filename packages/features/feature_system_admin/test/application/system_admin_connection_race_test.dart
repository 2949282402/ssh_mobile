// System Admin 连接 generation、不可变目标和迟到 Lease 释放测试。

import 'dart:async';

import 'package:feature_system_admin/feature_system_admin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart';

import '../fakes/system_admin_test_fakes.dart';

void main() {
  test('late connection A cannot replace newer target B', () async {
    final targetA = systemAdminTestTarget('server-a');
    final targetB = systemAdminTestTarget('server-b');
    final leaseA = FakeSystemAdminSshLease(targetBinding: targetA);
    final leaseB = FakeSystemAdminSshLease(targetBinding: targetB);
    final acquireA = Completer<SystemAdminSshLeasePort>();
    final acquireB = Completer<SystemAdminSshLeasePort>();
    final sshPort = FakeSystemAdminSshPort()
      ..acquireOverride = (target) => switch (target.id) {
        'server-a' => acquireA.future,
        'server-b' => acquireB.future,
        _ => throw StateError('unexpected target'),
      };
    final service = SystemAdminService(
      sshPort: sshPort,
      logger: FakeSystemAdminLogger(),
    );

    var staleConfirmationCalls = 0;
    final connectA = service.connect(
      targetA,
      onUnknownHostKey: (_) {
        staleConfirmationCalls++;
        return true;
      },
    );
    await Future<void>.delayed(Duration.zero);
    final connectB = service.connect(targetB);
    await Future<void>.delayed(Duration.zero);

    acquireB.complete(leaseB);
    await connectB;
    expect(service.activeTarget?.binding.fingerprint, targetB.fingerprint);
    expect(
      await sshPort.acquiredHostKeyConfirmations.first!(
        const SshHostKeyPromptRequest(
          connectionId: 'server-a',
          connectionName: 'server-a',
          host: 'server-a.example.test',
          port: 22,
          username: 'root',
          algorithm: 'ssh-ed25519',
          fingerprint: 'MD5:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00',
        ),
      ),
      isFalse,
    );
    expect(staleConfirmationCalls, 0);

    acquireA.complete(leaseA);
    await connectA;
    expect(service.activeTarget?.binding.fingerprint, targetB.fingerprint);
    expect(leaseA.isReleased, isTrue);
    expect(leaseA.runCount, 0);

    await service.lockUser(service.activeTarget!, 'operator');
    expect(leaseB.commands.last.executable, 'usermod');
    expect(leaseB.isReleased, isFalse);

    await service.close();
    service.dispose();
  });

  test(
    'route close releases a lease that arrives after disposal starts',
    () async {
      final target = systemAdminTestTarget('server-a');
      final lateLease = FakeSystemAdminSshLease(targetBinding: target);
      final pendingAcquire = Completer<SystemAdminSshLeasePort>();
      final sshPort = FakeSystemAdminSshPort()
        ..acquireOverride = (_) => pendingAcquire.future;
      final service = SystemAdminService(
        sshPort: sshPort,
        logger: FakeSystemAdminLogger(),
      );

      final connect = service.connect(target);
      await Future<void>.delayed(Duration.zero);
      var closeCompleted = false;
      final close = service.close().whenComplete(() => closeCompleted = true);
      await Future<void>.delayed(Duration.zero);

      expect(closeCompleted, isFalse);
      pendingAcquire.complete(lateLease);

      await Future.wait<void>(<Future<void>>[connect, close]);
      expect(lateLease.isReleased, isTrue);
      expect(lateLease.runCount, 0);
      expect(service.activeTarget, isNull);
      expect(service.isConnected, isFalse);

      service.dispose();
    },
  );

  test('late command result from A is rejected after switching to B', () async {
    final targetA = systemAdminTestTarget('server-a');
    final targetB = systemAdminTestTarget('server-b');
    final leaseA = FakeSystemAdminSshLease(targetBinding: targetA);
    final leaseB = FakeSystemAdminSshLease(targetBinding: targetB);
    final port = FakeSystemAdminSshPort()
      ..acquireOverride = (target) => target.id == 'server-a' ? leaseA : leaseB;
    final service = SystemAdminService(
      sshPort: port,
      logger: FakeSystemAdminLogger(),
    );
    await service.connect(targetA);
    final activeA = service.activeTarget!;
    final lateWho = Completer<RemoteCommandResult>();
    leaseA.responder = (command) {
      if (command.executable == 'who') return lateWho.future;
      throw StateError('unexpected command');
    };

    final queryA = service.getActiveSessions(activeA);
    await Future<void>.delayed(Duration.zero);
    await service.connect(targetB);
    lateWho.complete(
      const RemoteCommandResult(
        exitCode: 0,
        stdout: 'alice pts/0 2026-08-24 10:00 (192.0.2.1)',
        stderr: '',
      ),
    );

    expect(await queryA, isEmpty);
    expect(service.activeTarget?.connectionId, 'server-b');
    expect(leaseA.isReleased, isTrue);

    await service.close();
    service.dispose();
  });

  test(
    'route close promptly releases a lease during root validation',
    () async {
      final target = systemAdminTestTarget('server-a');
      final rootCheck = Completer<RemoteCommandResult>();
      final lease = FakeSystemAdminSshLease(
        targetBinding: target,
        responder: (_) => rootCheck.future,
      );
      final service = SystemAdminService(
        sshPort: FakeSystemAdminSshPort(lease),
        logger: FakeSystemAdminLogger(),
      );

      final connect = service.connect(target);
      for (var pump = 0; lease.runCount == 0 && pump < 10; pump++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(lease.runCount, 1);

      final close = service.close();
      await Future<void>.delayed(Duration.zero);
      expect(lease.isReleased, isTrue);
      rootCheck.complete(
        const RemoteCommandResult(exitCode: 0, stdout: '0', stderr: ''),
      );
      await Future.wait<void>(<Future<void>>[connect, close]);
      expect(service.activeTarget, isNull);

      service.dispose();
    },
  );

  test(
    'an acquired lease for a different immutable target fails closed',
    () async {
      final requested = systemAdminTestTarget('server-a');
      final wrongLease = FakeSystemAdminSshLease(
        targetBinding: systemAdminTestTarget('server-b'),
      );
      final service = SystemAdminService(
        sshPort: FakeSystemAdminSshPort(wrongLease),
        logger: FakeSystemAdminLogger(),
      );

      await service.connect(requested);

      expect(service.isConnected, isFalse);
      expect(service.activeTarget, isNull);
      expect(service.errorMessage, contains('different remote target'));
      expect(wrongLease.runCount, 0);
      expect(wrongLease.isReleased, isTrue);

      await service.close();
      service.dispose();
    },
  );
}
