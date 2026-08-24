import 'package:connection_core/connection_core.dart';
import 'package:feature_system_admin/feature_system_admin.dart' as admin;
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart';

import '../fakes/system_admin_test_fakes.dart';

void main() {
  late admin.SystemAdminService adminService;
  late FakeSystemAdminConnectionCatalog connectionCatalog;
  late FakeSystemAdminSshPort sshPort;
  late FakeSystemAdminSshLease sshLease;
  late FakeSystemAdminLogger logger;
  String? lastCommand;
  int nextExitCode = 0;
  String nextStdout = '';
  String nextStderr = '';

  String commandLabel(admin.SystemAdminCommand command) {
    return command.shellScript ??
        <String>[command.executable!, ...command.arguments].join(' ');
  }

  setUp(() {
    final connection = systemAdminTestConnection('conn_123');
    sshLease = FakeSystemAdminSshLease(
      targetBinding: SshTargetBinding.fromConfig(connection),
    );
    sshPort = FakeSystemAdminSshPort(sshLease);
    logger = FakeSystemAdminLogger();
    connectionCatalog = FakeSystemAdminConnectionCatalog()
      ..connections = <ConnectionConfig>[connection];
    adminService = admin.SystemAdminService(sshPort: sshPort, logger: logger);
    sshLease.responder = (command) {
      lastCommand = commandLabel(command);
      return RemoteCommandResult(
        exitCode: nextExitCode,
        stdout: command.executable == 'id' ? '0' : nextStdout,
        stderr: nextStderr,
      );
    };
    lastCommand = null;
    nextExitCode = 0;
    nextStdout = '';
    nextStderr = '';
  });

  tearDown(() async {
    await adminService.close();
    adminService.dispose();
  });

  admin.SystemAdminViewModel createViewModel() => admin.SystemAdminViewModel(
    adminService: adminService,
    connectionCatalog: connectionCatalog,
  )..debounceDuration = Duration.zero;

  Future<admin.SystemAdminViewModel> rootConnectedViewModel() async {
    final viewModel = createViewModel();
    viewModel.selectConnection('conn_123');
    await viewModel.connectIfNeeded('conn_123');
    expect(viewModel.activeManagementConnectionId, equals('conn_123'));
    return viewModel;
  }

  group('SystemAdminViewModel', () {
    test('initializes without a selected management connection', () {
      final viewModel = createViewModel();

      expect(viewModel.connectionId, isNull);
      expect(viewModel.selectedConnectionId, isNull);
      expect(viewModel.isConnected, isFalse);
      expect(viewModel.isConnecting, isFalse);
      expect(viewModel.accounts, isEmpty);
      expect(viewModel.sessions, isEmpty);
      expect(viewModel.services, isEmpty);
      expect(viewModel.ports, isEmpty);
    });

    test('selectConnection updates selection and notifies listeners', () {
      final viewModel = createViewModel();
      var notified = false;
      viewModel.addListener(() => notified = true);

      viewModel.selectConnection('conn_123');

      expect(viewModel.selectedConnectionId, equals('conn_123'));
      expect(viewModel.connectionId, equals('conn_123'));
      expect(notified, isTrue);
    });

    test(
      'connect opens management connection and synchronizes selection',
      () async {
        final viewModel = createViewModel();
        var notified = false;
        viewModel.addListener(() => notified = true);

        await viewModel.connect('conn_123');

        expect(viewModel.selectedConnectionId, equals('conn_123'));
        expect(viewModel.managementConnectionId, equals('conn_123'));
        expect(viewModel.isConnected, isTrue);
        expect(notified, isTrue);
        expect(sshPort.acquireCount, 1);
      },
    );

    test('failed connectIfNeeded retains selected connection', () async {
      final viewModel = createViewModel();
      viewModel.selectConnection('conn_123');
      sshPort.acquireOverride = (target) async {
        throw Exception('SSH connect timeout');
      };

      await viewModel.connectIfNeeded('conn_123');

      expect(viewModel.selectedConnectionId, equals('conn_123'));
      expect(viewModel.managementConnectionId, isNull);
      expect(viewModel.isConnected, isFalse);
      expect(viewModel.errorMessage, contains('SSH connect timeout'));
    });

    test('management actions require an active selected connection', () async {
      final viewModel = createViewModel();
      viewModel.selectConnection('conn_123');

      expect(await viewModel.checkUserSudo('admin'), isFalse);
      expect(lastCommand, isNull);
    });

    test('fetchAccounts parses user accounts and status snapshots', () async {
      final viewModel = await rootConnectedViewModel();
      nextStdout = '''
root:x:0:0:root:/root:/bin/bash
admin:x:1000:1000:Admin User:/home/admin:/bin/bash
===STATUS===
root P
admin L
''';

      await viewModel.fetchAccounts('conn_123');

      expect(viewModel.accounts, hasLength(2));
      expect(viewModel.accounts[0].username, equals('root'));
      expect(viewModel.accounts[0].uid, equals(0));
      expect(viewModel.accounts[1].username, equals('admin'));
      expect(viewModel.accounts[1].isLocked, isTrue);
      expect(lastCommand, contains('cat /etc/passwd'));
    });

    test('fetchSessions parses who output', () async {
      final viewModel = await rootConnectedViewModel();
      nextStdout = '''
root     pts/0        2026-06-03 08:30 (192.168.1.10)
''';

      await viewModel.fetchSessions('conn_123');

      expect(viewModel.sessions, hasLength(1));
      expect(viewModel.sessions.single.username, equals('root'));
      expect(viewModel.sessions.single.tty, equals('pts/0'));
      expect(viewModel.sessions.single.ipAddress, equals('192.168.1.10'));
      expect(lastCommand, equals('who'));
    });

    test('fetchServices parses systemd output', () async {
      final viewModel = await rootConnectedViewModel();
      nextStdout =
          'ssh.service loaded active running OpenBSD Secure Shell server';

      await viewModel.fetchServices('conn_123');

      expect(viewModel.services, hasLength(1));
      expect(viewModel.services.single.name, equals('ssh.service'));
      expect(viewModel.services.single.activeState, equals('active'));
      expect(viewModel.services.single.isRunning, isTrue);
      expect(lastCommand, contains('systemctl list-units'));
    });

    test('fetchPorts parses listening port output', () async {
      final viewModel = await rootConnectedViewModel();
      nextStdout =
          'tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1024,fd=3))';

      await viewModel.fetchPorts('conn_123');

      expect(viewModel.ports, hasLength(1));
      expect(viewModel.ports.single.protocol, equals('tcp'));
      expect(viewModel.ports.single.localPort, equals(22));
      expect(viewModel.ports.single.processName, equals('sshd'));
      expect(viewModel.ports.single.pid, equals(1024));
    });

    test('refreshAllData awaits all forced management fetches', () async {
      final viewModel = await rootConnectedViewModel();
      final commands = <String>[];
      sshLease.responder = (command) {
        final label = commandLabel(command);
        commands.add(label);
        final stdout = switch (label) {
          final value when value.contains('cat /etc/passwd') =>
            'root:x:0:0:root:/root:/bin/bash\n===STATUS===\nroot P\n',
          'who' => 'root pts/0 2026-07-15 10:30 (192.168.1.10)',
          final value when value.contains('systemctl list-units') =>
            'ssh.service loaded active running OpenSSH server',
          final value when value.contains('ss -tulpn') =>
            'tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1024,fd=3))',
          _ => '',
        };
        return RemoteCommandResult(exitCode: 0, stdout: stdout, stderr: '');
      };

      await viewModel.refreshAllData();

      expect(commands, hasLength(4));
      expect(viewModel.accounts, hasLength(1));
      expect(viewModel.sessions, hasLength(1));
      expect(viewModel.services, hasLength(1));
      expect(viewModel.ports, hasLength(1));
    });

    test('fetch caches empty results by connection id', () async {
      final viewModel = await rootConnectedViewModel();
      await viewModel.fetchSessions('conn_123');
      expect(viewModel.sessions, isEmpty);
      expect(lastCommand, equals('who'));

      lastCommand = null;
      await viewModel.fetchSessions('conn_123');
      expect(lastCommand, isNull);
    });

    test('clearInvalidSelection disconnects stale management state', () async {
      final viewModel = await rootConnectedViewModel();

      viewModel.clearInvalidSelection();

      expect(viewModel.selectedConnectionId, isNull);
      expect(viewModel.managementConnectionId, isNull);
      expect(viewModel.accounts, isEmpty);
      expect(viewModel.sessions, isEmpty);
      expect(viewModel.services, isEmpty);
      expect(viewModel.ports, isEmpty);
    });

    test(
      'editing the selected endpoint invalidates its active target',
      () async {
        final viewModel = await rootConnectedViewModel();
        connectionCatalog.replaceConnections(<ConnectionConfig>[
          systemAdminTestConnection('conn_123', host: 'changed.example.test'),
        ]);
        await Future<void>.delayed(Duration.zero);

        expect(viewModel.activeManagementTarget, isNull);
        expect(viewModel.isConnected, isFalse);
        expect(sshLease.isReleased, isTrue);
      },
    );

    test('power operations validate action and token freshness', () async {
      final viewModel = await rootConnectedViewModel();
      final target = viewModel.activeManagementTarget!;
      final rebootToken = admin.SystemPowerConfirmationToken.testing(
        action: admin.SystemPowerAction.reboot,
        target: target,
      );
      final shutdownToken = admin.SystemPowerConfirmationToken.testing(
        action: admin.SystemPowerAction.shutdown,
        target: target,
      );

      await viewModel.rebootServer(rebootToken);
      expect(lastCommand, equals('reboot'));

      lastCommand = null;
      expect(() => viewModel.rebootServer(shutdownToken), throwsArgumentError);
      expect(lastCommand, isNull);

      final expired = admin.SystemPowerConfirmationToken.testing(
        action: admin.SystemPowerAction.reboot,
        target: target,
        issuedAt: DateTime.now().subtract(const Duration(minutes: 3)),
      );
      expect(() => viewModel.rebootServer(expired), throwsStateError);
      expect(lastCommand, isNull);

      await viewModel.shutdownServer(shutdownToken);
      expect(lastCommand, equals('shutdown -h now'));
    });
  });
}
