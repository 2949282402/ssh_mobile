// System Admin 输出超限后会使目标 generation 失效并释放 Lease。

import 'package:feature_system_admin/feature_system_admin.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/system_admin_test_fakes.dart';

void main() {
  test(
    'output limit failure invalidates and releases the active target',
    () async {
      final binding = systemAdminTestTarget('server-a');
      final lease = FakeSystemAdminSshLease(targetBinding: binding);
      final service = SystemAdminService(
        sshPort: FakeSystemAdminSshPort(lease),
        logger: FakeSystemAdminLogger(),
      );
      await service.connect(binding);
      final target = service.activeTarget!;
      lease.responder = (_) => throw const SystemAdminOutputLimitException(
        maxBytes: SystemAdminCommand.maxOutputBytes,
      );

      expect(await service.getActiveSessions(target), isEmpty);
      expect(service.isConnected, isFalse);
      expect(service.activeTarget, isNull);
      expect(lease.isReleased, isTrue);
      expect(service.errorMessage, contains('output exceeded'));

      await service.close();
      service.dispose();
    },
  );

  test('command timeout invalidates and releases the active target', () async {
    final binding = systemAdminTestTarget('server-a');
    final lease = FakeSystemAdminSshLease(targetBinding: binding);
    final service = SystemAdminService(
      sshPort: FakeSystemAdminSshPort(lease),
      logger: FakeSystemAdminLogger(),
    );
    await service.connect(binding);
    final target = service.activeTarget!;
    lease.responder = (_) => throw const SystemAdminCommandTimeoutException();

    expect(await service.getActiveSessions(target), isEmpty);
    expect(service.isConnected, isFalse);
    expect(service.activeTarget, isNull);
    expect(lease.isReleased, isTrue);
    expect(service.errorMessage, 'System Admin command timed out.');

    await service.close();
    service.dispose();
  });
}
