// Playbook Repository 的加密、条件写入和执行历史持久化测试。

import 'package:drift/native.dart';
import 'package:feature_playbook/feature_playbook.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/playbook_test_fakes.dart';

void main() {
  test(
    'playbooks and run snapshots are encrypted at the database boundary',
    () async {
      final database = PlaybookDatabase.forTesting(NativeDatabase.memory());
      final protection = FakePlaybookDataProtection();
      final repository = DriftPlaybookRepository(
        database: database,
        dataProtection: protection,
      );
      addTearDown(database.dispose);

      final playbook = _samplePlaybook();
      await repository.savePlaybook(playbook);

      final playbookRow = await database
          .customSelect(
            'SELECT content_json FROM playbooks WHERE id = \'playbook-1\'',
          )
          .getSingle();
      expect(playbookRow.data['content_json'], startsWith('encrypted:'));
      expect(
        (await repository.loadPlaybooks()).single.toJson(),
        equals(playbook.toJson()),
      );
      expect(protection.encryptCalls, greaterThan(0));
      expect(protection.decryptCalls, greaterThan(0));

      final historyStep = PlaybookStep(
        id: 'step-1',
        name: '检查',
        command: 'cat /secret',
        description: '敏感输出不得明文落盘',
        status: StepStatus.success,
        stdout: 'secret-output',
      );
      await repository.saveRunSnapshot(
        PlaybookRunSnapshot(
          id: 'run-1',
          playbookId: playbook.id,
          connectionId: 'connection-1',
          status: 'success',
          startedAt: DateTime.utc(2026, 8, 8),
          finishedAt: DateTime.utc(2026, 8, 8, 0, 0, 1),
          summary: '执行完成',
          errorMessage: null,
          steps: [
            PlaybookRunStepSnapshot(
              id: 'run-step-1',
              stepIndex: 0,
              step: historyStep,
            ),
          ],
        ),
      );

      final runRow = await database
          .customSelect(
            'SELECT summary FROM playbook_runs WHERE id = \'run-1\'',
          )
          .getSingle();
      final stepRow = await database
          .customSelect(
            'SELECT content_json FROM playbook_run_steps WHERE id = \'run-step-1\'',
          )
          .getSingle();
      expect(runRow.data['summary'], startsWith('encrypted:'));
      expect(stepRow.data['content_json'], startsWith('encrypted:'));
      expect(stepRow.data['content_json'], isNot(contains('secret-output')));
    },
  );

  test('conditional save rejects a stale approval fingerprint', () async {
    final database = PlaybookDatabase.forTesting(NativeDatabase.memory());
    final repository = DriftPlaybookRepository(
      database: database,
      dataProtection: FakePlaybookDataProtection(),
    );
    addTearDown(database.dispose);

    final playbook = _samplePlaybook();
    await repository.savePlaybook(playbook);
    final changed = playbook.copyWith(description: 'changed after approval');

    expect(
      await repository.savePlaybookIfActionUnchanged(
        playbookId: playbook.id,
        expectedActionFingerprint: 'stale-fingerprint',
        playbook: changed,
      ),
      isFalse,
    );
    expect(
      (await repository.loadPlaybooks()).single.description,
      playbook.description,
    );
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
