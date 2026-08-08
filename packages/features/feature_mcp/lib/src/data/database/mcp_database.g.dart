// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'mcp_database.dart';

// ignore_for_file: type=lint
class $McpActivityRecordsTable extends McpActivityRecords
    with TableInfo<$McpActivityRecordsTable, McpActivityRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $McpActivityRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _occurredAtMeta = const VerificationMeta(
    'occurredAt',
  );
  @override
  late final GeneratedColumn<int> occurredAt = GeneratedColumn<int>(
    'occurred_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _methodMeta = const VerificationMeta('method');
  @override
  late final GeneratedColumn<String> method = GeneratedColumn<String>(
    'method',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _toolNameMeta = const VerificationMeta(
    'toolName',
  );
  @override
  late final GeneratedColumn<String> toolName = GeneratedColumn<String>(
    'tool_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _outcomeMeta = const VerificationMeta(
    'outcome',
  );
  @override
  late final GeneratedColumn<String> outcome = GeneratedColumn<String>(
    'outcome',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _policyReasonMeta = const VerificationMeta(
    'policyReason',
  );
  @override
  late final GeneratedColumn<String> policyReason = GeneratedColumn<String>(
    'policy_reason',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _durationMsMeta = const VerificationMeta(
    'durationMs',
  );
  @override
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
    'duration_ms',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    occurredAt,
    kind,
    method,
    toolName,
    outcome,
    policyReason,
    durationMs,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'mcp_activity_records';
  @override
  VerificationContext validateIntegrity(
    Insertable<McpActivityRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('occurred_at')) {
      context.handle(
        _occurredAtMeta,
        occurredAt.isAcceptableOrUnknown(data['occurred_at']!, _occurredAtMeta),
      );
    } else if (isInserting) {
      context.missing(_occurredAtMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('method')) {
      context.handle(
        _methodMeta,
        method.isAcceptableOrUnknown(data['method']!, _methodMeta),
      );
    }
    if (data.containsKey('tool_name')) {
      context.handle(
        _toolNameMeta,
        toolName.isAcceptableOrUnknown(data['tool_name']!, _toolNameMeta),
      );
    }
    if (data.containsKey('outcome')) {
      context.handle(
        _outcomeMeta,
        outcome.isAcceptableOrUnknown(data['outcome']!, _outcomeMeta),
      );
    } else if (isInserting) {
      context.missing(_outcomeMeta);
    }
    if (data.containsKey('policy_reason')) {
      context.handle(
        _policyReasonMeta,
        policyReason.isAcceptableOrUnknown(
          data['policy_reason']!,
          _policyReasonMeta,
        ),
      );
    }
    if (data.containsKey('duration_ms')) {
      context.handle(
        _durationMsMeta,
        durationMs.isAcceptableOrUnknown(data['duration_ms']!, _durationMsMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  McpActivityRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return McpActivityRecord(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      occurredAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}occurred_at'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      method: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}method'],
      ),
      toolName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tool_name'],
      ),
      outcome: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}outcome'],
      )!,
      policyReason: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}policy_reason'],
      ),
      durationMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_ms'],
      ),
    );
  }

  @override
  $McpActivityRecordsTable createAlias(String alias) {
    return $McpActivityRecordsTable(attachedDatabase, alias);
  }
}

class McpActivityRecord extends DataClass
    implements Insertable<McpActivityRecord> {
  final int id;
  final int occurredAt;
  final String kind;
  final String? method;
  final String? toolName;
  final String outcome;
  final String? policyReason;
  final int? durationMs;
  const McpActivityRecord({
    required this.id,
    required this.occurredAt,
    required this.kind,
    this.method,
    this.toolName,
    required this.outcome,
    this.policyReason,
    this.durationMs,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['occurred_at'] = Variable<int>(occurredAt);
    map['kind'] = Variable<String>(kind);
    if (!nullToAbsent || method != null) {
      map['method'] = Variable<String>(method);
    }
    if (!nullToAbsent || toolName != null) {
      map['tool_name'] = Variable<String>(toolName);
    }
    map['outcome'] = Variable<String>(outcome);
    if (!nullToAbsent || policyReason != null) {
      map['policy_reason'] = Variable<String>(policyReason);
    }
    if (!nullToAbsent || durationMs != null) {
      map['duration_ms'] = Variable<int>(durationMs);
    }
    return map;
  }

  McpActivityRecordsCompanion toCompanion(bool nullToAbsent) {
    return McpActivityRecordsCompanion(
      id: Value(id),
      occurredAt: Value(occurredAt),
      kind: Value(kind),
      method: method == null && nullToAbsent
          ? const Value.absent()
          : Value(method),
      toolName: toolName == null && nullToAbsent
          ? const Value.absent()
          : Value(toolName),
      outcome: Value(outcome),
      policyReason: policyReason == null && nullToAbsent
          ? const Value.absent()
          : Value(policyReason),
      durationMs: durationMs == null && nullToAbsent
          ? const Value.absent()
          : Value(durationMs),
    );
  }

  factory McpActivityRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return McpActivityRecord(
      id: serializer.fromJson<int>(json['id']),
      occurredAt: serializer.fromJson<int>(json['occurredAt']),
      kind: serializer.fromJson<String>(json['kind']),
      method: serializer.fromJson<String?>(json['method']),
      toolName: serializer.fromJson<String?>(json['toolName']),
      outcome: serializer.fromJson<String>(json['outcome']),
      policyReason: serializer.fromJson<String?>(json['policyReason']),
      durationMs: serializer.fromJson<int?>(json['durationMs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'occurredAt': serializer.toJson<int>(occurredAt),
      'kind': serializer.toJson<String>(kind),
      'method': serializer.toJson<String?>(method),
      'toolName': serializer.toJson<String?>(toolName),
      'outcome': serializer.toJson<String>(outcome),
      'policyReason': serializer.toJson<String?>(policyReason),
      'durationMs': serializer.toJson<int?>(durationMs),
    };
  }

  McpActivityRecord copyWith({
    int? id,
    int? occurredAt,
    String? kind,
    Value<String?> method = const Value.absent(),
    Value<String?> toolName = const Value.absent(),
    String? outcome,
    Value<String?> policyReason = const Value.absent(),
    Value<int?> durationMs = const Value.absent(),
  }) => McpActivityRecord(
    id: id ?? this.id,
    occurredAt: occurredAt ?? this.occurredAt,
    kind: kind ?? this.kind,
    method: method.present ? method.value : this.method,
    toolName: toolName.present ? toolName.value : this.toolName,
    outcome: outcome ?? this.outcome,
    policyReason: policyReason.present ? policyReason.value : this.policyReason,
    durationMs: durationMs.present ? durationMs.value : this.durationMs,
  );
  McpActivityRecord copyWithCompanion(McpActivityRecordsCompanion data) {
    return McpActivityRecord(
      id: data.id.present ? data.id.value : this.id,
      occurredAt: data.occurredAt.present
          ? data.occurredAt.value
          : this.occurredAt,
      kind: data.kind.present ? data.kind.value : this.kind,
      method: data.method.present ? data.method.value : this.method,
      toolName: data.toolName.present ? data.toolName.value : this.toolName,
      outcome: data.outcome.present ? data.outcome.value : this.outcome,
      policyReason: data.policyReason.present
          ? data.policyReason.value
          : this.policyReason,
      durationMs: data.durationMs.present
          ? data.durationMs.value
          : this.durationMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('McpActivityRecord(')
          ..write('id: $id, ')
          ..write('occurredAt: $occurredAt, ')
          ..write('kind: $kind, ')
          ..write('method: $method, ')
          ..write('toolName: $toolName, ')
          ..write('outcome: $outcome, ')
          ..write('policyReason: $policyReason, ')
          ..write('durationMs: $durationMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    occurredAt,
    kind,
    method,
    toolName,
    outcome,
    policyReason,
    durationMs,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is McpActivityRecord &&
          other.id == this.id &&
          other.occurredAt == this.occurredAt &&
          other.kind == this.kind &&
          other.method == this.method &&
          other.toolName == this.toolName &&
          other.outcome == this.outcome &&
          other.policyReason == this.policyReason &&
          other.durationMs == this.durationMs);
}

class McpActivityRecordsCompanion extends UpdateCompanion<McpActivityRecord> {
  final Value<int> id;
  final Value<int> occurredAt;
  final Value<String> kind;
  final Value<String?> method;
  final Value<String?> toolName;
  final Value<String> outcome;
  final Value<String?> policyReason;
  final Value<int?> durationMs;
  const McpActivityRecordsCompanion({
    this.id = const Value.absent(),
    this.occurredAt = const Value.absent(),
    this.kind = const Value.absent(),
    this.method = const Value.absent(),
    this.toolName = const Value.absent(),
    this.outcome = const Value.absent(),
    this.policyReason = const Value.absent(),
    this.durationMs = const Value.absent(),
  });
  McpActivityRecordsCompanion.insert({
    this.id = const Value.absent(),
    required int occurredAt,
    required String kind,
    this.method = const Value.absent(),
    this.toolName = const Value.absent(),
    required String outcome,
    this.policyReason = const Value.absent(),
    this.durationMs = const Value.absent(),
  }) : occurredAt = Value(occurredAt),
       kind = Value(kind),
       outcome = Value(outcome);
  static Insertable<McpActivityRecord> custom({
    Expression<int>? id,
    Expression<int>? occurredAt,
    Expression<String>? kind,
    Expression<String>? method,
    Expression<String>? toolName,
    Expression<String>? outcome,
    Expression<String>? policyReason,
    Expression<int>? durationMs,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (occurredAt != null) 'occurred_at': occurredAt,
      if (kind != null) 'kind': kind,
      if (method != null) 'method': method,
      if (toolName != null) 'tool_name': toolName,
      if (outcome != null) 'outcome': outcome,
      if (policyReason != null) 'policy_reason': policyReason,
      if (durationMs != null) 'duration_ms': durationMs,
    });
  }

  McpActivityRecordsCompanion copyWith({
    Value<int>? id,
    Value<int>? occurredAt,
    Value<String>? kind,
    Value<String?>? method,
    Value<String?>? toolName,
    Value<String>? outcome,
    Value<String?>? policyReason,
    Value<int?>? durationMs,
  }) {
    return McpActivityRecordsCompanion(
      id: id ?? this.id,
      occurredAt: occurredAt ?? this.occurredAt,
      kind: kind ?? this.kind,
      method: method ?? this.method,
      toolName: toolName ?? this.toolName,
      outcome: outcome ?? this.outcome,
      policyReason: policyReason ?? this.policyReason,
      durationMs: durationMs ?? this.durationMs,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (occurredAt.present) {
      map['occurred_at'] = Variable<int>(occurredAt.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (method.present) {
      map['method'] = Variable<String>(method.value);
    }
    if (toolName.present) {
      map['tool_name'] = Variable<String>(toolName.value);
    }
    if (outcome.present) {
      map['outcome'] = Variable<String>(outcome.value);
    }
    if (policyReason.present) {
      map['policy_reason'] = Variable<String>(policyReason.value);
    }
    if (durationMs.present) {
      map['duration_ms'] = Variable<int>(durationMs.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('McpActivityRecordsCompanion(')
          ..write('id: $id, ')
          ..write('occurredAt: $occurredAt, ')
          ..write('kind: $kind, ')
          ..write('method: $method, ')
          ..write('toolName: $toolName, ')
          ..write('outcome: $outcome, ')
          ..write('policyReason: $policyReason, ')
          ..write('durationMs: $durationMs')
          ..write(')'))
        .toString();
  }
}

abstract class _$McpDatabase extends GeneratedDatabase {
  _$McpDatabase(QueryExecutor e) : super(e);
  $McpDatabaseManager get managers => $McpDatabaseManager(this);
  late final $McpActivityRecordsTable mcpActivityRecords =
      $McpActivityRecordsTable(this);
  late final McpActivityDao mcpActivityDao = McpActivityDao(
    this as McpDatabase,
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [mcpActivityRecords];
}

typedef $$McpActivityRecordsTableCreateCompanionBuilder =
    McpActivityRecordsCompanion Function({
      Value<int> id,
      required int occurredAt,
      required String kind,
      Value<String?> method,
      Value<String?> toolName,
      required String outcome,
      Value<String?> policyReason,
      Value<int?> durationMs,
    });
typedef $$McpActivityRecordsTableUpdateCompanionBuilder =
    McpActivityRecordsCompanion Function({
      Value<int> id,
      Value<int> occurredAt,
      Value<String> kind,
      Value<String?> method,
      Value<String?> toolName,
      Value<String> outcome,
      Value<String?> policyReason,
      Value<int?> durationMs,
    });

class $$McpActivityRecordsTableFilterComposer
    extends Composer<_$McpDatabase, $McpActivityRecordsTable> {
  $$McpActivityRecordsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get occurredAt => $composableBuilder(
    column: $table.occurredAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get method => $composableBuilder(
    column: $table.method,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get toolName => $composableBuilder(
    column: $table.toolName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get outcome => $composableBuilder(
    column: $table.outcome,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get policyReason => $composableBuilder(
    column: $table.policyReason,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnFilters(column),
  );
}

class $$McpActivityRecordsTableOrderingComposer
    extends Composer<_$McpDatabase, $McpActivityRecordsTable> {
  $$McpActivityRecordsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get occurredAt => $composableBuilder(
    column: $table.occurredAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get method => $composableBuilder(
    column: $table.method,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get toolName => $composableBuilder(
    column: $table.toolName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get outcome => $composableBuilder(
    column: $table.outcome,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get policyReason => $composableBuilder(
    column: $table.policyReason,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$McpActivityRecordsTableAnnotationComposer
    extends Composer<_$McpDatabase, $McpActivityRecordsTable> {
  $$McpActivityRecordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get occurredAt => $composableBuilder(
    column: $table.occurredAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get method =>
      $composableBuilder(column: $table.method, builder: (column) => column);

  GeneratedColumn<String> get toolName =>
      $composableBuilder(column: $table.toolName, builder: (column) => column);

  GeneratedColumn<String> get outcome =>
      $composableBuilder(column: $table.outcome, builder: (column) => column);

  GeneratedColumn<String> get policyReason => $composableBuilder(
    column: $table.policyReason,
    builder: (column) => column,
  );

  GeneratedColumn<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => column,
  );
}

class $$McpActivityRecordsTableTableManager
    extends
        RootTableManager<
          _$McpDatabase,
          $McpActivityRecordsTable,
          McpActivityRecord,
          $$McpActivityRecordsTableFilterComposer,
          $$McpActivityRecordsTableOrderingComposer,
          $$McpActivityRecordsTableAnnotationComposer,
          $$McpActivityRecordsTableCreateCompanionBuilder,
          $$McpActivityRecordsTableUpdateCompanionBuilder,
          (
            McpActivityRecord,
            BaseReferences<
              _$McpDatabase,
              $McpActivityRecordsTable,
              McpActivityRecord
            >,
          ),
          McpActivityRecord,
          PrefetchHooks Function()
        > {
  $$McpActivityRecordsTableTableManager(
    _$McpDatabase db,
    $McpActivityRecordsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$McpActivityRecordsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$McpActivityRecordsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$McpActivityRecordsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> occurredAt = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String?> method = const Value.absent(),
                Value<String?> toolName = const Value.absent(),
                Value<String> outcome = const Value.absent(),
                Value<String?> policyReason = const Value.absent(),
                Value<int?> durationMs = const Value.absent(),
              }) => McpActivityRecordsCompanion(
                id: id,
                occurredAt: occurredAt,
                kind: kind,
                method: method,
                toolName: toolName,
                outcome: outcome,
                policyReason: policyReason,
                durationMs: durationMs,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int occurredAt,
                required String kind,
                Value<String?> method = const Value.absent(),
                Value<String?> toolName = const Value.absent(),
                required String outcome,
                Value<String?> policyReason = const Value.absent(),
                Value<int?> durationMs = const Value.absent(),
              }) => McpActivityRecordsCompanion.insert(
                id: id,
                occurredAt: occurredAt,
                kind: kind,
                method: method,
                toolName: toolName,
                outcome: outcome,
                policyReason: policyReason,
                durationMs: durationMs,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$McpActivityRecordsTableProcessedTableManager =
    ProcessedTableManager<
      _$McpDatabase,
      $McpActivityRecordsTable,
      McpActivityRecord,
      $$McpActivityRecordsTableFilterComposer,
      $$McpActivityRecordsTableOrderingComposer,
      $$McpActivityRecordsTableAnnotationComposer,
      $$McpActivityRecordsTableCreateCompanionBuilder,
      $$McpActivityRecordsTableUpdateCompanionBuilder,
      (
        McpActivityRecord,
        BaseReferences<
          _$McpDatabase,
          $McpActivityRecordsTable,
          McpActivityRecord
        >,
      ),
      McpActivityRecord,
      PrefetchHooks Function()
    >;

class $McpDatabaseManager {
  final _$McpDatabase _db;
  $McpDatabaseManager(this._db);
  $$McpActivityRecordsTableTableManager get mcpActivityRecords =>
      $$McpActivityRecordsTableTableManager(_db, _db.mcpActivityRecords);
}

mixin _$McpActivityDaoMixin on DatabaseAccessor<McpDatabase> {
  $McpActivityRecordsTable get mcpActivityRecords =>
      attachedDatabase.mcpActivityRecords;
  McpActivityDaoManager get managers => McpActivityDaoManager(this);
}

class McpActivityDaoManager {
  final _$McpActivityDaoMixin _db;
  McpActivityDaoManager(this._db);
  $$McpActivityRecordsTableTableManager get mcpActivityRecords =>
      $$McpActivityRecordsTableTableManager(
        _db.attachedDatabase,
        _db.mcpActivityRecords,
      );
}
