// Playbook Repository；它是 Module 数据库和执行 Service 之间的唯一持久化边界。

import 'dart:convert';

import 'package:drift/drift.dart' as drift;

import '../../domain/playbook_models.dart';
import '../../domain/playbook_ports.dart';
import '../../features/playbook/models/playbook.dart';
import '../database/playbook_database.dart' as db;

/// Playbook 持久化公共契约。
abstract interface class PlaybookRepository {
  Future<List<Playbook>> loadPlaybooks();

  Future<void> savePlaybook(Playbook playbook);

  Future<void> deletePlaybook(String id);

  Future<int?> savePlaybookIfRevisionMatches({
    required String playbookId,
    required int expectedRevision,
    required Playbook playbook,
  });

  Future<void> saveRunSnapshot(PlaybookRunSnapshot snapshot);
}

/// Drift Repository 实现；加密和数据库均由 Module 注入/拥有。
final class DriftPlaybookRepository implements PlaybookRepository {
  DriftPlaybookRepository({
    required db.PlaybookDatabase database,
    required PlaybookDataProtectionPort dataProtection,
  }) : this._fromDependencies(database, dataProtection);

  DriftPlaybookRepository._fromDependencies(
    this._database,
    this._dataProtection,
  );

  final db.PlaybookDatabase _database;
  final PlaybookDataProtectionPort _dataProtection;

  @override
  Future<List<Playbook>> loadPlaybooks() async {
    final rows = await _database.playbookDao.loadPlaybooks();
    final result = <Playbook>[];
    for (final row in rows) {
      result.add(await _fromRow(row));
    }
    return List.unmodifiable(result);
  }

  @override
  Future<void> savePlaybook(Playbook playbook) async {
    await _database.playbookDao.savePlaybook(await _toCompanion(playbook));
  }

  @override
  Future<void> deletePlaybook(String id) {
    return _database.playbookDao.deletePlaybook(id);
  }

  @override
  Future<int?> savePlaybookIfRevisionMatches({
    required String playbookId,
    required int expectedRevision,
    required Playbook playbook,
  }) async {
    if (playbook.id != playbookId) {
      throw ArgumentError.value(
        playbook.id,
        'playbook',
        'Playbook id must match playbookId.',
      );
    }
    return _database.playbookDao.savePlaybookIfRevisionMatches(
      playbook: await _toCompanion(playbook),
      expectedRevision: expectedRevision,
    );
  }

  @override
  Future<void> saveRunSnapshot(PlaybookRunSnapshot snapshot) async {
    final run = db.PlaybookRunsCompanion(
      id: drift.Value(snapshot.id),
      playbookId: drift.Value(snapshot.playbookId),
      connectionId: drift.Value(snapshot.connectionId),
      status: drift.Value(snapshot.status),
      startedAt: drift.Value(_toDbMillis(snapshot.startedAt)),
      finishedAt: drift.Value(
        snapshot.finishedAt == null ? null : _toDbMillis(snapshot.finishedAt!),
      ),
      summary: drift.Value(await _encrypt(snapshot.summary)),
      errorMessage: drift.Value(
        snapshot.errorMessage == null
            ? null
            : await _encrypt(snapshot.errorMessage!),
      ),
    );
    final steps = <db.PlaybookRunStepsCompanion>[];
    for (final item in snapshot.steps) {
      steps.add(
        db.PlaybookRunStepsCompanion(
          id: drift.Value(item.id),
          runId: drift.Value(snapshot.id),
          stepIndex: drift.Value(item.stepIndex),
          contentJson: drift.Value(
            await _encrypt(jsonEncode(item.step.toJson())),
          ),
        ),
      );
    }
    await _database.playbookDao.saveRunSnapshot(run: run, steps: steps);
  }

  Future<Playbook> _fromRow(db.Playbook row) async {
    final content = await _decrypt(row.contentJson);
    return Playbook.fromJson(
      jsonDecode(content) as Map<String, dynamic>,
    ).copyWith(revision: row.revision);
  }

  Future<db.PlaybooksCompanion> _toCompanion(Playbook playbook) async {
    return db.PlaybooksCompanion(
      id: drift.Value(playbook.id),
      name: const drift.Value(''),
      description: const drift.Value(''),
      contentJson: drift.Value(await _encrypt(jsonEncode(playbook.toJson()))),
      revision: drift.Value(playbook.revision),
      createdAt: drift.Value(_toDbMillis(playbook.createdAt)),
      updatedAt: drift.Value(_toDbMillis(playbook.updatedAt)),
    );
  }

  Future<String> _encrypt(String value) async {
    if (value.isEmpty || _dataProtection.isEncrypted(value)) return value;
    return _dataProtection.encryptString(value);
  }

  Future<String> _decrypt(String value) async {
    if (value.isEmpty || !_dataProtection.isEncrypted(value)) return value;
    return _dataProtection.decryptString(value);
  }

  static int _toDbMillis(DateTime value) =>
      value.toUtc().millisecondsSinceEpoch;
}
