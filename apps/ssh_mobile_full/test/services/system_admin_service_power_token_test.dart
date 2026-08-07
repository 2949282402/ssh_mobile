import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/ssh_service.dart'; // for RemoteCommandResult
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/services/system_admin_service.dart';
import 'package:ssh_mobile/widgets/system_power_confirm_flow.dart';

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

  group('SystemAdminService Power Confirmation Token validation tests', () {
    test('rebootServer execution with a valid reboot token', () async {
      final token = SystemPowerConfirmationToken.testing(
        action: SystemPowerAction.reboot,
      );

      await service.rebootServer('conn1', token);
      expect(lastCommand, 'reboot');
    });

    test(
      'rebootServer throws StateError and blocks execution with a shutdown token',
      () async {
        final token = SystemPowerConfirmationToken.testing(
          action: SystemPowerAction.shutdown,
        );

        expect(
          () => service.rebootServer('conn1', token),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'System power confirmation token action mismatch',
            ),
          ),
        );
        expect(lastCommand, isNull);
      },
    );

    test(
      'rebootServer throws StateError and blocks execution with an expired token',
      () async {
        final token = SystemPowerConfirmationToken.testing(
          action: SystemPowerAction.reboot,
          issuedAt: DateTime.now().subtract(const Duration(minutes: 3)),
        );

        expect(
          () => service.rebootServer('conn1', token),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'System power confirmation token expired',
            ),
          ),
        );
        expect(lastCommand, isNull);
      },
    );

    test('shutdownServer execution with a valid shutdown token', () async {
      final token = SystemPowerConfirmationToken.testing(
        action: SystemPowerAction.shutdown,
      );

      await service.shutdownServer('conn1', token);
      expect(lastCommand, 'shutdown -h now');
    });

    test(
      'shutdownServer throws StateError and blocks execution with a reboot token',
      () async {
        final token = SystemPowerConfirmationToken.testing(
          action: SystemPowerAction.reboot,
        );

        expect(
          () => service.shutdownServer('conn1', token),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'System power confirmation token action mismatch',
            ),
          ),
        );
        expect(lastCommand, isNull);
      },
    );

    test(
      'shutdownServer throws StateError and blocks execution with an expired token',
      () async {
        final token = SystemPowerConfirmationToken.testing(
          action: SystemPowerAction.shutdown,
          issuedAt: DateTime.now().subtract(const Duration(minutes: 3)),
        );

        expect(
          () => service.shutdownServer('conn1', token),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'System power confirmation token expired',
            ),
          ),
        );
        expect(lastCommand, isNull);
      },
    );
  });
}
