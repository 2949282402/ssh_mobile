// System Admin Module 生命周期测试。
//
// 测试验证 Module 不会在 activate 时自动连接服务器，并且释放时会先
// 取消活动命令、再关闭管理会话，避免 SSH 资源遗留。

import 'package:app_core/app_core.dart';
import 'package:feature_system_admin/feature_system_admin.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/system_admin_test_fakes.dart';

void main() {
  test(
    'module activation does not connect to a server automatically',
    () async {
      final session = FakeSystemAdminSshSession();
      final ssh = FakeSystemAdminSshPort(session);
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
      expect(ssh.connectCount, 0);
      expect(session.runCount, 0);

      await module.deactivate();
      expect(module.state, ModuleState.inactive);
      await module.dispose();
      expect(module.state, ModuleState.disposed);
      expect(session.isClosed, isFalse);
    },
  );

  test('module disposal releases an active management session', () async {
    final session = FakeSystemAdminSshSession();
    final ssh = FakeSystemAdminSshPort(session);
    final module = SystemAdminModule();

    await module.register(
      ModuleContext.fromMap({
        SystemAdminSshPort: ssh,
        SystemAdminLoggerPort: FakeSystemAdminLogger(),
      }),
    );
    await module.activate();
    await module.service.connect('server-1');

    expect(ssh.connectCount, 1);
    expect(session.runCount, 1);
    expect(module.service.isConnected, isTrue);

    await module.dispose();

    expect(session.cancelCount, greaterThan(0));
    expect(session.isClosed, isTrue);
    expect(module.state, ModuleState.disposed);
  });
}
