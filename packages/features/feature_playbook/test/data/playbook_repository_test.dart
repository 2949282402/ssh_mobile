// Playbook Repository 的加密、条件写入和执行历史持久化测试。

import 'dart:convert';

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
            'SELECT name, description, content_json, revision '
            'FROM playbooks WHERE id = \'playbook-1\'',
          )
          .getSingle();
      expect(playbookRow.data['name'], isEmpty);
      expect(playbookRow.data['description'], isEmpty);
      expect(playbookRow.data['content_json'], startsWith('encrypted:'));
      expect(playbookRow.data['revision'], 1);
      final loadedPlaybook = (await repository.loadPlaybooks()).single;
      expect(
        loadedPlaybook.toJson(),
        equals(playbook.copyWith(revision: 1).toJson()),
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

  test(
    'revision CAS rejects an execution write after a concurrent edit',
    () async {
      final database = PlaybookDatabase.forTesting(NativeDatabase.memory());
      final repository = DriftPlaybookRepository(
        database: database,
        dataProtection: FakePlaybookDataProtection(),
      );
      addTearDown(database.dispose);

      final playbook = _samplePlaybook();
      await repository.savePlaybook(playbook);
      final approved = (await repository.loadPlaybooks()).single;
      final concurrentEdit = approved.copyWith(
        description: 'changed after approval',
        updatedAt: approved.updatedAt.add(const Duration(seconds: 1)),
      );
      await repository.savePlaybook(concurrentEdit);

      expect(
        await repository.savePlaybookIfRevisionMatches(
          playbookId: playbook.id,
          expectedRevision: approved.revision,
          playbook: approved.copyWith(lastConnectionId: 'connection-1'),
        ),
        isNull,
      );
      final latest = (await repository.loadPlaybooks()).single;
      expect(latest.description, concurrentEdit.description);
      expect(latest.revision, 2);

      expect(
        await repository.savePlaybookIfRevisionMatches(
          playbookId: playbook.id,
          expectedRevision: latest.revision,
          playbook: latest.copyWith(lastConnectionId: 'connection-1'),
        ),
        3,
      );
    },
  );

  test('v1 migration blanks duplicated plaintext metadata', () async {
    final playbook = _samplePlaybook();
    final protection = FakePlaybookDataProtection();
    final encryptedContent = await protection.encryptString(
      jsonEncode(playbook.toJson()),
    );
    final executor = NativeDatabase.memory(
      setup: (raw) {
        raw.execute('''
          CREATE TABLE playbooks (
            id TEXT NOT NULL PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT NOT NULL DEFAULT '',
            content_json TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        raw.execute(
          'INSERT INTO playbooks '
          '(id, name, description, content_json, created_at, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?)',
          [
            playbook.id,
            'plaintext-name',
            'plaintext-description',
            encryptedContent,
            playbook.createdAt.millisecondsSinceEpoch,
            playbook.updatedAt.millisecondsSinceEpoch,
          ],
        );
        raw.userVersion = 1;
      },
    );
    final database = PlaybookDatabase.forTesting(executor);
    addTearDown(database.dispose);

    final row = await database
        .customSelect('SELECT name, description, revision FROM playbooks')
        .getSingle();

    expect(row.data['name'], isEmpty);
    expect(row.data['description'], isEmpty);
    expect(row.data['revision'], 1);
  });

  test('two writers for one revision cannot both commit', () async {
    final database = PlaybookDatabase.forTesting(NativeDatabase.memory());
    final repository = DriftPlaybookRepository(
      database: database,
      dataProtection: FakePlaybookDataProtection(),
    );
    addTearDown(database.dispose);

    await repository.savePlaybook(_samplePlaybook());
    final approved = (await repository.loadPlaybooks()).single;
    final results = await Future.wait([
      repository.savePlaybookIfRevisionMatches(
        playbookId: approved.id,
        expectedRevision: approved.revision,
        playbook: approved.copyWith(description: 'writer-a'),
      ),
      repository.savePlaybookIfRevisionMatches(
        playbookId: approved.id,
        expectedRevision: approved.revision,
        playbook: approved.copyWith(description: 'writer-b'),
      ),
    ]);

    expect(results.whereType<int>(), [approved.revision + 1]);
    expect(results.where((result) => result == null), hasLength(1));
    expect(
      (await repository.loadPlaybooks()).single.description,
      anyOf('writer-a', 'writer-b'),
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
