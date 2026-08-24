// System Admin 远程命令解析和管理行为测试。
//
// 通过 Service 的测试替身命令通道验证解析器迁移后仍保留原有的用户、
// 会话、服务和监听端口数据行为，不需要真实服务器或凭据。

import 'package:feature_system_admin/feature_system_admin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart';

import '../fakes/system_admin_test_fakes.dart';

void main() {
  test(
    'parses management command snapshots without a real SSH server',
    () async {
      final target = systemAdminTestTarget('server-1');
      final lease = FakeSystemAdminSshLease(targetBinding: target);
      lease.responder = (command) {
        final executable = command.executable;
        final output = switch (executable) {
          'id' => '0',
          'who' => 'gary pts/0 2026-08-08 09:30 (192.0.2.10)',
          null when command.shellScript != null =>
            'root:x:0:0:root:/root:/bin/bash\n'
                'gary:x:1000:1000:Gary:/home/gary:/bin/bash\n'
                'nobody:x:65534:65534:Nobody:/nonexistent:/usr/sbin/nologin\n'
                '===STATUS===\n'
                'root P 2026-01-01 0 99999 7 -1\n'
                'gary L 2026-01-01 0 99999 7 -1',
          'systemctl' => 'ssh.service loaded active running OpenSSH server',
          'ss' =>
            'tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=10,fd=3))',
          _ => '',
        };
        return RemoteCommandResult(exitCode: 0, stdout: output, stderr: '');
      };
      final service = SystemAdminService(
        sshPort: FakeSystemAdminSshPort(lease),
        logger: FakeSystemAdminLogger(),
      );
      await service.connect(target);
      final activeTarget = service.activeTarget!;

      final sessions = await service.getActiveSessions(activeTarget);
      final accounts = await service.getUserAccounts(activeTarget);
      final services = await service.getSystemdServices(activeTarget);
      final ports = await service.getListeningPorts(activeTarget);

      expect(sessions.single.ipAddress, '192.0.2.10');
      expect(accounts.map((account) => account.username), ['root', 'gary']);
      expect(accounts.last.isLocked, isTrue);
      expect(services.single.isRunning, isTrue);
      expect(ports.single.localPort, 22);
      expect(ports.single.processName, 'sshd');

      await service.close();
      service.dispose();
    },
  );
}
