// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'terminal_database.dart';

// ignore_for_file: type=lint
class $TerminalHistoryTable extends TerminalHistory
    with TableInfo<$TerminalHistoryTable, TerminalHistoryData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TerminalHistoryTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sessionIdMeta = const VerificationMeta(
    'sessionId',
  );
  @override
  late final GeneratedColumn<String> sessionId = GeneratedColumn<String>(
    'session_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _connectionIdMeta = const VerificationMeta(
    'connectionId',
  );
  @override
  late final GeneratedColumn<String> connectionId = GeneratedColumn<String>(
    'connection_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _connectionNameMeta = const VerificationMeta(
    'connectionName',
  );
  @override
  late final GeneratedColumn<String> connectionName = GeneratedColumn<String>(
    'connection_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _tmuxSessionNameMeta = const VerificationMeta(
    'tmuxSessionName',
  );
  @override
  late final GeneratedColumn<String> tmuxSessionName = GeneratedColumn<String>(
    'tmux_session_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
    'state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _errorMessageMeta = const VerificationMeta(
    'errorMessage',
  );
  @override
  late final GeneratedColumn<String> errorMessage = GeneratedColumn<String>(
    'error_message',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    sessionId,
    connectionId,
    connectionName,
    displayName,
    tmuxSessionName,
    state,
    errorMessage,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'terminal_history';
  @override
  VerificationContext validateIntegrity(
    Insertable<TerminalHistoryData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('session_id')) {
      context.handle(
        _sessionIdMeta,
        sessionId.isAcceptableOrUnknown(data['session_id']!, _sessionIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sessionIdMeta);
    }
    if (data.containsKey('connection_id')) {
      context.handle(
        _connectionIdMeta,
        connectionId.isAcceptableOrUnknown(
          data['connection_id']!,
          _connectionIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_connectionIdMeta);
    }
    if (data.containsKey('connection_name')) {
      context.handle(
        _connectionNameMeta,
        connectionName.isAcceptableOrUnknown(
          data['connection_name']!,
          _connectionNameMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_connectionNameMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_displayNameMeta);
    }
    if (data.containsKey('tmux_session_name')) {
      context.handle(
        _tmuxSessionNameMeta,
        tmuxSessionName.isAcceptableOrUnknown(
          data['tmux_session_name']!,
          _tmuxSessionNameMeta,
        ),
      );
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    } else if (isInserting) {
      context.missing(_stateMeta);
    }
    if (data.containsKey('error_message')) {
      context.handle(
        _errorMessageMeta,
        errorMessage.isAcceptableOrUnknown(
          data['error_message']!,
          _errorMessageMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {sessionId};
  @override
  TerminalHistoryData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TerminalHistoryData(
      sessionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}session_id'],
      )!,
      connectionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}connection_id'],
      )!,
      connectionName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}connection_name'],
      )!,
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      )!,
      tmuxSessionName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tmux_session_name'],
      ),
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state'],
      )!,
      errorMessage: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}error_message'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $TerminalHistoryTable createAlias(String alias) {
    return $TerminalHistoryTable(attachedDatabase, alias);
  }
}

class TerminalHistoryData extends DataClass
    implements Insertable<TerminalHistoryData> {
  final String sessionId;
  final String connectionId;
  final String connectionName;
  final String displayName;
  final String? tmuxSessionName;
  final String state;
  final String? errorMessage;
  final int createdAt;
  final int updatedAt;
  const TerminalHistoryData({
    required this.sessionId,
    required this.connectionId,
    required this.connectionName,
    required this.displayName,
    this.tmuxSessionName,
    required this.state,
    this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['session_id'] = Variable<String>(sessionId);
    map['connection_id'] = Variable<String>(connectionId);
    map['connection_name'] = Variable<String>(connectionName);
    map['display_name'] = Variable<String>(displayName);
    if (!nullToAbsent || tmuxSessionName != null) {
      map['tmux_session_name'] = Variable<String>(tmuxSessionName);
    }
    map['state'] = Variable<String>(state);
    if (!nullToAbsent || errorMessage != null) {
      map['error_message'] = Variable<String>(errorMessage);
    }
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  TerminalHistoryCompanion toCompanion(bool nullToAbsent) {
    return TerminalHistoryCompanion(
      sessionId: Value(sessionId),
      connectionId: Value(connectionId),
      connectionName: Value(connectionName),
      displayName: Value(displayName),
      tmuxSessionName: tmuxSessionName == null && nullToAbsent
          ? const Value.absent()
          : Value(tmuxSessionName),
      state: Value(state),
      errorMessage: errorMessage == null && nullToAbsent
          ? const Value.absent()
          : Value(errorMessage),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory TerminalHistoryData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TerminalHistoryData(
      sessionId: serializer.fromJson<String>(json['sessionId']),
      connectionId: serializer.fromJson<String>(json['connectionId']),
      connectionName: serializer.fromJson<String>(json['connectionName']),
      displayName: serializer.fromJson<String>(json['displayName']),
      tmuxSessionName: serializer.fromJson<String?>(json['tmuxSessionName']),
      state: serializer.fromJson<String>(json['state']),
      errorMessage: serializer.fromJson<String?>(json['errorMessage']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'sessionId': serializer.toJson<String>(sessionId),
      'connectionId': serializer.toJson<String>(connectionId),
      'connectionName': serializer.toJson<String>(connectionName),
      'displayName': serializer.toJson<String>(displayName),
      'tmuxSessionName': serializer.toJson<String?>(tmuxSessionName),
      'state': serializer.toJson<String>(state),
      'errorMessage': serializer.toJson<String?>(errorMessage),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  TerminalHistoryData copyWith({
    String? sessionId,
    String? connectionId,
    String? connectionName,
    String? displayName,
    Value<String?> tmuxSessionName = const Value.absent(),
    String? state,
    Value<String?> errorMessage = const Value.absent(),
    int? createdAt,
    int? updatedAt,
  }) => TerminalHistoryData(
    sessionId: sessionId ?? this.sessionId,
    connectionId: connectionId ?? this.connectionId,
    connectionName: connectionName ?? this.connectionName,
    displayName: displayName ?? this.displayName,
    tmuxSessionName: tmuxSessionName.present
        ? tmuxSessionName.value
        : this.tmuxSessionName,
    state: state ?? this.state,
    errorMessage: errorMessage.present ? errorMessage.value : this.errorMessage,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  TerminalHistoryData copyWithCompanion(TerminalHistoryCompanion data) {
    return TerminalHistoryData(
      sessionId: data.sessionId.present ? data.sessionId.value : this.sessionId,
      connectionId: data.connectionId.present
          ? data.connectionId.value
          : this.connectionId,
      connectionName: data.connectionName.present
          ? data.connectionName.value
          : this.connectionName,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      tmuxSessionName: data.tmuxSessionName.present
          ? data.tmuxSessionName.value
          : this.tmuxSessionName,
      state: data.state.present ? data.state.value : this.state,
      errorMessage: data.errorMessage.present
          ? data.errorMessage.value
          : this.errorMessage,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TerminalHistoryData(')
          ..write('sessionId: $sessionId, ')
          ..write('connectionId: $connectionId, ')
          ..write('connectionName: $connectionName, ')
          ..write('displayName: $displayName, ')
          ..write('tmuxSessionName: $tmuxSessionName, ')
          ..write('state: $state, ')
          ..write('errorMessage: $errorMessage, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    sessionId,
    connectionId,
    connectionName,
    displayName,
    tmuxSessionName,
    state,
    errorMessage,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TerminalHistoryData &&
          other.sessionId == this.sessionId &&
          other.connectionId == this.connectionId &&
          other.connectionName == this.connectionName &&
          other.displayName == this.displayName &&
          other.tmuxSessionName == this.tmuxSessionName &&
          other.state == this.state &&
          other.errorMessage == this.errorMessage &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class TerminalHistoryCompanion extends UpdateCompanion<TerminalHistoryData> {
  final Value<String> sessionId;
  final Value<String> connectionId;
  final Value<String> connectionName;
  final Value<String> displayName;
  final Value<String?> tmuxSessionName;
  final Value<String> state;
  final Value<String?> errorMessage;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const TerminalHistoryCompanion({
    this.sessionId = const Value.absent(),
    this.connectionId = const Value.absent(),
    this.connectionName = const Value.absent(),
    this.displayName = const Value.absent(),
    this.tmuxSessionName = const Value.absent(),
    this.state = const Value.absent(),
    this.errorMessage = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TerminalHistoryCompanion.insert({
    required String sessionId,
    required String connectionId,
    required String connectionName,
    required String displayName,
    this.tmuxSessionName = const Value.absent(),
    required String state,
    this.errorMessage = const Value.absent(),
    required int createdAt,
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : sessionId = Value(sessionId),
       connectionId = Value(connectionId),
       connectionName = Value(connectionName),
       displayName = Value(displayName),
       state = Value(state),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<TerminalHistoryData> custom({
    Expression<String>? sessionId,
    Expression<String>? connectionId,
    Expression<String>? connectionName,
    Expression<String>? displayName,
    Expression<String>? tmuxSessionName,
    Expression<String>? state,
    Expression<String>? errorMessage,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (sessionId != null) 'session_id': sessionId,
      if (connectionId != null) 'connection_id': connectionId,
      if (connectionName != null) 'connection_name': connectionName,
      if (displayName != null) 'display_name': displayName,
      if (tmuxSessionName != null) 'tmux_session_name': tmuxSessionName,
      if (state != null) 'state': state,
      if (errorMessage != null) 'error_message': errorMessage,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TerminalHistoryCompanion copyWith({
    Value<String>? sessionId,
    Value<String>? connectionId,
    Value<String>? connectionName,
    Value<String>? displayName,
    Value<String?>? tmuxSessionName,
    Value<String>? state,
    Value<String?>? errorMessage,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return TerminalHistoryCompanion(
      sessionId: sessionId ?? this.sessionId,
      connectionId: connectionId ?? this.connectionId,
      connectionName: connectionName ?? this.connectionName,
      displayName: displayName ?? this.displayName,
      tmuxSessionName: tmuxSessionName ?? this.tmuxSessionName,
      state: state ?? this.state,
      errorMessage: errorMessage ?? this.errorMessage,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (sessionId.present) {
      map['session_id'] = Variable<String>(sessionId.value);
    }
    if (connectionId.present) {
      map['connection_id'] = Variable<String>(connectionId.value);
    }
    if (connectionName.present) {
      map['connection_name'] = Variable<String>(connectionName.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (tmuxSessionName.present) {
      map['tmux_session_name'] = Variable<String>(tmuxSessionName.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (errorMessage.present) {
      map['error_message'] = Variable<String>(errorMessage.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TerminalHistoryCompanion(')
          ..write('sessionId: $sessionId, ')
          ..write('connectionId: $connectionId, ')
          ..write('connectionName: $connectionName, ')
          ..write('displayName: $displayName, ')
          ..write('tmuxSessionName: $tmuxSessionName, ')
          ..write('state: $state, ')
          ..write('errorMessage: $errorMessage, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$TerminalDatabase extends GeneratedDatabase {
  _$TerminalDatabase(QueryExecutor e) : super(e);
  $TerminalDatabaseManager get managers => $TerminalDatabaseManager(this);
  late final $TerminalHistoryTable terminalHistory = $TerminalHistoryTable(
    this,
  );
  late final Index idxTerminalHistoryUpdatedAt = Index(
    'idx_terminal_history_updated_at',
    'CREATE INDEX idx_terminal_history_updated_at ON terminal_history (updated_at DESC)',
  );
  late final Index idxTerminalHistoryConnectionId = Index(
    'idx_terminal_history_connection_id',
    'CREATE INDEX idx_terminal_history_connection_id ON terminal_history (connection_id)',
  );
  late final Index idxTerminalHistoryState = Index(
    'idx_terminal_history_state',
    'CREATE INDEX idx_terminal_history_state ON terminal_history (state)',
  );
  late final TerminalHistoryDao terminalHistoryDao = TerminalHistoryDao(
    this as TerminalDatabase,
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    terminalHistory,
    idxTerminalHistoryUpdatedAt,
    idxTerminalHistoryConnectionId,
    idxTerminalHistoryState,
  ];
}

typedef $$TerminalHistoryTableCreateCompanionBuilder =
    TerminalHistoryCompanion Function({
      required String sessionId,
      required String connectionId,
      required String connectionName,
      required String displayName,
      Value<String?> tmuxSessionName,
      required String state,
      Value<String?> errorMessage,
      required int createdAt,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$TerminalHistoryTableUpdateCompanionBuilder =
    TerminalHistoryCompanion Function({
      Value<String> sessionId,
      Value<String> connectionId,
      Value<String> connectionName,
      Value<String> displayName,
      Value<String?> tmuxSessionName,
      Value<String> state,
      Value<String?> errorMessage,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int> rowid,
    });

class $$TerminalHistoryTableFilterComposer
    extends Composer<_$TerminalDatabase, $TerminalHistoryTable> {
  $$TerminalHistoryTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get sessionId => $composableBuilder(
    column: $table.sessionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get connectionId => $composableBuilder(
    column: $table.connectionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get connectionName => $composableBuilder(
    column: $table.connectionName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tmuxSessionName => $composableBuilder(
    column: $table.tmuxSessionName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get errorMessage => $composableBuilder(
    column: $table.errorMessage,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TerminalHistoryTableOrderingComposer
    extends Composer<_$TerminalDatabase, $TerminalHistoryTable> {
  $$TerminalHistoryTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get sessionId => $composableBuilder(
    column: $table.sessionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get connectionId => $composableBuilder(
    column: $table.connectionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get connectionName => $composableBuilder(
    column: $table.connectionName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tmuxSessionName => $composableBuilder(
    column: $table.tmuxSessionName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get errorMessage => $composableBuilder(
    column: $table.errorMessage,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TerminalHistoryTableAnnotationComposer
    extends Composer<_$TerminalDatabase, $TerminalHistoryTable> {
  $$TerminalHistoryTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get sessionId =>
      $composableBuilder(column: $table.sessionId, builder: (column) => column);

  GeneratedColumn<String> get connectionId => $composableBuilder(
    column: $table.connectionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get connectionName => $composableBuilder(
    column: $table.connectionName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get tmuxSessionName => $composableBuilder(
    column: $table.tmuxSessionName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<String> get errorMessage => $composableBuilder(
    column: $table.errorMessage,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$TerminalHistoryTableTableManager
    extends
        RootTableManager<
          _$TerminalDatabase,
          $TerminalHistoryTable,
          TerminalHistoryData,
          $$TerminalHistoryTableFilterComposer,
          $$TerminalHistoryTableOrderingComposer,
          $$TerminalHistoryTableAnnotationComposer,
          $$TerminalHistoryTableCreateCompanionBuilder,
          $$TerminalHistoryTableUpdateCompanionBuilder,
          (
            TerminalHistoryData,
            BaseReferences<
              _$TerminalDatabase,
              $TerminalHistoryTable,
              TerminalHistoryData
            >,
          ),
          TerminalHistoryData,
          PrefetchHooks Function()
        > {
  $$TerminalHistoryTableTableManager(
    _$TerminalDatabase db,
    $TerminalHistoryTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TerminalHistoryTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TerminalHistoryTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TerminalHistoryTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> sessionId = const Value.absent(),
                Value<String> connectionId = const Value.absent(),
                Value<String> connectionName = const Value.absent(),
                Value<String> displayName = const Value.absent(),
                Value<String?> tmuxSessionName = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<String?> errorMessage = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TerminalHistoryCompanion(
                sessionId: sessionId,
                connectionId: connectionId,
                connectionName: connectionName,
                displayName: displayName,
                tmuxSessionName: tmuxSessionName,
                state: state,
                errorMessage: errorMessage,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String sessionId,
                required String connectionId,
                required String connectionName,
                required String displayName,
                Value<String?> tmuxSessionName = const Value.absent(),
                required String state,
                Value<String?> errorMessage = const Value.absent(),
                required int createdAt,
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => TerminalHistoryCompanion.insert(
                sessionId: sessionId,
                connectionId: connectionId,
                connectionName: connectionName,
                displayName: displayName,
                tmuxSessionName: tmuxSessionName,
                state: state,
                errorMessage: errorMessage,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TerminalHistoryTableProcessedTableManager =
    ProcessedTableManager<
      _$TerminalDatabase,
      $TerminalHistoryTable,
      TerminalHistoryData,
      $$TerminalHistoryTableFilterComposer,
      $$TerminalHistoryTableOrderingComposer,
      $$TerminalHistoryTableAnnotationComposer,
      $$TerminalHistoryTableCreateCompanionBuilder,
      $$TerminalHistoryTableUpdateCompanionBuilder,
      (
        TerminalHistoryData,
        BaseReferences<
          _$TerminalDatabase,
          $TerminalHistoryTable,
          TerminalHistoryData
        >,
      ),
      TerminalHistoryData,
      PrefetchHooks Function()
    >;

class $TerminalDatabaseManager {
  final _$TerminalDatabase _db;
  $TerminalDatabaseManager(this._db);
  $$TerminalHistoryTableTableManager get terminalHistory =>
      $$TerminalHistoryTableTableManager(_db, _db.terminalHistory);
}

mixin _$TerminalHistoryDaoMixin on DatabaseAccessor<TerminalDatabase> {
  $TerminalHistoryTable get terminalHistory => attachedDatabase.terminalHistory;
  TerminalHistoryDaoManager get managers => TerminalHistoryDaoManager(this);
}

class TerminalHistoryDaoManager {
  final _$TerminalHistoryDaoMixin _db;
  TerminalHistoryDaoManager(this._db);
  $$TerminalHistoryTableTableManager get terminalHistory =>
      $$TerminalHistoryTableTableManager(
        _db.attachedDatabase,
        _db.terminalHistory,
      );
}
