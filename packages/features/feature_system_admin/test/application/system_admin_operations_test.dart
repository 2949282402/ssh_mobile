// System Admin 账户与只读检查职责的独立行为覆盖。

import 'package:feature_system_admin/feature_system_admin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart';

import '../fakes/system_admin_test_fakes.dart';

void main() {
  late _Harness harness;

  setUp(() async {
    harness = await _Harness.create();
  });

  tearDown(() async {
    await harness.close();
  });

  test(
    'account mutations validate commands and expose bounded snapshots',
    () async {
      harness.lease.responder = (command) {
        switch (command.executable) {
          case 'usermod':
          case 'chpasswd':
            return _ok();
          case 'du':
            return _ok(stdout: '12M\t/home/operator\n');
          case 'ps':
            return _ok(stdout: '42 2048 1.5 2.5 /usr/bin/demo --serve\n');
          default:
            throw StateError('unexpected command ${command.executable}');
        }
      };

      await harness.service.lockUser(harness.activeTarget, 'operator');
      await harness.service.unlockUser(harness.activeTarget, 'operator');
      await harness.service.changePassword(
        harness.activeTarget,
        'operator',
        'safe-password',
      );
      expect(
        await harness.service.getUserHomeStorageUsage(
          harness.activeTarget,
          '/home/operator',
        ),
        '12M',
      );
      final processes = await harness.service.getUserProcessesAndMemory(
        harness.activeTarget,
        'operator',
      );
      expect(processes.single.pid, 42);
      expect(processes.single.command, contains('/usr/bin/demo'));
      expect(
        harness.lease.commands
            .where((command) => command.executable == 'usermod')
            .map((command) => command.arguments.first),
        <String>['-L', '-U'],
      );
    },
  );

  test(
    'account command failures are stable and read failures return empty data',
    () async {
      harness.lease.responder = (command) {
        if (command.executable == 'usermod' ||
            command.executable == 'chpasswd') {
          return _failed();
        }
        if (command.executable == 'du') throw StateError('transport failed');
        if (command.executable == 'ps') return _failed();
        if (command.shellScript != null) return _failed();
        throw StateError('unexpected command ${command.executable}');
      };

      await expectLater(
        harness.service.lockUser(harness.activeTarget, 'operator'),
        throwsStateError,
      );
      await expectLater(
        harness.service.changePassword(
          harness.activeTarget,
          'operator',
          'safe-password',
        ),
        throwsStateError,
      );
      expect(
        await harness.service.getUserHomeStorageUsage(
          harness.activeTarget,
          '/home/operator',
        ),
        'N/A',
      );
      expect(
        await harness.service.getUserProcessesAndMemory(
          harness.activeTarget,
          'operator',
        ),
        isEmpty,
      );
      expect(
        await harness.service.getUserAccounts(harness.activeTarget),
        isEmpty,
      );
    },
  );

  test('sudo grant falls back and revoke verifies both exact groups', () async {
    var grantAttempts = 0;
    final groups = <String>{'wheel'};
    harness.lease.responder = (command) {
      if (command.executable == 'usermod') {
        grantAttempts++;
        return grantAttempts == 1 ? _failed() : _ok();
      }
      if (command.executable == 'groups') {
        return _ok(stdout: 'operator : ${groups.join(' ')}');
      }
      if (command.executable == 'gpasswd') return _failed();
      if (command.executable == 'deluser') {
        groups.remove(command.arguments.last);
        return _ok();
      }
      throw StateError('unexpected command ${command.executable}');
    };

    await harness.service.setUserSudo(harness.activeTarget, 'operator', true);
    expect(grantAttempts, 2);
    expect(
      await harness.service.checkUserSudo(harness.activeTarget, 'operator'),
      isTrue,
    );
    await harness.service.setUserSudo(harness.activeTarget, 'operator', false);
    expect(groups, isEmpty);
    expect(
      harness.lease.commands.where(
        (command) => command.executable == 'deluser',
      ),
      hasLength(2),
    );
  });

  test('sudo and user creation failures do not report success', () async {
    harness.lease.responder = (command) {
      if (command.executable == 'groups') return _failed();
      if (command.executable == 'useradd') return _failed();
      throw StateError('unexpected command ${command.executable}');
    };

    expect(
      await harness.service.checkUserSudo(harness.activeTarget, 'operator'),
      isFalse,
    );
    await expectLater(
      harness.service.createUser(
        harness.activeTarget,
        username: 'operator',
        password: 'safe-password',
      ),
      throwsStateError,
    );
  });

  test('account dynamic values fail closed before a remote command', () async {
    final runs = harness.lease.runCount;
    await expectLater(
      harness.service.getUserHomeStorageUsage(harness.activeTarget, 'relative'),
      throwsArgumentError,
    );
    await expectLater(
      harness.service.getUserHomeStorageUsage(
        harness.activeTarget,
        '/home/operator\n/etc',
      ),
      throwsArgumentError,
    );
    await expectLater(
      harness.service.createUser(
        harness.activeTarget,
        username: 'Operator',
        password: 'safe-password',
      ),
      throwsArgumentError,
    );
    await expectLater(
      harness.service.createUser(
        harness.activeTarget,
        username: 'operator',
        password: 'safe-password',
        shell: '/../bin/sh',
      ),
      throwsArgumentError,
    );
    await expectLater(
      harness.service.changePassword(harness.activeTarget, 'operator', ''),
      throwsArgumentError,
    );
    expect(harness.lease.runCount, runs);
  });

  test(
    'inspection commands cover success, fallback and strict validation',
    () async {
      harness.lease.responder = (command) {
        switch (command.executable) {
          case 'who':
            return _ok(stdout: 'operator pts/1 2026-08-24 10:00 (192.0.2.1)');
          case 'pkill':
            return const RemoteCommandResult(
              exitCode: 1,
              stdout: '',
              stderr: '',
            );
          case 'systemctl':
            if (command.arguments.first == 'list-units') {
              return _ok(stdout: 'ssh.service loaded active running OpenSSH');
            }
            return _ok();
          case 'ss':
            return _failed();
          case 'netstat':
            return _ok(stdout: 'tcp 0 0 0.0.0.0:22 0.0.0.0:* LISTEN 10/sshd');
          default:
            throw StateError('unexpected command ${command.executable}');
        }
      };

      expect(
        await harness.service.getActiveSessions(harness.activeTarget),
        hasLength(1),
      );
      await harness.service.killActiveSession(
        harness.activeTarget,
        '/dev/pts/1',
      );
      expect(
        await harness.service.getSystemdServices(harness.activeTarget),
        hasLength(1),
      );
      await harness.service.manageSystemdService(
        harness.activeTarget,
        'ssh.service',
        'restart',
      );
      expect(
        await harness.service.getListeningPorts(harness.activeTarget),
        hasLength(1),
      );
      await expectLater(
        harness.service.manageSystemdService(
          harness.activeTarget,
          'ssh.service',
          'reload-or-inject',
        ),
        throwsArgumentError,
      );
      await expectLater(
        harness.service.killActiveSession(harness.activeTarget, '../pts/1'),
        throwsArgumentError,
      );
    },
  );

  test(
    'inspection failures return empty snapshots or rethrow mutations',
    () async {
      harness.lease.responder = (command) {
        if (command.executable == 'pkill' ||
            (command.executable == 'systemctl' &&
                command.arguments.first != 'list-units')) {
          return const RemoteCommandResult(exitCode: 2, stdout: '', stderr: '');
        }
        if (command.executable == 'netstat') throw StateError('offline');
        return _failed();
      };

      expect(
        await harness.service.getActiveSessions(harness.activeTarget),
        isEmpty,
      );
      expect(
        await harness.service.getSystemdServices(harness.activeTarget),
        isEmpty,
      );
      expect(
        await harness.service.getListeningPorts(harness.activeTarget),
        isEmpty,
      );
      await expectLater(
        harness.service.killActiveSession(harness.activeTarget, 'pts/1'),
        throwsStateError,
      );
      await expectLater(
        harness.service.manageSystemdService(
          harness.activeTarget,
          'ssh.service',
          'stop',
        ),
        throwsStateError,
      );
      await expectLater(
        harness.service.manageSystemdService(
          harness.activeTarget,
          'bad\nservice',
          'stop',
        ),
        throwsArgumentError,
      );
    },
  );
}

RemoteCommandResult _ok({String stdout = ''}) =>
    RemoteCommandResult(exitCode: 0, stdout: stdout, stderr: '');

RemoteCommandResult _failed() =>
    const RemoteCommandResult(exitCode: 1, stdout: '', stderr: 'failed');

final class _Harness {
  _Harness(this.lease, this.service, this.activeTarget);

  final FakeSystemAdminSshLease lease;
  final SystemAdminService service;
  final SystemAdminSessionTarget activeTarget;

  static Future<_Harness> create() async {
    final target = systemAdminTestTarget('server-a');
    final lease = FakeSystemAdminSshLease(targetBinding: target);
    final service = SystemAdminService(
      sshPort: FakeSystemAdminSshPort(lease),
      logger: FakeSystemAdminLogger(),
    );
    await service.connect(target);
    return _Harness(lease, service, service.activeTarget!);
  }

  Future<void> close() async {
    await service.close();
    service.dispose();
  }
}
