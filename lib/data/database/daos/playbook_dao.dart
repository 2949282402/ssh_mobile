part of '../app_database.dart';

@DriftAccessor(tables: [Playbooks, PlaybookRuns, PlaybookRunSteps])
class PlaybookDao extends DatabaseAccessor<AppDatabase>
    with _$PlaybookDaoMixin {
  PlaybookDao(super.db);

  Future<List<Playbook>> loadPlaybooks() {
    return (select(playbooks)
          ..orderBy([
            (row) => OrderingTerm(
                  expression: row.updatedAt,
                  mode: OrderingMode.desc,
                ),
          ]))
        .get();
  }

  Future<void> savePlaybook(PlaybooksCompanion playbook) async {
    await into(playbooks).insertOnConflictUpdate(playbook);
  }

  Future<void> replaceAllPlaybooks(List<PlaybooksCompanion> items) async {
    await transaction(() async {
      await delete(playbooks).go();
      if (items.isNotEmpty) {
        await batch((batch) => batch.insertAll(playbooks, items));
      }
    });
  }

  Future<void> deletePlaybook(String id) async {
    await (delete(playbooks)..where((row) => row.id.equals(id))).go();
  }

  Future<List<Playbook>> loadAllPlaybooksForReencryption() {
    return select(playbooks).get();
  }

  Future<void> updatePlaybookContentJson({
    required String id,
    required String contentJson,
  }) {
    return (update(playbooks)..where((row) => row.id.equals(id))).write(
      PlaybooksCompanion(contentJson: Value(contentJson)),
    );
  }
}
