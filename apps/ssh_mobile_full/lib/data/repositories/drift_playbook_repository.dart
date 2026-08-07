part of '../../services/storage_service.dart';

extension DriftPlaybookRepositoryOps on StorageService {
  Future<List<Playbook>> _loadDriftPlaybooks() async {
    final database = _database;
    if (!_driftPlaybooksActive || database == null) return const [];
    final rows = await database.playbookDao.loadPlaybooks();
    final playbooks = <Playbook>[];
    for (final row in rows) {
      playbooks.add(await _playbookFromDrift(row));
    }
    return _playbooksCache = List.unmodifiable(playbooks);
  }

  Future<void> _saveDriftPlaybook(Playbook playbook) async {
    final database = _database;
    if (!_driftPlaybooksActive || database == null) return;
    await database.playbookDao.savePlaybook(
      await _playbookToCompanion(playbook),
    );
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
    final companions = <db.PlaybooksCompanion>[];
    for (final playbook in ordered) {
      companions.add(await _playbookToCompanion(playbook));
    }
    await database.playbookDao.replaceAllPlaybooks(companions);
    _playbooksCache = List.unmodifiable(ordered);
  }

  Future<db.PlaybooksCompanion> _playbookToCompanion(Playbook playbook) async {
    return db.PlaybooksCompanion(
      id: drift.Value(playbook.id),
      name: drift.Value(playbook.name),
      description: drift.Value(playbook.description),
      contentJson: drift.Value(
        await _encryptDriftText(jsonEncode(playbook.toJson())),
      ),
      createdAt: drift.Value(_toDbMillis(playbook.createdAt)),
      updatedAt: drift.Value(_toDbMillis(playbook.updatedAt)),
    );
  }

  Future<Playbook> _playbookFromDrift(db.Playbook row) async {
    final contentJson = await _decryptDriftText(row.contentJson);
    return Playbook.fromJson(jsonDecode(contentJson) as Map<String, dynamic>);
  }
}
