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

  Future<void> savePlaybook(PlaybooksCompanion playbook) async {
    await into(playbooks).insertOnConflictUpdate(playbook);
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
