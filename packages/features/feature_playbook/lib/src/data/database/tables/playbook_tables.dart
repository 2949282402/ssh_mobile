part of '../playbook_database.dart';

/// 可复用剧本表；正文 JSON 加密保存，便于保留完整的步骤快照。
class Playbooks extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get description => text().withDefault(const Constant(''))();
  TextColumn get contentJson => text()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  List<Index> get indexes => [
    Index(
      'idx_playbooks_updated_at',
      'CREATE INDEX idx_playbooks_updated_at '
          'ON playbooks(updated_at DESC)',
    ),
  ];
}

/// 一次剧本执行的状态摘要。
class PlaybookRuns extends Table {
  TextColumn get id => text()();
  TextColumn get playbookId =>
      text().references(Playbooks, #id, onDelete: KeyAction.cascade)();
  TextColumn get connectionId => text().nullable()();
  TextColumn get status => text()();
  IntColumn get startedAt => integer()();
  IntColumn get finishedAt => integer().nullable()();
  TextColumn get summary => text().withDefault(const Constant(''))();
  TextColumn get errorMessage => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  List<Index> get indexes => [
    Index(
      'idx_playbook_runs_playbook_started',
      'CREATE INDEX idx_playbook_runs_playbook_started '
          'ON playbook_runs(playbook_id, started_at DESC)',
    ),
  ];
}

/// 一次执行中每个步骤的加密结果快照。
class PlaybookRunSteps extends Table {
  TextColumn get id => text()();
  TextColumn get runId =>
      text().references(PlaybookRuns, #id, onDelete: KeyAction.cascade)();
  IntColumn get stepIndex => integer()();
  TextColumn get contentJson => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  List<Index> get indexes => [
    Index(
      'idx_playbook_run_steps_run_index',
      'CREATE INDEX idx_playbook_run_steps_run_index '
          'ON playbook_run_steps(run_id, step_index ASC)',
    ),
  ];
}
