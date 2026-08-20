import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:feature_playbook/feature_playbook.dart';
import 'package:connection_core/connection_core.dart';
import 'package:ssh_mobile/core/services/ssh_host_key_policy.dart';
import 'package:ssh_mobile/services/connection_target_binding.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import 'package:ssh_mobile/services/remote_target_scope.dart';
import 'test_utils/test_storage_adapter.dart';
import 'package:ssh_mobile/services/ssh_service.dart';

class FakeSshService extends SshService {
  final TestStorageAdapter storage;

  FakeSshService(this.storage)
    : super(
        connectionRepository: storage.connectionRepository,
        credentialRepository: storage.credentialRepository,
        hostKeyRepository: storage.hostKeyRepository,
        terminalMetadataStore: storage.terminalMetadataStore,
      );

  String lastExecutedCommand = '';
  int callCount = 0;

  @override
  Future<RemoteCommandResult> runOneShotCommand({
    required String connectionId,
    required String command,
    Duration timeout = const Duration(seconds: 15),
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    lastExecutedCommand = command;
    callCount++;

    if (command == 'invalid_command') {
      return RemoteCommandResult(
        stdout: '',
        stderr: 'command not found',
        exitCode: 127,
      );
    }
    if (command == 'regex_mismatch') {
      return RemoteCommandResult(
        stdout: 'not what we want',
        stderr: '',
        exitCode: 0,
      );
    }
    return RemoteCommandResult(
      stdout: 'success_output',
      stderr: '',
      exitCode: 0,
    );
  }
}

class _DelayedPlaybookStorage extends TestStorageAdapter {
  final Completer<void> releaseLoad = Completer<void>();

  @override
  Future<List<Playbook>> loadPlaybooks() async {
    await releaseLoad.future;
    return const [];
  }
}

class _GatedBoundSshService extends FakeSshService {
  final Completer<void> firstCommandStarted = Completer<void>();
  final Completer<void> releaseFirstCommand = Completer<void>();
  final List<String> executedCommands = [];

  _GatedBoundSshService(TestStorageAdapter storage) : super(storage);

  @override
  Future<RemoteCommandResult> runOneShotCommandForBinding({
    required ConnectionTargetBinding binding,
    required String command,
    Duration timeout = const Duration(seconds: 15),
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    final target = await storage.resolveConnectionTarget(binding);
    if (target == null) {
      throw RemoteTargetScopeException.targetChanged(binding.id);
    }
    if (!firstCommandStarted.isCompleted) {
      firstCommandStarted.complete();
      await releaseFirstCommand.future;
    }
    executedCommands.add(command);
    return super.runOneShotCommand(
      connectionId: binding.id,
      command: command,
      timeout: timeout,
      onUnknownHostKey: onUnknownHostKey,
    );
  }
}

class _ConcurrentStartSshService extends FakeSshService {
  final Completer<void> oldFirstStarted = Completer<void>();
  final Completer<void> releaseOldFirst = Completer<void>();
  final Completer<void> oldFirstReturned = Completer<void>();
  final Completer<void> newFirstStarted = Completer<void>();
  final Completer<void> releaseNewFirst = Completer<void>();
  final Completer<void> newSecondStarted = Completer<void>();
  final List<String> executedCommands = [];
  int activeCommandCount = 0;
  int maxConcurrentCommandCount = 0;

  _ConcurrentStartSshService(TestStorageAdapter storage) : super(storage);

  @override
  Future<RemoteCommandResult> runOneShotCommand({
    required String connectionId,
    required String command,
    Duration timeout = const Duration(seconds: 15),
    SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    lastExecutedCommand = command;
    callCount++;
    executedCommands.add(command);
    activeCommandCount++;
    maxConcurrentCommandCount = maxConcurrentCommandCount < activeCommandCount
        ? activeCommandCount
        : maxConcurrentCommandCount;

    try {
      if (command == 'old-first' && !oldFirstStarted.isCompleted) {
        oldFirstStarted.complete();
        await releaseOldFirst.future;
        oldFirstReturned.complete();
      } else if (command == 'new-first' && !newFirstStarted.isCompleted) {
        newFirstStarted.complete();
        await releaseNewFirst.future;
      } else if (command == 'new-second' && !newSecondStarted.isCompleted) {
        newSecondStarted.complete();
      }

      return RemoteCommandResult(
        stdout: 'output:$command',
        stderr: '',
        exitCode: 0,
      );
    } finally {
      activeCommandCount--;
    }
  }
}

String _actionFingerprint(Playbook playbook) {
  return jsonEncode({
    'id': playbook.id,
    'name': playbook.name,
    'description': playbook.description,
    'steps': playbook.steps
        .map(
          (step) => {
            'id': step.id,
            'name': step.name,
            'command': step.command,
            'description': step.description,
            'expectedOutcomeRegex': step.expectedOutcomeRegex,
          },
        )
        .toList(growable: false),
  });
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

  test(
    'PlaybookService ignores an initial load completed after disposal',
    () async {
      final storage = _DelayedPlaybookStorage();
      final ssh = FakeSshService(storage);
      final service = createTestPlaybook(
        repository: storage.playbookRepository,
        sshService: ssh,
      );

      service.dispose();
      storage.releaseLoad.complete();
      await Future<void>.delayed(Duration.zero);

      ssh.dispose();
      storage.dispose();
    },
  );

  group('Playbook Service and Execution Tests', () {
    late TestStorageAdapter storage;
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
      storage = TestStorageAdapter();
      await storage.init();
      ssh = FakeSshService(storage);
      service = createTestPlaybook(
        repository: storage.playbookRepository,
        sshService: ssh,
      );
    });

    tearDown(() async {
      await storage.shutdown();
      storage.dispose();
      debugDefaultTargetPlatformOverride = null;
    });

    test('create, update, select, and delete playbooks', () async {
      final now = DateTime.now();
      final playbook = Playbook(
        id: 'p_test',
        name: 'Test Playbook',
        description: 'Testing',
        steps: [
          PlaybookStep(
            id: 's_test',
            name: 'Step 1',
            command: 'echo 1',
            description: 's1',
          ),
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
      final updated = playbook.copyWith(
        name: 'Updated Name',
        updatedAt: DateTime.now(),
      );
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
          PlaybookStep(
            id: 's1',
            name: 'S1',
            command: 'echo 1',
            description: 's1',
          ),
          PlaybookStep(
            id: 's2',
            name: 'S2',
            command: 'echo 2',
            description: 's2',
          ),
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

    test(
      'a superseded execution cannot adopt or overwrite the new run',
      () async {
        final concurrentSsh = _ConcurrentStartSshService(storage);
        final concurrentService = createTestPlaybook(
          repository: storage.playbookRepository,
          sshService: concurrentSsh,
        );
        final now = DateTime.now();
        final oldPlaybook = Playbook(
          id: 'p-old-run',
          name: 'Old run',
          description: 'Superseded run',
          steps: [
            PlaybookStep(
              id: 'old-1',
              name: 'Old first',
              command: 'old-first',
              description: 'old first',
            ),
            PlaybookStep(
              id: 'old-2',
              name: 'Old second',
              command: 'old-second',
              description: 'old second',
            ),
          ],
          createdAt: now,
          updatedAt: now,
        );
        final newPlaybook = Playbook(
          id: 'p-new-run',
          name: 'New run',
          description: 'Current run',
          steps: [
            PlaybookStep(
              id: 'new-1',
              name: 'New first',
              command: 'new-first',
              description: 'new first',
            ),
            PlaybookStep(
              id: 'new-2',
              name: 'New second',
              command: 'new-second',
              description: 'new second',
            ),
          ],
          createdAt: now,
          updatedAt: now,
        );
        await concurrentService.createPlaybook(oldPlaybook);
        await concurrentService.createPlaybook(newPlaybook);

        await concurrentService.startExecution(oldPlaybook.id, 'conn-old');
        await concurrentSsh.oldFirstStarted.future;
        await concurrentService.startExecution(newPlaybook.id, 'conn-new');
        await Future<void>.delayed(Duration.zero);

        expect(concurrentSsh.newFirstStarted.isCompleted, isFalse);
        expect(concurrentSsh.executedCommands, ['old-first']);

        concurrentSsh.releaseOldFirst.complete();
        await concurrentSsh.oldFirstReturned.future;
        await concurrentSsh.newFirstStarted.future.timeout(
          const Duration(seconds: 2),
        );

        expect(concurrentSsh.executedCommands, [
          'old-first',
          'new-first',
        ], reason: 'The old loop must not execute a command from the new run.');
        expect(concurrentService.activePlaybook?.id, newPlaybook.id);
        expect(concurrentService.currentStepIndex, 0);
        expect(concurrentService.isRunning, isTrue);
        expect(
          concurrentService.activePlaybook!.steps.map((step) => step.command),
          ['new-first', 'new-second'],
        );
        final persistedWhileBlocked = (await storage.loadPlaybooks())
            .singleWhere((playbook) => playbook.id == newPlaybook.id);
        expect(persistedWhileBlocked.steps.first.status, StepStatus.running);
        expect(persistedWhileBlocked.steps.first.stdout, isNull);
        expect(persistedWhileBlocked.steps.last.status, StepStatus.pending);

        concurrentSsh.releaseNewFirst.complete();
        await concurrentSsh.newSecondStarted.future.timeout(
          const Duration(seconds: 2),
        );
        for (
          var attempt = 0;
          attempt < 100 && concurrentService.isRunning;
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        expect(concurrentSsh.executedCommands, [
          'old-first',
          'new-first',
          'new-second',
        ]);
        expect(concurrentService.activePlaybook?.id, newPlaybook.id);
        expect(concurrentService.isRunning, isFalse);
        expect(concurrentService.isPaused, isFalse);
        expect(concurrentSsh.maxConcurrentCommandCount, 1);
        expect(
          concurrentService.activePlaybook!.steps.map((step) => step.status),
          [StepStatus.success, StepStatus.success],
        );
        expect(
          concurrentService.activePlaybook!.steps.map((step) => step.stdout),
          ['output:new-first', 'output:new-second'],
        );
      },
    );

    test(
      'skip is ignored while the current remote command is in flight',
      () async {
        final gatedSsh = _ConcurrentStartSshService(storage);
        final gatedService = createTestPlaybook(
          repository: storage.playbookRepository,
          sshService: gatedSsh,
        );
        final now = DateTime.now();
        final playbook = Playbook(
          id: 'p-running-skip',
          name: 'Running skip',
          description: 'Skip must wait for a paused state',
          steps: [
            PlaybookStep(
              id: 'running-1',
              name: 'Running first',
              command: 'old-first',
              description: 'blocked first command',
            ),
            PlaybookStep(
              id: 'running-2',
              name: 'Running second',
              command: 'old-second',
              description: 'must not overlap the first command',
            ),
          ],
          createdAt: now,
          updatedAt: now,
        );
        await gatedService.createPlaybook(playbook);

        await gatedService.startExecution(playbook.id, 'conn-running-skip');
        await gatedSsh.oldFirstStarted.future;
        await gatedService.skipCurrentStep('conn-running-skip');
        await Future<void>.delayed(Duration.zero);

        expect(gatedSsh.executedCommands, ['old-first']);
        expect(gatedService.currentStepIndex, 0);
        expect(gatedService.isRunning, isTrue);
        expect(gatedService.isPaused, isFalse);
        expect(
          gatedService.activePlaybook!.steps.first.status,
          StepStatus.running,
        );

        gatedSsh.releaseOldFirst.complete();
        await gatedSsh.oldFirstReturned.future;
        for (
          var attempt = 0;
          attempt < 100 && gatedService.isRunning;
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        expect(gatedSsh.executedCommands, ['old-first', 'old-second']);
        expect(gatedService.isRunning, isFalse);
        expect(gatedService.isPaused, isFalse);
        expect(gatedService.activePlaybook!.steps.map((step) => step.status), [
          StepStatus.success,
          StepStatus.success,
        ]);
      },
    );

    test('pause then skip waits for the in-flight command to settle', () async {
      final gatedSsh = _ConcurrentStartSshService(storage);
      final gatedService = createTestPlaybook(
        repository: storage.playbookRepository,
        sshService: gatedSsh,
      );
      final now = DateTime.now();
      final playbook = Playbook(
        id: 'p-pause-skip',
        name: 'Pause then skip',
        description: 'Paused controls must not overlap remote commands',
        steps: [
          PlaybookStep(
            id: 'pause-skip-1',
            name: 'Blocked first',
            command: 'old-first',
            description: 'blocked first command',
          ),
          PlaybookStep(
            id: 'pause-skip-2',
            name: 'Second',
            command: 'old-second',
            description: 'must start after the first command settles',
          ),
        ],
        createdAt: now,
        updatedAt: now,
      );
      await gatedService.createPlaybook(playbook);

      await gatedService.startExecution(playbook.id, 'conn-pause-skip');
      await gatedSsh.oldFirstStarted.future;
      gatedService.pauseExecution();

      var skipCompleted = false;
      final skip = gatedService
          .skipCurrentStep('conn-pause-skip')
          .whenComplete(() => skipCompleted = true);
      await Future<void>.delayed(Duration.zero);

      expect(skipCompleted, isFalse);
      expect(gatedSsh.executedCommands, ['old-first']);
      expect(gatedSsh.activeCommandCount, 1);

      gatedSsh.releaseOldFirst.complete();
      await gatedSsh.oldFirstReturned.future;
      await skip.timeout(const Duration(seconds: 2));
      for (
        var attempt = 0;
        attempt < 100 && gatedService.isRunning;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(gatedSsh.executedCommands, ['old-first', 'old-second']);
      expect(gatedSsh.maxConcurrentCommandCount, 1);
      expect(gatedService.isRunning, isFalse);
      expect(gatedService.isPaused, isFalse);
      expect(gatedService.activePlaybook!.steps.map((step) => step.status), [
        StepStatus.skipped,
        StepStatus.success,
      ]);
    });

    test(
      'pause then resume waits before retrying the in-flight command',
      () async {
        final gatedSsh = _ConcurrentStartSshService(storage);
        final gatedService = createTestPlaybook(
          repository: storage.playbookRepository,
          sshService: gatedSsh,
        );
        final now = DateTime.now();
        final playbook = Playbook(
          id: 'p-pause-resume',
          name: 'Pause then resume',
          description: 'Resume must wait for the old command future',
          steps: [
            PlaybookStep(
              id: 'pause-resume-1',
              name: 'Blocked command',
              command: 'old-first',
              description: 'retried only after the first attempt settles',
            ),
          ],
          createdAt: now,
          updatedAt: now,
        );
        await gatedService.createPlaybook(playbook);

        await gatedService.startExecution(playbook.id, 'conn-pause-resume');
        await gatedSsh.oldFirstStarted.future;
        gatedService.pauseExecution();

        var resumeCompleted = false;
        final resume = gatedService
            .resumeExecution('conn-pause-resume')
            .whenComplete(() => resumeCompleted = true);
        await Future<void>.delayed(Duration.zero);

        expect(resumeCompleted, isFalse);
        expect(gatedSsh.executedCommands, ['old-first']);
        expect(gatedSsh.activeCommandCount, 1);

        gatedSsh.releaseOldFirst.complete();
        await gatedSsh.oldFirstReturned.future;
        await resume.timeout(const Duration(seconds: 2));
        for (
          var attempt = 0;
          attempt < 100 && gatedService.isRunning;
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        expect(gatedSsh.executedCommands, ['old-first', 'old-first']);
        expect(gatedSsh.maxConcurrentCommandCount, 1);
        expect(gatedService.isRunning, isFalse);
        expect(gatedService.isPaused, isFalse);
        expect(
          gatedService.activePlaybook!.steps.single.status,
          StepStatus.success,
        );
      },
    );

    test(
      'approved execution stops before a later step if target changes',
      () async {
        final connection = ConnectionConfig(
          id: 'conn-approved',
          name: 'Approved target',
          host: 'old.example.com',
          username: 'ops',
        );
        await storage.addConnection(connection);
        final gatedSsh = _GatedBoundSshService(storage);
        final approvedService = createTestPlaybook(
          repository: storage.playbookRepository,
          sshService: gatedSsh,
        );
        final playbook = Playbook(
          id: 'p-approved-target',
          name: 'Approved target run',
          description: 'Two steps',
          steps: [
            PlaybookStep(
              id: 's1',
              name: 'First',
              command: 'echo first',
              description: 'first',
            ),
            PlaybookStep(
              id: 's2',
              name: 'Second',
              command: 'echo second',
              description: 'second',
            ),
          ],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        await storage.savePlaybook(playbook);
        final binding = ssh_core.SshTargetBinding.fromConfig(connection);

        expect(
          await approvedService.startApprovedExecution(
            playbook: playbook,
            actionFingerprint: _actionFingerprint(playbook),
            connectionTarget: binding,
          ),
          isTrue,
        );
        await gatedSsh.firstCommandStarted.future;
        await storage.updateConnection(
          connection.copyWith(host: 'replacement.example.com', port: 2222),
        );
        gatedSsh.releaseFirstCommand.complete();
        await Future<void>.delayed(const Duration(milliseconds: 150));

        expect(gatedSsh.executedCommands, ['echo first']);
        expect(approvedService.isRunning, isFalse);
        expect(approvedService.isPaused, isTrue);
      },
    );

    test(
      'approved execution never adopts a concurrently edited command',
      () async {
        final connection = ConnectionConfig(
          id: 'conn-playbook-edit',
          name: 'Approved target',
          host: 'old.example.com',
          username: 'ops',
        );
        await storage.addConnection(connection);
        final gatedSsh = _GatedBoundSshService(storage);
        final approvedService = createTestPlaybook(
          repository: storage.playbookRepository,
          sshService: gatedSsh,
        );
        final playbook = Playbook(
          id: 'p-approved-content',
          name: 'Approved content run',
          description: 'Two steps',
          steps: [
            PlaybookStep(
              id: 's1',
              name: 'First',
              command: 'echo first',
              description: 'first',
            ),
            PlaybookStep(
              id: 's2',
              name: 'Second',
              command: 'echo approved-second',
              description: 'second',
            ),
          ],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        await storage.savePlaybook(playbook);

        expect(
          await approvedService.startApprovedExecution(
            playbook: playbook,
            actionFingerprint: _actionFingerprint(playbook),
            connectionTarget: ssh_core.SshTargetBinding.fromConfig(connection),
          ),
          isTrue,
        );
        await gatedSsh.firstCommandStarted.future;
        final edited = playbook.copyWith(
          steps: [
            playbook.steps.first,
            playbook.steps.last.copyWith(command: 'dangerous-new-command'),
          ],
          updatedAt: DateTime.now(),
        );
        await storage.savePlaybook(edited);
        gatedSsh.releaseFirstCommand.complete();
        await Future<void>.delayed(const Duration(milliseconds: 150));

        expect(gatedSsh.executedCommands, ['echo first']);
        expect(
          gatedSsh.executedCommands,
          isNot(contains('dangerous-new-command')),
        );
        expect(approvedService.isRunning, isFalse);
        expect(approvedService.isPaused, isTrue);
        final persisted = (await storage.loadPlaybooks()).singleWhere(
          (item) => item.id == playbook.id,
        );
        expect(persisted.steps.last.command, 'dangerous-new-command');
      },
    );

    test('sequential execution failed path and pause/resume', () async {
      final playbook = Playbook(
        id: 'p_run',
        name: 'Run Playbook',
        description: 'Run',
        steps: [
          PlaybookStep(
            id: 's1',
            name: 'S1',
            command: 'echo 1',
            description: 's1',
          ),
          PlaybookStep(
            id: 's2',
            name: 'S2',
            command: 'invalid_command',
            description: 's2',
          ),
          PlaybookStep(
            id: 's3',
            name: 'S3',
            command: 'echo 3',
            description: 's3',
          ),
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
          PlaybookStep(
            id: 's1',
            name: 'S1',
            command: 'invalid_command',
            description: 's1',
          ),
          PlaybookStep(
            id: 's2',
            name: 'S2',
            command: 'echo 2',
            description: 's2',
          ),
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
          PlaybookStep(
            id: 's1',
            name: 'S1',
            command: 'echo 1',
            description: 's1',
          ),
          PlaybookStep(
            id: 's2',
            name: 'S2',
            command: 'echo 2',
            description: 's2',
          ),
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
