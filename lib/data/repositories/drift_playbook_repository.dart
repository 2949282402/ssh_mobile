part of '../../services/storage_service.dart';

extension DriftPlaybookRepositoryOps on StorageService {
  Future<List<Playbook>> _loadDriftPlaybooks() async {
    final database = _database;
    if (!_driftPlaybooksActive || database == null) return const [];
    final rows = await database.playbookDao.loadPlaybooks();
    final playbooks = rows.map(_playbookFromDrift).toList(growable: false);
    return _playbooksCache = List.unmodifiable(playbooks);
  }

  Future<void> _saveDriftPlaybook(Playbook playbook) async {
    final database = _database;
    if (!_driftPlaybooksActive || database == null) return;
    await database.playbookDao.savePlaybook(_playbookToCompanion(playbook));
    final playbooks = upsertPlaybooksByUpdatedAt(
      _playbooksCache ?? const <Playbook>[],
      playbook,
    );
    _playbooksCache = List.unmodifiable(playbooks);
  }

  Future<void> _deleteDriftPlaybook(String id) async {
    final database = _database;
    if (!_driftPlaybooksActive || database == null) return;
    await database.playbookDao.deletePlaybook(id);
    final cached = _playbooksCache;
    if (cached != null) {
      _playbooksCache = List.unmodifiable(
        cached.where((item) => item.id != id).toList(growable: false),
      );
    }
  }

  Future<void> _replaceDriftPlaybooks(List<Playbook> playbooks) async {
    final database = _database;
    if (!_driftReady || database == null) return;
    final ordered = [...playbooks]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await database.playbookDao.replaceAllPlaybooks(
      ordered.map(_playbookToCompanion).toList(growable: false),
    );
    _playbooksCache = List.unmodifiable(ordered);
  }

  db.PlaybooksCompanion _playbookToCompanion(Playbook playbook) {
    return db.PlaybooksCompanion(
      id: drift.Value(playbook.id),
      name: drift.Value(playbook.name),
      description: drift.Value(playbook.description),
      contentJson: drift.Value(jsonEncode(playbook.toJson())),
      createdAt: drift.Value(_toDbMillis(playbook.createdAt)),
      updatedAt: drift.Value(_toDbMillis(playbook.updatedAt)),
    );
  }

  Playbook _playbookFromDrift(db.Playbook row) {
    return Playbook.fromJson(
        jsonDecode(row.contentJson) as Map<String, dynamic>);
  }
}
