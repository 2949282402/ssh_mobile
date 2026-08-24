part of '../playbook_database.dart';

/// Playbook 数据库访问对象；事务边界由这里统一维护。
@DriftAccessor(tables: [Playbooks, PlaybookRuns, PlaybookRunSteps])
class PlaybookDao extends DatabaseAccessor<PlaybookDatabase>
    with _$PlaybookDaoMixin {
  PlaybookDao(super.db);

  Future<List<Playbook>> loadPlaybooks() {
    return (select(playbooks)..orderBy([
          (row) =>
              OrderingTerm(expression: row.updatedAt, mode: OrderingMode.desc),
        ]))
        .get();
  }

  /// Atomically creates a playbook at revision 1 or advances the persisted
  /// revision. Compatibility metadata columns intentionally stay empty.
  Future<void> savePlaybook(PlaybooksCompanion playbook) async {
    await customUpdate(
      'INSERT INTO playbooks '
      '(id, name, description, content_json, revision, created_at, updated_at) '
      "VALUES (?, '', '', ?, 1, ?, ?) "
      'ON CONFLICT(id) DO UPDATE SET '
      "name = '', description = '', "
      'content_json = excluded.content_json, '
      'revision = playbooks.revision + 1, '
      'updated_at = excluded.updated_at',
      variables: [
        Variable<String>(playbook.id.value),
        Variable<String>(playbook.contentJson.value),
        Variable<int>(playbook.createdAt.value),
        Variable<int>(playbook.updatedAt.value),
      ],
      updates: {playbooks},
    );
  }

  /// Updates exactly one expected revision and returns the new revision.
  Future<int?> savePlaybookIfRevisionMatches({
    required PlaybooksCompanion playbook,
    required int expectedRevision,
  }) async {
    final changed =
        await (update(playbooks)..where(
              (row) =>
                  row.id.equals(playbook.id.value) &
                  row.revision.equals(expectedRevision),
            ))
            .write(
              PlaybooksCompanion(
                name: const Value(''),
                description: const Value(''),
                contentJson: playbook.contentJson,
                revision: Value(expectedRevision + 1),
                updatedAt: playbook.updatedAt,
              ),
            );
    return changed == 1 ? expectedRevision + 1 : null;
  }

  Future<void> deletePlaybook(String id) async {
    await (delete(playbooks)..where((row) => row.id.equals(id))).go();
  }

  /// 保存执行摘要及步骤，避免产生半套历史记录。
  Future<void> saveRunSnapshot({
    required PlaybookRunsCompanion run,
    required List<PlaybookRunStepsCompanion> steps,
  }) async {
    await transaction(() async {
      await into(playbookRuns).insertOnConflictUpdate(run);
      await (delete(
        playbookRunSteps,
      )..where((row) => row.runId.equals(run.id.value))).go();
      if (steps.isNotEmpty) {
        await batch((batch) => batch.insertAll(playbookRunSteps, steps));
      }
    });
  }
}
