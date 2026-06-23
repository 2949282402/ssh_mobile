part of '../app_database.dart';

@DriftAccessor(tables: [MigrationMeta])
class MigrationMetaDao extends DatabaseAccessor<AppDatabase>
    with _$MigrationMetaDaoMixin {
  MigrationMetaDao(super.db);

  Future<bool> isComplete(String key) async {
    final value = await (select(migrationMeta)
          ..where((row) => row.key.equals(key)))
        .getSingleOrNull();
    return value?.value == 'true';
  }

  Future<void> markComplete(String key) async {
    await into(migrationMeta).insertOnConflictUpdate(
      MigrationMetaCompanion.insert(
        key: key,
        value: 'true',
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }
}
