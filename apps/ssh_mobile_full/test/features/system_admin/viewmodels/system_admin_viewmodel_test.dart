import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ssh_mobile/features/system_admin/viewmodels/system_admin_viewmodel.dart';
import 'package:ssh_mobile/widgets/system_power_confirm_flow.dart';
import 'package:ssh_mobile/services/system_admin_service.dart';
import '../../../test_utils/test_storage_adapter.dart';
import 'package:ssh_mobile/services/ssh_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStorageAdapter storageService;
  late SystemAdminService adminService;
  String? lastCommand;
  int nextExitCode = 0;
  String nextStdout = '';
  String nextStderr = '';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    storageService = TestStorageAdapter();
    await storageService.init();

    adminService = createTestSystemAdminService(storageService);

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

  tearDown(() async {
    adminService.dispose();
    await storageService.shutdown();
    storageService.dispose();
  });

  group('SystemAdminViewModel Tests', () {
    Future<SystemAdminViewModel> rootConnectedViewModel() async {
      final viewModel = SystemAdminViewModel(
        adminService: adminService,
        connectionRepository: storageService.connectionRepository,
      )..debounceDuration = Duration.zero;
      viewModel.selectConnection('conn_123');
      await viewModel.connectIfNeeded('conn_123');
      expect(viewModel.activeManagementConnectionId, equals('conn_123'));
      return viewModel;
    }

    test('Initialization status checks', () {
      final viewModel = SystemAdminViewModel(
        adminService: adminService,
        connectionRepository: storageService.connectionRepository,
      );

      expect(viewModel.connectionId, isNull);
      expect(viewModel.selectedConnectionId, isNull);
      expect(viewModel.isConnected, isFalse);
      expect(viewModel.isConnecting, isFalse);
      expect(viewModel.accounts, isEmpty);
      expect(viewModel.sessions, isEmpty);
      expect(viewModel.services, isEmpty);
      expect(viewModel.ports, isEmpty);
    });

    test(
      'selectConnection updates selectedConnectionId and triggers notifyListeners',
      () {
        final viewModel = SystemAdminViewModel(
          adminService: adminService,
          connectionRepository: storageService.connectionRepository,
        );

        bool notified = false;
        viewModel.addListener(() {
          notified = true;
        });

        viewModel.selectConnection('conn_123');
        expect(viewModel.selectedConnectionId, equals('conn_123'));
        expect(viewModel.connectionId, equals('conn_123'));
        expect(notified, isTrue);
      },
    );

    test(
      'connect only opens management connection without changing selection',
      () async {
        final viewModel = SystemAdminViewModel(
          adminService: adminService,
          connectionRepository: storageService.connectionRepository,
        );

        bool notified = false;
        viewModel.addListener(() {
          notified = true;
        });

        await viewModel.connect('conn_123');
        expect(viewModel.selectedConnectionId, isNull);
        expect(viewModel.managementConnectionId, equals('conn_123'));
        expect(notified, isTrue);
      },
    );

    test('selectConnection does not trigger root management connection', () {
      final viewModel = SystemAdminViewModel(
        adminService: adminService,
        connectionRepository: storageService.connectionRepository,
      );

      viewModel.selectConnection('conn_123');
      expect(viewModel.selectedConnectionId, equals('conn_123'));
      expect(viewModel.managementConnectionId, isNull);
      expect(viewModel.isConnected, isFalse);
    });

    test('failed connectIfNeeded retains selectedConnectionId', () async {
      final viewModel = SystemAdminViewModel(
        adminService: adminService,
        connectionRepository: storageService.connectionRepository,
      );
      viewModel.selectConnection('conn_123');

      // stub connect failure
      adminService.connectOverride = (id) async {
        throw Exception('SSH connect timeout');
      };

      try {
        await viewModel.connectIfNeeded('conn_123');
      } catch (_) {}

      expect(viewModel.selectedConnectionId, equals('conn_123'));
      expect(viewModel.managementConnectionId, isNull);
      expect(viewModel.isConnected, isFalse);
    });

    test(
      'management actions require active selected management connection',
      () async {
        final viewModel = SystemAdminViewModel(
          adminService: adminService,
          connectionRepository: storageService.connectionRepository,
        );

        viewModel.selectConnection('conn_123'); // selection is conn_123
        expect(viewModel.selectedConnectionId, equals('conn_123'));
        expect(viewModel.managementConnectionId, isNull);

        // Try checking user sudo. It reads managementConnectionId which is null, so it returns early false
        final isSudo = await viewModel.checkUserSudo('admin');
        expect(isSudo, isFalse);
        expect(lastCommand, isNull); // Didn't execute SSH command
      },
    );

    test('fetchAccounts loads and parses user accounts correctly', () async {
      final viewModel = await rootConnectedViewModel();

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
      final viewModel = await rootConnectedViewModel();

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
      final viewModel = await rootConnectedViewModel();

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
      final viewModel = await rootConnectedViewModel();

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

    test('refreshAllData awaits every forced management fetch', () async {
      final viewModel = await rootConnectedViewModel();
      viewModel.debounceDuration = const Duration(milliseconds: 300);
      final commands = <String>[];
      adminService.runCommandOverride = (command) async {
        commands.add(command);
        final stdout = switch (command) {
          final value when value.contains('cat /etc/passwd') =>
            '''
root:x:0:0:root:/root:/bin/bash
===STATUS===
root P
''',
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

      nextStdout = '';
      nextExitCode = 0;

      await viewModel.fetchSessions('conn_123');
      expect(viewModel.sessions, isEmpty);
      expect(lastCommand, equals('who'));

      lastCommand = null;
      await viewModel.fetchSessions('conn_123');
      expect(lastCommand, isNull);
    });

    test(
      'clearInvalidSelection disconnects stale selected management session',
      () async {
        final viewModel = await rootConnectedViewModel();

        expect(viewModel.selectedConnectionId, equals('conn_123'));
        expect(viewModel.managementConnectionId, equals('conn_123'));

        viewModel.clearInvalidSelection();

        expect(viewModel.selectedConnectionId, isNull);
        expect(viewModel.managementConnectionId, isNull);
        expect(viewModel.accounts, isEmpty);
        expect(viewModel.sessions, isEmpty);
        expect(viewModel.services, isEmpty);
        expect(viewModel.ports, isEmpty);
      },
    );

    test('rebootServer and shutdownServer require valid/fresh tokens', () async {
      final viewModel = SystemAdminViewModel(
        adminService: adminService,
        connectionRepository: storageService.connectionRepository,
      );

      // Connect the viewmodel/service mock so managementConnectionId is not null
      adminService.connectOverride = (id) async {};
      viewModel.selectConnection('conn_123');
      await viewModel.connectIfNeeded('conn_123');

      // 1. Successful reboot
      final rebootToken = SystemPowerConfirmationToken.testing(
        action: SystemPowerAction.reboot,
      );
      await viewModel.rebootServer(rebootToken);
      expect(lastCommand, equals('reboot'));

      // Reset command tracker
      lastCommand = null;

      // 2. Action mismatch reboot
      final shutdownToken = SystemPowerConfirmationToken.testing(
        action: SystemPowerAction.shutdown,
      );
      expect(() => viewModel.rebootServer(shutdownToken), throwsArgumentError);
      expect(lastCommand, isNull);

      // 3. Expired reboot token
      final expiredRebootToken = SystemPowerConfirmationToken.testing(
        action: SystemPowerAction.reboot,
        issuedAt: DateTime.now().subtract(const Duration(minutes: 3)),
      );
      expect(
        () => viewModel.rebootServer(expiredRebootToken),
        throwsStateError,
      );
      expect(lastCommand, isNull);

      // 4. Successful shutdown
      await viewModel.shutdownServer(shutdownToken);
      expect(lastCommand, equals('shutdown -h now'));

      // Reset command tracker
      lastCommand = null;

      // 5. Action mismatch shutdown
      expect(() => viewModel.shutdownServer(rebootToken), throwsArgumentError);
      expect(lastCommand, isNull);

      // 6. Expired shutdown token
      final expiredShutdownToken = SystemPowerConfirmationToken.testing(
        action: SystemPowerAction.shutdown,
        issuedAt: DateTime.now().subtract(const Duration(minutes: 3)),
      );
      expect(
        () => viewModel.shutdownServer(expiredShutdownToken),
        throwsStateError,
      );
      expect(lastCommand, isNull);
    });
  });
}
