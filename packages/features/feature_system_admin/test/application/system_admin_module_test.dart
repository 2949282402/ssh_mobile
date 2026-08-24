// System Admin Module 生命周期测试。
//
// 测试验证 Module 不会在 activate 时自动连接服务器，并且释放时会先
// 取消活动命令、再关闭管理会话，避免 SSH 资源遗留。

import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:feature_system_admin/feature_system_admin.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/system_admin_test_fakes.dart';

void main() {
  test(
    'module activation does not connect to a server automatically',
    () async {
      final lease = FakeSystemAdminSshLease(
        targetBinding: systemAdminTestTarget('server-1'),
      );
      final ssh = FakeSystemAdminSshPort(lease);
      final module = SystemAdminModule();

      await module.register(
        ModuleContext.fromMap({
          SystemAdminSshPort: ssh,
          SystemAdminLoggerPort: FakeSystemAdminLogger(),
        }),
      );
      await module.initialize();
      await module.activate();

      expect(module.state, ModuleState.active);
      expect(ssh.acquireCount, 0);
      expect(lease.runCount, 0);

      await module.deactivate();
      expect(module.state, ModuleState.inactive);
      await module.dispose();
      expect(module.state, ModuleState.disposed);
      expect(lease.isReleased, isFalse);
    },
  );

  test('module disposal releases an active management session', () async {
    final target = systemAdminTestTarget('server-1');
    final lease = FakeSystemAdminSshLease(targetBinding: target);
    final ssh = FakeSystemAdminSshPort(lease);
    final module = SystemAdminModule();

    await module.register(
      ModuleContext.fromMap({
        SystemAdminSshPort: ssh,
        SystemAdminLoggerPort: FakeSystemAdminLogger(),
      }),
    );
    await module.activate();
    await module.service.connect(target);

    expect(ssh.acquireCount, 1);
    expect(lease.runCount, 1);
    expect(module.service.isConnected, isTrue);

    await module.dispose();

    expect(lease.cancelCount, greaterThan(0));
    expect(lease.isReleased, isTrue);
    expect(module.state, ModuleState.disposed);
  });

  test('dispose wins an activation continuation already in flight', () async {
    final module = SystemAdminModule();
    await module.register(
      ModuleContext.fromMap({
        SystemAdminSshPort: FakeSystemAdminSshPort(),
        SystemAdminLoggerPort: FakeSystemAdminLogger(),
      }),
    );

    final activation = module.activate();
    final disposal = module.dispose();
    await Future.wait<void>([activation, disposal]);

    expect(module.state, ModuleState.disposed);
  });

  test('module disposal waits for and releases a late acquisition', () async {
    final target = systemAdminTestTarget('server-1');
    final lateLease = FakeSystemAdminSshLease(targetBinding: target);
    final pendingAcquire = Completer<SystemAdminSshLeasePort>();
    final ssh = FakeSystemAdminSshPort()
      ..acquireOverride = (_) => pendingAcquire.future;
    final module = SystemAdminModule();
    await module.register(
      ModuleContext.fromMap({
        SystemAdminSshPort: ssh,
        SystemAdminLoggerPort: FakeSystemAdminLogger(),
      }),
    );
    await module.activate();

    final connect = module.service.connect(target);
    await Future<void>.delayed(Duration.zero);
    var disposeCompleted = false;
    final disposal = module.dispose().whenComplete(
      () => disposeCompleted = true,
    );
    await Future<void>.delayed(Duration.zero);

    expect(disposeCompleted, isFalse);
    pendingAcquire.complete(lateLease);
    await Future.wait<void>(<Future<void>>[connect, disposal]);

    expect(lateLease.isReleased, isTrue);
    expect(module.state, ModuleState.disposed);
  });
}
