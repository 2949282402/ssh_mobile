import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/models/playbook.dart';
import 'package:ssh_mobile/services/playbook_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';

class FakeSshService extends SshService {
  FakeSshService(super.storage);

  String lastExecutedCommand = '';
  int callCount = 0;

  @override
  Future<RemoteCommandResult> runOneShotCommand({
    required String connectionId,
    required String command,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    lastExecutedCommand = command;
    callCount++;

    if (command == 'invalid_command') {
      return RemoteCommandResult(stdout: '', stderr: 'command not found', exitCode: 127);
    }
    if (command == 'regex_mismatch') {
      return RemoteCommandResult(stdout: 'not what we want', stderr: '', exitCode: 0);
    }
    return RemoteCommandResult(stdout: 'success_output', stderr: '', exitCode: 0);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Playbook Model Tests', () {
    test('PlaybookStep round-trips toJson and fromJson', () {
      final step = PlaybookStep(
        id: 's1',
        name: 'step1',
        command: 'echo 1',
        description: 'desc1',
        expectedOutcomeRegex: '1',
        status: StepStatus.running,
        stdout: 'out',
        stderr: 'err',
        exitCode: 0,
      );

      final decoded = PlaybookStep.fromJson(step.toJson());

      expect(decoded.id, 's1');
      expect(decoded.name, 'step1');
      expect(decoded.command, 'echo 1');
      expect(decoded.description, 'desc1');
      expect(decoded.expectedOutcomeRegex, '1');
      expect(decoded.status, StepStatus.running);
      expect(decoded.stdout, 'out');
      expect(decoded.stderr, 'err');
      expect(decoded.exitCode, 0);
    });

    test('Playbook round-trips toJson and fromJson', () {
      final step = PlaybookStep(
        id: 's1',
        name: 'step1',
        command: 'echo 1',
        description: 'desc1',
      );
      final now = DateTime.utc(2026, 1, 1);
      final playbook = Playbook(
        id: 'p1',
        name: 'playbook1',
        description: 'desc p1',
        steps: [step],
        createdAt: now,
        updatedAt: now,
        lastConnectionId: 'conn1',
      );

      final decoded = Playbook.fromJson(playbook.toJson());

      expect(decoded.id, 'p1');
      expect(decoded.name, 'playbook1');
      expect(decoded.description, 'desc p1');
      expect(decoded.steps.single.id, 's1');
      expect(decoded.createdAt, now);
      expect(decoded.updatedAt, now);
      expect(decoded.lastConnectionId, 'conn1');
    });
  });

  group('Playbook Service and Execution Tests', () {
    late StorageService storage;
    late FakeSshService ssh;
    late PlaybookService service;

    setUp(() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (MethodCall methodCall) async {
          if (methodCall.method == 'read') {
            return null;
          }
          if (methodCall.method == 'write') {
            return true;
          }
          if (methodCall.method == 'delete') {
            return true;
          }
          return null;
        },
      );
      SharedPreferences.setMockInitialValues({});
      storage = StorageService();
      await storage.init();
      ssh = FakeSshService(storage);
      service = PlaybookService(storageService: storage, sshService: ssh);
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('create, update, select, and delete playbooks', () async {
      final now = DateTime.now();
      final playbook = Playbook(
        id: 'p_test',
        name: 'Test Playbook',
        description: 'Testing',
        steps: [
          PlaybookStep(id: 's_test', name: 'Step 1', command: 'echo 1', description: 's1')
        ],
        createdAt: now,
        updatedAt: now,
      );

      // Create
      await service.createPlaybook(playbook);
      expect(service.playbooks.length, 1);
      expect(service.playbooks.first.id, 'p_test');

      // Select
      service.selectPlaybook('p_test');
      expect(service.activePlaybook?.id, 'p_test');

      // Update
      final updated = playbook.copyWith(name: 'Updated Name', updatedAt: DateTime.now());
      await service.updatePlaybook(updated);
      expect(service.playbooks.first.name, 'Updated Name');
      expect(service.activePlaybook?.name, 'Updated Name');

      // Reset steps status
      service.resetPlaybook('p_test');
      expect(service.activePlaybook?.steps.first.status, StepStatus.pending);

      // Delete
      await service.deletePlaybook('p_test');
      expect(service.playbooks, isEmpty);
      expect(service.activePlaybook, isNull);
    });

    test('sequential execution success path', () async {
      final playbook = Playbook(
        id: 'p_run',
        name: 'Run Playbook',
        description: 'Run',
        steps: [
          PlaybookStep(id: 's1', name: 'S1', command: 'echo 1', description: 's1'),
          PlaybookStep(id: 's2', name: 'S2', command: 'echo 2', description: 's2'),
        ],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await service.createPlaybook(playbook);
      service.selectPlaybook('p_run');

      // Start execution
      await service.startExecution('p_run', 'conn_1');

      // Wait a moment for execution loop to complete
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final active = service.activePlaybook!;
      expect(service.isRunning, isFalse);
      expect(service.isPaused, isFalse);
      expect(active.steps[0].status, StepStatus.success);
      expect(active.steps[0].stdout, 'success_output');
      expect(active.steps[1].status, StepStatus.success);
      expect(active.steps[1].stdout, 'success_output');
      expect(ssh.callCount, 2);
    });

    test('sequential execution failed path and pause/resume', () async {
      final playbook = Playbook(
        id: 'p_run',
        name: 'Run Playbook',
        description: 'Run',
        steps: [
          PlaybookStep(id: 's1', name: 'S1', command: 'echo 1', description: 's1'),
          PlaybookStep(id: 's2', name: 'S2', command: 'invalid_command', description: 's2'),
          PlaybookStep(id: 's3', name: 'S3', command: 'echo 3', description: 's3'),
        ],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await service.createPlaybook(playbook);

      // Start execution
      await service.startExecution('p_run', 'conn_1');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Should be paused/stopped at step 1 (0-indexed, which is S2)
      expect(service.isRunning, isFalse);
      expect(service.isPaused, isTrue);
      expect(service.currentStepIndex, 1);

      final active = service.activePlaybook!;
      expect(active.steps[0].status, StepStatus.success);
      expect(active.steps[1].status, StepStatus.failed);
      expect(active.steps[1].stderr, 'command not found');
      expect(active.steps[1].exitCode, 127);
      expect(active.steps[2].status, StepStatus.pending);
      expect(ssh.callCount, 2);

      // Resume execution should attempt S2 again
      await service.resumeExecution('conn_1');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // S2 still fails, so it stays failed and paused
      expect(service.isRunning, isFalse);
      expect(service.isPaused, isTrue);
      expect(service.currentStepIndex, 1);
      expect(ssh.callCount, 3);
    });

    test('execution skips step and resumes', () async {
      final playbook = Playbook(
        id: 'p_run',
        name: 'Run Playbook',
        description: 'Run',
        steps: [
          PlaybookStep(id: 's1', name: 'S1', command: 'invalid_command', description: 's1'),
          PlaybookStep(id: 's2', name: 'S2', command: 'echo 2', description: 's2'),
        ],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await service.createPlaybook(playbook);

      // Start execution
      await service.startExecution('p_run', 'conn_1');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Fails at step 0 (S1)
      expect(service.isRunning, isFalse);
      expect(service.isPaused, isTrue);
      expect(service.currentStepIndex, 0);

      // Skip current step (S1)
      await service.skipCurrentStep('conn_1');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Should skip S1, execute S2, and successfully complete the playbook
      expect(service.isRunning, isFalse);
      expect(service.isPaused, isFalse);

      final active = service.activePlaybook!;
      expect(active.steps[0].status, StepStatus.skipped);
      expect(active.steps[1].status, StepStatus.success);
      expect(ssh.callCount, 2); // 1 failed run + 1 success run of S2
    });

    test('execution fails on regex mismatch', () async {
      final playbook = Playbook(
        id: 'p_run',
        name: 'Run Playbook',
        description: 'Run',
        steps: [
          PlaybookStep(
            id: 's1',
            name: 'S1',
            command: 'regex_mismatch',
            description: 's1',
            expectedOutcomeRegex: 'expected_pattern',
          ),
        ],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await service.createPlaybook(playbook);

      // Start execution
      await service.startExecution('p_run', 'conn_1');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(service.isRunning, isFalse);
      expect(service.isPaused, isTrue);
      expect(service.activePlaybook!.steps[0].status, StepStatus.failed);
    });

    test('manual pause execution stops loop', () async {
      final playbook = Playbook(
        id: 'p_run',
        name: 'Run Playbook',
        description: 'Run',
        steps: [
          PlaybookStep(id: 's1', name: 'S1', command: 'echo 1', description: 's1'),
          PlaybookStep(id: 's2', name: 'S2', command: 'echo 2', description: 's2'),
        ],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await service.createPlaybook(playbook);
      service.selectPlaybook('p_run');

      // Start execution
      await service.startExecution('p_run', 'conn_1');

      // Immediately pause execution
      service.pauseExecution();

      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Execution should be paused, likely after step 0 or immediately
      expect(service.isRunning, isFalse);
      expect(service.isPaused, isTrue);
    });
  });
}
