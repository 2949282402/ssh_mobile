// System Admin 破坏性操作确认 Token 的目标绑定和一次性消费测试。

import 'package:feature_system_admin/feature_system_admin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart';

import '../fakes/system_admin_test_fakes.dart';

void main() {
  late SystemAdminService service;
  late FakeSystemAdminSshLease leaseA;
  late FakeSystemAdminSshLease leaseB;
  late SystemAdminSessionTarget activeA;
  late SshTargetBinding targetB;

  setUp(() async {
    final targetA = systemAdminTestTarget('server-a');
    targetB = systemAdminTestTarget('server-b');
    leaseA = FakeSystemAdminSshLease(targetBinding: targetA);
    leaseB = FakeSystemAdminSshLease(targetBinding: targetB);
    final port = FakeSystemAdminSshPort()
      ..acquireOverride = (target) => target.id == 'server-a' ? leaseA : leaseB;
    service = SystemAdminService(
      sshPort: port,
      logger: FakeSystemAdminLogger(),
    );
    await service.connect(targetA);
    activeA = service.activeTarget!;
  });

  tearDown(() async {
    await service.close();
    service.dispose();
  });

  test('a power token is consumed exactly once', () async {
    final token = SystemPowerConfirmationToken.testing(
      action: SystemPowerAction.reboot,
      target: activeA,
      nonce: 'one-time-token',
    );

    await service.rebootServer(token);
    final runsAfterFirstUse = leaseA.runCount;
    await expectLater(service.rebootServer(token), throwsA(isA<StateError>()));

    expect(leaseA.runCount, runsAfterFirstUse);
    expect(leaseA.commands.last.executable, 'reboot');
  });

  test('a consumed token cannot be retried after command failure', () async {
    leaseA.responder = (command) {
      if (command.executable == 'reboot') {
        throw StateError('simulated transport failure');
      }
      throw StateError('unexpected command');
    };
    final token = SystemPowerConfirmationToken.testing(
      action: SystemPowerAction.reboot,
      target: activeA,
      nonce: 'failed-but-consumed',
    );

    await expectLater(service.rebootServer(token), throwsA(isA<StateError>()));
    final runsAfterFailure = leaseA.runCount;
    await expectLater(service.rebootServer(token), throwsA(isA<StateError>()));

    expect(leaseA.runCount, runsAfterFailure);
  });

  test('a token for target A cannot execute after reconnecting to B', () async {
    final tokenA = SystemPowerConfirmationToken.testing(
      action: SystemPowerAction.shutdown,
      target: activeA,
      nonce: 'target-a-only',
    );

    await service.connect(targetB);
    expect(service.activeTarget?.connectionId, 'server-b');
    final bRunsBeforeAttempt = leaseB.runCount;

    await expectLater(
      service.shutdownServer(tokenA),
      throwsA(isA<StateError>()),
    );
    expect(leaseB.runCount, bRunsBeforeAttempt);
  });

  test('future-dated and expired tokens fail closed', () async {
    final expired = SystemPowerConfirmationToken.testing(
      action: SystemPowerAction.reboot,
      target: activeA,
      issuedAt: DateTime.now().subtract(const Duration(minutes: 3)),
      nonce: 'expired',
    );
    final future = SystemPowerConfirmationToken.testing(
      action: SystemPowerAction.reboot,
      target: activeA,
      issuedAt: DateTime.now().add(const Duration(minutes: 1)),
      nonce: 'future',
    );
    final runsBeforeAttempt = leaseA.runCount;

    await expectLater(
      service.rebootServer(expired),
      throwsA(isA<StateError>()),
    );
    await expectLater(service.rebootServer(future), throwsA(isA<StateError>()));
    expect(leaseA.runCount, runsBeforeAttempt);
  });

  test('the replay registry is bounded and fails closed at capacity', () async {
    for (
      var index = 0;
      index < SystemAdminService.powerTokenRegistryCapacity;
      index++
    ) {
      await service.rebootServer(
        SystemPowerConfirmationToken.testing(
          action: SystemPowerAction.reboot,
          target: activeA,
          nonce: 'bounded-$index',
        ),
      );
    }
    final runsAtCapacity = leaseA.runCount;

    await expectLater(
      service.rebootServer(
        SystemPowerConfirmationToken.testing(
          action: SystemPowerAction.reboot,
          target: activeA,
          nonce: 'bounded-overflow',
        ),
      ),
      throwsA(isA<StateError>()),
    );
    expect(leaseA.runCount, runsAtCapacity);
  });

  test('a consumed nonce is evicted when its token validity ends', () async {
    const nonce = 'expires-with-token';
    final nearlyExpired = SystemPowerConfirmationToken.testing(
      action: SystemPowerAction.reboot,
      target: activeA,
      issuedAt: DateTime.now().subtract(
        SystemPowerConfirmationToken.validity -
            const Duration(milliseconds: 500),
      ),
      nonce: nonce,
    );

    await service.rebootServer(nearlyExpired);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await service.rebootServer(
      SystemPowerConfirmationToken.testing(
        action: SystemPowerAction.reboot,
        target: activeA,
        nonce: nonce,
      ),
    );

    expect(
      leaseA.commands.where((command) => command.executable == 'reboot'),
      hasLength(2),
    );
  });
}
