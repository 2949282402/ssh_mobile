// System Admin 动态参数、密码 stdin 和目标绑定安全测试。

import 'dart:convert';

import 'package:feature_system_admin/feature_system_admin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart';

import '../fakes/system_admin_test_fakes.dart';

void main() {
  late FakeSystemAdminSshLease lease;
  late SystemAdminService service;
  late SystemAdminSessionTarget activeTarget;

  setUp(() async {
    final binding = systemAdminTestTarget('server-a');
    lease = FakeSystemAdminSshLease(targetBinding: binding);
    service = SystemAdminService(
      sshPort: FakeSystemAdminSshPort(lease),
      logger: FakeSystemAdminLogger(),
    );
    await service.connect(binding);
    activeTarget = service.activeTarget!;
  });

  tearDown(() async {
    await service.close();
    service.dispose();
  });

  test(
    'username and login shell injection are rejected before execution',
    () async {
      final initialRuns = lease.runCount;

      await expectLater(
        service.createUser(
          activeTarget,
          username: 'operator;id',
          password: 'safe-password',
        ),
        throwsArgumentError,
      );
      await expectLater(
        service.createUser(
          activeTarget,
          username: 'operator',
          password: 'safe-password',
          shell: '/bin/bash;id',
        ),
        throwsArgumentError,
      );
      await expectLater(
        service.changePassword(activeTarget, 'operator', 'line1\nline2'),
        throwsArgumentError,
      );

      expect(lease.runCount, initialRuns);
    },
  );

  test(
    'password is carried only by bounded stdin, never command text',
    () async {
      const password = r'''S3cr'et;$HOME$(id)''';

      await service.createUser(
        activeTarget,
        username: 'operator',
        password: password,
        shell: '/usr/bin/zsh',
      );

      final useradd = lease.commands[1];
      final chpasswd = lease.commands[2];
      expect(useradd.executable, 'useradd');
      expect(useradd.arguments, <String>[
        '-m',
        '-s',
        '/usr/bin/zsh',
        '--',
        'operator',
      ]);
      expect(chpasswd.executable, 'chpasswd');
      expect(chpasswd.arguments, isEmpty);
      expect(utf8.decode(chpasswd.standardInputBytes!), 'operator:$password\n');

      final commandText = lease.commands
          .map(
            (command) => <String>[
              command.executable ?? '',
              ...command.arguments,
              command.shellScript ?? '',
            ].join(' '),
          )
          .join('\n');
      expect(commandText, isNot(contains(password)));
    },
  );

  test('password command failure does not disclose echoed secret', () async {
    const password = 'server-must-not-echo-this';
    lease.responder = (command) {
      if (command.executable == 'id') {
        return const RemoteCommandResult(exitCode: 0, stdout: '0', stderr: '');
      }
      if (command.executable == 'chpasswd') {
        return const RemoteCommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'server-must-not-echo-this',
        );
      }
      return const RemoteCommandResult(exitCode: 0, stdout: '', stderr: '');
    };

    Object? failure;
    try {
      await service.createUser(
        activeTarget,
        username: 'operator',
        password: password,
      );
    } catch (error) {
      failure = error;
    }

    expect(failure, isA<StateError>());
    expect(failure.toString(), isNot(contains(password)));
    expect(lease.commands.last.executable, 'userdel');
  });

  test('a command cannot run with a stale session generation', () async {
    final stale = SystemAdminSessionTarget(
      binding: activeTarget.binding,
      generation: activeTarget.generation + 1,
    );
    final initialRuns = lease.runCount;

    await expectLater(
      service.lockUser(stale, 'operator'),
      throwsA(isA<StateError>()),
    );
    expect(lease.runCount, initialRuns);
  });

  test(
    'admin revocation removes both groups and verifies the result',
    () async {
      final groups = <String>{'sudo', 'wheel'};
      lease.responder = (command) {
        if (command.executable == 'groups') {
          return RemoteCommandResult(
            exitCode: 0,
            stdout: 'operator : ${groups.join(' ')}',
            stderr: '',
          );
        }
        if (command.executable == 'gpasswd') {
          groups.remove(command.arguments.last);
          return const RemoteCommandResult(exitCode: 0, stdout: '', stderr: '');
        }
        throw StateError('unexpected command');
      };

      await service.setUserSudo(activeTarget, 'operator', false);

      expect(groups, isEmpty);
      expect(
        lease.commands
            .where((command) => command.executable == 'gpasswd')
            .map((command) => command.arguments.last),
        <String>['sudo', 'wheel'],
      );
    },
  );

  test('sudo status uses exact group names', () async {
    lease.responder = (command) {
      if (command.executable == 'groups') {
        return const RemoteCommandResult(
          exitCode: 0,
          stdout: 'operator : nosudo wheelbarrow',
          stderr: '',
        );
      }
      throw StateError('unexpected command');
    };

    expect(await service.checkUserSudo(activeTarget, 'operator'), isFalse);
  });
}
