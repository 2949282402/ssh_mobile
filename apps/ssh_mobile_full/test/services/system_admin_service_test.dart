import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/ssh_service.dart'; // for RemoteCommandResult
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/services/system_admin_service.dart';

void main() {
  late StorageService fakeStorage;
  late SystemAdminService service;
  String? lastCommand;
  int nextExitCode = 0;
  String nextStdout = '';
  String nextStderr = '';

  setUp(() {
    fakeStorage = StorageService();
    service = SystemAdminService(fakeStorage);
    lastCommand = null;
    nextExitCode = 0;
    nextStdout = '';
    nextStderr = '';

    service.runCommandOverride = (cmd) async {
      lastCommand = cmd;
      return RemoteCommandResult(
        exitCode: nextExitCode,
        stdout: nextStdout,
        stderr: nextStderr,
      );
    };
  });

  test('checkRootPrivilege returns status isRoot', () async {
    final isRoot = await service.checkRootPrivilege('conn1');
    expect(isRoot, isFalse);
  });

  test('getActiveSessions parses who command output correctly', () async {
    nextStdout = '''
root     pts/0        2026-06-03 08:30 (192.168.1.10)
admin    pts/1        2026-06-03 08:31 (192.168.1.11)
''';
    nextExitCode = 0;

    final sessions = await service.getActiveSessions('conn1');
    expect(sessions, hasLength(2));

    expect(sessions[0].username, 'root');
    expect(sessions[0].tty, 'pts/0');
    expect(sessions[0].loginTime, '2026-06-03 08:30');
    expect(sessions[0].ipAddress, '192.168.1.10');

    expect(sessions[1].username, 'admin');
    expect(sessions[1].tty, 'pts/1');
    expect(sessions[1].loginTime, '2026-06-03 08:31');
    expect(sessions[1].ipAddress, '192.168.1.11');
    expect(lastCommand, 'who');
  });

  test(
    'getUserAccounts parses /etc/passwd and password status correctly',
    () async {
      nextStdout = '''
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev:
admin:x:1000:1000:Admin User:/home/admin:/bin/bash
===STATUS===
root P 06/03/2026 0 99999 7 -1
admin L 06/03/2026 0 99999 7 -1
''';
      nextExitCode = 0;

      final accounts = await service.getUserAccounts('conn1');
      // Only root and admin should be returned (bin has empty/nologin-style shell and low UID)
      expect(accounts, hasLength(2));

      expect(accounts[0].username, 'root');
      expect(accounts[0].uid, 0);
      expect(accounts[0].homeDir, '/root');
      expect(accounts[0].shell, '/bin/bash');
      expect(accounts[0].status, 'P');
      expect(accounts[0].isLocked, isFalse);

      expect(accounts[1].username, 'admin');
      expect(accounts[1].uid, 1000);
      expect(accounts[1].homeDir, '/home/admin');
      expect(accounts[1].shell, '/bin/bash');
      expect(accounts[1].status, 'L');
      expect(accounts[1].isLocked, isTrue);
    },
  );

  test('getSystemdServices parses running and stopped services', () async {
    nextStdout = '''
cron.service loaded active running Regular background program daemon
ssh.service  loaded active running OpenBSD Secure Shell server
nginx.service loaded inactive dead HTTP Nginx server
''';
    nextExitCode = 0;

    final services = await service.getSystemdServices('conn1');
    expect(services, hasLength(3));

    expect(services[0].name, 'cron.service');
    expect(services[0].isRunning, isTrue);
    expect(services[0].isEnabled, isTrue);

    expect(services[2].name, 'nginx.service');
    expect(services[2].isRunning, isFalse);
    expect(services[2].activeState, 'inactive');
  });

  test('getListeningPorts parses ss outputs', () async {
    nextStdout = '''
Netid State Recv-Q Send-Q Local Address:Port Peer Address:Port Process
tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1024,fd=3))
udp UNCONN 0 0 127.0.0.53:53 0.0.0.0:* users:(("systemd-resolve",pid=42,fd=12))
''';
    nextExitCode = 0;

    final ports = await service.getListeningPorts('conn1');
    expect(ports, hasLength(2));

    expect(ports[0].protocol, 'tcp');
    expect(ports[0].localPort, 22);
    expect(ports[0].processName, 'sshd');
    expect(ports[0].pid, 1024);

    expect(ports[1].protocol, 'udp');
    expect(ports[1].localPort, 53);
    expect(ports[1].processName, 'systemd-resolve');
    expect(ports[1].pid, 42);
  });

  test('getUserProcessesAndMemory parses ps command outputs', () async {
    nextStdout = '''
  100   2048  0.1  0.2 /usr/sbin/sshd -D
  101   4096  1.5  0.4 postgres: writer process
''';
    nextExitCode = 0;

    final procs = await service.getUserProcessesAndMemory('conn1', 'admin');
    expect(procs, hasLength(2));

    expect(procs[0].pid, 101); // Sorted by RSS descending: 4096 > 2048
    expect(procs[0].rssBytes, 4096 * 1024);
    expect(procs[0].cpuPercent, 1.5);
    expect(procs[0].command, 'postgres: writer process');

    expect(procs[1].pid, 100);
    expect(procs[1].rssBytes, 2048 * 1024);
    expect(procs[1].cpuPercent, 0.1);
  });

  test('createUser executes useradd and chpasswd successfully', () async {
    nextExitCode = 0;
    nextStdout = '';

    await service.createUser(
      'conn1',
      username: 'testuser',
      password: 'password123',
    );
    expect(lastCommand, contains('chpasswd'));
  });

  test('checkUserSudo returns true if output contains sudo or wheel', () async {
    nextExitCode = 0;
    nextStdout = 'testuser : testuser sudo\n';

    final isSudo = await service.checkUserSudo('conn1', 'testuser');
    expect(isSudo, isTrue);
    expect(lastCommand, contains('groups'));
  });

  test('setUserSudo grants sudo group membership correctly', () async {
    nextExitCode = 0;
    nextStdout = '';

    await service.setUserSudo('conn1', 'testuser', true);
    expect(lastCommand, contains('usermod -aG'));
  });

  test('connect failure sets errorMessage and notifies listeners', () async {
    bool notified = false;
    service.addListener(() {
      notified = true;
    });

    // conn_invalid does not exist in storage service, so config is null, connection fails
    await service.connect('conn_invalid');
    expect(service.connectionId, isNull);
    expect(service.isConnected, isFalse);
    expect(service.isConnecting, isFalse);
    expect(service.errorMessage, contains('Connection config not found'));
    expect(notified, isTrue);
  });

  test('disconnect clears preserved errorMessage', () async {
    await service.connect('conn_invalid');
    expect(service.errorMessage, isNotNull);

    service.disconnect();
    expect(service.errorMessage, isNull);
  });
}
