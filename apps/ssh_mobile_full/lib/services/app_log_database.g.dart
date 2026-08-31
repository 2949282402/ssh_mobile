// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_log_database.dart';

// ignore_for_file: type=lint
class $AppLogRecordsTable extends AppLogRecords
    with TableInfo<$AppLogRecordsTable, AppLogRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AppLogRecordsTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _timeMeta = const VerificationMeta('time');
  @override
  late final GeneratedColumn<int> time = GeneratedColumn<int>(
    'time',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _levelMeta = const VerificationMeta('level');
  @override
  late final GeneratedColumn<String> level = GeneratedColumn<String>(
    'level',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _messageMeta = const VerificationMeta(
    'message',
  );
  @override
  late final GeneratedColumn<String> message = GeneratedColumn<String>(
    'message',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceLocationMeta = const VerificationMeta(
    'sourceLocation',
  );
  @override
  late final GeneratedColumn<String> sourceLocation = GeneratedColumn<String>(
    'source_location',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _stackTraceMeta = const VerificationMeta(
    'stackTrace',
  );
  @override
  late final GeneratedColumn<String> stackTrace = GeneratedColumn<String>(
    'stack_trace',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _detailsMeta = const VerificationMeta(
    'details',
  );
  @override
  late final GeneratedColumn<String> details = GeneratedColumn<String>(
    'details',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    time,
    level,
    message,
    sourceLocation,
    stackTrace,
    details,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'app_log_records';
  @override
  VerificationContext validateIntegrity(
    Insertable<AppLogRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('time')) {
      context.handle(
        _timeMeta,
        time.isAcceptableOrUnknown(data['time']!, _timeMeta),
      );
    } else if (isInserting) {
      context.missing(_timeMeta);
    }
    if (data.containsKey('level')) {
      context.handle(
        _levelMeta,
        level.isAcceptableOrUnknown(data['level']!, _levelMeta),
      );
    } else if (isInserting) {
      context.missing(_levelMeta);
    }
    if (data.containsKey('message')) {
      context.handle(
        _messageMeta,
        message.isAcceptableOrUnknown(data['message']!, _messageMeta),
      );
    } else if (isInserting) {
      context.missing(_messageMeta);
    }
    if (data.containsKey('source_location')) {
      context.handle(
        _sourceLocationMeta,
        sourceLocation.isAcceptableOrUnknown(
          data['source_location']!,
          _sourceLocationMeta,
        ),
      );
    }
    if (data.containsKey('stack_trace')) {
      context.handle(
        _stackTraceMeta,
        stackTrace.isAcceptableOrUnknown(data['stack_trace']!, _stackTraceMeta),
      );
    }
    if (data.containsKey('details')) {
      context.handle(
        _detailsMeta,
        details.isAcceptableOrUnknown(data['details']!, _detailsMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AppLogRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AppLogRecord(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      time: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}time'],
      )!,
      level: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}level'],
      )!,
      message: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message'],
      )!,
      sourceLocation: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_location'],
      ),
      stackTrace: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}stack_trace'],
      ),
      details: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}details'],
      ),
    );
  }

  @override
  $AppLogRecordsTable createAlias(String alias) {
    return $AppLogRecordsTable(attachedDatabase, alias);
  }
}

class AppLogRecord extends DataClass implements Insertable<AppLogRecord> {
  final int id;
  final int time;
  final String level;
  final String message;
  final String? sourceLocation;
  final String? stackTrace;
  final String? details;
  const AppLogRecord({
    required this.id,
    required this.time,
    required this.level,
    required this.message,
    this.sourceLocation,
    this.stackTrace,
    this.details,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['time'] = Variable<int>(time);
    map['level'] = Variable<String>(level);
    map['message'] = Variable<String>(message);
    if (!nullToAbsent || sourceLocation != null) {
      map['source_location'] = Variable<String>(sourceLocation);
    }
    if (!nullToAbsent || stackTrace != null) {
      map['stack_trace'] = Variable<String>(stackTrace);
    }
    if (!nullToAbsent || details != null) {
      map['details'] = Variable<String>(details);
    }
    return map;
  }

  AppLogRecordsCompanion toCompanion(bool nullToAbsent) {
    return AppLogRecordsCompanion(
      id: Value(id),
      time: Value(time),
      level: Value(level),
      message: Value(message),
      sourceLocation: sourceLocation == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceLocation),
      stackTrace: stackTrace == null && nullToAbsent
          ? const Value.absent()
          : Value(stackTrace),
      details: details == null && nullToAbsent
          ? const Value.absent()
          : Value(details),
    );
  }

  factory AppLogRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AppLogRecord(
      id: serializer.fromJson<int>(json['id']),
      time: serializer.fromJson<int>(json['time']),
      level: serializer.fromJson<String>(json['level']),
      message: serializer.fromJson<String>(json['message']),
      sourceLocation: serializer.fromJson<String?>(json['sourceLocation']),
      stackTrace: serializer.fromJson<String?>(json['stackTrace']),
      details: serializer.fromJson<String?>(json['details']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'time': serializer.toJson<int>(time),
      'level': serializer.toJson<String>(level),
      'message': serializer.toJson<String>(message),
      'sourceLocation': serializer.toJson<String?>(sourceLocation),
      'stackTrace': serializer.toJson<String?>(stackTrace),
      'details': serializer.toJson<String?>(details),
    };
  }

  AppLogRecord copyWith({
    int? id,
    int? time,
    String? level,
    String? message,
    Value<String?> sourceLocation = const Value.absent(),
    Value<String?> stackTrace = const Value.absent(),
    Value<String?> details = const Value.absent(),
  }) => AppLogRecord(
    id: id ?? this.id,
    time: time ?? this.time,
    level: level ?? this.level,
    message: message ?? this.message,
    sourceLocation: sourceLocation.present
        ? sourceLocation.value
        : this.sourceLocation,
    stackTrace: stackTrace.present ? stackTrace.value : this.stackTrace,
    details: details.present ? details.value : this.details,
  );
  AppLogRecord copyWithCompanion(AppLogRecordsCompanion data) {
    return AppLogRecord(
      id: data.id.present ? data.id.value : this.id,
      time: data.time.present ? data.time.value : this.time,
      level: data.level.present ? data.level.value : this.level,
      message: data.message.present ? data.message.value : this.message,
      sourceLocation: data.sourceLocation.present
          ? data.sourceLocation.value
          : this.sourceLocation,
      stackTrace: data.stackTrace.present
          ? data.stackTrace.value
          : this.stackTrace,
      details: data.details.present ? data.details.value : this.details,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AppLogRecord(')
          ..write('id: $id, ')
          ..write('time: $time, ')
          ..write('level: $level, ')
          ..write('message: $message, ')
          ..write('sourceLocation: $sourceLocation, ')
          ..write('stackTrace: $stackTrace, ')
          ..write('details: $details')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    time,
    level,
    message,
    sourceLocation,
    stackTrace,
    details,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AppLogRecord &&
          other.id == this.id &&
          other.time == this.time &&
          other.level == this.level &&
          other.message == this.message &&
          other.sourceLocation == this.sourceLocation &&
          other.stackTrace == this.stackTrace &&
          other.details == this.details);
}

class AppLogRecordsCompanion extends UpdateCompanion<AppLogRecord> {
  final Value<int> id;
  final Value<int> time;
  final Value<String> level;
  final Value<String> message;
  final Value<String?> sourceLocation;
  final Value<String?> stackTrace;
  final Value<String?> details;
  const AppLogRecordsCompanion({
    this.id = const Value.absent(),
    this.time = const Value.absent(),
    this.level = const Value.absent(),
    this.message = const Value.absent(),
    this.sourceLocation = const Value.absent(),
    this.stackTrace = const Value.absent(),
    this.details = const Value.absent(),
  });
  AppLogRecordsCompanion.insert({
    this.id = const Value.absent(),
    required int time,
    required String level,
    required String message,
    this.sourceLocation = const Value.absent(),
    this.stackTrace = const Value.absent(),
    this.details = const Value.absent(),
  }) : time = Value(time),
       level = Value(level),
       message = Value(message);
  static Insertable<AppLogRecord> custom({
    Expression<int>? id,
    Expression<int>? time,
    Expression<String>? level,
    Expression<String>? message,
    Expression<String>? sourceLocation,
    Expression<String>? stackTrace,
    Expression<String>? details,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (time != null) 'time': time,
      if (level != null) 'level': level,
      if (message != null) 'message': message,
      if (sourceLocation != null) 'source_location': sourceLocation,
      if (stackTrace != null) 'stack_trace': stackTrace,
      if (details != null) 'details': details,
    });
  }

  AppLogRecordsCompanion copyWith({
    Value<int>? id,
    Value<int>? time,
    Value<String>? level,
    Value<String>? message,
    Value<String?>? sourceLocation,
    Value<String?>? stackTrace,
    Value<String?>? details,
  }) {
    return AppLogRecordsCompanion(
      id: id ?? this.id,
      time: time ?? this.time,
      level: level ?? this.level,
      message: message ?? this.message,
      sourceLocation: sourceLocation ?? this.sourceLocation,
      stackTrace: stackTrace ?? this.stackTrace,
      details: details ?? this.details,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (time.present) {
      map['time'] = Variable<int>(time.value);
    }
    if (level.present) {
      map['level'] = Variable<String>(level.value);
    }
    if (message.present) {
      map['message'] = Variable<String>(message.value);
    }
    if (sourceLocation.present) {
      map['source_location'] = Variable<String>(sourceLocation.value);
    }
    if (stackTrace.present) {
      map['stack_trace'] = Variable<String>(stackTrace.value);
    }
    if (details.present) {
      map['details'] = Variable<String>(details.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AppLogRecordsCompanion(')
          ..write('id: $id, ')
          ..write('time: $time, ')
          ..write('level: $level, ')
          ..write('message: $message, ')
          ..write('sourceLocation: $sourceLocation, ')
          ..write('stackTrace: $stackTrace, ')
          ..write('details: $details')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppLogDatabase extends GeneratedDatabase {
  _$AppLogDatabase(QueryExecutor e) : super(e);
  $AppLogDatabaseManager get managers => $AppLogDatabaseManager(this);
  late final $AppLogRecordsTable appLogRecords = $AppLogRecordsTable(this);
  late final Index idxAppLogTime = Index(
    'idx_app_log_time',
    'CREATE INDEX idx_app_log_time ON app_log_records (time DESC)',
  );
  late final AppLogDao appLogDao = AppLogDao(this as AppLogDatabase);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    appLogRecords,
    idxAppLogTime,
  ];
}

typedef $$AppLogRecordsTableCreateCompanionBuilder =
    AppLogRecordsCompanion Function({
      Value<int> id,
      required int time,
      required String level,
      required String message,
      Value<String?> sourceLocation,
      Value<String?> stackTrace,
      Value<String?> details,
    });
typedef $$AppLogRecordsTableUpdateCompanionBuilder =
    AppLogRecordsCompanion Function({
      Value<int> id,
      Value<int> time,
      Value<String> level,
      Value<String> message,
      Value<String?> sourceLocation,
      Value<String?> stackTrace,
      Value<String?> details,
    });

class $$AppLogRecordsTableFilterComposer
    extends Composer<_$AppLogDatabase, $AppLogRecordsTable> {
  $$AppLogRecordsTableFilterComposer({
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

  ColumnFilters<int> get time => $composableBuilder(
    column: $table.time,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get level => $composableBuilder(
    column: $table.level,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get message => $composableBuilder(
    column: $table.message,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceLocation => $composableBuilder(
    column: $table.sourceLocation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stackTrace => $composableBuilder(
    column: $table.stackTrace,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get details => $composableBuilder(
    column: $table.details,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AppLogRecordsTableOrderingComposer
    extends Composer<_$AppLogDatabase, $AppLogRecordsTable> {
  $$AppLogRecordsTableOrderingComposer({
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

  ColumnOrderings<int> get time => $composableBuilder(
    column: $table.time,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get level => $composableBuilder(
    column: $table.level,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get message => $composableBuilder(
    column: $table.message,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceLocation => $composableBuilder(
    column: $table.sourceLocation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stackTrace => $composableBuilder(
    column: $table.stackTrace,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get details => $composableBuilder(
    column: $table.details,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AppLogRecordsTableAnnotationComposer
    extends Composer<_$AppLogDatabase, $AppLogRecordsTable> {
  $$AppLogRecordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get time =>
      $composableBuilder(column: $table.time, builder: (column) => column);

  GeneratedColumn<String> get level =>
      $composableBuilder(column: $table.level, builder: (column) => column);

  GeneratedColumn<String> get message =>
      $composableBuilder(column: $table.message, builder: (column) => column);

  GeneratedColumn<String> get sourceLocation => $composableBuilder(
    column: $table.sourceLocation,
    builder: (column) => column,
  );

  GeneratedColumn<String> get stackTrace => $composableBuilder(
    column: $table.stackTrace,
    builder: (column) => column,
  );

  GeneratedColumn<String> get details =>
      $composableBuilder(column: $table.details, builder: (column) => column);
}

class $$AppLogRecordsTableTableManager
    extends
        RootTableManager<
          _$AppLogDatabase,
          $AppLogRecordsTable,
          AppLogRecord,
          $$AppLogRecordsTableFilterComposer,
          $$AppLogRecordsTableOrderingComposer,
          $$AppLogRecordsTableAnnotationComposer,
          $$AppLogRecordsTableCreateCompanionBuilder,
          $$AppLogRecordsTableUpdateCompanionBuilder,
          (
            AppLogRecord,
            BaseReferences<_$AppLogDatabase, $AppLogRecordsTable, AppLogRecord>,
          ),
          AppLogRecord,
          PrefetchHooks Function()
        > {
  $$AppLogRecordsTableTableManager(
    _$AppLogDatabase db,
    $AppLogRecordsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AppLogRecordsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AppLogRecordsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AppLogRecordsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> time = const Value.absent(),
                Value<String> level = const Value.absent(),
                Value<String> message = const Value.absent(),
                Value<String?> sourceLocation = const Value.absent(),
                Value<String?> stackTrace = const Value.absent(),
                Value<String?> details = const Value.absent(),
              }) => AppLogRecordsCompanion(
                id: id,
                time: time,
                level: level,
                message: message,
                sourceLocation: sourceLocation,
                stackTrace: stackTrace,
                details: details,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int time,
                required String level,
                required String message,
                Value<String?> sourceLocation = const Value.absent(),
                Value<String?> stackTrace = const Value.absent(),
                Value<String?> details = const Value.absent(),
              }) => AppLogRecordsCompanion.insert(
                id: id,
                time: time,
                level: level,
                message: message,
                sourceLocation: sourceLocation,
                stackTrace: stackTrace,
                details: details,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AppLogRecordsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppLogDatabase,
      $AppLogRecordsTable,
      AppLogRecord,
      $$AppLogRecordsTableFilterComposer,
      $$AppLogRecordsTableOrderingComposer,
      $$AppLogRecordsTableAnnotationComposer,
      $$AppLogRecordsTableCreateCompanionBuilder,
      $$AppLogRecordsTableUpdateCompanionBuilder,
      (
        AppLogRecord,
        BaseReferences<_$AppLogDatabase, $AppLogRecordsTable, AppLogRecord>,
      ),
      AppLogRecord,
      PrefetchHooks Function()
    >;

class $AppLogDatabaseManager {
  final _$AppLogDatabase _db;
  $AppLogDatabaseManager(this._db);
  $$AppLogRecordsTableTableManager get appLogRecords =>
      $$AppLogRecordsTableTableManager(_db, _db.appLogRecords);
}

mixin _$AppLogDaoMixin on DatabaseAccessor<AppLogDatabase> {
  $AppLogRecordsTable get appLogRecords => attachedDatabase.appLogRecords;
  AppLogDaoManager get managers => AppLogDaoManager(this);
}

class AppLogDaoManager {
  final _$AppLogDaoMixin _db;
  AppLogDaoManager(this._db);
  $$AppLogRecordsTableTableManager get appLogRecords =>
      $$AppLogRecordsTableTableManager(_db.attachedDatabase, _db.appLogRecords);
}
