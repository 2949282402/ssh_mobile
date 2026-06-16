import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ssh_mobile/features/system_admin/viewmodels/system_admin_viewmodel.dart';
import 'package:ssh_mobile/services/system_admin_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storageService;
  late SystemAdminService adminService;
  String? lastCommand;
  int nextExitCode = 0;
  String nextStdout = '';
  String nextStderr = '';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storageService = StorageService();
    await storageService.init();

    adminService = SystemAdminService(storageService);

    // Stub SSH connections and privilege checks
    adminService.connectOverride = (id) async {
      // Just manually update service state to pretend we are connected as root
      // By using reflect or custom setter, but we can also just use service fields
      // In this case, we just stub connect to succeed.
    };

    lastCommand = null;
    nextExitCode = 0;
    nextStdout = '';
    nextStderr = '';

    adminService.runCommandOverride = (cmd) async {
      lastCommand = cmd;
      return RemoteCommandResult(
        exitCode: nextExitCode,
        stdout: nextStdout,
        stderr: nextStderr,
      );
    };
  });

  tearDown(() {
    storageService.dispose();
  });

  group('SystemAdminViewModel Tests', () {
    test('Initialization status checks', () {
      final viewModel = SystemAdminViewModel(
        adminService: adminService,
        storageService: storageService,
      );

      expect(viewModel.connectionId, isNull);
      expect(viewModel.isConnected, isFalse);
      expect(viewModel.isConnecting, isFalse);
      expect(viewModel.accounts, isEmpty);
      expect(viewModel.sessions, isEmpty);
      expect(viewModel.services, isEmpty);
      expect(viewModel.ports, isEmpty);
    });

    test('fetchAccounts loads and parses user accounts correctly', () async {
      final viewModel = SystemAdminViewModel(
        adminService: adminService,
        storageService: storageService,
      );

      nextStdout = '''
root:x:0:0:root:/root:/bin/bash
admin:x:1000:1000:Admin User:/home/admin:/bin/bash
===STATUS===
root P
admin L
''';
      nextExitCode = 0;

      await viewModel.fetchAccounts('conn_123');

      expect(viewModel.accounts, hasLength(2));
      expect(viewModel.accounts[0].username, equals('root'));
      expect(viewModel.accounts[0].uid, equals(0));
      expect(viewModel.accounts[1].username, equals('admin'));
      expect(viewModel.accounts[1].isLocked, isTrue);
      expect(lastCommand, contains('cat /etc/passwd'));
    });

    test('fetchSessions loads and parses sessions correctly', () async {
      final viewModel = SystemAdminViewModel(
        adminService: adminService,
        storageService: storageService,
      );

      nextStdout = '''
root     pts/0        2026-06-03 08:30 (192.168.1.10)
''';
      nextExitCode = 0;

      await viewModel.fetchSessions('conn_123');

      expect(viewModel.sessions, hasLength(1));
      expect(viewModel.sessions[0].username, equals('root'));
      expect(viewModel.sessions[0].tty, equals('pts/0'));
      expect(viewModel.sessions[0].ipAddress, equals('192.168.1.10'));
      expect(lastCommand, equals('who'));
    });

    test('fetchServices parses systemctl services correctly', () async {
      final viewModel = SystemAdminViewModel(
        adminService: adminService,
        storageService: storageService,
      );

      nextStdout = '''
ssh.service loaded active running OpenBSD Secure Shell server
''';
      nextExitCode = 0;

      await viewModel.fetchServices('conn_123');

      expect(viewModel.services, hasLength(1));
      expect(viewModel.services[0].name, equals('ssh.service'));
      expect(viewModel.services[0].activeState, equals('active'));
      expect(viewModel.services[0].isRunning, isTrue);
      expect(lastCommand, contains('systemctl list-units'));
    });

    test('fetchPorts parses ss listening ports correctly', () async {
      final viewModel = SystemAdminViewModel(
        adminService: adminService,
        storageService: storageService,
      );

      nextStdout = '''
tcp   LISTEN  0       128               0.0.0.0:22            0.0.0.0:*      users:(("sshd",pid=1024,fd=3))
''';
      nextExitCode = 0;

      await viewModel.fetchPorts('conn_123');

      expect(viewModel.ports, hasLength(1));
      expect(viewModel.ports[0].protocol, equals('tcp'));
      expect(viewModel.ports[0].localPort, equals(22));
      expect(viewModel.ports[0].processName, equals('sshd'));
      expect(viewModel.ports[0].pid, equals(1024));
    });
  });
}
