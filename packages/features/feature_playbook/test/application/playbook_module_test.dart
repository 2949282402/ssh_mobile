// Playbook Module 生命周期、旧数据导入和绑定执行测试。

import 'dart:convert';

import 'package:app_core/app_core.dart';
import 'package:connection_core/connection_core.dart';
import 'package:drift/native.dart';
import 'package:feature_playbook/feature_playbook.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;

import '../fakes/playbook_test_fakes.dart';

void main() {
  test('module owns the playbook database and lifecycle', () async {
    final database = PlaybookDatabase.forTesting(NativeDatabase.memory());
    final module = PlaybookModule(databaseFactory: () => database);

    await module.register(
      ModuleContext.fromMap({
        PlaybookSshPort: FakePlaybookSshPort(),
        PlaybookLoggerPort: FakePlaybookLogger(),
        PlaybookDataProtectionPort: FakePlaybookDataProtection(),
      }),
    );

    final firstInitialization = module.initialize();
    expect(identical(firstInitialization, module.initialize()), isTrue);
    await firstInitialization;
    expect(module.state, ModuleState.initialized);
    expect(module.service.playbooks, isEmpty);
    await module.service.createPlaybook(_samplePlaybook());
    expect(module.service.playbooks.single.id, 'playbook-1');

    await module.activate();
    expect(module.state, ModuleState.active);
    await module.deactivate();
    expect(module.state, ModuleState.inactive);

    final firstDispose = module.dispose();
    expect(identical(firstDispose, module.dispose()), isTrue);
    await firstDispose;
    expect(module.state, ModuleState.disposed);
    expect(() => module.service, throwsStateError);
    expect(() => module.database, throwsStateError);
  });

  test('approved execution keeps the immutable target binding', () async {
    final database = PlaybookDatabase.forTesting(NativeDatabase.memory());
    final repository = DriftPlaybookRepository(
      database: database,
      dataProtection: FakePlaybookDataProtection(),
    );
    final ssh = FakePlaybookSshPort();
    final service = PlaybookService(
      repository: repository,
      sshPort: ssh,
      logger: FakePlaybookLogger(),
    );
    addTearDown(() async {
      service.dispose();
      await database.dispose();
    });

    final playbook = _samplePlaybook();
    await repository.savePlaybook(playbook);
    final target = ssh_core.SshTargetBinding.fromConfig(
      ConnectionConfig(
        id: 'connection-1',
        name: '测试服务器',
        host: 'example.test',
        username: 'gary',
      ),
    );

    final actionFingerprint = jsonEncode({
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

    expect(
      await service.startApprovedExecution(
        playbook: playbook,
        actionFingerprint: actionFingerprint,
        connectionTarget: target,
      ),
      isTrue,
    );
    for (var attempt = 0; attempt < 20 && service.isRunning; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(ssh.bindings.single.id, target.id);
    expect(ssh.commands.single, 'connection-1:uname -a');
    expect(service.isRunning, isFalse);
    expect(service.isPaused, isFalse);
    expect(service.activePlaybook?.steps.single.status, StepStatus.success);
  });
}

Playbook _samplePlaybook() {
  final timestamp = DateTime.utc(2026, 8, 8);
  return Playbook(
    id: 'playbook-1',
    name: '诊断',
    description: '服务器诊断流程',
    steps: [
      PlaybookStep(
        id: 'step-1',
        name: '版本',
        command: 'uname -a',
        description: '读取系统版本',
      ),
    ],
    createdAt: timestamp,
    updatedAt: timestamp,
  );
}
